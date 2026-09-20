import { useEffect, useRef, useState } from "react";
import type { InstantRow } from "../../hooks/useInstant";
import { SafetyNumberPanel } from "./SafetyNumberPanel";
import { ReportSheet } from "./ReportSheet";
import { InstantAvatar, InstantSheet, StreakBadge } from "./chrome";
import {
  IconBlock,
  IconCamera,
  IconChevron,
  IconExpired,
  IconEye,
  IconFlag,
  IconRefresh,
  IconReply,
  IconSend,
  IconShield,
} from "./icons";
import { relativeShort, relativeSpoken } from "./relativeTime";
import { receiptStatus } from "./sendReceipt";
import { INSTANT_COLORS, viewportSizing, viewportTopLine } from "./style";
import type { InstantConnectionState } from "../../hooks/useInstant";

// Conversations, ported from `ios/Instant/Features/Inbox/InboxScreen.swift`.
// One row per person: avatar, name with their streak beside it, and whatever
// the row has to say.
//
// This sits to the *left* of the camera in the pager, which is where Snapchat
// puts chat and where the camera's own chat button points.

export function InboxScreen({
  rows,
  hasLoaded,
  connection,
  currentUserId,
  onOpen,
  onAim,
  onRefresh,
  onOpenCamera,
  onBlocked,
}: {
  rows: InstantRow[];
  hasLoaded: boolean;
  connection: InstantConnectionState;
  currentUserId: number | null;
  onOpen: (row: InstantRow) => void;
  onAim: (row: InstantRow) => void;
  onRefresh: () => void;
  onOpenCamera: () => void;
  onBlocked: (userId: number) => void;
}) {
  /// Read once per render so every receipt on screen is aged against the same
  /// clock, and advanced on a timer while the inbox is up: a receipt is the one
  /// thing here that goes stale while nothing happens, and a list nobody is
  /// touching never redraws.
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    const timer = window.setInterval(() => setNow(new Date()), 60_000);
    return () => window.clearInterval(timer);
  }, []);

  const [menuFor, setMenuFor] = useState<InstantRow | null>(null);
  const [safetyNumberFor, setSafetyNumberFor] = useState<InstantRow | null>(null);
  const [reportFor, setReportFor] = useState<InstantRow | null>(null);
  const [blockCandidate, setBlockCandidate] = useState<InstantRow | null>(null);

  const warning = connectionWarning(connection);

  return (
    // The same rectangle the camera gets, for the same reason: the account
    // button is pinned to the viewport's top-left corner, and a list that ran
    // to the window's edges would leave it floating in the middle of a row.
    <div
      className="absolute inset-0 flex justify-center"
      style={{ background: INSTANT_COLORS.background }}
    >
      <div className="flex h-full flex-col" style={{ width: viewportSizing.width }}>
        {/* Dropped onto the viewport's top line rather than the window's. The
            account button is pinned over this row and lives inside the frame,
            so on anything taller than 16:9 a header measured from the window
            sits above it and the two read as two rows. */}
        <header
          className="flex items-center gap-2 px-4 pb-3"
          style={{ paddingTop: viewportTopLine }}
        >
          {/* Starts to the right of where the pinned account button lands, so the
              two read as one line rather than two headers stacked up. */}
          <h1 className="ml-[56px] text-[30px] font-extrabold tracking-tight text-white">Instant</h1>
          <span className="flex-1" />
          {warning && (
            <span
              className="flex items-center gap-1.5 rounded-full px-2.5 py-1 text-[12px] font-semibold"
              style={{ color: warning.color, background: `${warning.color}24` }}
            >
              <span className="h-[7px] w-[7px] rounded-full" style={{ background: warning.color }} />
              {warning.text}
            </span>
          )}
          <button
            type="button"
            onClick={onRefresh}
            aria-label="Refresh"
            className="flex h-11 w-11 items-center justify-center rounded-full text-white"
            style={{ background: INSTANT_COLORS.surfaceRaised }}
          >
            <IconRefresh size={18} />
          </button>
          {/* The way back, for a pointer that has no swipe. */}
          <button
            type="button"
            onClick={onOpenCamera}
            aria-label="Camera"
            data-testid="inbox.camera"
            className="flex h-11 w-11 items-center justify-center rounded-full text-white"
            style={{ background: INSTANT_COLORS.surfaceRaised }}
          >
            <IconCamera size={18} />
          </button>
        </header>

        <div className="min-h-0 flex-1 overflow-y-auto px-4 pb-6">
          {rows.length === 0 ? (
            hasLoaded ? (
              <Empty />
            ) : (
              <p
                className="pt-16 text-center text-sm"
                style={{ color: INSTANT_COLORS.secondaryText }}
              >
                Loading…
              </p>
            )
          ) : (
            <ul>
              {rows.map((row) => (
                <ConversationRow
                  key={row.userId}
                  row={row}
                  now={now}
                  onOpen={() => (row.pending ? onOpen(row) : onAim(row))}
                  onMenu={() => setMenuFor(row)}
                />
              ))}
            </ul>
          )}
        </div>

        {menuFor && (
          <InstantSheet title={menuFor.name} onClose={() => setMenuFor(null)}>
            {/* Everything about the person rather than the conversation:
                reporting and blocking, and the safety number. */}
            <MenuItem
              icon={<IconShield size={18} />}
              label="Safety number"
              onClick={() => {
                setSafetyNumberFor(menuFor);
                setMenuFor(null);
              }}
            />
            <MenuItem
              icon={<IconFlag size={18} />}
              label="Report…"
              onClick={() => {
                setReportFor(menuFor);
                setMenuFor(null);
              }}
            />
            <MenuItem
              icon={<IconBlock size={18} />}
              label="Block"
              destructive
              onClick={() => {
                setBlockCandidate(menuFor);
                setMenuFor(null);
              }}
            />
          </InstantSheet>
        )}

        {safetyNumberFor && (
          <InstantSheet title="Safety number" onClose={() => setSafetyNumberFor(null)}>
            <div className="pb-6">
              <SafetyNumberPanel
                currentUserId={currentUserId}
                peerUserId={safetyNumberFor.userId}
                peerName={safetyNumberFor.name}
              />
            </div>
          </InstantSheet>
        )}

        {reportFor && (
          <ReportSheet
            reportedUserId={reportFor.userId}
            reportedName={reportFor.name}
            onClose={() => setReportFor(null)}
            onBlocked={onBlocked}
          />
        )}

        {blockCandidate && (
          <BlockConfirmation
            row={blockCandidate}
            onClose={() => setBlockCandidate(null)}
            onBlocked={(userId) => {
              setBlockCandidate(null);
              onBlocked(userId);
            }}
          />
        )}
      </div>
    </div>
  );
}

