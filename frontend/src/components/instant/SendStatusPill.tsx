import { IconCheck, IconClose, IconWarning } from "./icons";
import { INSTANT_COLORS } from "./style";
import type { OutboxItem } from "./useOutbox";

// How the outbox is doing, in one small capsule — the port of
// `ios/Instant/Features/SendStatus/SendStatusPill.swift`.
//
// Small on purpose: sending is the normal case, and the pill is there so a send
// that has left the screen is not also out of mind. A spinner while it goes, a
// tick for a moment when it has gone, and — the only state that stays — what
// went wrong, with a way to try again.

export function SendStatusPill({
  item,
  inFlight,
  sentCount,
  onRetry,
  onDismiss,
}: {
  item: OutboxItem | undefined;
  inFlight: number;
  sentCount: number;
  onRetry: (id: string) => void;
  onDismiss: (id: string) => void;
}) {
  if (!item) {
    return null;
  }

  if (item.phase === "failed") {
    return (
      <div
        className="pointer-events-auto flex max-w-full items-center gap-2.5 rounded-full py-1.5 pl-3 pr-1.5 text-white"
        style={{ background: `${INSTANT_COLORS.unread}ed` }}
      >
        <IconWarning size={14} />
        <span className="min-w-0">
          <span className="block text-[13px] font-semibold" data-testid="sendStatus.failed">
            Couldn&apos;t send to {item.recipient.name}
          </span>
          <span className="block truncate text-[12px] opacity-85">{item.message}</span>
        </span>
        <button
          type="button"
          onClick={() => onRetry(item.id)}
          data-testid="sendStatus.retry"
          className="rounded-full bg-white/20 px-2.5 py-1 text-[13px] font-bold"
        >
          Retry
        </button>
        <button
          type="button"
          aria-label="Dismiss"
          onClick={() => onDismiss(item.id)}
          className="p-1.5"
        >
          <IconClose size={11} />
        </button>
      </div>
    );
  }

  return (
    <div className="pointer-events-auto flex items-center gap-2 rounded-full bg-black/55 px-3 py-1.5 text-[13px] font-semibold text-white">
      {item.phase === "sending" ? (
        <>
          <span className="h-3.5 w-3.5 animate-spin rounded-full border-2 border-white/30 border-t-white" />
          <span data-testid="sendStatus.sending">
            {/* Names the person when there is one send and counts when there
                are several — the pill is not the place for a list. */}
            {inFlight > 1 ? `Sending ${inFlight}…` : `Sending to ${item.recipient.name}…`}
          </span>
        </>
      ) : (
        <>
          <IconCheck size={12} />
          <span data-testid="sendStatus.sent">
            {/* A photo sent to several people lands as several confirmations a
                moment apart; naming only the last would read as though it went
                to one. */}
            {sentCount > 1 ? `Sent to ${sentCount} people` : `Sent to ${item.recipient.name}`}
          </span>
        </>
      )}
    </div>
  );
}
