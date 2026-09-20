// Checks GET /api/v1/instant/conversations' query against an in-memory fake.
//
//   cd backend && npx tsx scripts/verify-conversations.ts
//
// The fake stands in for Prisma so the rules can be driven through states that
// are awkward to reach against a real database — a streak that lapsed months
// ago, a partner who was never approved, a conversation older than the 30-day
// instant sweep. It implements only the two queries the module issues.

import type { PrismaClient } from "@prisma/client";
import { listConversationsForUser } from "../src/instant-conversations";

let checks = 0;
let failures = 0;
function check(label: string, ok: boolean, detail?: unknown) {
  checks += 1;
  if (ok) console.log(`  ok   ${label}`);
  else {
    failures += 1;
    console.log(`  FAIL ${label}${detail === undefined ? "" : ` -> ${JSON.stringify(detail)}`}`);
  }
}

type FakeUser = {
  id: number;
  name: string | null;
  themeKey: string;
  profilePictureKey: string | null;
  status: string;
  emailVerifiedAt: Date | null;
};

type FakeStreak = {
  userLowId: number;
  userHighId: number;
  count: number;
  lastLowSentAt: Date | null;
  lastHighSentAt: Date | null;
};

type FakeInstant = {
  senderId: number;
  recipientId: number;
  openedAt: Date | null;
  mediaKey: string | null;
  expiresAt: Date;
  // Only the receipt query reads it, and only rows that carry one are sends as
  // far as it is concerned. The waiting tally never looks.
  createdAt?: Date;
};

function makePrisma(users: FakeUser[], streaks: FakeStreak[], instants: FakeInstant[]) {
  const byId = new Map(users.map((user) => [user.id, user]));
  return {
    instantStreak: {
      findMany: async ({ where }: any) => {
        const wanted: number[] = where.OR.map((clause: any) => clause.userLowId ?? clause.userHighId);
        const userId = wanted[0];
        return streaks
          .filter((streak) => streak.userLowId === userId || streak.userHighId === userId)
          .map((streak) => ({
            ...streak,
            userLow: byId.get(streak.userLowId),
            userHigh: byId.get(streak.userHighId),
          }));
      },
    },
    instant: {
      // Two different queries land here: what is waiting for the caller, and
      // what the caller sent. They are told apart the same way the module
      // writes them — by which end of the instant the `where` names.
      findMany: async ({ where }: any) => {
        if (where.senderId !== undefined) {
          return instants
            .filter(
              (instant): instant is FakeInstant & { createdAt: Date } =>
                instant.senderId === where.senderId &&
                instant.createdAt !== undefined &&
                instant.createdAt.getTime() > where.createdAt.gt.getTime()
            )
            .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime())
            .map((instant) => ({
              recipientId: instant.recipientId,
              createdAt: instant.createdAt,
              openedAt: instant.openedAt,
              expiresAt: instant.expiresAt,
            }));
        }
        return instants
          .filter(
            (instant) =>
              instant.recipientId === where.recipientId &&
              instant.openedAt === null &&
              instant.mediaKey !== null &&
              instant.expiresAt.getTime() > where.expiresAt.gt.getTime()
          )
          .map((instant) => ({ senderId: instant.senderId }));
      },
    },
  } as unknown as PrismaClient;
}

const now = new Date("2026-09-10T12:00:00.000Z");
const ago = (hours: number) => new Date(now.getTime() - hours * 3_600_000);
const approved = (id: number, name: string): FakeUser => ({
  id,
  name,
  themeKey: "ocean",
  profilePictureKey: null,
  status: "approved",
  emailVerifiedAt: new Date("2026-01-01T00:00:00.000Z"),
});

const url = (key: string | null) => (key ? `https://images.test/${key}` : null);