/// A row means one of two things, depending on whether they have something
/// waiting: it opens what is waiting, or — with nothing to read — it means the
/// other direction, the camera already aimed at them.
function ConversationRow({
  row,
  now,
  onOpen,
  onMenu,
}: {
  row: InstantRow;
  now: Date;
  onOpen: () => void;
  onMenu: () => void;
}) {
  // Press and hold on a touch screen, right-click on a desktop. Both reach the
  // same menu, because neither pointer has the other's affordance.
  const holdTimer = useRef<number | null>(null);
  const held = useRef(false);

  const startHold = () => {
    held.current = false;
    holdTimer.current = window.setTimeout(() => {
      held.current = true;
      onMenu();
    }, 500);
  };
  const endHold = () => {
    if (holdTimer.current !== null) {
      window.clearTimeout(holdTimer.current);
      holdTimer.current = null;
    }
  };
  /// A finger on the way past is scrolling the list, not pressing and holding.
  const start = useRef<{ x: number; y: number } | null>(null);
  const moveHold = (event: React.PointerEvent) => {
    if (!start.current) {
      return;
    }
    const moved =
      Math.abs(event.clientX - start.current.x) + Math.abs(event.clientY - start.current.y);
    if (moved > 10) {
      endHold();
    }
  };

  return (
    <li className="border-b" style={{ borderColor: INSTANT_COLORS.surfaceRaised }}>
      <button
        type="button"
        onClick={() => {
          if (!held.current) {
            onOpen();
          }
        }}
        onContextMenu={(event) => {
          event.preventDefault();
          onMenu();
        }}
        onPointerDown={(event) => {
          start.current = { x: event.clientX, y: event.clientY };
          startHold();
        }}
        onPointerMove={moveHold}
        onPointerUp={endHold}
        onPointerLeave={endHold}
        onPointerCancel={endHold}
        data-testid={`inbox.conversation.${row.name}`}
        className="flex w-full select-none items-center gap-3 py-3 text-left"
      >
        <InstantAvatar name={row.name} themeKey={row.themeKey} url={row.profilePictureUrl} />

        <span className="min-w-0 flex-1">
          <span className="flex items-center gap-1.5">
            <span className="truncate text-[16px] font-semibold text-white">{row.name}</span>
            {row.streakCount > 0 && (
              <StreakBadge count={row.streakCount} atRisk={row.streakAtRisk} />
            )}
          </span>
          <Status row={row} now={now} />
        </span>

        {/* Every row leads somewhere, and the glyph says where: into what is
            waiting, or out to the camera aimed at them. */}
        <span style={{ color: INSTANT_COLORS.secondaryText }}>
          {row.pending ? <IconChevron size={14} /> : <IconCamera size={16} />}
        </span>
      </button>
    </li>
  );
}

