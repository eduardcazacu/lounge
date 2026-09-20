import { useCallback, useEffect, useMemo, useState } from "react";
import axios from "axios";
import type { InstantConversation } from "@blogging-app/common";
import { BACKEND_URL } from "../../config";
import { getAuthHeader } from "../../lib/auth";
import type { UserListItem } from "../../hooks";
import { InstantAvatar, InstantSheet } from "./chrome";
import { IconCheck } from "./icons";
import { INSTANT_COLORS } from "./style";
import type { InstantRecipient } from "./useOutbox";

// Who the photo is for, ported from `ios/Instant/Features/SendTo/SendToModel.swift`.
//
// Two things make this more than a list of names: a photo can go to several
// people at once — each of them gets an instant of their own — and somebody
// with no device enrolled cannot be sent to at all, because there would be no
// public key to wrap the content key for.

type Candidate = {
  user: UserListItem;
  /// Null while the key directory is still answering for them.
  isEnrolled: boolean | null;
  /// When you last exchanged an instant with them, if ever. ISO 8601, so it
  /// sorts chronologically as a plain string.
  lastInteractionAt: string | null;
};

/// People you have talked to, most recent first, then everyone else in the
/// order the server sent them.
///
/// The server's order is by most recent *Lounge post*, which is a fine default
/// for somebody you have never messaged and says nothing at all about who you
/// send photos to. Recency comes from the conversation history rather than
/// anything held in this browser, so it survives a reinstall and is the same on
/// every device you sign in from.
function orderCandidates(
  users: UserListItem[],
  history: InstantConversation[]
): Candidate[] {
  const lastSeen = new Map<number, string>();
  for (const entry of history) {
    const existing = lastSeen.get(entry.userId);
    if (!existing || entry.lastInteractionAt > existing) {
      lastSeen.set(entry.userId, entry.lastInteractionAt);
    }
  }
  return users
    .map((user, position) => ({
      position,
      candidate: {
        user,
        isEnrolled: null,
        lastInteractionAt: lastSeen.get(user.id) ?? null,
      } satisfies Candidate,
    }))
    .sort((left, right) => {
      const leftSeen = left.candidate.lastInteractionAt;
      const rightSeen = right.candidate.lastInteractionAt;
      if (leftSeen && rightSeen) {
        // The same instant for both is possible on a fast exchange; fall back
        // to the server order so the list stays stable.
        return leftSeen === rightSeen ? left.position - right.position : leftSeen > rightSeen ? -1 : 1;
      }
      if (leftSeen) {
        return -1;
      }
      if (rightSeen) {
        return 1;
      }
      return left.position - right.position;
    })
    .map((entry) => entry.candidate);
}

function displayName(user: UserListItem): string {
  return user.name?.trim() || "Someone";
}

