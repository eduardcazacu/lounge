import { Hono } from "hono";
import { verify } from "hono/jwt";
import { Prisma } from "@prisma/client";
import { getConfig } from "../env";
import { getAdminEmails, isAdminEmail } from "../admin-config";
import { getPrismaClient } from "../prisma";
import { sendBroadcastEmail, sendWelcomeEmail } from "../email";
import { sendBroadcastNotification } from "../push";
import { runInstantSweep } from "../scheduled";
import z from "zod";
import { resolveReportInput } from "@blogging-app/common";

type AdminEnv = {
  Bindings: {
    DATABASE_URL?: string;
    JWT_SECRET?: string;
    ADMIN_EMAILS?: string;
    RESEND_API_KEY?: string;
    EMAIL_FROM?: string;
    FRONTEND_URL?: string;
    VAPID_PUBLIC_KEY?: string;
    VAPID_PRIVATE_KEY?: string;
    VAPID_SUBJECT?: string;
    R2_PUBLIC_BASE_URL?: string;
    BLOG_IMAGES?: R2Bucket;
  };
  Variables: {
    userId: number;
    adminEmail: string;
    // Broadcasts reach only the admin's own group, so review accounts in
    // "testing" never receive messages meant for the community.
    groupId: number;
  };
};

export const adminRouter = new Hono<AdminEnv>();

const broadcastNotificationInput = z.object({
  title: z.string().trim().min(1).max(120),
  body: z.string().trim().min(1).max(500),
});

const broadcastEmailInput = z.object({
  subject: z.string().trim().min(1).max(200),
  body: z.string().trim().min(1).max(20000),
});

adminRouter.use("/*", async (c, next) => {
  try {
    const authHeader = c.req.header("Authorization") || "";
    const token = authHeader.startsWith("Bearer ")
      ? authHeader.slice("Bearer ".length).trim()
      : authHeader.trim();

    if (!token) {
      c.status(403);
      return c.json({ msg: "Missing authorization token" });
    }

    const { databaseUrl, jwtSecret } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const payload = await verify(token, jwtSecret, "HS256");
    const userId = Number(payload?.id);
    if (!Number.isFinite(userId)) {
      c.status(403);
      return c.json({ msg: "Token payload is missing a valid user id" });
    }

    const user = await prisma.user.findUnique({
      where: { id: userId },
      select: { email: true, groupId: true },
    });
    if (!user) {
      c.status(403);
      return c.json({ msg: "Invalid user" });
    }

    const adminEmails = getAdminEmails(c);
    if (!isAdminEmail(user.email, adminEmails)) {
      c.status(403);
      return c.json({ msg: "Admin access required" });
    }

    c.set("userId", userId);
    c.set("adminEmail", user.email);
    c.set("groupId", user.groupId);
    await next();
  } catch (e) {
    c.status(403);
    return c.json({
      msg: "You are not logged in",
      error: e instanceof Error ? e.message : "Invalid token",
    });
  }
});

adminRouter.get("/stats", async (c) => {
  try {
    const { databaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const since = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);

    const [
      totalUsers,
      totalPosts,
      postAuthors,
      commentAuthors,
      postLikers,
      commentLikers,
    ] = await Promise.all([
      prisma.user.count(),
      prisma.post.count(),
      prisma.post.findMany({
        where: { createdAt: { gte: since } },
        select: { authorId: true },
        distinct: ["authorId"],
      }),
      prisma.comment.findMany({
        where: { createdAt: { gte: since } },
        select: { authorId: true },
        distinct: ["authorId"],
      }),
      prisma.postLike.findMany({
        where: { createdAt: { gte: since } },
        select: { userId: true },
        distinct: ["userId"],
      }),
      prisma.commentLike.findMany({
        where: { createdAt: { gte: since } },
        select: { userId: true },
        distinct: ["userId"],
      }),
    ]);

    // A user is "monthly active" if they posted, commented, or liked anything
    // (post or comment) within the last 30 days.
    const activeUserIds = new Set<number>();
    for (const row of postAuthors) activeUserIds.add(row.authorId);
    for (const row of commentAuthors) activeUserIds.add(row.authorId);
    for (const row of postLikers) activeUserIds.add(row.userId);
    for (const row of commentLikers) activeUserIds.add(row.userId);

    return c.json({
      stats: {
        totalUsers,
        totalPosts,
        monthlyActiveUsers: activeUserIds.size,
      },
    });
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to load stats" });
  }
});

