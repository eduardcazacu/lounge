import type { PrismaClient } from "@prisma/client";
import type { InstantConversation, InstantSendReceipt } from "@blogging-app/common";

import { STREAK_WARNING_WINDOW_MS, streakDeadline } from "./instant-streaks";

// Who you have talked to, whether or not a streak is running.
//
// The streak table doubles as a permanent index of conversations: `recordSend`
// upserts a row on the very first send, and a lapse only zeroes the count — the
// row, and its two `last*SentAt` marks, stay for good. That matters because the
// `instants` rows themselves are swept after 30 days, so they cannot be the
// source of truth for "who have I ever talked to".
//
// Nothing here reads media, keys or envelopes; a conversation is metadata the
// server already holds in the clear.

const conversationUserSelect = {
  id: true,
  name: true,
  themeKey: true,
  profilePictureKey: true,
  status: true,
  emailVerifiedAt: true,
} as const;

// Matches the cap on `GET /api/v1/user/list`. Ordering is by recency, so a
// truncated list keeps the conversations anyone would actually look for.
const MAX_CONVERSATIONS = 200;

// How far back a read receipt is worth reporting. An instant lives 24 hours, so
// this covers its whole life and a day of aftermath — long enough to say "they
// never opened it", short enough that a conversation nobody is thinking about
// stops carrying a receipt. It also bounds the query: only what one person sent
// in two days.
//
// The clients apply their own window to what they draw. The two need not agree
// exactly; whichever is shorter is the one that shows.
const SEND_RECEIPT_WINDOW_MS = 48 * 60 * 60 * 1000;

function newest(left: Date | null, right: Date | null): Date | null {
  if (!left) return right;
  if (!right) return left;
  return left.getTime() >= right.getTime() ? left : right;
}

export async function listConversationsForUser(
  prisma: PrismaClient,
  userId: number,
  buildProfilePictureUrl: (key: string | null) => string | null,
  now: Date = new Date(),
  // People on the other side of a block. Their conversation disappears for both.
  hiddenUserIds: ReadonlySet<number> = new Set()
): Promise<InstantConversation[]> {
  const [streaks, waiting, sent] = await Promise.all([
    prisma.instantStreak.findMany({
      // Deliberately not filtered on `count`: a lapsed streak is still a
      // conversation, which is the whole point of this endpoint.
      where: { OR: [{ userLowId: userId }, { userHighId: userId }] },
      include: {
        userLow: { select: conversationUserSelect },
        userHigh: { select: conversationUserSelect },
      },
    }),
    // Tallied in JS rather than with groupBy: the set is bounded by what one
    // person has left unopened, and this keeps the query shape boring.
    prisma.instant.findMany({
      where: {
        recipientId: userId,
        openedAt: null,
        mediaKey: { not: null },
        expiresAt: { gt: now },
      },
      select: { senderId: true },
    }),
    // The other direction: what the caller has sent recently, for the receipt.
    // Newest first, so the first row seen per recipient is the one to report.
    prisma.instant.findMany({
      where: {
        senderId: userId,
        createdAt: { gt: new Date(now.getTime() - SEND_RECEIPT_WINDOW_MS) },
      },
      orderBy: { createdAt: "desc" },
      select: { recipientId: true, createdAt: true, openedAt: true, expiresAt: true },
    }),
  ]);

  const unopenedBySender = new Map<number, number>();
  for (const instant of waiting) {
    unopenedBySender.set(instant.senderId, (unopenedBySender.get(instant.senderId) ?? 0) + 1);
  }

  // Only the newest per person. Several photos to the same person are several
  // instants, and a row has space for one answer to "did it land" — the last
  // one is the one being asked about.
  const receiptByRecipient = new Map<number, InstantSendReceipt>();
  for (const instant of sent) {
    if (receiptByRecipient.has(instant.recipientId)) {
      continue;
    }
    receiptByRecipient.set(instant.recipientId, {
      sentAt: instant.createdAt.toISOString(),
      openedAt: instant.openedAt ? instant.openedAt.toISOString() : null,
      expiresAt: instant.expiresAt.toISOString(),
    });
  }

  const conversations: InstantConversation[] = [];

  for (const streak of streaks) {
    const iAmLow = streak.userLowId === userId;
    const partner = iAmLow ? streak.userHigh : streak.userLow;

    if (hiddenUserIds.has(partner.id)) {
      continue;
    }

    // Same gate as the rest of the API: someone unapproved or unverified is not
    // addressable, so listing them would only offer a send that 404s.
    if (partner.status !== "approved" || partner.emailVerifiedAt === null) {
      continue;
    }

    const lastSentAt = iAmLow ? streak.lastLowSentAt : streak.lastHighSentAt;
    const lastReceivedAt = iAmLow ? streak.lastHighSentAt : streak.lastLowSentAt;
    const lastInteractionAt = newest(lastSentAt, lastReceivedAt);
    if (!lastInteractionAt) {
      // A row with no send on either side should not exist, but an empty
      // conversation is not worth showing if one ever does.
      continue;
    }

    const deadline = streakDeadline(streak.lastLowSentAt, streak.lastHighSentAt);
    const msLeft = deadline ? deadline.getTime() - now.getTime() : -1;

    conversations.push({
      userId: partner.id,
      name: partner.name,
      themeKey: partner.themeKey,
      profilePictureUrl: buildProfilePictureUrl(partner.profilePictureKey),
      lastInteractionAt: lastInteractionAt.toISOString(),
      lastSentAt: lastSentAt ? lastSentAt.toISOString() : null,
      lastReceivedAt: lastReceivedAt ? lastReceivedAt.toISOString() : null,
      unopenedCount: unopenedBySender.get(partner.id) ?? 0,
      lastSentReceipt: receiptByRecipient.get(partner.id) ?? null,
      // Reported even when zero: a lapsed streak still says something about the
      // conversation, and the client decides whether to draw it.
      streakCount: streak.count,
      streakDeadline: streak.count > 0 && deadline ? deadline.toISOString() : null,
      streakAtRisk: streak.count > 0 && msLeft > 0 && msLeft <= STREAK_WARNING_WINDOW_MS,
    });
  }

  return conversations
    .sort((a, b) => b.lastInteractionAt.localeCompare(a.lastInteractionAt))
    .slice(0, MAX_CONVERSATIONS);
}