export function SendToSheet({
  users,
  usersLoading,
  history,
  currentUserId,
  initialSelection,
  onClose,
  onSend,
}: {
  users: UserListItem[];
  usersLoading: boolean;
  history: InstantConversation[];
  currentUserId: number | null;
  initialSelection: number[];
  onClose: () => void;
  onSend: (recipients: InstantRecipient[]) => void;
}) {
  const [candidates, setCandidates] = useState<Candidate[]>([]);
  const [selected, setSelected] = useState<number[]>(initialSelection);
  const [confirmingEveryone, setConfirmingEveryone] = useState(false);

  // The list includes the caller; the send endpoint 400s on a self-send, so
  // filter rather than let somebody tap into an error.
  const addressable = useMemo(
    () => users.filter((user) => user.id !== currentUserId),
    [users, currentUserId]
  );

  useEffect(() => {
    setCandidates(orderCandidates(addressable, history));
    // Deliberately not keyed on `history`: it refreshes while the sheet is
    // open, and re-sorting under a finger moves the row somebody is reaching
    // for.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [addressable]);

  // Enrollment is per-user and the key directory is a separate call, so rows
  // settle from "checking" to enabled or disabled as the answers land.
  useEffect(() => {
    let cancelled = false;
    for (const user of addressable) {
      void axios
        .get(`${BACKEND_URL}/api/v1/instant/keys/${user.id}`, {
          headers: { Authorization: getAuthHeader() },
        })
        .then((response) => (response.data?.devices ?? []).length > 0)
        .catch(() => false)
        .then((enrolled: boolean) => {
          if (cancelled) {
            return;
          }
          setCandidates((current) =>
            current.map((candidate) =>
              candidate.user.id === user.id ? { ...candidate, isEnrolled: enrolled } : candidate
            )
          );
          if (!enrolled) {
            // An aim carried in from the camera is ticked before anybody has
            // been checked, and a tick on a disabled row is one that cannot be
            // taken off.
            setSelected((current) => current.filter((id) => id !== user.id));
          }
        });
    }
    return () => {
      cancelled = true;
    };
  }, [addressable]);

  const toggle = useCallback((id: number) => {
    setSelected((current) =>
      current.includes(id) ? current.filter((candidate) => candidate !== id) : [...current, id]
    );
  }, []);

  const recipientsFor = useCallback(
    (ids: number[]): InstantRecipient[] =>
      candidates
        .filter((candidate) => ids.includes(candidate.user.id))
        .map((candidate) => ({ userId: candidate.user.id, name: displayName(candidate.user) })),
    [candidates]
  );

  const reachable = candidates.filter((candidate) => candidate.isEnrolled === true);
  /// "All" waits until every row has settled. Offered earlier it would mean
  /// "everyone whose check happened to come back first", and the count in its
  /// confirmation would be a guess.
  const canSendToEveryone =
    reachable.length > 0 && !candidates.some((candidate) => candidate.isEnrolled === null);

  const recent = candidates.filter((candidate) => candidate.lastInteractionAt !== null);
  const rest = candidates.filter((candidate) => candidate.lastInteractionAt === null);

  /// Names one or two people and counts past that; a send button is not the
  /// place for a list.
  const names = recipientsFor(selected).map((recipient) => recipient.name);
  const sendTitle =
    names.length === 0
      ? "Send"
      : names.length === 1
        ? `Send to ${names[0]}`
        : names.length === 2
          ? `Send to ${names[0]} and ${names[1]}`
          : `Send to ${names.length} people`;

  const row = (candidate: Candidate) => {
    const id = candidate.user.id;
    const ticked = selected.includes(id);
    const disabled = candidate.isEnrolled === false;
    return (
      <button
        key={id}
        type="button"
        disabled={disabled}
        onClick={() => toggle(id)}
        data-testid={`sendTo.row.${displayName(candidate.user)}`}
        className="flex w-full items-center gap-3 py-2.5 text-left disabled:opacity-40"
      >
        <InstantAvatar
          name={displayName(candidate.user)}
          themeKey={candidate.user.themeKey ?? ""}
          url={candidate.user.profilePictureUrl}
          size={44}
        />
        <span className="min-w-0 flex-1">
          <span className="block truncate text-[15px] font-semibold text-white">
            {displayName(candidate.user)}
          </span>
          <span className="block text-[12px]" style={{ color: INSTANT_COLORS.secondaryText }}>
            {candidate.isEnrolled === null
              ? "Checking…"
              : candidate.isEnrolled
                ? "Ready for Instant"
                : "Hasn't set up Instant"}
          </span>
        </span>
        <span
          className="flex h-6 w-6 items-center justify-center rounded-full border-2"
          style={{
            borderColor: ticked ? "#fff" : "rgba(255,255,255,0.35)",
            background: ticked ? "#fff" : "transparent",
            color: "#000",
          }}
        >
          {ticked && <IconCheck size={14} />}
        </span>
      </button>
    );
  };

  return (
    <InstantSheet
      title="Send to"
      onClose={onClose}
      footer={
        <div className="flex items-center gap-2">
          <button
            type="button"
            disabled={!canSendToEveryone}
            onClick={() => setConfirmingEveryone(true)}
            data-testid="sendTo.all"
            className="rounded-full border border-white/25 px-4 py-3 text-sm font-bold text-white disabled:opacity-40"
          >
            All
          </button>
          <button
            type="button"
            disabled={selected.length === 0}
            onClick={() => onSend(recipientsFor(selected))}
            data-testid="sendTo.send"
            className="flex-1 rounded-full bg-white px-4 py-3 text-sm font-bold text-black disabled:opacity-40"
          >
            {sendTitle}
          </button>
        </div>
      }
    >
      {usersLoading && candidates.length === 0 ? (
        <p className="py-6 text-center text-sm" style={{ color: INSTANT_COLORS.secondaryText }}>
          Loading your Lounge…
        </p>
      ) : (
        <>
          {recent.length > 0 && (
            <>
              <h3
                className="pt-1 text-[11px] font-bold uppercase tracking-wide"
                style={{ color: INSTANT_COLORS.secondaryText }}
              >
                Recent
              </h3>
              {recent.map(row)}
            </>
          )}
          {rest.length > 0 && (
            <>
              {/* With nothing recent there is only one group, and a lone header
                  over the whole list labels nothing. */}
              {recent.length > 0 && (
                <h3
                  className="pt-3 text-[11px] font-bold uppercase tracking-wide"
                  style={{ color: INSTANT_COLORS.secondaryText }}
                >
                  Everyone else
                </h3>
              )}
              {rest.map(row)}
            </>
          )}
        </>
      )}

      {confirmingEveryone && (
        <div
          data-sheet
          className="absolute inset-0 z-10 flex items-center justify-center bg-black/70 px-6"
        >
          <div
            className="w-full max-w-xs rounded-2xl p-5 text-center"
            style={{ background: INSTANT_COLORS.surfaceRaised }}
          >
            <p className="text-[15px] font-bold text-white">Send to everyone?</p>
            {/* The count is what makes this a confirmation rather than a speed
                bump: it is the number of people about to get the photo. */}
            <p className="mt-1.5 text-[13px]" style={{ color: INSTANT_COLORS.secondaryText }}>
              {reachable.length === 1
                ? "This photo will go to the one person who has Instant set up."
                : `This photo will go to all ${reachable.length} people who have Instant set up.`}
            </p>
            <div className="mt-4 flex gap-2">
              <button
                type="button"
                onClick={() => setConfirmingEveryone(false)}
                className="flex-1 rounded-full border border-white/25 py-2.5 text-sm font-semibold text-white"
              >
                Cancel
              </button>
              <button
                type="button"
                data-testid="sendTo.all.confirm"
                onClick={() =>
                  onSend(recipientsFor(reachable.map((candidate) => candidate.user.id)))
                }
                className="flex-1 rounded-full bg-white py-2.5 text-sm font-bold text-black"
              >
                Send
              </button>
            </div>
          </div>
        </div>
      )}
    </InstantSheet>
  );
}
