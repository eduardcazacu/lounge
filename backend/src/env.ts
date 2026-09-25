import type { Context } from "hono";

export type AppEnv = {
  DATABASE_URL?: string;
  HYPERDRIVE?: Hyperdrive;
  JWT_SECRET?: string;
  R2_PUBLIC_BASE_URL?: string;
  VAPID_PUBLIC_KEY?: string;
  VAPID_PRIVATE_KEY?: string;
  VAPID_SUBJECT?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_PRIVATE_KEY?: string;
  APNS_BUNDLE_ID?: string;
};

export function getConfig(c: Context<any>) {
  // Hyperdrive when the Worker has the binding, the database itself otherwise.
  // On Workers `src/prisma.ts` builds a client per request, and without
  // Hyperdrive every one of those opened its own TCP, TLS and Postgres
  // handshake before its first query — the bulk of what each API call cost.
  // Node (`npm run dev`) and the scripts have no binding and keep DATABASE_URL.
  // See wiki/decisions.md.
  const databaseUrl =
    c.env?.HYPERDRIVE?.connectionString ?? c.env?.DATABASE_URL ?? process.env.DATABASE_URL;
  const jwtSecret = c.env?.JWT_SECRET ?? process.env.JWT_SECRET;
  const r2PublicBaseUrl = c.env?.R2_PUBLIC_BASE_URL ?? process.env.R2_PUBLIC_BASE_URL;
  const vapidPublicKey = c.env?.VAPID_PUBLIC_KEY ?? process.env.VAPID_PUBLIC_KEY;
  const vapidPrivateKey = c.env?.VAPID_PRIVATE_KEY ?? process.env.VAPID_PRIVATE_KEY;
  const vapidSubject = c.env?.VAPID_SUBJECT ?? process.env.VAPID_SUBJECT;

  // APNs. All four are needed together; with any of them missing the APNs
  // branch reports itself unconfigured instead of throwing, so the app can ship
  // before the Apple Developer account exists.
  const apnsKeyId = c.env?.APNS_KEY_ID ?? process.env.APNS_KEY_ID;
  const apnsTeamId = c.env?.APNS_TEAM_ID ?? process.env.APNS_TEAM_ID;
  const apnsPrivateKey = c.env?.APNS_PRIVATE_KEY ?? process.env.APNS_PRIVATE_KEY;
  const apnsBundleId = c.env?.APNS_BUNDLE_ID ?? process.env.APNS_BUNDLE_ID;

  if (!databaseUrl) {
    throw new Error("DATABASE_URL is required");
  }

  if (!jwtSecret) {
    throw new Error("JWT_SECRET is required");
  }

  return {
    databaseUrl,
    jwtSecret,
    r2PublicBaseUrl,
    vapidPublicKey,
    vapidPrivateKey,
    vapidSubject,
    apnsKeyId,
    apnsTeamId,
    apnsPrivateKey,
    apnsBundleId,
  };
}
