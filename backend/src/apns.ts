// APNs provider-token sending, from a Cloudflare Worker.
//
// Apple's HTTP/2 API wants a short-lived ES256 JWT signed with a .p8 key rather
// than a certificate. That maps cleanly onto WebCrypto: ECDSA over P-256 with
// SHA-256 produces the raw r‖s pair, which *is* the JWS ES256 signature — no
// DER unwrapping needed, unlike Node's crypto.
//
// Everything is gated on four secrets. Missing any of them is reported as an
// unconfigured provider rather than thrown, so the iOS app can register tokens
// and ship before the Apple Developer account exists; adding the secrets turns
// delivery on with no code change.
//
//   npx wrangler secret put APNS_KEY_ID       # the 10-char Key ID
//   npx wrangler secret put APNS_TEAM_ID      # the 10-char Team ID
//   npx wrangler secret put APNS_PRIVATE_KEY  # contents of AuthKey_XXXX.p8
//   npx wrangler secret put APNS_BUNDLE_ID    # com.eduardcazacu.instant

export type ApnsConfig = {
  apnsKeyId?: string | null;
  apnsTeamId?: string | null;
  apnsPrivateKey?: string | null;
  apnsBundleId?: string | null;
};

export type ResolvedApnsConfig = {
  keyId: string;
  teamId: string;
  privateKey: string;
  bundleId: string;
};

export type ApnsPayload = {
  title: string;
  body: string;
  data?: Record<string, unknown>;
};

export type ApnsSendResult = {
  statusCode: number | null;
  reason?: string;
  success: boolean;
  /** Apple says this token is dead and the row should go. */
  shouldDeleteSubscription: boolean;
};

export const APNS_PRODUCTION_HOST = "https://api.push.apple.com";
export const APNS_SANDBOX_HOST = "https://api.sandbox.push.apple.com";

/** Apple rejects tokens older than an hour and rate-limits minting them. */
const TOKEN_LIFETIME_MS = 50 * 60 * 1000;

export function resolveApnsConfig(config: ApnsConfig): ResolvedApnsConfig | null {
  const keyId = config.apnsKeyId?.trim();
  const teamId = config.apnsTeamId?.trim();
  const privateKey = config.apnsPrivateKey?.trim();
  const bundleId = config.apnsBundleId?.trim();
  if (!keyId || !teamId || !privateKey || !bundleId) {
    return null;
  }
  return { keyId, teamId, privateKey, bundleId };
}

/**
 * Development builds talk to the sandbox and TestFlight/App Store builds talk to
 * production; the same device token is not valid in both. The environment is
 * encoded in `provider` so the two can live in one table without a migration.
 */
export function apnsHostForProvider(provider: string): string {
  return provider === "apns-sandbox" ? APNS_SANDBOX_HOST : APNS_PRODUCTION_HOST;
}

export function isApnsProvider(provider: string): boolean {
  return provider === "apns" || provider === "apns-sandbox";
}

