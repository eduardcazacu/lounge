import type { PrismaClient } from "@prisma/client";
import { hasMarkedSpoilers } from "@blogging-app/common";

// A review marked as a spoiler is covered for anyone who has not finished the
// book, with a way to look anyway. Passages marked inside a review's text
// (`reviewSegments` in common/) are masked for the same readers, by the same
// test, one tap each. "Finished" is the book club's test for a
// reader who has seen the ending (`readerReach` is 1): any finished run of the
// work, so a re-reader in the middle of it still counts. A DNF does not.
//
// The text is still sent, and the cover is drawn by the client. That is
// deliberate, and unlike the book club, which withholds notes on the server:
// a club note is gated by the reader's progress, while a spoiler review is one
// tap from being read by choice. Withholding it would cost that tap a round trip
// and protect nothing the reader did not ask to see.

/** The works among `itemIds` that `userId` has finished at least once. */
export async function finishedItemIds(prisma: PrismaClient, userId: number, itemIds: number[]): Promise<Set<number>> {
  if (itemIds.length === 0) return new Set();
  const runs = await prisma.shelfRun.findMany({
    where: { status: "finished", entry: { userId, itemId: { in: [...new Set(itemIds)] } } },
    select: { entry: { select: { itemId: true } } },
  });
  return new Set(runs.map((run) => run.entry.itemId));
}

/** Whether this viewer should see the review covered. */
export function coveredFor(
  review: { spoiler: boolean },
  reviewerId: number,
  itemId: number,
  viewerId: number,
  finished: Set<number>
) {
  return review.spoiler && unfinishedFor(reviewerId, itemId, viewerId, finished);
}

/** Whether this viewer is someone a spoiler is kept from: neither the reviewer nor finished. */
function unfinishedFor(reviewerId: number, itemId: number, viewerId: number, finished: Set<number>) {
  return reviewerId !== viewerId && !finished.has(itemId);
}

/** Whether this viewer should see the passages marked in the review's text masked. */
export function masksSpoilersFor(
  review: { body: string | null },
  reviewerId: number,
  itemId: number,
  viewerId: number,
  finished: Set<number>
) {
  return hasMarkedSpoilers(review.body) && unfinishedFor(reviewerId, itemId, viewerId, finished);
}

/** Whether `finishedItemIds` needs asking about this review's book at all. */
export function gatesSpoilers(review: { spoiler: boolean; body: string | null }) {
  return review.spoiler || hasMarkedSpoilers(review.body);
}