function Status({ row, now }: { row: InstantRow; now: Date }) {
  if (row.pending) {
    return (
      <span className="mt-0.5 flex items-center gap-1.5">
        <span
          className="h-2.5 w-2.5 rounded-sm"
          style={{ background: INSTANT_COLORS.unread }}
        />
        <span className="text-[13px] font-semibold" style={{ color: INSTANT_COLORS.unread }}>
          {row.pending.envelope ? "New Instant" : "Can't be opened here"}
        </span>
        <span className="text-[13px]" style={{ color: INSTANT_COLORS.secondaryText }}>
          {row.pendingCount > 1
            ? `· ${row.pendingCount} waiting`
            : `· ${durationText(row.pending.durationMode)}`}
        </span>
      </span>
    );
  }
  if (row.suggestsReply) {
    // Ranked above the streak warning: replying keeps the streak too, and this
    // is the more specific thing to do.
    return (
      <span
        className="mt-0.5 flex items-center gap-1.5 text-[13px] font-semibold"
        style={{ color: INSTANT_COLORS.flame }}
      >
        <IconReply size={11} />
        Tap to reply
      </span>
    );
  }
  if (row.streakNeedsYourSend) {
    // Only when it is actually your move. A streak lapsing because they have
    // gone quiet is not something this reader can fix.
    return (
      <span className="mt-0.5 block text-[13px]" style={{ color: INSTANT_COLORS.unread }}>
        Send one today to keep your streak
      </span>
    );
  }

  const receipt = receiptStatus(row.lastSentReceipt, now);
  if (!receipt) {
    return null;
  }
  // Last, because it is the only line here that asks for nothing. Quiet —
  // secondary text, no colour — so it never competes with a line that wants a
  // tap.
  const [icon, text, spoken] =
    receipt.kind === "waiting"
      ? [
          <IconSend key="i" size={11} />,
          `Sent ${relativeShort(receipt.since, now)}`,
          `Sent ${relativeSpoken(receipt.since, now)}, not opened yet`,
        ]
      : receipt.kind === "opened"
        ? [
            <IconEye key="i" size={11} />,
            `Opened ${relativeShort(receipt.at, now)}`,
            `Opened ${relativeSpoken(receipt.at, now)}`,
          ]
        : [<IconExpired key="i" size={12} />, "Expired unopened", "Expired unopened"];

  return (
    <span
      className="mt-0.5 flex items-center gap-1.5 text-[13px]"
      style={{ color: INSTANT_COLORS.secondaryText }}
      aria-label={spoken}
    >
      {icon}
      <span aria-hidden="true">{text}</span>
    </span>
  );
}

