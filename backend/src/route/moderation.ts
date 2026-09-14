import { Hono, type Context, type Next } from "hono";
import { verify } from "hono/jwt";
import type { PrismaClient } from "@prisma/client";
import { blockUserInput, createReportInput } from "@blogging-app/common";
import { getConfig } from "../env";
import { getAdminEmails } from "../admin-config";
import { getPrismaClient } from "../prisma";
import { getUserGroupId } from "../groups";
import { scheduleBackgroundWork } from "../background";
import { sendReportEmail } from "../email";

// Reporting and blocking — what App Store Guideline 1.2 asks of any app where
// people send each other content. See backend/README.md.

type ModerationEnv = {
  Bindings: {
    DATABASE_URL?: string;
    JWT_SECRET?: string;
    ADMIN_EMAILS?: string;
    RESEND_API_KEY?: string;
    EMAIL_FROM?: string;
    FRONTEND_URL?: string;
    R2_PUBLIC_BASE_URL?: string;
    BLOG_IMAGES?: R2Bucket;
  };
  Variables: {
    userId: number;
  };
};

export const moderationRouter = new Hono<ModerationEnv>();

// Evidence is the reporter's own decrypted photo, re-encoded on their device.
// Same ceiling as every other upload.
const MAX_EVIDENCE_BYTES = 3 * 1024 * 1024;
const ALLOWED_EVIDENCE_MIME = new Set(["image/webp", "image/jpeg", "image/png"]);
export const EVIDENCE_KEY_PREFIX = "reports/";

