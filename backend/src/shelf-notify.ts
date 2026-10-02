import type { PrismaClient } from "@prisma/client";
import { blockedUserIds } from "./blocks";
import { sendPushToUsers } from "./push";
import { dayOf, partitionClubNotes, readerReach } from "./shelf-logic";

// Books' notifications, beyond replies in a review's discussion (which live
// with the discussion in src/route/shelf.ts).
//
// Two kinds, each with its own switch on the account:
//
// - Book club: a note someone left that the reader can already read. The
//   same gate as the club screen decides (partitionClubNotes), so a
//   notification never shows anyone more than the club would — and its text is
//   in the notification, because a note within your reach is not a spoiler.
//   At most one per book per reader per day: a busy club is one buzz.
// - Activity: a friend starting a book you want to read, or finishing one
//   you are reading. Never from an import or a backfilled read, which would
//   replay years of somebody's history at everyone at once.
//
// All of it is Web Push only (no apnsConfig): the iOS app is Instant and
// cannot open Books. Blocks are honoured in both directions.

export type NotifyConfig = {
  databaseUrl: string;
  vapidPublicKey?: string | null;
  vapidPrivateKey?: string | null;
  vapidSubject?: string | null;
};

const BOOK_CLUB_SNIPPET = 140;

/**
 * Records that `key` was sent to this person today, or reports that it
 * already was. The insert is the check, so two notes arriving together cannot
 * both get through.
 */
async function claimToday(prisma: PrismaClient, userId: number, key: string) {
  try {
    await prisma.notificationSent.create({ data: { userId, key, sentOn: new Date(`${dayOf(new Date())}T00:00:00Z`) } });
    return true;
  } catch {
    return false;
  }
}

async function send(config: NotifyConfig, userIds: number[], title: string, body: string, openUrl: string, topic: string) {
  if (userIds.length === 0) return;
  await sendPushToUsers({
    databaseUrl: config.databaseUrl,
    userIds,
    payload: { title, body, data: { openUrl } },
    topic,
    vapidConfig: {
      vapidPublicKey: config.vapidPublicKey,
      vapidPrivateKey: config.vapidPrivateKey,
      vapidSubject: config.vapidSubject,
    },
  });
}

/**
 * A note was just left in a book club. Tells the people currently reading the
 * book who can already read it — and nobody who could not.
 */
export async function notifyBookClubNote(
  prisma: PrismaClient,
  config: NotifyConfig,
  logId: number
): Promise<number[]> {
  const log = await prisma.progressLog.findUnique({
    where: { id: logId },
    select: {
      id: true,
      userId: true,
      toPosition: true,
      note: true,
      user: { select: { name: true, groupId: true } },
      run: {
        select: {
          totalUnits: true,
          unitsConfirmed: true,
          entry: { select: { item: { select: { id: true, title: true, totalUnits: true } } } },
        },
      },
    },
  });
  if (!log?.note) return [];
  const item = log.run.entry.item;

  const [runs, blocked] = await Promise.all([
    prisma.shelfRun.findMany({
      where: {
        entry: {
          itemId: item.id,
          userId: { not: log.userId },
          user: { groupId: log.user.groupId, notificationsEnabled: true, notifyBookClub: true },
        },
      },
      select: {
        status: true,
        position: true,
        totalUnits: true,
        unitsConfirmed: true,
        entry: { select: { userId: true } },
      },
    }),
    blockedUserIds(prisma, log.userId),
  ]);

  // Everyone with a read of this book in progress; their reach counts every
  // read they have had of it, as on the club screen.
  const readers = new Map<number, typeof runs>();
  for (const run of runs) {
    const userId = run.entry.userId;
    readers.set(userId, [...(readers.get(userId) ?? []), run]);
  }

  const note = {
    id: log.id,
    userId: log.userId,
    toPosition: log.toPosition,
    runTotalUnits: log.run.totalUnits,
    runUnitsConfirmed: log.run.unitsConfirmed,
  };
  const recipients: number[] = [];
  for (const [userId, theirRuns] of readers) {
    if (blocked.has(userId)) continue;
    if (!theirRuns.some((run) => run.status === "active")) continue;
    const reach = readerReach(theirRuns, item.totalUnits);
    // Someone who has finished the book is not reading it; their club has
    // moved on, and a buzz about page 40 is noise.
    if (reach.fraction >= 1) continue;
    const { visible } = partitionClubNotes([note], userId, reach, item.totalUnits);
    if (visible.length === 0) continue;
    if (await claimToday(prisma, userId, `club:${item.id}`)) recipients.push(userId);
  }

  const name = log.user.name?.trim() || "Someone";
  const snippet = log.note.length > BOOK_CLUB_SNIPPET ? `${log.note.slice(0, BOOK_CLUB_SNIPPET - 1)}…` : log.note;
  await send(
    config,
    recipients,
    `${name} in the ${item.title} book club`,
    snippet,
    `/books/club/${item.id}`,
    `shelf-club-${item.id}`
  );
  return recipients;
}

