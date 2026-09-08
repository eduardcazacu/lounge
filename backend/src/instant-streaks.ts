import type { PrismaClient } from "@prisma/client";
import type { InstantStreakSummary } from "@blogging-app/common";

// Snapchat-style streaks over Instant sends.
//
// A streak between two users advances once per UTC day, and only when BOTH have
// sent to the other within the last 24 hours. It lapses when either side's most
// recent send ages past that window.
//
// Streaks count sends, not opens: an instant that expired unopened, or that the
// recipient could not decrypt after losing their device key, still counts. That
// is deliberate — streak state must not depend on key material the server has no
// way to reason about.

export const STREAK_WINDOW_MS = 24 * 60 * 60 * 1000;
// How far ahead of the deadline we warn people.
export const STREAK_WARNING_WINDOW_MS = 4 * 60 * 60 * 1000;
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

export function streakDeadline(
  lastLowSentAt: Date | null,
  lastHighSentAt: Date | null
): Date | null {
  if (!lastLowSentAt || !lastHighSentAt) {
    return null;
  }
  const oldest = Math.min(lastLowSentAt.getTime(), lastHighSentAt.getTime());
  return new Date(oldest + STREAK_WINDOW_MS);
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

  const streak = await prisma.instantStreak.upsert({
    where: { userLowId_userHighId: { userLowId: low, userHighId: high } },
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

  if (now.getTime() - otherSentAt.getTime() > STREAK_WINDOW_MS) {
    // The other side went quiet for more than a day; whatever streak existed is
    // already gone. This send starts the clock again rather than extending it.
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
      count: { increment: 1 },
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

// Streaks long enough to be worth saving that lapse within the warning window
// and have not already been warned about today.
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
    if (!deadline) {
      continue;
    }
    const msLeft = deadline.getTime() - now.getTime();
    if (msLeft <= 0 || msLeft > STREAK_WARNING_WINDOW_MS) {
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
  now: Date = new Date()
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
    .map((streak) => {
      const partner = streak.userLowId === userId ? streak.userHigh : streak.userLow;
      const deadline = streakDeadline(streak.lastLowSentAt, streak.lastHighSentAt);
      const msLeft = deadline ? deadline.getTime() - now.getTime() : -1;
      return {
        userId: partner.id,
        name: partner.name,
        themeKey: partner.themeKey,
        profilePictureUrl: buildProfilePictureUrl(partner.profilePictureKey),
        count: streak.count,
        deadline: deadline ? deadline.toISOString() : null,
        atRisk: msLeft > 0 && msLeft <= STREAK_WARNING_WINDOW_MS,
      } satisfies InstantStreakSummary;
    })
    .sort((a, b) => (a.deadline ?? "").localeCompare(b.deadline ?? ""));
}