async function main() {
  const me = 1;

  console.log("\nconversations without a streak");
  {
    // The case this endpoint exists for: talked months ago, streak long gone.
    const prisma = makePrisma(
      [approved(me, "Me"), approved(2, "Ana")],
      [{ userLowId: 1, userHighId: 2, count: 0, lastLowSentAt: ago(24 * 90), lastHighSentAt: null }],
      []
    );
    const result = await listConversationsForUser(prisma, me, url, now);
    check("a lapsed conversation is still listed", result.length === 1, result);
    check("with a zero streak", result[0]?.streakCount === 0);
    check("and no deadline", result[0]?.streakDeadline === null);
    check("and is not flagged at risk", result[0]?.streakAtRisk === false);
  }

  console.log("\nordering");
  {
    const prisma = makePrisma(
      [approved(me, "Me"), approved(2, "Ana"), approved(3, "Bo"), approved(4, "Cass")],
      [
        { userLowId: 1, userHighId: 2, count: 0, lastLowSentAt: ago(100), lastHighSentAt: null },
        { userLowId: 1, userHighId: 3, count: 3, lastLowSentAt: ago(5), lastHighSentAt: ago(2) },
        { userLowId: 1, userHighId: 4, count: 0, lastLowSentAt: null, lastHighSentAt: ago(50) },
      ],
      []
    );
    const result = await listConversationsForUser(prisma, me, url, now);
    // Newest first, counting either direction — Bo heard from 2h ago, Cass sent
    // 50h ago, Ana 100h ago.
    check("newest interaction first", result.map((c) => c.userId).join(",") === "3,4,2", result.map((c) => c.userId));
    check("a conversation I only received in still counts", result.some((c) => c.userId === 4));
  }

  console.log("\ndirection");
  {
    const prisma = makePrisma(
      [approved(me, "Me"), approved(2, "Ana")],
      [{ userLowId: 1, userHighId: 2, count: 1, lastLowSentAt: ago(9), lastHighSentAt: ago(3) }],
      []
    );
    const [conversation] = await listConversationsForUser(prisma, me, url, now);
    check("my own send is reported as sent", conversation.lastSentAt === ago(9).toISOString());
    check("theirs as received", conversation.lastReceivedAt === ago(3).toISOString());
    check("and the latest of the two leads", conversation.lastInteractionAt === ago(3).toISOString());
  }

  console.log("\ndirection is relative to the caller");
  {
    // The same row read from the other side has to swap sent and received.
    const prisma = makePrisma(
      [approved(me, "Me"), approved(2, "Ana")],
      [{ userLowId: 1, userHighId: 2, count: 1, lastLowSentAt: ago(9), lastHighSentAt: ago(3) }],
      []
    );
    const [conversation] = await listConversationsForUser(prisma, 2, url, now);
    check("sent and received swap for the other person", conversation.lastSentAt === ago(3).toISOString());
    check("and so does received", conversation.lastReceivedAt === ago(9).toISOString());
    check("the partner is the caller's counterpart", conversation.userId === 1);
  }

  console.log("\nwaiting instants");
  {
    const prisma = makePrisma(
      [approved(me, "Me"), approved(2, "Ana"), approved(3, "Bo")],
      [
        { userLowId: 1, userHighId: 2, count: 0, lastLowSentAt: null, lastHighSentAt: ago(1) },
        { userLowId: 1, userHighId: 3, count: 0, lastLowSentAt: ago(2), lastHighSentAt: null },
      ],
      [
        { senderId: 2, recipientId: 1, openedAt: null, mediaKey: "instant/a", expiresAt: ago(-5) },
        { senderId: 2, recipientId: 1, openedAt: null, mediaKey: "instant/b", expiresAt: ago(-5) },
        // Already opened, so no longer waiting.
        { senderId: 2, recipientId: 1, openedAt: ago(1), mediaKey: null, expiresAt: ago(-5) },
        // Expired.
        { senderId: 3, recipientId: 1, openedAt: null, mediaKey: "instant/c", expiresAt: ago(1) },
      ]
    );
    const result = await listConversationsForUser(prisma, me, url, now);
    const ana = result.find((c) => c.userId === 2)!;
    const bo = result.find((c) => c.userId === 3)!;
    check("counts only what is still openable", ana.unopenedCount === 2, ana.unopenedCount);
    check("an expired instant is not waiting", bo.unopenedCount === 0, bo.unopenedCount);
  }

  console.log("\nread receipts");
  {
    // What the caller sent, which is the other direction from everything else
    // here: three people, three states of the same question.
    const sent = (recipientId: number, hoursAgo: number, openedAt: Date | null): FakeInstant => ({
      senderId: me,
      recipientId,
      createdAt: ago(hoursAgo),
      openedAt,
      mediaKey: openedAt ? null : "instant/x",
      expiresAt: new Date(ago(hoursAgo).getTime() + 24 * 3_600_000),
    });
    const prisma = makePrisma(
      [approved(me, "Me"), approved(2, "Ana"), approved(3, "Bo"), approved(4, "Cass"), approved(5, "Dee")],
      [
        { userLowId: 1, userHighId: 2, count: 0, lastLowSentAt: ago(1), lastHighSentAt: null },
        { userLowId: 1, userHighId: 3, count: 0, lastLowSentAt: ago(2), lastHighSentAt: null },
        { userLowId: 1, userHighId: 4, count: 0, lastLowSentAt: ago(30), lastHighSentAt: null },
        { userLowId: 1, userHighId: 5, count: 0, lastLowSentAt: ago(60), lastHighSentAt: null },
      ],
      [
        // Ana: sent an hour ago, still waiting.
        sent(2, 1, null),
        // Bo: sent two hours ago and opened an hour later — and an older one he
        // never opened, which must not be the one reported.
        sent(3, 2, ago(1)),
        sent(3, 20, null),
        // Cass: sent 30 hours ago and never opened, so it has expired.
        sent(4, 30, null),
        // Dee: sent 60 hours ago, past the window entirely.
        sent(5, 60, null),
      ]
    );
    const result = await listConversationsForUser(prisma, me, url, now);
    const receipt = (userId: number) => result.find((c) => c.userId === userId)!.lastSentReceipt;
    check("a send still waiting reports no open", receipt(2)?.openedAt === null, receipt(2));
    check("and says when it went", receipt(2)?.sentAt === ago(1).toISOString(), receipt(2));
    check("an opened one carries the moment it was claimed", receipt(3)?.openedAt === ago(1).toISOString(), receipt(3));
    check("the newest send is the one reported", receipt(3)?.sentAt === ago(2).toISOString(), receipt(3));
    check("an expired send is still reported, unopened", receipt(4)?.openedAt === null, receipt(4));
    check("with an expiry already past", (receipt(4)?.expiresAt ?? "") < now.toISOString(), receipt(4));
    check("a send older than the window is not reported", receipt(5) === null, receipt(5));
  }

  console.log("\nreceipts are the caller's own sends");
  {
    // The receipt belongs to whoever sent, so the same instant read from the
    // recipient's side is not one.
    const prisma = makePrisma(
      [approved(me, "Me"), approved(2, "Ana")],
      [{ userLowId: 1, userHighId: 2, count: 1, lastLowSentAt: ago(1), lastHighSentAt: ago(2) }],
      [
        {
          senderId: me,
          recipientId: 2,
          createdAt: ago(1),
          openedAt: null,
          mediaKey: "instant/a",
          expiresAt: ago(-23),
        },
      ]
    );
    const [mine] = await listConversationsForUser(prisma, me, url, now);
    const [theirs] = await listConversationsForUser(prisma, 2, url, now);
    check("the sender gets a receipt", mine.lastSentReceipt !== null, mine.lastSentReceipt);
    check("the recipient gets none", theirs.lastSentReceipt === null, theirs.lastSentReceipt);
    check("the recipient sees it as waiting instead", theirs.unopenedCount === 1, theirs.unopenedCount);
  }

  console.log("\nlive streaks");
  {
    const prisma = makePrisma(
      [approved(me, "Me"), approved(2, "Ana"), approved(3, "Bo")],
      [
        // Both sent recently: 24h from the older send, so ~22h left.
        { userLowId: 1, userHighId: 2, count: 12, lastLowSentAt: ago(2), lastHighSentAt: ago(1) },
        // Older side was 21h ago, so 3h left — inside the 4h warning window.
        { userLowId: 1, userHighId: 3, count: 8, lastLowSentAt: ago(21), lastHighSentAt: ago(1) },
      ],
      []
    );
    const result = await listConversationsForUser(prisma, me, url, now);
    const ana = result.find((c) => c.userId === 2)!;
    const bo = result.find((c) => c.userId === 3)!;
    check("a live streak reports its count", ana.streakCount === 12);
    check("and a deadline", ana.streakDeadline !== null);
    check("a comfortable streak is not at risk", ana.streakAtRisk === false);
    check("one inside the warning window is", bo.streakAtRisk === true);
  }

  console.log("\neligibility");
  {
    const pending: FakeUser = { ...approved(2, "Ana"), status: "pending" };
    const unverified: FakeUser = { ...approved(3, "Bo"), emailVerifiedAt: null };
    const prisma = makePrisma(
      [approved(me, "Me"), pending, unverified, approved(4, "Cass")],
      [
        { userLowId: 1, userHighId: 2, count: 0, lastLowSentAt: ago(1), lastHighSentAt: null },
        { userLowId: 1, userHighId: 3, count: 0, lastLowSentAt: ago(1), lastHighSentAt: null },
        { userLowId: 1, userHighId: 4, count: 0, lastLowSentAt: ago(1), lastHighSentAt: null },
      ],
      []
    );
    const result = await listConversationsForUser(prisma, me, url, now);
    // Listing someone unaddressable would only offer a send that 404s.
    check("an unapproved partner is hidden", !result.some((c) => c.userId === 2));
    check("an unverified partner is hidden", !result.some((c) => c.userId === 3));
    check("an approved one is listed", result.some((c) => c.userId === 4));
  }

  console.log("\ndegenerate rows");
  {
    const prisma = makePrisma(
      [approved(me, "Me"), approved(2, "Ana")],
      [{ userLowId: 1, userHighId: 2, count: 0, lastLowSentAt: null, lastHighSentAt: null }],
      []
    );
    const result = await listConversationsForUser(prisma, me, url, now);
    check("a row with no send on either side is skipped", result.length === 0, result);
  }

  console.log("\nblocks");
  {
    // Ana is on the other side of a block; Bo is not. Which of them did the
    // blocking is not this module's concern — the route passes both directions.
    const prisma = makePrisma(
      [approved(me, "Me"), approved(2, "Ana"), approved(3, "Bo")],
      [
        { userLowId: 1, userHighId: 2, count: 12, lastLowSentAt: ago(1), lastHighSentAt: ago(2) },
        { userLowId: 1, userHighId: 3, count: 0, lastLowSentAt: ago(5), lastHighSentAt: null },
      ],
      [{ senderId: 2, recipientId: me, openedAt: null, mediaKey: "instant/a", expiresAt: ago(-10) }]
    );
    const result = await listConversationsForUser(prisma, me, url, now, new Set([2]));
    check("a blocked partner is hidden, streak and waiting instant included", result.every((c) => c.userId !== 2), result);
    check("everyone else is still listed", result.map((c) => c.userId).join(",") === "3", result.map((c) => c.userId));
  }

  console.log("\nprofile pictures");
  {
    const withPicture: FakeUser = { ...approved(2, "Ana"), profilePictureKey: "profile-pictures/2/a.webp" };
    const prisma = makePrisma(
      [approved(me, "Me"), withPicture],
      [{ userLowId: 1, userHighId: 2, count: 0, lastLowSentAt: ago(1), lastHighSentAt: null }],
      []
    );
    const [conversation] = await listConversationsForUser(prisma, me, url, now);
    check(
      "the key is resolved to a URL",
      conversation.profilePictureUrl === "https://images.test/profile-pictures/2/a.webp",
      conversation.profilePictureUrl
    );
  }

  console.log(`\n${checks - failures}/${checks} checks passed`);
  if (failures > 0) process.exit(1);
}

void main();
