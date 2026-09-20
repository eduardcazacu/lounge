import { Hono, type Context, type Next } from "hono";
import { sign, verify } from "hono/jwt";
import {
  createInstantInput,
  registerInstantDeviceInput,
  wsTicketInput,
  type InstantDelivery,
} from "@blogging-app/common";
import { getConfig } from "../env";
import { getPrismaClient } from "../prisma";
import { getUserGroupId } from "../groups";
import { blockedUserIds, isBlockedEitherWay } from "../blocks";
import { scheduleBackgroundWork } from "../background";
import { sendPushToUsers } from "../push";
import { listStreaksForUser, recordSend } from "../instant-streaks";
import { listConversationsForUser } from "../instant-conversations";
import type { DeliveryEnvelope, DeliveryMeta, InstantInbox } from "../instant-inbox";
import type { PrismaClient } from "@prisma/client";

type InstantEnv = {
  Bindings: {
    DATABASE_URL?: string;
    JWT_SECRET?: string;
    R2_PUBLIC_BASE_URL?: string;
    VAPID_PUBLIC_KEY?: string;
    VAPID_PRIVATE_KEY?: string;
    VAPID_SUBJECT?: string;
    BLOG_IMAGES?: R2Bucket;
    INSTANT_INBOX?: DurableObjectNamespace<InstantInbox>;
  };
  Variables: {
    userId: number;
  };
};

export const instantRouter = new Hono<InstantEnv>();

// A WebSocket ticket is a separate audience from the normal access token so
// neither can stand in for the other.
const WS_TICKET_AUDIENCE = "instant-ws";
const WS_TICKET_TTL_SECONDS = 60;

// Unopened instants are swept after this long. Same ceiling Snapchat uses.
const INSTANT_TTL_MS = 24 * 60 * 60 * 1000;
// Ciphertext is the compressed WebP plus a 16-byte tag, so this matches the
// limit the other upload endpoints already enforce.
const MAX_INSTANT_BYTES = 3 * 1024 * 1024;
const MAX_DEVICES_PER_USER = 10;
const INBOX_PAGE_SIZE = 50;
const MEDIA_KEY_PREFIX = "instant/";

// `/ws` carries no Authorization header — browsers cannot set one on a
// WebSocket — so it authenticates itself with a ticket instead.
const TICKET_AUTHENTICATED_PATHS = new Set(["/api/v1/instant/ws"]);

function buildPublicImageUrl(baseUrl: string | undefined, key: string | null) {
  if (!baseUrl || !key) {
    return null;
  }
  const normalizedBase = baseUrl.endsWith("/") ? baseUrl.slice(0, -1) : baseUrl;
  return `${normalizedBase}/${key}`;
}

instantRouter.use("/*", async (c: Context<InstantEnv>, next: Next) => {
  if (TICKET_AUTHENTICATED_PATHS.has(c.req.path)) {
    return next();
  }
  try {
    const authHeader = c.req.header("Authorization") || "";
    const token = authHeader.startsWith("Bearer ")
      ? authHeader.slice("Bearer ".length).trim()
      : authHeader.trim();
    if (!token) {
      c.status(403);
      return c.json({ msg: "Missing authorization token" });
    }
    const { jwtSecret } = getConfig(c);
    const payload = await verify(token, jwtSecret, "HS256");
    if (payload?.aud === WS_TICKET_AUDIENCE) {
      // A short-lived socket ticket must not double as an API credential.
      c.status(403);
      return c.json({ msg: "WebSocket tickets cannot be used for API requests" });
    }
    const userId = Number(payload?.id);
    if (!Number.isFinite(userId)) {
      c.status(403);
      return c.json({ msg: "Token payload is missing a valid user id" });
    }
    c.set("userId", userId);
    await next();
  } catch (e) {
    c.status(403);
    return c.json({
      msg: "You are not logged in",
      error: e instanceof Error ? e.message : "Invalid token",
    });
  }
});

function getInboxStub(c: Context<InstantEnv>, userId: number) {
  const namespace = c.env?.INSTANT_INBOX;
  if (!namespace) {
    return null;
  }
  return namespace.get(namespace.idFromName(`user:${userId}`));
}

const senderSelect = {
  id: true,
  name: true,
  themeKey: true,
  profilePictureKey: true,
} as const;

type InstantRow = {
  id: string;
  mediaType: string;
  mediaIv: string | null;
  ephemeralPubKey: string | null;
  byteSize: number;
  durationMode: string;
  createdAt: Date;
  expiresAt: Date;
  sender: {
    id: number;
    name: string | null;
    themeKey: string;
    profilePictureKey: string | null;
  };
};