/**
 * Someone started a book: tells the friends who have it on their want list.
 * Each gets their own link, to their own entry for it, so starting it too is
 * one tap away.
 */
export async function notifyStartedReading(
  prisma: PrismaClient,
  config: NotifyConfig,
  input: { actorId: number; itemId: number }
): Promise<number[]> {
  const actor = await prisma.user.findUnique({ where: { id: input.actorId }, select: { name: true, groupId: true } });
  const item = await prisma.catalogItem.findUnique({ where: { id: input.itemId }, select: { title: true } });
  if (!actor || !item) return [];
  const [wishes, blocked] = await Promise.all([
    prisma.shelfEntry.findMany({
      where: {
        itemId: input.itemId,
        wantedAt: { not: null },
        userId: { not: input.actorId },
        user: { groupId: actor.groupId, notificationsEnabled: true, notifyBookActivity: true },
        runs: { none: { status: "active" } },
      },
      select: { id: true, userId: true },
    }),
    blockedUserIds(prisma, input.actorId),
  ]);

  const name = actor.name?.trim() || "Someone";
  const sent: number[] = [];
  for (const wish of wishes) {
    if (blocked.has(wish.userId)) continue;
    if (!(await claimToday(prisma, wish.userId, `started:${input.itemId}:${input.actorId}`))) continue;
    await send(
      config,
      [wish.userId],
      `${name} started ${item.title}`,
      "It's on your want-to-read list.",
      `/books/item/${wish.id}`,
      `shelf-started-${input.itemId}-${input.actorId}`
    );
    sent.push(wish.userId);
  }
  return sent;
}

/**
 * Someone finished a book: tells the friends reading it now. Nothing about
 * what they thought — a rating is the beginning of a spoiler.
 */
export async function notifyFinishedReading(
  prisma: PrismaClient,
  config: NotifyConfig,
  input: { actorId: number; itemId: number }
): Promise<number[]> {
  const actor = await prisma.user.findUnique({ where: { id: input.actorId }, select: { name: true, groupId: true } });
  const item = await prisma.catalogItem.findUnique({ where: { id: input.itemId }, select: { title: true } });
  if (!actor || !item) return [];
  const [readers, blocked] = await Promise.all([
    prisma.shelfRun.findMany({
      where: {
        status: "active",
        entry: {
          itemId: input.itemId,
          userId: { not: input.actorId },
          user: { groupId: actor.groupId, notificationsEnabled: true, notifyBookActivity: true },
        },
      },
      select: { entry: { select: { userId: true } } },
    }),
    blockedUserIds(prisma, input.actorId),
  ]);

  const recipients: number[] = [];
  for (const userId of new Set(readers.map((run) => run.entry.userId))) {
    if (blocked.has(userId)) continue;
    if (await claimToday(prisma, userId, `finished:${input.itemId}:${input.actorId}`)) recipients.push(userId);
  }
  const name = actor.name?.trim() || "Someone";
  await send(
    config,
    recipients,
    `${name} finished ${item.title}`,
    "You're reading it too. Their notes are in the book club as you get to them.",
    `/books/club/${input.itemId}`,
    `shelf-finished-${input.itemId}-${input.actorId}`
  );
  return recipients;
}
