import type { PrismaClient } from "@prisma/client";
import type { InstantStreakSummary } from "@blogging-app/common";

// Snapchat-style streaks over Instant sends.
//
// A streak between two users advances once per UTC day, and only when the other
// side has sent today or yesterday. A send keeps the streak alive until the end
// of the next UTC day, so it lapses at midnight after a whole day in which one
// side sent nothing. Snapping the deadline to midnight means the time you sent
// yesterday doesn't decide how much of today you get.
//
// Streaks count sends, not opens: an instant that expired unopened, or that the
// recipient could not decrypt after losing their device key, still counts. That
// is deliberate — streak state must not depend on key material the server has no
// way to reason about.

const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;
// How long past the time of yesterday's send a streak starts to count as at risk.
export const STREAK_WARNING_DELAY_MS = HOUR_MS;
// Only streaks worth saving get a notification.
export const STREAK_WARNING_MIN_COUNT = 7;

export type StreakPair = { low: number; high: number };

// One row per relationship, keyed on the ordered pair.
export function orderPair(a: number, b: number): StreakPair {
  return a < b ? { low: a, high: b } : { low: b, high: a };
}

// Midnight UTC for the day containing `date`. All streak day arithmetic is UTC,
// so a user in a distant timezone sees the day roll over at an odd local hour.
export function utcDayStart(date: Date): Date {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()));
}

// The midnight a single send stops counting: the end of the day after it.
function keepsAliveUntil(sentAt: Date): Date {
  return new Date(utcDayStart(sentAt).getTime() + 2 * DAY_MS);
}

export function streakDeadline(
  lastLowSentAt: Date | null,
  lastHighSentAt: Date | null
): Date | null {
  if (!lastLowSentAt || !lastHighSentAt) {
    return null;
  }
  const oldest = Math.min(lastLowSentAt.getTime(), lastHighSentAt.getTime());
  return keepsAliveUntil(new Date(oldest));
}

// When a streak starts counting as at risk: a little after the time of day the
// quiet side sent yesterday, so the warning arrives around when they usually
// send instead of at one fixed hour for everybody. Never later than an hour
// before the deadline, because the hourly cron's last tick before midnight is
// 23:00 and a later warning would never be sent.
export function streakWarnsAt(
  lastLowSentAt: Date | null,
  lastHighSentAt: Date | null
): Date | null {
  const deadline = streakDeadline(lastLowSentAt, lastHighSentAt);
  if (!lastLowSentAt || !lastHighSentAt || !deadline) {
    return null;
  }
  const oldest = Math.min(lastLowSentAt.getTime(), lastHighSentAt.getTime());
  return new Date(Math.min(oldest + DAY_MS + STREAK_WARNING_DELAY_MS, deadline.getTime() - HOUR_MS));
}

export function isStreakAtRisk(
  lastLowSentAt: Date | null,
  lastHighSentAt: Date | null,
  now: Date
): boolean {
  const deadline = streakDeadline(lastLowSentAt, lastHighSentAt);
  const warnsAt = streakWarnsAt(lastLowSentAt, lastHighSentAt);
  if (!deadline || !warnsAt) {
    return false;
  }
  return warnsAt.getTime() <= now.getTime() && now.getTime() < deadline.getTime();
}

// Called on every send. Records the sender's side, then advances the streak if
// the exchange is now mutual and today has not already been counted.
export async function recordSend(
  prisma: PrismaClient,
  senderId: number,
  recipientId: number,
  now: Date = new Date()
): Promise<void> {
  const { low, high } = orderPair(senderId, recipientId);
  const senderIsLow = senderId === low;
  const where = { userLowId_userHighId: { userLowId: low, userHighId: high } };

  // Every deadline is a midnight, which is exactly when the hourly cron fires,
  // so a send in the seconds before it runs can find a dead streak still
  // counted. Judge that from the marks as they were before this send, which
  // the upsert below overwrites.
  const before = await prisma.instantStreak.findUnique({
    where,
    select: { count: true, lastLowSentAt: true, lastHighSentAt: true },
  });
  const beforeDeadline = before && streakDeadline(before.lastLowSentAt, before.lastHighSentAt);
  const lapsedUnswept =
    !!before && before.count > 0 && (!beforeDeadline || beforeDeadline.getTime() <= now.getTime());

  const streak = await prisma.instantStreak.upsert({
    where,
    create: {
      userLowId: low,
      userHighId: high,
      count: 0,
      lastLowSentAt: senderIsLow ? now : null,
      lastHighSentAt: senderIsLow ? null : now,
    },
    update: senderIsLow ? { lastLowSentAt: now } : { lastHighSentAt: now },
  });

  const otherSentAt = senderIsLow ? streak.lastHighSentAt : streak.lastLowSentAt;
  if (!otherSentAt) {
    // Never reciprocated. Nothing to count yet.
    return;
  }

  if (keepsAliveUntil(otherSentAt).getTime() <= now.getTime()) {
    // The other side sent nothing yesterday or today; whatever streak existed
    // is already gone. This send starts the clock again rather than extending it.
    if (streak.count !== 0) {
      await prisma.instantStreak.update({
        where: { id: streak.id },
        data: { count: 0, lastIncrementOn: null, warnedForOn: null },
      });
    }
    return;
  }

  const today = utcDayStart(now);
  if (streak.lastIncrementOn && streak.lastIncrementOn.getTime() >= today.getTime()) {
    // Already counted today. Further sends keep the streak alive but don't add.
    return;
  }

  await prisma.instantStreak.update({
    where: { id: streak.id },
    data: {
      // A streak the sweep should already have zeroed restarts here, as it
      // would have after the sweep.
      count: lapsedUnswept ? 1 : { increment: 1 },
      lastIncrementOn: today,
      // Clear the warning stamp so tomorrow can warn again.
      warnedForOn: null,
    },
  });
}