function base64Url(bytes: ArrayBuffer | Uint8Array): string {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let binary = "";
  for (const byte of view) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Strips the PEM armour and decodes the PKCS#8 body. */
export function decodePkcs8(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

export async function signProviderToken(
  config: ResolvedApnsConfig,
  issuedAtSeconds: number
): Promise<string> {
  const header = base64Url(
    new TextEncoder().encode(JSON.stringify({ alg: "ES256", kid: config.keyId, typ: "JWT" }))
  );
  const claims = base64Url(
    new TextEncoder().encode(JSON.stringify({ iss: config.teamId, iat: issuedAtSeconds }))
  );

  const key = await crypto.subtle.importKey(
    "pkcs8",
    decodePkcs8(config.privateKey),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );

  // WebCrypto's ECDSA output is already the fixed-width r‖s that JWS wants.
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(`${header}.${claims}`)
  );

  return `${header}.${claims}.${base64Url(signature)}`;
}

type CachedToken = { token: string; issuedAtMs: number; keyId: string; teamId: string };
let cachedToken: CachedToken | null = null;

/** Exposed so tests can start from a known state. */
export function resetApnsTokenCache(): void {
  cachedToken = null;
}

export async function getProviderToken(
  config: ResolvedApnsConfig,
  nowMs: number = Date.now()
): Promise<string> {
  if (
    cachedToken &&
    cachedToken.keyId === config.keyId &&
    cachedToken.teamId === config.teamId &&
    nowMs - cachedToken.issuedAtMs < TOKEN_LIFETIME_MS
  ) {
    return cachedToken.token;
  }
  const token = await signProviderToken(config, Math.floor(nowMs / 1000));
  cachedToken = { token, issuedAtMs: nowMs, keyId: config.keyId, teamId: config.teamId };
  return token;
}

/**
 * A token Apple will never accept again. These mirror the 404/410 handling the
 * Web Push path already does: the subscription is dead, so drop the row rather
 * than retrying it every hour forever.
 */
const DEAD_TOKEN_REASONS = new Set([
  "BadDeviceToken",
  "Unregistered",
  "DeviceTokenNotForTopic",
  "ExpiredToken",
]);

export function isDeadTokenResponse(status: number, reason?: string): boolean {
  if (status === 410) return true;
  return status === 400 && reason !== undefined && DEAD_TOKEN_REASONS.has(reason);
}

export function buildApnsBody(payload: ApnsPayload): string {
  // Deliberately just enough to say who and to open the app. An Instant
  // notification cannot preview the photo: the server holds ciphertext and has
  // no key, so there is nothing to preview even in principle.
  return JSON.stringify({
    aps: {
      alert: { title: payload.title, body: payload.body },
      sound: "default",
    },
    data: payload.data ?? {},
  });
}

export async function sendApnsNotification(input: {
  config: ResolvedApnsConfig;
  deviceToken: string;
  provider: string;
  payload: ApnsPayload;
  /** Collapses repeat notifications for one instant into a single banner. */
  collapseId?: string;
  fetchImpl?: typeof fetch;
  nowMs?: number;
}): Promise<ApnsSendResult> {
  const doFetch = input.fetchImpl ?? fetch;
  const host = apnsHostForProvider(input.provider);

  let token: string;
  try {
    token = await getProviderToken(input.config, input.nowMs ?? Date.now());
  } catch (error) {
    return {
      statusCode: null,
      reason: error instanceof Error ? error.message : "Could not sign an APNs token",
      success: false,
      shouldDeleteSubscription: false,
    };
  }

  const headers: Record<string, string> = {
    authorization: `bearer ${token}`,
    "apns-topic": input.config.bundleId,
    "apns-push-type": "alert",
    "apns-priority": "10",
    "apns-expiration": "0",
    "content-type": "application/json",
  };
  if (input.collapseId) {
    // Apple caps this at 64 bytes.
    headers["apns-collapse-id"] = input.collapseId.slice(0, 64);
  }

  let response: Response;
  try {
    response = await doFetch(`${host}/3/device/${input.deviceToken}`, {
      method: "POST",
      headers,
      body: buildApnsBody(input.payload),
    });
  } catch (error) {
    return {
      statusCode: null,
      reason: error instanceof Error ? error.message : "APNs request failed",
      success: false,
      shouldDeleteSubscription: false,
    };
  }

  if (response.status === 200) {
    return { statusCode: 200, success: true, shouldDeleteSubscription: false };
  }

  let reason: string | undefined;
  try {
    const body = (await response.json()) as { reason?: string };
    reason = body?.reason;
  } catch {
    // Apple usually sends a JSON reason, but a proxy in between might not.
  }

  return {
    statusCode: response.status,
    reason,
    success: false,
    shouldDeleteSubscription: isDeadTokenResponse(response.status, reason),
  };
}
