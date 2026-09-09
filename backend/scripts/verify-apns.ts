// Checks the APNs sender against a stubbed Apple, end to end except for Apple.
//
//   cd backend && npx tsx scripts/verify-apns.ts
//
// This repo has no test runner, so this follows the same shape as the other
// verification scripts: exercise the real module, print each check, exit non-zero
// on failure. It generates its own throwaway P-256 key rather than needing a
// real .p8, so it runs with no Apple Developer account.

import {
  APNS_PRODUCTION_HOST,
  APNS_SANDBOX_HOST,
  apnsHostForProvider,
  buildApnsBody,
  decodePkcs8,
  isApnsProvider,
  isDeadTokenResponse,
  resetApnsTokenCache,
  resolveApnsConfig,
  sendApnsNotification,
  signProviderToken,
  type ResolvedApnsConfig,
} from "../src/apns";

let failures = 0;
let checks = 0;

function check(label: string, ok: boolean, detail?: unknown) {
  checks += 1;
  if (ok) {
    console.log(`  ok   ${label}`);
  } else {
    failures += 1;
    console.log(`  FAIL ${label}${detail === undefined ? "" : ` -> ${JSON.stringify(detail)}`}`);
  }
}

function fromBase64Url(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(padded + "=".repeat((4 - (padded.length % 4)) % 4));
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function toPem(der: ArrayBuffer): string {
  const bytes = new Uint8Array(der);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  const body = btoa(binary).match(/.{1,64}/g)!.join("\n");
  return `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----\n`;
}

async function main() {
  // A throwaway signing key standing in for AuthKey_XXXXXXXXXX.p8.
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"]
  );
  const pem = toPem(await crypto.subtle.exportKey("pkcs8", pair.privateKey));

  const config: ResolvedApnsConfig = {
    keyId: "ABCDE12345",
    teamId: "TEAM123456",
    privateKey: pem,
    bundleId: "com.eduardcazacu.instant",
  };

  console.log("\nconfiguration");
  check("all four secrets present resolves", resolveApnsConfig({
    apnsKeyId: "a", apnsTeamId: "b", apnsPrivateKey: "c", apnsBundleId: "d",
  }) !== null);
  // Partial config must not half-work: a missing bundle id would make every
  // request 400 with a topic mismatch nobody would connect to the cause.
  check("a missing secret resolves to null", resolveApnsConfig({
    apnsKeyId: "a", apnsTeamId: "b", apnsPrivateKey: "c",
  }) === null);
  check("blank strings resolve to null", resolveApnsConfig({
    apnsKeyId: "  ", apnsTeamId: "b", apnsPrivateKey: "c", apnsBundleId: "d",
  }) === null);
  check("PEM armour is stripped", decodePkcs8(pem).length > 100);

  console.log("\nprovider token");
  resetApnsTokenCache();
  const token = await signProviderToken(config, 1_700_000_000);
  const [headerB64, claimsB64, signatureB64] = token.split(".");
  const header = JSON.parse(new TextDecoder().decode(fromBase64Url(headerB64)));
  const claims = JSON.parse(new TextDecoder().decode(fromBase64Url(claimsB64)));

  check("header names ES256 and the key id", header.alg === "ES256" && header.kid === "ABCDE12345", header);
  check("claims carry the team id and issue time", claims.iss === "TEAM123456" && claims.iat === 1_700_000_000, claims);
  // WebCrypto emits fixed-width r||s, which is exactly what JWS ES256 wants —
  // unlike Node's crypto, which returns DER and would need unwrapping.
  check("signature is 64 raw bytes (r||s), not DER", fromBase64Url(signatureB64).length === 64);
  check("no base64 padding anywhere", !token.includes("="));

  const verified = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    pair.publicKey,
    fromBase64Url(signatureB64) as BufferSource,
    new TextEncoder().encode(`${headerB64}.${claimsB64}`) as BufferSource
  );
  check("signature verifies against the public key", verified);

  console.log("\ntoken caching");
  resetApnsTokenCache();
  const { getProviderToken } = await import("../src/apns");
  const first = await getProviderToken(config, 1_700_000_000_000);
  const reused = await getProviderToken(config, 1_700_000_000_000 + 10 * 60 * 1000);
  const rotated = await getProviderToken(config, 1_700_000_000_000 + 55 * 60 * 1000);
  // Apple rate-limits token minting and rejects tokens older than an hour, so
  // this has to reuse within the window and rotate before it.
  check("reuses a token inside the window", first === reused);
  check("rotates before Apple's one-hour limit", first !== rotated);

  console.log("\nrouting and payload");
  check("sandbox provider hits the sandbox host", apnsHostForProvider("apns-sandbox") === APNS_SANDBOX_HOST);
  check("production provider hits the production host", apnsHostForProvider("apns") === APNS_PRODUCTION_HOST);
  check("webpush is not an APNs provider", !isApnsProvider("webpush") && isApnsProvider("apns") && isApnsProvider("apns-sandbox"));

  const body = JSON.parse(buildApnsBody({
    title: "Ana sent you an instant",
    body: "Open it before it disappears.",
    data: { openUrl: "/instant", instantId: "abc" },
  }));
  check("alert carries title and body", body.aps.alert.title === "Ana sent you an instant");
  check("data carries the instant id", body.data.instantId === "abc");
  // The server holds ciphertext and no key, so there is nothing to preview even
  // in principle; asserting it keeps a future "helpful" change honest.
  const raw = buildApnsBody({ title: "t", body: "b", data: { openUrl: "/instant" } });
  check("payload carries no key material or media", !/wrappedKey|mediaIv|ciphertext|ephemeral/.test(raw));

  console.log("\nrequests to Apple");
  resetApnsTokenCache();
  let captured: { url: string; init: RequestInit } | null = null;
  const okFetch = (async (url: string, init: RequestInit) => {
    captured = { url, init };
    return new Response(null, { status: 200 });
  }) as unknown as typeof fetch;

  const success = await sendApnsNotification({
    config,
    deviceToken: "deadbeefcafe",
    provider: "apns-sandbox",
    payload: { title: "t", body: "b" },
    collapseId: "instant-abc12345",
    fetchImpl: okFetch,
  });

  const request = captured! as { url: string; init: RequestInit };
  const headers = request.init.headers as Record<string, string>;
  check("posts to /3/device/<token> on the right host", request.url === `${APNS_SANDBOX_HOST}/3/device/deadbeefcafe`, request.url);
  check("method is POST", request.init.method === "POST");
  check("authorization is a bearer provider token", headers.authorization.startsWith("bearer ey"));
  check("apns-topic is the bundle id", headers["apns-topic"] === "com.eduardcazacu.instant");
  check("push type and priority are set for an alert", headers["apns-push-type"] === "alert" && headers["apns-priority"] === "10");
  check("collapse id is passed through", headers["apns-collapse-id"] === "instant-abc12345");
  check("200 is reported as success", success.success && !success.shouldDeleteSubscription);

  const longCollapse = await sendApnsNotification({
    config, deviceToken: "t", provider: "apns", payload: { title: "t", body: "b" },
    collapseId: "x".repeat(200), fetchImpl: okFetch,
  });
  void longCollapse;
  check(
    "collapse id is truncated to Apple's 64-byte limit",
    ((captured! as { init: RequestInit }).init.headers as Record<string, string>)["apns-collapse-id"].length === 64
  );

  console.log("\nfailure handling");
  const deadTokenFetch = (async () =>
    new Response(JSON.stringify({ reason: "BadDeviceToken" }), { status: 400 })
  ) as unknown as typeof fetch;
  const dead = await sendApnsNotification({
    config, deviceToken: "stale", provider: "apns",
    payload: { title: "t", body: "b" }, fetchImpl: deadTokenFetch,
  });
  // Dead tokens must be deleted, mirroring the 404/410 cleanup Web Push already
  // does — otherwise every hourly streak sweep retries them forever.
  check("BadDeviceToken marks the subscription for deletion", dead.shouldDeleteSubscription && !dead.success);

  const unregisteredFetch = (async () =>
    new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 })
  ) as unknown as typeof fetch;
  const unregistered = await sendApnsNotification({
    config, deviceToken: "gone", provider: "apns",
    payload: { title: "t", body: "b" }, fetchImpl: unregisteredFetch,
  });
  check("410 Unregistered marks the subscription for deletion", unregistered.shouldDeleteSubscription);

  const throttledFetch = (async () =>
    new Response(JSON.stringify({ reason: "TooManyRequests" }), { status: 429 })
  ) as unknown as typeof fetch;
  const throttled = await sendApnsNotification({
    config, deviceToken: "t", provider: "apns",
    payload: { title: "t", body: "b" }, fetchImpl: throttledFetch,
  });
  // A throttle is temporary; deleting the row would lose a working device.
  check("a throttle does not delete the subscription", !throttled.success && !throttled.shouldDeleteSubscription);
  check("the reason is surfaced for logging", throttled.reason === "TooManyRequests");

  const networkFetch = (async () => {
    throw new Error("connection reset");
  }) as unknown as typeof fetch;
  const offline = await sendApnsNotification({
    config, deviceToken: "t", provider: "apns",
    payload: { title: "t", body: "b" }, fetchImpl: networkFetch,
  });
  check("a network failure is reported, not thrown", !offline.success && offline.statusCode === null);
  check("a network failure keeps the subscription", !offline.shouldDeleteSubscription);

  check("dead-token classification", isDeadTokenResponse(410) && isDeadTokenResponse(400, "Unregistered") && !isDeadTokenResponse(400, "PayloadTooLarge") && !isDeadTokenResponse(503));

  const badKey = await sendApnsNotification({
    config: { ...config, privateKey: "-----BEGIN PRIVATE KEY-----\nnope\n-----END PRIVATE KEY-----" },
    deviceToken: "t", provider: "apns", payload: { title: "t", body: "b" },
    fetchImpl: okFetch, nowMs: 2_000_000_000_000,
  });
  check("an unusable signing key fails the send instead of throwing", !badKey.success);

  console.log(`\n${checks - failures}/${checks} checks passed`);
  if (failures > 0) process.exit(1);
}

void main();