// Zero out every streak whose window has closed. Runs from the hourly cron.
//
// Deliberately done with the query API and JS date arithmetic rather than SQL:
// the timestamp columns are `timestamp without time zone`, so comparing them
// against driver-supplied parameters invites a session-timezone offset. A
// friends-group app has few enough streaks that reading them is free.
export async function expireLapsedStreaks(
  prisma: PrismaClient,
  now: Date = new Date()
): Promise<number> {
  const live = await prisma.instantStreak.findMany({
    where: { count: { gt: 0 } },
    select: { id: true, lastLowSentAt: true, lastHighSentAt: true },
  });

  const lapsedIds = live
    .filter((streak) => {
      const deadline = streakDeadline(streak.lastLowSentAt, streak.lastHighSentAt);
      // A one-sided streak has no deadline and cannot still be alive.
      return deadline === null || deadline.getTime() <= now.getTime();
    })
    .map((streak) => streak.id);

  if (lapsedIds.length === 0) {
    return 0;
  }

  const result = await prisma.instantStreak.updateMany({
    where: { id: { in: lapsedIds } },
    data: { count: 0, lastIncrementOn: null, warnedForOn: null },
  });
  return result.count;
}

export type StreakAtRisk = {
  id: number;
  userLowId: number;
  userHighId: number;
  count: number;
  deadline: Date;
};

// Streaks long enough to be worth saving that are at risk and have not already
// been warned about today.
export async function findStreaksAtRisk(
  prisma: PrismaClient,
  now: Date = new Date()
): Promise<StreakAtRisk[]> {
  const today = utcDayStart(now);
  const candidates = await prisma.instantStreak.findMany({
    where: {
      count: { gte: STREAK_WARNING_MIN_COUNT },
      lastLowSentAt: { not: null },
      lastHighSentAt: { not: null },
    },
    select: {
      id: true,
      userLowId: true,
      userHighId: true,
      count: true,
      lastLowSentAt: true,
      lastHighSentAt: true,
      warnedForOn: true,
    },
  });

  const atRisk: StreakAtRisk[] = [];
  for (const streak of candidates) {
    const deadline = streakDeadline(streak.lastLowSentAt, streak.lastHighSentAt);
    if (!deadline || !isStreakAtRisk(streak.lastLowSentAt, streak.lastHighSentAt, now)) {
      continue;
    }
    if (streak.warnedForOn && streak.warnedForOn.getTime() >= today.getTime()) {
      continue;
    }
    atRisk.push({
      id: streak.id,
      userLowId: streak.userLowId,
      userHighId: streak.userHighId,
      count: streak.count,
      deadline,
    });
  }
  return atRisk;
}

export async function markStreaksWarned(
  prisma: PrismaClient,
  streakIds: number[],
  now: Date = new Date()
): Promise<void> {
  if (streakIds.length === 0) {
    return;
  }
  await prisma.instantStreak.updateMany({
    where: { id: { in: streakIds } },
    data: { warnedForOn: utcDayStart(now) },
  });
}

const streakUserSelect = {
  id: true,
  name: true,
  themeKey: true,
  profilePictureKey: true,
} as const;

// Live streaks for one user, newest deadline first.
export async function listStreaksForUser(
  prisma: PrismaClient,
  userId: number,
  buildProfilePictureUrl: (key: string | null) => string | null,
  now: Date = new Date(),
  // People on the other side of a block.
  hiddenUserIds: ReadonlySet<number> = new Set()
): Promise<InstantStreakSummary[]> {
  const streaks = await prisma.instantStreak.findMany({
    where: {
      count: { gt: 0 },
      OR: [{ userLowId: userId }, { userHighId: userId }],
    },
    include: {
      userLow: { select: streakUserSelect },
      userHigh: { select: streakUserSelect },
    },
  });

  return streaks
    .filter((streak) => !hiddenUserIds.has(streak.userLowId === userId ? streak.userHighId : streak.userLowId))
    .map((streak) => {
      const partner = streak.userLowId === userId ? streak.userHigh : streak.userLow;
      const deadline = streakDeadline(streak.lastLowSentAt, streak.lastHighSentAt);
      return {
        userId: partner.id,
        name: partner.name,
        themeKey: partner.themeKey,
        profilePictureUrl: buildProfilePictureUrl(partner.profilePictureKey),
        count: streak.count,
        deadline: deadline ? deadline.toISOString() : null,
        atRisk: isStreakAtRisk(streak.lastLowSentAt, streak.lastHighSentAt, now),
      } satisfies InstantStreakSummary;
    })
    .sort((a, b) => (a.deadline ?? "").localeCompare(b.deadline ?? ""));
}