adminRouter.get("/pending-users", async (c) => {
  try {
    const { databaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const users = await prisma.user.findMany({
      where: { status: "pending" },
      orderBy: { createdAt: "asc" },
      select: {
        id: true,
        email: true,
        name: true,
        createdAt: true,
      },
    });

    return c.json({
      users: users.map((user) => ({
        id: user.id,
        email: user.email,
        name: user.name,
        createdAt: user.createdAt.toISOString(),
      })),
    });
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to load pending users" });
  }
});

adminRouter.put("/approve/:id", async (c) => {
  const targetId = Number(c.req.param("id"));
  if (!Number.isFinite(targetId)) {
    c.status(400);
    return c.json({ msg: "Invalid user id" });
  }

  try {
    const { databaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const adminId = c.get("userId");
    const resendApiKey = c.env?.RESEND_API_KEY ?? process.env.RESEND_API_KEY;
    const emailFrom = c.env?.EMAIL_FROM ?? process.env.EMAIL_FROM;
    const frontendUrl = c.env?.FRONTEND_URL ?? process.env.FRONTEND_URL ?? "http://localhost:5173";

    const existingUser = await prisma.user.findUnique({
      where: { id: targetId },
      select: {
        id: true,
        email: true,
        name: true,
        status: true,
      },
    });

    if (!existingUser) {
      c.status(404);
      return c.json({ msg: "User not found" });
    }

    const wasApproved = existingUser.status === "approved";
    const user = await prisma.user.update({
      where: { id: targetId },
      data: {
        status: "approved",
        approvedBy: adminId,
      },
      select: {
        id: true,
        email: true,
        status: true,
      },
    });

    if (wasApproved) {
      return c.json({ msg: "User is already approved", user });
    }

    if (!resendApiKey || !emailFrom) {
      return c.json({
        msg: "User approved, but welcome email was skipped (missing RESEND_API_KEY or EMAIL_FROM).",
        user,
      });
    }

    const signinUrl = new URL("/signin", frontendUrl).toString();

    try {
      await sendWelcomeEmail({
        apiKey: resendApiKey,
        from: emailFrom,
        to: existingUser.email,
        appName: "Eddie's Lounge",
        recipientName: existingUser.name,
        signinUrl,
      });
      return c.json({ msg: "User approved and welcome email sent", user });
    } catch (emailError) {
      console.error(emailError);
      return c.json({
        msg: "User approved, but failed to send welcome email.",
        user,
      });
    }
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to approve user" });
  }
});

adminRouter.put("/reject/:id", async (c) => {
  const targetId = Number(c.req.param("id"));
  if (!Number.isFinite(targetId)) {
    c.status(400);
    return c.json({ msg: "Invalid user id" });
  }

  try {
    const { databaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    try {
      const user = await prisma.user.update({
        where: { id: targetId },
        data: { status: "rejected" },
        select: {
          id: true,
          email: true,
          status: true,
        },
      });
      return c.json({ msg: "User rejected", user });
    } catch (e) {
      if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === "P2025") {
        c.status(404);
        return c.json({ msg: "User not found" });
      }
      throw e;
    }
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to reject user" });
  }
});

adminRouter.get("/email/recipients", async (c) => {
  try {
    const { databaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const recipients = await prisma.user.findMany({
      where: { groupId: c.get("groupId"), status: "approved" },
      orderBy: { email: "asc" },
      select: { id: true, email: true, name: true },
    });

    return c.json({ recipients });
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to load email recipients" });
  }
});

adminRouter.post("/email/broadcast", async (c) => {
  try {
    const body = await c.req.json();
    const parsed = broadcastEmailInput.safeParse(body);
    if (!parsed.success) {
      c.status(400);
      return c.json({
        msg: "Invalid broadcast email payload",
        errors: parsed.error.flatten(),
      });
    }

    const resendApiKey = c.env?.RESEND_API_KEY ?? process.env.RESEND_API_KEY;
    const emailFrom = c.env?.EMAIL_FROM ?? process.env.EMAIL_FROM;
    if (!resendApiKey || !emailFrom) {
      c.status(400);
      return c.json({
        msg: "Email broadcast is not configured (missing RESEND_API_KEY or EMAIL_FROM).",
      });
    }

    const { databaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const recipients = await prisma.user.findMany({
      where: { groupId: c.get("groupId"), status: "approved" },
      select: { email: true, name: true },
    });

    if (recipients.length === 0) {
      c.status(400);
      return c.json({ msg: "No approved users available for broadcast." });
    }

    const result = await sendBroadcastEmail({
      apiKey: resendApiKey,
      from: emailFrom,
      appName: "Eddie's Lounge",
      subject: parsed.data.subject,
      markdownBody: parsed.data.body,
      recipients,
    });

    if (result.delivered === 0) {
      console.error("[admin] email broadcast failed for all recipients", {
        attempted: result.attempted,
        failures: result.failures,
      });
      c.status(502);
      return c.json({
        msg: "Email broadcast failed for all recipients.",
        result: { attempted: result.attempted, delivered: 0, failed: result.failed },
      });
    }

    if (result.failed > 0) {
      console.warn("[admin] email broadcast had partial failures", {
        attempted: result.attempted,
        delivered: result.delivered,
        failed: result.failed,
        failures: result.failures,
      });
    }

    return c.json({
      msg: `Email sent to ${result.delivered} of ${result.attempted} user${result.attempted === 1 ? "" : "s"}.`,
      result: {
        attempted: result.attempted,
        delivered: result.delivered,
        failed: result.failed,
      },
    });
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to send broadcast email." });
  }
});

adminRouter.post("/push/broadcast", async (c) => {
  try {
    const body = await c.req.json();
    const parsed = broadcastNotificationInput.safeParse(body);
    if (!parsed.success) {
      c.status(400);
      return c.json({
        msg: "Invalid broadcast notification payload",
        errors: parsed.error.flatten(),
      });
    }

    const { databaseUrl, vapidPublicKey, vapidPrivateKey, vapidSubject } = getConfig(c);
    const result = await sendBroadcastNotification({
      databaseUrl,
      groupId: c.get("groupId"),
      title: parsed.data.title,
      body: parsed.data.body,
      vapidConfig: {
        vapidPublicKey,
        vapidPrivateKey,
        vapidSubject,
      },
    });

    return c.json({
      msg: `Broadcast sent to ${result.delivered} device${result.delivered === 1 ? "" : "s"}.`,
      result,
    });
  } catch (e) {
    if (e instanceof Error) {
      const msg = e.message || "Failed to send broadcast notification.";
      if (
        msg.includes("Push notifications are not configured") ||
        msg.includes("No subscribed users available") ||
        msg.includes("Broadcast delivery failed")
      ) {
        c.status(400);
        return c.json({ msg });
      }
    }

    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to send broadcast notification." });
  }
});

// --- reports ----------------------------------------------------------------
//
// Reports span every group: whoever administers the app answers for all of it.

adminRouter.get("/reports", async (c) => {
  try {
    const { databaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const userSelect = { select: { id: true, name: true, email: true, status: true } } as const;
    const reports = await prisma.contentReport.findMany({
      // Open first ("open" < "resolved"), oldest open report on top.
      orderBy: [{ status: "asc" }, { createdAt: "asc" }],
      take: 200,
      select: {
        id: true,
        instantId: true,
        reason: true,
        details: true,
        evidenceKey: true,
        status: true,
        resolution: true,
        createdAt: true,
        resolvedAt: true,
        reporter: userSelect,
        reportedUser: userSelect,
      },
    });

    return c.json({
      reports: reports.map((report) => ({
        id: report.id,
        instantId: report.instantId,
        reason: report.reason,
        details: report.details,
        hasEvidence: report.evidenceKey !== null,
        status: report.status,
        resolution: report.resolution,
        createdAt: report.createdAt.toISOString(),
        resolvedAt: report.resolvedAt ? report.resolvedAt.toISOString() : null,
        reporter: report.reporter,
        reportedUser: report.reportedUser,
      })),
    });
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to load reports" });
  }
});

// Streamed through the API rather than linked from the public bucket domain:
// evidence is a private photo someone chose to show the moderators, not
// anybody holding a URL.
adminRouter.get("/reports/:id/evidence", async (c) => {
  const reportId = Number(c.req.param("id"));
  if (!Number.isInteger(reportId) || reportId <= 0) {
    c.status(400);
    return c.json({ msg: "Invalid report id" });
  }
  try {
    const { databaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const report = await prisma.contentReport.findUnique({
      where: { id: reportId },
      select: { evidenceKey: true },
    });
    const bucket = c.env?.BLOG_IMAGES;
    const object = report?.evidenceKey && bucket ? await bucket.get(report.evidenceKey) : null;
    if (!object) {
      c.status(404);
      return c.json({ msg: "No photo is attached to this report." });
    }
    const bytes = await object.arrayBuffer();
    return c.body(bytes, 200, {
      "Content-Type": object.httpMetadata?.contentType ?? "application/octet-stream",
      "Content-Length": String(bytes.byteLength),
      "Cache-Control": "no-store",
    });
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to load the attached photo" });
  }
});

adminRouter.put("/reports/:id/resolve", async (c) => {
  const reportId = Number(c.req.param("id"));
  if (!Number.isInteger(reportId) || reportId <= 0) {
    c.status(400);
    return c.json({ msg: "Invalid report id" });
  }
  try {
    const parsed = resolveReportInput.safeParse(await c.req.json());
    if (!parsed.success) {
      c.status(400);
      return c.json({ msg: "Invalid resolution", errors: parsed.error.flatten() });
    }

    const { databaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const report = await prisma.contentReport.findUnique({
      where: { id: reportId },
      select: { id: true, evidenceKey: true, reportedUserId: true },
    });
    if (!report) {
      c.status(404);
      return c.json({ msg: "Report not found" });
    }

    const now = new Date();
    if (parsed.data.action === "suspend" && report.reportedUserId !== null) {
      // "rejected" is what sign-in and refresh already refuse, and revoking the
      // sessions ends the one they are in within an access token's lifetime.
      await prisma.$transaction([
        prisma.user.update({
          where: { id: report.reportedUserId },
          data: { status: "rejected" },
        }),
        prisma.session.updateMany({
          where: { userId: report.reportedUserId, revokedAt: null },
          data: { revokedAt: now },
        }),
      ]);
    }

    // The photo was shared for this decision and nothing else.
    const bucket = c.env?.BLOG_IMAGES;
    if (report.evidenceKey && bucket) {
      await bucket.delete(report.evidenceKey);
    }

    const updated = await prisma.contentReport.update({
      where: { id: report.id },
      data: {
        status: "resolved",
        resolution: parsed.data.action === "suspend" ? "suspended" : "dismissed",
        resolvedAt: now,
        evidenceKey: bucket ? null : report.evidenceKey,
      },
      select: { id: true, status: true, resolution: true },
    });

    return c.json({ report: updated });
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to resolve the report" });
  }
});

// Runs the hourly Instant maintenance pass on demand. Cron triggers fire under
// neither `tsx src/server.ts` nor `wrangler dev`, so without this the expiry
// sweep and the streak warnings would be untestable outside production.
adminRouter.post("/instant/sweep", async (c) => {
  try {
    const report = await runInstantSweep({
      DATABASE_URL: c.env?.DATABASE_URL ?? process.env.DATABASE_URL,
      VAPID_PUBLIC_KEY: c.env?.VAPID_PUBLIC_KEY ?? process.env.VAPID_PUBLIC_KEY,
      VAPID_PRIVATE_KEY: c.env?.VAPID_PRIVATE_KEY ?? process.env.VAPID_PRIVATE_KEY,
      VAPID_SUBJECT: c.env?.VAPID_SUBJECT ?? process.env.VAPID_SUBJECT,
      BLOG_IMAGES: c.env?.BLOG_IMAGES,
    });
    return c.json({ msg: "Instant sweep complete.", report });
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to run the Instant sweep." });
  }
});