moderationRouter.use("/*", async (c: Context<ModerationEnv>, next: Next) => {
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
    const userId = Number(payload?.id);
    if (!Number.isFinite(userId) || payload?.aud !== undefined) {
      // `aud` is only ever set on Instant's socket tickets, which must not
      // stand in for an access token here either.
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

/**
 * The person on the other end, if they are someone the caller could actually
 * see: same group, and not themselves. Anything else reads as not found.
 */
async function findPeer(prisma: PrismaClient, userId: number, peerId: number) {
  if (peerId === userId) return null;
  const groupId = await getUserGroupId(prisma, userId);
  if (groupId === null) return null;
  return prisma.user.findFirst({
    where: { id: peerId, groupId },
    select: { id: true, name: true },
  });
}

/**
 * Unopened instants between two people who have just been separated by a block.
 * Neither side can open them any more — the inbox hides them — so the
 * ciphertext is deleted now rather than left for the expiry sweep. Object
 * first, as the sweep does, so a failure never strands one.
 */
async function discardUnopenedBetween(
  prisma: PrismaClient,
  bucket: R2Bucket | undefined,
  a: number,
  b: number
) {
  const pending = await prisma.instant.findMany({
    where: {
      OR: [
        { senderId: a, recipientId: b },
        { senderId: b, recipientId: a },
      ],
      openedAt: null,
      mediaKey: { not: null },
    },
    select: { id: true, mediaKey: true },
  });
  for (const instant of pending) {
    if (instant.mediaKey && bucket) {
      await bucket.delete(instant.mediaKey);
    }
  }
  if (pending.length > 0) {
    await prisma.instant.deleteMany({ where: { id: { in: pending.map((instant) => instant.id) } } });
  }
}

async function block(
  c: Context<ModerationEnv>,
  prisma: PrismaClient,
  blockerId: number,
  blockedId: number
) {
  // Blocking twice is not an error, and should not log like one.
  await prisma.userBlock.createMany({ data: [{ blockerId, blockedId }], skipDuplicates: true });
  scheduleBackgroundWork(c, discardUnopenedBetween(prisma, c.env?.BLOG_IMAGES, blockerId, blockedId));
}

// --- blocks ----------------------------------------------------------------

moderationRouter.get("/blocks", async (c) => {
  try {
    const { databaseUrl, r2PublicBaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const rows = await prisma.userBlock.findMany({
      where: { blockerId: c.get("userId") },
      orderBy: { createdAt: "desc" },
      select: {
        createdAt: true,
        blocked: { select: { id: true, name: true, themeKey: true, profilePictureKey: true } },
      },
    });
    const base = r2PublicBaseUrl?.replace(/\/$/, "");
    return c.json({
      blocks: rows.map((row) => ({
        userId: row.blocked.id,
        name: row.blocked.name,
        themeKey: row.blocked.themeKey,
        profilePictureUrl:
          base && row.blocked.profilePictureKey ? `${base}/${row.blocked.profilePictureKey}` : null,
        blockedAt: row.createdAt.toISOString(),
      })),
    });
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to load blocked people" });
  }
});

moderationRouter.post("/blocks", async (c) => {
  try {
    const parsed = blockUserInput.safeParse(await c.req.json());
    if (!parsed.success) {
      c.status(400);
      return c.json({ msg: "Invalid block request", errors: parsed.error.flatten() });
    }
    const { databaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const userId = c.get("userId");

    const peer = await findPeer(prisma, userId, parsed.data.userId);
    if (!peer) {
      c.status(404);
      return c.json({ msg: "User not found" });
    }

    await block(c, prisma, userId, peer.id);
    return c.json({ ok: true });
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to block user" });
  }
});

moderationRouter.delete("/blocks/:userId", async (c) => {
  try {
    const blockedId = Number(c.req.param("userId"));
    if (!Number.isInteger(blockedId) || blockedId <= 0) {
      c.status(400);
      return c.json({ msg: "Invalid user id" });
    }
    const { databaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    // Only undoes a block the caller made. If the other person blocked them
    // too, that one stands.
    await prisma.userBlock.deleteMany({ where: { blockerId: c.get("userId"), blockedId } });
    return c.json({ ok: true });
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to unblock user" });
  }
});

// --- reports ---------------------------------------------------------------

moderationRouter.post("/reports", async (c) => {
  try {
    const form = await c.req.formData();
    const rawPayload = form.get("payload");
    const evidence = form.get("evidence");

    if (typeof rawPayload !== "string") {
      c.status(400);
      return c.json({ msg: "Missing payload" });
    }
    let payloadJson: unknown;
    try {
      payloadJson = JSON.parse(rawPayload);
    } catch {
      c.status(400);
      return c.json({ msg: "Payload is not valid JSON" });
    }
    const parsed = createReportInput.safeParse(payloadJson);
    if (!parsed.success) {
      c.status(400);
      return c.json({ msg: "Invalid report", errors: parsed.error.flatten() });
    }

    if (evidence !== null) {
      if (!(evidence instanceof File)) {
        c.status(400);
        return c.json({ msg: "Evidence must be a file" });
      }
      if (!ALLOWED_EVIDENCE_MIME.has(evidence.type)) {
        c.status(400);
        return c.json({ msg: "Evidence must be a WEBP, JPG or PNG image." });
      }
      if (evidence.size <= 0 || evidence.size > MAX_EVIDENCE_BYTES) {
        c.status(400);
        return c.json({ msg: "Evidence must be between 1B and 3MB." });
      }
    }

    const bucket = c.env?.BLOG_IMAGES;
    if (evidence instanceof File && !bucket) {
      c.status(500);
      return c.json({ msg: "BLOG_IMAGES R2 binding is not configured." });
    }

    const { databaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const userId = c.get("userId");
    const { reportedUserId, instantId, reason, details, alsoBlock } = parsed.data;

    const reported = await findPeer(prisma, userId, reportedUserId);
    if (!reported) {
      c.status(404);
      return c.json({ msg: "User not found" });
    }

    let evidenceKey: string | null = null;
    if (evidence instanceof File && bucket) {
      evidenceKey = `${EVIDENCE_KEY_PREFIX}${crypto.randomUUID()}`;
      await bucket.put(evidenceKey, await evidence.arrayBuffer(), {
        httpMetadata: { contentType: evidence.type, cacheControl: "no-store" },
        customMetadata: { reporterId: String(userId), reportedUserId: String(reported.id) },
      });
    }

    let report;
    try {
      report = await prisma.contentReport.create({
        data: {
          reporterId: userId,
          reportedUserId: reported.id,
          instantId: instantId ?? null,
          reason,
          details: details || null,
          evidenceKey,
        },
        select: { id: true, reporter: { select: { name: true } } },
      });
    } catch (error) {
      // Never leave a photo in R2 that no report points at.
      if (evidenceKey && bucket) {
        await Promise.resolve(bucket.delete(evidenceKey)).catch(() => undefined);
      }
      throw error;
    }

    if (alsoBlock) {
      await block(c, prisma, userId, reported.id);
    }

    const resendApiKey = c.env?.RESEND_API_KEY ?? process.env.RESEND_API_KEY;
    const emailFrom = c.env?.EMAIL_FROM ?? process.env.EMAIL_FROM;
    const frontendUrl = c.env?.FRONTEND_URL ?? process.env.FRONTEND_URL ?? "http://localhost:5173";
    const adminEmails = getAdminEmails(c).filter(Boolean);
    if (resendApiKey && emailFrom && adminEmails.length > 0) {
      scheduleBackgroundWork(
        c,
        sendReportEmail({
          apiKey: resendApiKey,
          from: emailFrom,
          to: adminEmails,
          appName: "Eddie's Lounge",
          reportId: report.id,
          reporterName: report.reporter?.name,
          reportedUserName: reported.name,
          reason,
          details: details || null,
          hasEvidence: evidenceKey !== null,
          adminUrl: new URL("/admin", frontendUrl).toString(),
        }).catch((error) => console.error("[moderation] failed to email admins", error))
      );
    } else {
      // Still recorded and visible in /admin; nobody is told, which is worth
      // shouting about since the 24-hour promise depends on it.
      console.warn("[moderation] report stored but admins were not emailed", {
        reportId: report.id,
        hasResendKey: Boolean(resendApiKey),
        hasEmailFrom: Boolean(emailFrom),
        adminCount: adminEmails.length,
      });
    }

    return c.json({ report: { id: report.id }, blocked: alsoBlock });
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to submit report" });
  }
});
