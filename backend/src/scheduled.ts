import type { Context } from "hono";
import { getConfig } from "./env";
import { getPrismaClient } from "./prisma";
import { sendPushToUsers } from "./push";
import {
  expireLapsedStreaks,
  findStreaksAtRisk,
  markStreaksWarned,
  STREAK_WARNING_WINDOW_MS,
} from "./instant-streaks";

// Instants that have been opened keep a row for a while so streaks and read
// receipts stay coherent, but the row holds no media and no key material.
const OPENED_ROW_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;
// Cap the work one tick can do, so a backlog can never blow the CPU budget.
const SWEEP_BATCH_SIZE = 200;

export type SweepEnv = {
  DATABASE_URL?: string;
  HYPERDRIVE?: Hyperdrive;
  JWT_SECRET?: string;
  R2_PUBLIC_BASE_URL?: string;
  VAPID_PUBLIC_KEY?: string;
  VAPID_PRIVATE_KEY?: string;
  VAPID_SUBJECT?: string;
  BLOG_IMAGES?: R2Bucket;
};

export type SweepReport = {
  expiredInstants: number;
  /** Expired rows left untouched because there was no R2 binding to delete from. */
  skippedWithoutBucket: number;
  deletedRows: number;
  lapsedStreaks: number;
  warnedStreaks: number;
};

// The hourly maintenance pass. Exported plainly so the admin route can run it
// on demand — cron triggers fire under neither `tsx src/server.ts` nor
// `wrangler dev`, which would otherwise make this impossible to test.
export async function runInstantSweep(env: SweepEnv, now: Date = new Date()): Promise<SweepReport> {
  // getConfig reads c.env with a process.env fallback; a scheduled handler has
  // no Hono context, so hand it the bindings directly.
  const { databaseUrl, vapidPublicKey, vapidPrivateKey, vapidSubject, apnsKeyId, apnsTeamId, apnsPrivateKey, apnsBundleId } = getConfig({
    env,
  } as unknown as Context<any>);
  const prisma = getPrismaClient(databaseUrl);
  const bucket = env?.BLOG_IMAGES;

  // 1. Unopened instants past their 24h TTL. Delete the object first, then the
  //    keys, so a failure part-way through never leaves a readable pair.
  const expired = await prisma.instant.findMany({
    where: { expiresAt: { lt: now }, mediaKey: { not: null } },
    select: { id: true, mediaKey: true },
    take: SWEEP_BATCH_SIZE,
  });

  let expiredCount = 0;
  let skippedWithoutBucket = 0;
  for (const instant of expired) {
    try {
      if (instant.mediaKey) {
        if (!bucket) {
          // The row is the only thing that still knows this object's key, so
          // clearing it without a bucket to delete from would strand the
          // ciphertext permanently. Leave the row alone and retry next run.
          skippedWithoutBucket += 1;
          continue;
        }
        await bucket.delete(instant.mediaKey);
      }
      await prisma.instantKeyEnvelope.deleteMany({ where: { instantId: instant.id } });
      await prisma.instant.update({
        where: { id: instant.id },
        data: { mediaKey: null, mediaIv: null, ephemeralPubKey: null },
      });
      expiredCount += 1;
    } catch (error) {
      console.error("[instant] failed to expire instant", instant.id, error);
    }
  }

  if (skippedWithoutBucket > 0) {
    console.warn(
      "[instant] skipped expiring media because the BLOG_IMAGES binding is missing",
      { skipped: skippedWithoutBucket }
    );
  }

  // 2. Drop long-dead rows. Streak state lives in its own table and survives.
  const deleted = await prisma.instant.deleteMany({
    where: { createdAt: { lt: new Date(now.getTime() - OPENED_ROW_RETENTION_MS) } },
  });

  // 3. Streaks whose window has closed.
  const lapsed = await expireLapsedStreaks(prisma, now);

  // 4. Warn both people on a long streak that is about to lapse.
  const atRisk = await findStreaksAtRisk(prisma, now);
  const warnedIds: number[] = [];
  for (const streak of atRisk) {
    const hoursLeft = Math.max(
      1,
      Math.round((streak.deadline.getTime() - now.getTime()) / (60 * 60 * 1000))
    );
    try {
      await sendPushToUsers({
        databaseUrl,
        userIds: [streak.userLowId, streak.userHighId],
        payload: {
          title: `Your ${streak.count}-day streak is about to end`,
          body: `Send an instant in the next ${hoursLeft} hour${hoursLeft === 1 ? "" : "s"} to keep it alive.`,
          data: { openUrl: "/instant", streakCount: streak.count },
        },
        topic: `streak-${streak.id}`,
        appFirst: true,
        vapidConfig: { vapidPublicKey, vapidPrivateKey, vapidSubject },
        apnsConfig: { apnsKeyId, apnsTeamId, apnsPrivateKey, apnsBundleId },
      });
      warnedIds.push(streak.id);
    } catch (error) {
      console.error("[instant] failed to warn about streak", streak.id, error);
    }
  }
  await markStreaksWarned(prisma, warnedIds, now);

  const report: SweepReport = {
    expiredInstants: expiredCount,
    skippedWithoutBucket,
    deletedRows: deleted.count,
    lapsedStreaks: lapsed,
    warnedStreaks: warnedIds.length,
  };
  console.log("[instant] sweep complete", {
    ...report,
    warningWindowHours: STREAK_WARNING_WINDOW_MS / (60 * 60 * 1000),
  });
  return report;
}

export async function scheduled(
  _controller: ScheduledController,
  env: SweepEnv,
  ctx: ExecutionContext
): Promise<void> {
  ctx.waitUntil(
    runInstantSweep(env).catch((error) => {
      console.error("[instant] sweep failed", error);
    })
  );
}