function serializeDeliveryMeta(row: InstantRow, r2PublicBaseUrl: string | undefined): DeliveryMeta {
  return {
    id: row.id,
    senderId: row.sender.id,
    senderName: row.sender.name,
    senderThemeKey: row.sender.themeKey,
    senderProfilePictureUrl: buildPublicImageUrl(r2PublicBaseUrl, row.sender.profilePictureKey),
    mediaType: row.mediaType,
    mediaIv: row.mediaIv ?? "",
    ephemeralPubKey: row.ephemeralPubKey ?? "",
    byteSize: row.byteSize,
    durationMode: row.durationMode as DeliveryMeta["durationMode"],
    createdAt: row.createdAt.toISOString(),
    expiresAt: row.expiresAt.toISOString(),
  };
}

// Erase everything that could ever reproduce the image: the wrapped keys, the
// IV and ephemeral public key, and the object itself. Called the moment the
// media is handed over, and again from the cron sweep for anything unopened.
async function destroyInstantMedia(
  prisma: PrismaClient,
  bucket: R2Bucket | undefined,
  instantId: string,
  mediaKey: string | null
) {
  await prisma.instantKeyEnvelope.deleteMany({ where: { instantId } });
  await prisma.instant.update({
    where: { id: instantId },
    data: { mediaKey: null, mediaIv: null, ephemeralPubKey: null },
  });
  if (mediaKey && bucket) {
    await bucket.delete(mediaKey);
  }
}

// --- device keys -----------------------------------------------------------

