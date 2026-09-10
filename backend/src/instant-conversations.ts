import type { PrismaClient } from "@prisma/client";
import type { InstantConversation } from "@blogging-app/common";

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

function newest(left: Date | null, right: Date | null): Date | null {
  if (!left) return right;
  if (!right) return left;
  return left.getTime() >= right.getTime() ? left : right;
}

export async function listConversationsForUser(
  prisma: PrismaClient,
  userId: number,
  buildProfilePictureUrl: (key: string | null) => string | null,
  now: Date = new Date()
): Promise<InstantConversation[]> {
  const [streaks, waiting] = await Promise.all([
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
  ]);

  const unopenedBySender = new Map<number, number>();
  for (const instant of waiting) {
    unopenedBySender.set(instant.senderId, (unopenedBySender.get(instant.senderId) ?? 0) + 1);
  }

  const conversations: InstantConversation[] = [];

  for (const streak of streaks) {
    const iAmLow = streak.userLowId === userId;
    const partner = iAmLow ? streak.userHigh : streak.userLow;

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
