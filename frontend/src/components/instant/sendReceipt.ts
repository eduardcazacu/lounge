import type { InstantSendReceipt } from "@blogging-app/common";

// What a conversation row has to say about the last photo you sent.
//
// The Swift original is `InstantSendReceipt.status` in
// `ios/Instant/Core/Networking/DTOs.swift`. `openedAt` is the server's own mark
// — the moment the recipient's device claimed the media and it stopped existing
// — rather than the `viewedAt` the viewer posts back, which is a call a client
// that died mid-view never makes. See wiki/decisions.md.

export type ReceiptStatus =
  | { kind: "waiting"; since: Date }
  | { kind: "opened"; at: Date }
  /// The 24 hours ran out and nobody looked. The most informative of the three,
  /// and the reason the window outlives the photo.
  | { kind: "expiredUnopened" };

/// How long a receipt is worth showing. Past this the photo is long gone either
/// way and the row has nothing to add.
///
/// The server stops reporting one at about the same age. Neither side depends
/// on the other's exact number — whichever is shorter is the one that shows,
/// and this one also covers a send this client recorded locally and the server
/// has not answered for yet.
export const RECEIPT_DISPLAY_WINDOW_MS = 48 * 60 * 60 * 1000;

/// An unopened instant is swept 24 hours after it was sent. Used to date a send
/// this client has just made, before the server has said anything about it.
export const INSTANT_LIFETIME_MS = 24 * 60 * 60 * 1000;

function parse(timestamp: string | null | undefined): Date | null {
  if (!timestamp) {
    return null;
  }
  const date = new Date(timestamp);
  return Number.isNaN(date.getTime()) ? null : date;
}

/// What there is to say about it, or null when there is nothing worth saying.
export function receiptStatus(
  receipt: InstantSendReceipt | null | undefined,
  now: Date = new Date()
): ReceiptStatus | null {
  const sentAt = parse(receipt?.sentAt);
  if (!receipt || !sentAt || now.getTime() - sentAt.getTime() >= RECEIPT_DISPLAY_WINDOW_MS) {
    return null;
  }
  const openedAt = parse(receipt.openedAt);
  if (openedAt) {
    return { kind: "opened", at: openedAt };
  }
  const expiresAt = parse(receipt.expiresAt);
  if (!expiresAt || expiresAt <= now) {
    return { kind: "expiredUnopened" };
  }
  return { kind: "waiting", since: sentAt };
}