instantRouter.post("/keys", async (c) => {
  try {
    const parsed = registerInstantDeviceInput.safeParse(await c.req.json());
    if (!parsed.success) {
      c.status(400);
      return c.json({ msg: "Invalid device key", errors: parsed.error.flatten() });
    }

    const { databaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const userId = c.get("userId");
    const now = new Date();

    const known = await prisma.instantDeviceKey.findUnique({
      where: { userId_deviceId: { userId, deviceId: parsed.data.deviceId } },
      select: { id: true },
    });

    // Identities are per-browser and unrecoverable, so every cleared profile or
    // private window leaves a dead row behind. Refusing to enroll at the cap
    // would eventually lock someone out of their own account with no way to
    // clear it, so evict the least recently seen device instead. Losing a stale
    // row costs nothing: anything wrapped to it was already unopenable.
    if (!known) {
      const existing = await prisma.instantDeviceKey.findMany({
        where: { userId },
        select: { id: true },
        orderBy: [{ lastSeenAt: { sort: "asc", nulls: "first" } }, { id: "asc" }],
      });
      const surplus = existing.length - (MAX_DEVICES_PER_USER - 1);
      if (surplus > 0) {
        await prisma.instantDeviceKey.deleteMany({
          where: { id: { in: existing.slice(0, surplus).map((device) => device.id) } },
        });
      }
    }

    const device = await prisma.instantDeviceKey.upsert({
      where: { userId_deviceId: { userId, deviceId: parsed.data.deviceId } },
      create: {
        userId,
        deviceId: parsed.data.deviceId,
        publicKey: parsed.data.publicKey,
        userAgent: c.req.header("User-Agent")?.slice(0, 255) ?? null,
        lastSeenAt: now,
      },
      update: { publicKey: parsed.data.publicKey, lastSeenAt: now },
      select: { id: true, deviceId: true, publicKey: true, createdAt: true },
    });

    return c.json({ device });
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to register device" });
  }
});

// The key directory. Note the caveat in backend/README.md: the server publishes
// these and could substitute its own, which is why clients show a safety number.
instantRouter.get("/keys/:userId", async (c) => {
  try {
    const targetId = Number(c.req.param("userId"));
    if (!Number.isInteger(targetId) || targetId <= 0) {
      c.status(400);
      return c.json({ msg: "Invalid user id" });
    }

    const { databaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const userId = c.get("userId");
    const groupId = await getUserGroupId(prisma, userId);
    if (groupId === null) {
      c.status(403);
      return c.json({ msg: "Invalid user" });
    }

    const deviceSelect = { id: true, deviceId: true, publicKey: true, createdAt: true } as const;
    // Across a block there is nobody to encrypt to.
    const blocked = targetId !== userId && (await isBlockedEitherWay(prisma, userId, targetId));
    const devices = blocked ? [] : await prisma.instantDeviceKey.findMany({
      where: {
        userId: targetId,
        // Someone outside your group has no published keys as far as you can tell.
        user: { groupId, status: "approved", emailVerifiedAt: { not: null } },
      },
      select: deviceSelect,
      orderBy: { id: "asc" },
      take: MAX_DEVICES_PER_USER,
    });

    const myDevices =
      targetId === userId
        ? devices
        : await prisma.instantDeviceKey.findMany({
            where: { userId },
            select: deviceSelect,
            orderBy: { id: "asc" },
            take: MAX_DEVICES_PER_USER,
          });

    return c.json({ userId: targetId, devices, myDevices });
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to load device keys" });
  }
});

// --- realtime --------------------------------------------------------------

instantRouter.post("/ws-ticket", async (c) => {
  try {
    const parsed = wsTicketInput.safeParse(await c.req.json());
    if (!parsed.success) {
      c.status(400);
      return c.json({ msg: "Invalid ticket request", errors: parsed.error.flatten() });
    }

    const { databaseUrl, jwtSecret } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const userId = c.get("userId");

    const device = await prisma.instantDeviceKey.findUnique({
      where: { userId_deviceId: { userId, deviceId: parsed.data.deviceId } },
      select: { id: true },
    });
    if (!device) {
      c.status(404);
      return c.json({ msg: "Register this device before connecting" });
    }

    const ticket = await sign(
      {
        id: userId,
        deviceId: parsed.data.deviceId,
        aud: WS_TICKET_AUDIENCE,
        exp: Math.floor(Date.now() / 1000) + WS_TICKET_TTL_SECONDS,
      },
      jwtSecret,
      "HS256"
    );

    return c.json({ ticket, expiresIn: WS_TICKET_TTL_SECONDS });
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to issue a socket ticket" });
  }
});

instantRouter.get("/ws", async (c) => {
  if (c.req.header("Upgrade")?.toLowerCase() !== "websocket") {
    c.status(426);
    return c.json({ msg: "Expected a WebSocket upgrade" });
  }

  const ticket = c.req.query("ticket") ?? "";
  if (!ticket) {
    c.status(403);
    return c.json({ msg: "Missing socket ticket" });
  }

  const { databaseUrl, jwtSecret } = getConfig(c);

  // Authenticate before anything else, so an invalid token is refused the same
  // way whether or not this runtime can serve sockets at all. Scoped tightly:
  // only a bad token should be reported as a bad token.
  let userId: number;
  let deviceId: string;
  try {
    const payload = await verify(ticket, jwtSecret, "HS256");
    if (payload?.aud !== WS_TICKET_AUDIENCE) {
      c.status(403);
      return c.json({ msg: "This token is not a socket ticket" });
    }
    userId = Number(payload?.id);
    deviceId = typeof payload?.deviceId === "string" ? payload.deviceId : "";
  } catch (e) {
    console.error(e);
    c.status(403);
    return c.json({ msg: "Socket ticket is invalid or expired" });
  }

  if (!Number.isFinite(userId) || !deviceId) {
    c.status(403);
    return c.json({ msg: "Socket ticket is missing an identity" });
  }

  const namespace = c.env?.INSTANT_INBOX;
  if (!namespace) {
    c.status(501);
    return c.json({
      msg: "Realtime Instant delivery needs the INSTANT_INBOX Durable Object binding. Run the backend with `wrangler dev` rather than `tsx src/server.ts`.",
    });
  }

  try {
    // The device could have been removed between minting and connecting.
    const prisma = getPrismaClient(databaseUrl);
    const device = await prisma.instantDeviceKey.findUnique({
      where: { userId_deviceId: { userId, deviceId } },
      select: { id: true },
    });
    if (!device) {
      c.status(403);
      return c.json({ msg: "Unknown device" });
    }
    scheduleBackgroundWork(
      c,
      prisma.instantDeviceKey.update({ where: { id: device.id }, data: { lastSeenAt: new Date() } })
    );

    const target = new URL(c.req.url);
    target.pathname = "/ws";
    target.search = "";
    target.searchParams.set("userId", String(userId));
    target.searchParams.set("deviceId", deviceId);

    const stub = namespace.get(namespace.idFromName(`user:${userId}`));
    return stub.fetch(new Request(target.toString(), c.req.raw));
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Could not open the Instant socket" });
  }
});

// --- sending ---------------------------------------------------------------

instantRouter.post("/", async (c) => {
  const bucket = c.env?.BLOG_IMAGES;
  if (!bucket) {
    c.status(500);
    return c.json({ msg: "BLOG_IMAGES R2 binding is not configured." });
  }

  try {
    const form = await c.req.formData();
    const media = form.get("media");
    const rawPayload = form.get("payload");

    if (!(media instanceof File)) {
      c.status(400);
      return c.json({ msg: "Missing encrypted media" });
    }
    if (typeof rawPayload !== "string") {
      c.status(400);
      return c.json({ msg: "Missing payload" });
    }
    if (media.size === 0 || media.size > MAX_INSTANT_BYTES) {
      c.status(400);
      return c.json({ msg: `Instants must be between 1 byte and ${MAX_INSTANT_BYTES} bytes.` });
    }

    let payloadJson: unknown;
    try {
      payloadJson = JSON.parse(rawPayload);
    } catch {
      c.status(400);
      return c.json({ msg: "Payload is not valid JSON" });
    }

    const parsed = createInstantInput.safeParse(payloadJson);
    if (!parsed.success) {
      c.status(400);
      return c.json({ msg: "Invalid instant", errors: parsed.error.flatten() });
    }

    const { databaseUrl, r2PublicBaseUrl, vapidPublicKey, vapidPrivateKey, vapidSubject, apnsKeyId, apnsTeamId, apnsPrivateKey, apnsBundleId } =
      getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const userId = c.get("userId");
    const { recipientId, durationMode, mediaType, mediaIv, ephemeralPubKey, envelopes } =
      parsed.data;

    if (recipientId === userId) {
      c.status(400);
      return c.json({ msg: "Send an instant to someone else." });
    }

    const groupId = await getUserGroupId(prisma, userId);
    const recipient = groupId === null ? null : await prisma.user.findFirst({
      where: { id: recipientId, groupId, status: "approved", emailVerifiedAt: { not: null } },
      select: { id: true },
    });
    // A block reads exactly like someone who does not exist, so it cannot be
    // probed for.
    if (!recipient || (await isBlockedEitherWay(prisma, userId, recipientId))) {
      c.status(404);
      return c.json({ msg: "Recipient not found" });
    }

    // Every envelope must be addressed to a distinct device owned by the
    // recipient — otherwise a sender could ask us to hand a wrapped key to
    // somebody else's device.
    const deviceKeyIds = [...new Set(envelopes.map((envelope) => envelope.deviceKeyId))];
    if (deviceKeyIds.length !== envelopes.length) {
      c.status(400);
      return c.json({ msg: "Envelopes must target distinct devices" });
    }
    const devices = await prisma.instantDeviceKey.findMany({
      where: { id: { in: deviceKeyIds }, userId: recipientId },
      select: { id: true, deviceId: true },
    });
    if (devices.length !== deviceKeyIds.length) {
      c.status(400);
      return c.json({ msg: "One or more envelopes are not addressed to this recipient's devices" });
    }

    const bytes = await media.arrayBuffer();
    const mediaKey = `${MEDIA_KEY_PREFIX}${crypto.randomUUID()}`;
    await bucket.put(mediaKey, bytes, {
      httpMetadata: { contentType: "application/octet-stream", cacheControl: "no-store" },
      customMetadata: { senderId: String(userId), recipientId: String(recipientId) },
    });

    const now = new Date();
    const expiresAt = new Date(now.getTime() + INSTANT_TTL_MS);

    let created;
    try {
      created = await prisma.instant.create({
        data: {
          senderId: userId,
          recipientId,
          mediaKey,
          mediaIv,
          ephemeralPubKey,
          mediaType,
          byteSize: bytes.byteLength,
          durationMode,
          createdAt: now,
          expiresAt,
          envelopes: {
            create: envelopes.map((envelope) => ({
              deviceKeyId: envelope.deviceKeyId,
              wrappedKey: envelope.wrappedKey,
              wrapIv: envelope.wrapIv,
            })),
          },
        },
        select: {
          id: true,
          mediaType: true,
          mediaIv: true,
          ephemeralPubKey: true,
          byteSize: true,
          durationMode: true,
          createdAt: true,
          expiresAt: true,
          sender: { select: senderSelect },
        },
      });
    } catch (error) {
      // Never leave an object in R2 that no row points at.
      await Promise.resolve(bucket.delete(mediaKey)).catch(() => undefined);
      throw error;
    }

    await recordSend(prisma, userId, recipientId, now);

    const envelopeByDeviceKeyId = new Map(
      envelopes.map((envelope) => [
        envelope.deviceKeyId,
        { wrappedKey: envelope.wrappedKey, wrapIv: envelope.wrapIv } satisfies DeliveryEnvelope,
      ])
    );
    const envelopesByDeviceId: Record<string, DeliveryEnvelope> = {};
    for (const device of devices) {
      const envelope = envelopeByDeviceKeyId.get(device.id);
      if (envelope) {
        envelopesByDeviceId[device.deviceId] = envelope;
      }
    }

    let delivered = false;
    const stub = getInboxStub(c, recipientId);
    if (stub) {
      try {
        delivered = await stub.deliver(
          serializeDeliveryMeta(created, r2PublicBaseUrl),
          envelopesByDeviceId
        );
      } catch (error) {
        console.error("Failed to deliver instant over the socket", error);
      }
    }

    if (!delivered) {
      const senderName = created.sender.name?.trim() || "Someone";
      scheduleBackgroundWork(
        c,
        sendPushToUsers({
          databaseUrl,
          userIds: [recipientId],
          payload: {
            title: `${senderName} sent you an instant`,
            body: "Open it before it disappears.",
            // Deliberately carries no key material and no media — the server
            // holds only ciphertext and could not preview the photo anyway.
            //
            // The sender's identity is here so the Notification Service
            // Extension can update the home-screen widget without a token: it
            // has no way to call the API. This is all metadata the title
            // already reveals or that the server serves publicly.
            data: {
              openUrl: "/instant",
              instantId: created.id,
              senderId: created.sender.id,
              senderName,
              senderThemeKey: created.sender.themeKey,
              senderProfilePictureUrl: buildPublicImageUrl(
                r2PublicBaseUrl,
                created.sender.profilePictureKey
              ),
            },
          },
          topic: `instant-${created.id.slice(0, 8)}`,
          appFirst: true,
          vapidConfig: { vapidPublicKey, vapidPrivateKey, vapidSubject },
          apnsConfig: { apnsKeyId, apnsTeamId, apnsPrivateKey, apnsBundleId },
        })
      );
    }

    return c.json({
      instant: {
        id: created.id,
        createdAt: created.createdAt.toISOString(),
        expiresAt: created.expiresAt.toISOString(),
        delivered,
      },
    });
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to send instant" });
  }
});

// --- receiving -------------------------------------------------------------

instantRouter.get("/inbox", async (c) => {
  try {
    const deviceId = c.req.query("deviceId") ?? "";
    if (!deviceId) {
      c.status(400);
      return c.json({ msg: "Missing deviceId" });
    }

    const { databaseUrl, r2PublicBaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const userId = c.get("userId");

    const device = await prisma.instantDeviceKey.findUnique({
      where: { userId_deviceId: { userId, deviceId } },
      select: { id: true },
    });
    if (!device) {
      c.status(404);
      return c.json({ msg: "Unknown device" });
    }
    scheduleBackgroundWork(
      c,
      prisma.instantDeviceKey.update({ where: { id: device.id }, data: { lastSeenAt: new Date() } })
    );

    const blocked = await blockedUserIds(prisma, userId);
    const rows = await prisma.instant.findMany({
      where: {
        recipientId: userId,
        ...(blocked.size > 0 ? { senderId: { notIn: [...blocked] } } : {}),
        openedAt: null,
        mediaKey: { not: null },
        expiresAt: { gt: new Date() },
      },
      orderBy: { createdAt: "asc" },
      take: INBOX_PAGE_SIZE,
      select: {
        id: true,
        mediaType: true,
        mediaIv: true,
        ephemeralPubKey: true,
        byteSize: true,
        durationMode: true,
        createdAt: true,
        expiresAt: true,
        sender: { select: senderSelect },
        // Only ever this device's envelope; the others are none of its business.
        envelopes: {
          where: { deviceKeyId: device.id },
          select: { wrappedKey: true, wrapIv: true },
        },
      },
    });

    const instants: InstantDelivery[] = rows.map((row) => ({
      ...serializeDeliveryMeta(row, r2PublicBaseUrl),
      envelope: row.envelopes[0] ?? null,
    }));

    return c.json({ instants });
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to load inbox" });
  }
});

// Hands over the ciphertext exactly once, then destroys it. Claiming the row
// before reading R2 means a second request can never be served, even from
// another of the recipient's devices — and it means a download that fails
// mid-flight loses the image. That is the same trade Snapchat makes.
instantRouter.get("/:id/media", async (c) => {
  try {
    const id = c.req.param("id");
    const { databaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const bucket = c.env?.BLOG_IMAGES;
    const userId = c.get("userId");

    const openedAt = new Date();
    const claimed = await prisma.instant.updateMany({
      where: {
        id,
        recipientId: userId,
        openedAt: null,
        mediaKey: { not: null },
        expiresAt: { gt: new Date() },
      },
      data: { openedAt },
    });
    if (claimed.count === 0) {
      c.status(410);
      return c.json({ msg: "This instant is no longer available." });
    }

    const instant = await prisma.instant.findUnique({
      where: { id },
      select: { mediaKey: true, senderId: true },
    });

    // The claim is the read receipt, and this is the one place it can be born:
    // exactly one request ever gets past the `updateMany` above, and from here
    // the photo is gone whatever happens next. Telling the sender from
    // `/viewed` instead would leave a recipient whose app died mid-view owing a
    // receipt that never comes. See wiki/decisions.md.
    const senderStub = instant ? getInboxStub(c, instant.senderId) : null;
    if (senderStub) {
      scheduleBackgroundWork(
        c,
        Promise.resolve(senderStub.notifyOpened(id, userId, openedAt.toISOString()))
      );
    }

    const object = instant?.mediaKey && bucket ? await bucket.get(instant.mediaKey) : null;
    const bytes = object ? await object.arrayBuffer() : null;

    // Destroy the keys and the object whether or not the read succeeded.
    scheduleBackgroundWork(c, destroyInstantMedia(prisma, bucket, id, instant?.mediaKey ?? null));

    if (!bytes) {
      c.status(410);
      return c.json({ msg: "This instant is no longer available." });
    }

    return c.body(bytes, 200, {
      "Content-Type": "application/octet-stream",
      "Content-Length": String(bytes.byteLength),
      "Cache-Control": "no-store",
    });
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to load instant" });
  }
});

instantRouter.post("/:id/viewed", async (c) => {
  try {
    const id = c.req.param("id");
    const { databaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const userId = c.get("userId");

    const instant = await prisma.instant.findFirst({
      where: { id, recipientId: userId },
      select: { id: true, viewedAt: true },
    });
    if (!instant) {
      c.status(404);
      return c.json({ msg: "Instant not found" });
    }

    // Records that the photo reached a screen, which the claim on `/media`
    // cannot know. The sender was already told by then — a receipt that waits
    // for this call is one a viewer that crashed never sends.
    const viewedAt = instant.viewedAt ?? new Date();
    if (!instant.viewedAt) {
      await prisma.instant.update({ where: { id }, data: { viewedAt } });
    }

    return c.json({ ok: true, viewedAt: viewedAt.toISOString() });
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to record view" });
  }
});

// The recipient has no envelope it can unwrap — its keypair was replaced after
// this was sent. Nothing can ever open it, so remove it now.
instantRouter.post("/:id/undecryptable", async (c) => {
  try {
    const id = c.req.param("id");
    const { databaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const bucket = c.env?.BLOG_IMAGES;
    const userId = c.get("userId");

    const instant = await prisma.instant.findFirst({
      where: { id, recipientId: userId },
      select: { id: true, mediaKey: true },
    });
    if (!instant) {
      c.status(404);
      return c.json({ msg: "Instant not found" });
    }

    if (instant.mediaKey && bucket) {
      scheduleBackgroundWork(c, Promise.resolve(bucket.delete(instant.mediaKey)));
    }
    await prisma.instant.delete({ where: { id } });

    return c.json({ ok: true });
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to discard instant" });
  }
});

// --- streaks ---------------------------------------------------------------

// Everyone you have exchanged instants with, newest first, whether or not a
// streak is running. `/streaks` answers "what am I about to lose"; this answers
// "who do I talk to", which is what an inbox needs.
instantRouter.get("/conversations", async (c) => {
  try {
    const { databaseUrl, r2PublicBaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const userId = c.get("userId");

    const conversations = await listConversationsForUser(
      prisma,
      userId,
      (key) => buildPublicImageUrl(r2PublicBaseUrl, key),
      new Date(),
      await blockedUserIds(prisma, userId)
    );

    return c.json({ conversations });
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to load conversations" });
  }
});

instantRouter.get("/streaks", async (c) => {
  try {
    const { databaseUrl, r2PublicBaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const userId = c.get("userId");

    const streaks = await listStreaksForUser(
      prisma,
      userId,
      (key) => buildPublicImageUrl(r2PublicBaseUrl, key),
      new Date(),
      await blockedUserIds(prisma, userId)
    );

    return c.json({ streaks });
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to load streaks" });
  }
});