function durationText(mode: string): string {
  return mode === "infinite" ? "Open until you close it" : `Visible for ${mode}`;
}

function MenuItem({
  icon,
  label,
  onClick,
  destructive = false,
}: {
  icon: React.ReactNode;
  label: string;
  onClick: () => void;
  destructive?: boolean;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="flex w-full items-center gap-3 py-3.5 text-left text-[15px] font-semibold"
      style={{ color: destructive ? INSTANT_COLORS.unread : "#fff" }}
    >
      {icon}
      {label}
    </button>
  );
}

function BlockConfirmation({
  row,
  onClose,
  onBlocked,
}: {
  row: InstantRow;
  onClose: () => void;
  onBlocked: (userId: number) => void;
}) {
  const [error, setError] = useState<string | null>(null);
  const [working, setWorking] = useState(false);

  return (
    <div
      data-sheet
      className="absolute inset-0 z-40 flex items-center justify-center bg-black/70 px-6"
    >
      <div
        className="w-full max-w-xs rounded-2xl p-5 text-center"
        style={{ background: INSTANT_COLORS.surfaceRaised }}
      >
        <p className="text-[15px] font-bold text-white">Block {row.name}?</p>
        <p className="mt-1.5 text-[13px]" style={{ color: INSTANT_COLORS.secondaryText }}>
          You and {row.name} won&apos;t be able to see or send instants to each other. Anything
          waiting from them is deleted. You can unblock them from your account.
        </p>
        {error && (
          <p className="mt-2 text-[13px]" style={{ color: INSTANT_COLORS.unread }}>
            {error}
          </p>
        )}
        <div className="mt-4 flex gap-2">
          <button
            type="button"
            onClick={onClose}
            className="flex-1 rounded-full border border-white/25 py-2.5 text-sm font-semibold text-white"
          >
            Cancel
          </button>
          <button
            type="button"
            disabled={working}
            data-testid="inbox.block.confirm"
            onClick={async () => {
              setWorking(true);
              const { blockUser } = await import("./moderation");
              try {
                await blockUser(row.userId);
                onBlocked(row.userId);
              } catch {
                setError("Check your connection and try again.");
              } finally {
                setWorking(false);
              }
            }}
            className="flex-1 rounded-full py-2.5 text-sm font-bold text-white disabled:opacity-50"
            style={{ background: INSTANT_COLORS.unread }}
          >
            Block
          </button>
        </div>
      </div>
    </div>
  );
}

function Empty() {
  return (
    <div className="flex flex-col items-center gap-2 pt-24 text-center">
      <p className="text-base font-semibold text-white">No conversations yet</p>
      <p className="text-sm" style={{ color: INSTANT_COLORS.secondaryText }}>
        Swipe back to the camera and send one.
      </p>
    </div>
  );
}

/// Only shown when live delivery is actually broken. A dot that is always there
/// is ambient noise; one that appears only when something is wrong is worth
/// reading, and it carries its own text because an unlabelled coloured dot
/// leaves the reader to guess.
function connectionWarning(connection: InstantConnectionState) {
  switch (connection) {
    case "offline":
      return { text: "Reconnecting", color: "#fb923c" };
    case "unsupported":
      return { text: "Not live", color: INSTANT_COLORS.secondaryText };
    default:
      return null;
  }
}
