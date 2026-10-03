import { Hono } from "hono";
import type { Context } from "hono";
import { z } from "zod";
import type { PrismaClient } from "@prisma/client";
import { getConfig } from "../env";
import { getPrismaClient } from "../prisma";
import { hashReaderKey, receivePush, sameHash } from "../reader-sync";

// KOReader's progress sync protocol, so a Kindle running KOReader can use the
// Lounge as its "custom sync server" and move Books' progress as it is read.
// What a sync means for Books is src/reader-sync.ts; this is only the wire.
//
// The contract is KOReader's, not ours, and is fixed by
// plugins/kosync.koplugin/{api.json,KOSyncClient.lua} in the KOReader
// repository. Two parts of it overrule the Lounge's own conventions:
//
// - Statuses. KOReader's HTTP library raises on any status not listed for
//   that call in api.json, and the reader then sees "Unknown server error"
//   instead of our message. So a refused login is 401, not the 403 used
//   everywhere else, and a refused registration is 402.
// - Errors are `{ message }`, which is what KOReader shows, not `{ msg }`.
//
// Field names (`device_id`, `percentage`, …) are KOReader's and must not be
// renamed.

type KosyncEnv = {
  Bindings: { DATABASE_URL?: string; JWT_SECRET?: string };
  Variables: { userId: number; timeZone: string };
};

export const kosyncRouter = new Hono<KosyncEnv>();

const KOREADER_JSON = "application/vnd.koreader.v1+json";

function reply(c: Context<KosyncEnv>, status: 200 | 201 | 401 | 402 | 400 | 404, body: unknown) {
  return c.body(JSON.stringify(body), status, { "Content-Type": KOREADER_JSON });
}

function db(c: Context<KosyncEnv>) {
  return getPrismaClient(getConfig(c).databaseUrl) as PrismaClient;
}

// Accounts are made in /books, which shows the password once.
kosyncRouter.post("/users/create", (c) =>
  reply(c, 402, { message: "Set up KOReader sync in Lounge Books, then use Login with the details it shows." })
);

kosyncRouter.use("/*", async (c, next) => {
  const username = c.req.header("x-auth-user")?.trim();
  const key = c.req.header("x-auth-key")?.trim();
  if (!username || !key) return reply(c, 401, { message: "Log in with the details from Lounge Books." });
  const sync = await db(c).readerSync.findUnique({
    where: { username },
    select: { userId: true, keyHash: true, timeZone: true },
  });
  if (!sync || !sameHash(hashReaderKey(key), sync.keyHash)) {
    return reply(c, 401, { message: "Wrong username or password. Lounge Books shows them under KOReader sync." });
  }
  c.set("userId", sync.userId);
  c.set("timeZone", sync.timeZone);
  await next();
});

kosyncRouter.get("/users/auth", async (c) => {
  await db(c).readerSync.update({ where: { userId: c.get("userId") }, data: { lastSeenAt: new Date() } });
  return reply(c, 200, { authorized: "OK" });
});

const pushInput = z.object({
  document: z.string().trim().min(1).max(200),
  // A page number for PDFs, an xpointer for reflowable books; kept verbatim.
  progress: z.union([z.string(), z.number()]).transform(String),
  percentage: z.number().min(0).max(1.5),
  device: z.string().max(200),
  device_id: z.string().max(200),
  // Sent when "Send document metadata" is on in KOReader's progress sync menu.
  metadata: z
    .object({
      title: z.string().optional().nullable(),
      authors: z.string().optional().nullable(),
    })
    .passthrough()
    .optional()
    .nullable(),
});

kosyncRouter.put("/syncs/progress", async (c) => {
  let raw: unknown;
  try {
    raw = await c.req.json();
  } catch {
    raw = null;
  }
  const parsed = pushInput.safeParse(raw);
  // 400 is not in api.json's list for this call, so KOReader treats it as a
  // network failure and queues the push again. Nothing KOReader sends today
  // is refused here; the list is the reference server's validation.
  if (!parsed.success) return reply(c, 400, { message: "Unrecognised progress." });
  const push = parsed.data;
  const prisma = db(c);
  const userId = c.get("userId");
  const storedAt = await receivePush(prisma, userId, c.get("timeZone"), {
    document: push.document,
    progress: push.progress,
    percentage: Math.min(1, push.percentage),
    device: push.device,
    deviceId: push.device_id,
    title: push.metadata?.title?.trim() || null,
    authors: push.metadata?.authors?.trim() || null,
  });
  await prisma.readerSync.update({ where: { userId }, data: { lastSeenAt: new Date() } });
  return reply(c, 200, { document: push.document, timestamp: Math.floor(storedAt.getTime() / 1000) });
});

kosyncRouter.get("/syncs/progress/:document", async (c) => {
  const doc = await db(c).readerDocument.findUnique({
    where: { userId_document: { userId: c.get("userId"), document: c.req.param("document") } },
    select: { document: true, progress: true, percentage: true, device: true, deviceId: true, updatedAt: true },
  });
  // An empty object is "no progress yet" to KOReader, as from the reference
  // server; a 404 would be an error on the reader's screen.
  if (!doc) return reply(c, 200, {});
  return reply(c, 200, {
    document: doc.document,
    progress: doc.progress,
    percentage: doc.percentage,
    device: doc.device,
    device_id: doc.deviceId,
    timestamp: Math.floor(doc.updatedAt.getTime() / 1000),
  });
});
