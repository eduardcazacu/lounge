import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import axios from "axios";
import type {
  InstantConversation,
  InstantDelivery,
  InstantWireEvent,
} from "@blogging-app/common";
import { BACKEND_URL, WS_BASE_URL } from "../config";
import { clearAuthStorage, getAuthHeader, getCurrentUserId } from "../lib/auth";
import { getOrCreateDevice, type InstantDevice } from "../lib/instantKeystore";
import { INSTANT_LIFETIME_MS } from "../components/instant/sendReceipt";

// Realtime inbox. Shaped like useChat, but socket-driven instead of polled.
//
// The socket is not a delivery guarantee on its own: every (re)connect also
// drains GET /inbox, which is what catches anything queued while this device
// was offline and what a native client uses on cold start.

// How often to re-check which account is signed in. `storage` covers other
// tabs, but the tab that made the change never receives its own event.
const IDENTITY_POLL_MS = 5_000;
const PING_INTERVAL_MS = 25_000;
const MIN_RECONNECT_MS = 1_000;
const MAX_RECONNECT_MS = 30_000;

export type InstantConnectionState = "connecting" | "open" | "offline" | "unsupported";

// One row per person: whatever they have waiting, plus the streak and the
// receipt that belong to them.
//
// The merge is the port of `InstantStore.conversations` in
// `ios/Instant/Core/Store/InstantStore.swift`. Conversations and waiting
// instants come from two endpoints keyed by user, and showing them as two lists
// made the reader join them by eye.
export type InstantRow = {
  userId: number;
  name: string;
  themeKey: string;
  profilePictureUrl: string | null;
  /// The oldest instant still waiting, which is the one to open first.
  pending: InstantDelivery | null;
  pendingCount: number;
  streakCount: number;
  streakAtRisk: boolean;
  lastInteractionAt: string | null;
  lastSentReceipt: InstantConversation["lastSentReceipt"];
  /// Their instant has been opened and nothing has gone back yet.
  suggestsReply: boolean;
  /// A streak about to lapse that is waiting on *you*. One waiting on them is
  /// not something the reader can act on, so it neither nags nor jumps the
  /// queue.
  streakNeedsYourSend: boolean;
};

/// Whether keeping this streak alive is the caller's move. The deadline is set
/// by whichever side went quiet first.
function needsYourSend(conversation: InstantConversation): boolean {
  if (!conversation.streakAtRisk) {
    return false;
  }
  if (!conversation.lastSentAt) {
    // Never having sent counts as your move: there is nobody else it could be
    // waiting on.
    return true;
  }
  if (!conversation.lastReceivedAt) {
    return false;
  }
  return conversation.lastSentAt < conversation.lastReceivedAt;
}

/// A copy of a conversation carrying a send this client has just made.
///
/// Both marks move, because both are read: the order is by `lastInteractionAt`,
/// and `lastSentAt` is how a row knows whether a streak about to lapse is still
/// waiting on you. `max` rather than assignment — the server's view of the same
/// conversation can come back a moment stale, and a refresh must never undo a
/// send that has already happened.
function withSend(conversation: InstantConversation, timestamp: string): InstantConversation {
  const receipt = conversation.lastSentReceipt;
  return {
    ...conversation,
    lastInteractionAt:
      conversation.lastInteractionAt > timestamp ? conversation.lastInteractionAt : timestamp,
    lastSentAt:
      conversation.lastSentAt && conversation.lastSentAt > timestamp
        ? conversation.lastSentAt
        : timestamp,
    // Nothing newer than this send can have been opened, so it is waiting by
    // definition. The server's own receipt wins as soon as it catches up — it
    // is the only side that can say the photo has been taken.
    lastSentReceipt:
      receipt && receipt.sentAt >= timestamp
        ? receipt
        : {
            sentAt: timestamp,
            openedAt: null,
            expiresAt: new Date(new Date(timestamp).getTime() + INSTANT_LIFETIME_MS).toISOString(),
          },
  };
}

// The whole app shares one `localStorage.token`, so signing a second account in
// anywhere re-points every open tab at it. Instant has to notice: a tab that
// kept using its old socket would silently be listening as the wrong user.
function useSignedInUserId() {
  const [userId, setUserId] = useState<number | null>(() => getCurrentUserId());

  useEffect(() => {
    const sync = () => {
      const next = getCurrentUserId();
      setUserId((current) => (current === next ? current : next));
    };
    window.addEventListener("storage", sync);
    document.addEventListener("visibilitychange", sync);
    const timer = window.setInterval(sync, IDENTITY_POLL_MS);
    return () => {
      window.removeEventListener("storage", sync);
      document.removeEventListener("visibilitychange", sync);
      window.clearInterval(timer);
    };
  }, []);

  return userId;
}

function isAuthError(error: unknown) {
  return (
    axios.isAxiosError(error) &&
    (error.response?.status === 401 || error.response?.status === 403)
  );
}

export function useInstant(enabled: boolean) {
  const [device, setDevice] = useState<InstantDevice | null>(null);
  const [enrollError, setEnrollError] = useState<string | null>(null);
  const [instants, setInstants] = useState<InstantDelivery[]>([]);
  // Everyone you have talked to, whether or not a streak is running.
  // `/streaks` is a strict subset of this and is no longer fetched for the
  // list: a conversation used to vanish the moment its streak lapsed, and a
  // one-way send never appeared at all.
  const [serverHistory, setServerHistory] = useState<InstantConversation[]>([]);
  // When this client last sent to each person. Kept rather than dropped on the
  // next refresh: `withSend` takes the later of the two marks, so a server
  // still catching up cannot walk a send backwards.
  const [sendsByUser, setSendsByUser] = useState<Record<number, string>>({});
  // People whose instant has just been opened, so their row can offer a reply
  // rather than sitting inert. Session-scoped on purpose: the prompt is the
  // tail end of "you just looked at their photo", and one that survived a
  // reload would be a chore list rather than a nudge.
  const [replyHints, setReplyHints] = useState<number[]>([]);
  const [hasLoaded, setHasLoaded] = useState(false);
  const [connection, setConnection] = useState<InstantConnectionState>("connecting");
  const [authExpired, setAuthExpired] = useState(false);

  const socketRef = useRef<WebSocket | null>(null);
  const reconnectDelayRef = useRef(MIN_RECONNECT_MS);
  const reconnectTimerRef = useRef<number | null>(null);
  const seenIdsRef = useRef<Set<string>>(new Set());
  const currentUserId = useSignedInUserId();

  const handleAuthError = useCallback((error: unknown) => {
    if (isAuthError(error)) {
      clearAuthStorage();
      setAuthExpired(true);
      return true;
    }
    return false;
  }, []);

  const mergeInstants = useCallback((incoming: InstantDelivery[]) => {
    if (incoming.length === 0) {
      return;
    }
    // Dedup against instants already handled — including ones the user has
    // since viewed and dismissed, which is why this cannot just compare against
    // the current array.
    //
    // The bookkeeping happens HERE and not inside the setInstants updater. An
    // updater that mutates a ref is impure, and React double-invokes updaters
    // under StrictMode: the second pass would see every id already recorded,
    // skip them all, and commit an empty list. The instant would arrive, be
    // merged, and vanish.
    const fresh = incoming.filter((instant) => !seenIdsRef.current.has(instant.id));
    if (fresh.length === 0) {
      return;
    }
    for (const instant of fresh) {
      seenIdsRef.current.add(instant.id);
    }
    setInstants((previous) =>
      [...previous, ...fresh].sort((a, b) => a.createdAt.localeCompare(b.createdAt))
    );
  }, []);

  // Forget an instant locally. Used once it has been viewed or found
  // undecryptable — either way it can never be shown again.
  const dismissInstant = useCallback((instantId: string) => {
    setInstants((previous) => {
      // The server's count for this person is now stale by one, and until the
      // next history refresh lands, showing the larger of the two would keep
      // claiming mail that has already been read. Over-reporting is the worse
      // failure — it sends somebody looking for nothing.
      const senderId = previous.find((instant) => instant.id === instantId)?.senderId;
      if (senderId !== undefined) {
        setServerHistory((history) =>
          history.map((entry) =>
            entry.userId === senderId
              ? { ...entry, unopenedCount: Math.max(0, entry.unopenedCount - 1) }
              : entry
          )
        );
      }
      return previous.filter((instant) => instant.id !== instantId);
    });
  }, []);

  /// Records that something from this person has actually been seen, which is
  /// the moment a reply is most likely. Paired with `dismissInstant`, which is
  /// also called for an instant that was already gone or could not be
  /// decrypted — neither of which anyone opened, so neither earns a prompt.
  const noteOpened = useCallback((senderId: number) => {
    setReplyHints((current) => (current.includes(senderId) ? current : [...current, senderId]));
  }, []);

  /// Records an instant this client has just sent. Two things happen on a send
  /// and both have to be visible before the server is asked again: the
  /// conversation becomes the most recent one in either direction, and a reply
  /// prompt from them is answered.
  const noteSent = useCallback((userId: number, at: Date = new Date()) => {
    setSendsByUser((current) => ({ ...current, [userId]: at.toISOString() }));
    setReplyHints((current) => current.filter((id) => id !== userId));
  }, []);

  /// Drops everything this client holds about somebody just blocked. The server
  /// already hides them; this makes it true before the next refresh rather than
  /// after it.
  const forgetUser = useCallback((userId: number) => {
    setInstants((previous) => previous.filter((instant) => instant.senderId !== userId));
    setServerHistory((history) => history.filter((entry) => entry.userId !== userId));
    setSendsByUser((current) => {
      const next = { ...current };
      delete next[userId];
      return next;
    });
    setReplyHints((current) => current.filter((id) => id !== userId));
  }, []);

  // --- enrollment ----------------------------------------------------------

  // Nothing from the previous account may survive a switch: its instants were
  // wrapped to a different key and its socket belonged to a different inbox.
  useEffect(() => {
    setDevice(null);
    setInstants([]);
    setServerHistory([]);
    setSendsByUser({});
    setReplyHints([]);
    setHasLoaded(false);
    seenIdsRef.current = new Set();
  }, [currentUserId]);

  useEffect(() => {
    if (!enabled || currentUserId === null) {
      return;
    }
    let cancelled = false;

    const enroll = async () => {
      try {
        const identity = await getOrCreateDevice(currentUserId);
        if (cancelled) {
          return;
        }
        // The token can change while we are generating a keypair. Registering
        // this account's key under another account would hand them a shared
        // identity, so bail and let the next sync re-run with the right user.
        if (getCurrentUserId() !== currentUserId) {
          return;
        }
        // Registering is idempotent, so it is safe to do on every mount; it also
        // re-registers an identity the server has forgotten.
        await axios.post(
          `${BACKEND_URL}/api/v1/instant/keys`,
          { deviceId: identity.deviceId, publicKey: identity.publicKeyB64 },
          { headers: { Authorization: getAuthHeader() } }
        );
        if (cancelled) {
          return;
        }
        setDevice(identity);
        setEnrollError(null);
      } catch (error: unknown) {
        if (cancelled || handleAuthError(error)) {
          return;
        }
        setEnrollError(
          error instanceof Error
            ? error.message
            : "Could not set up Instant on this device."
        );
      }
    };

    void enroll();
    return () => {
      cancelled = true;
    };
  }, [enabled, currentUserId, handleAuthError]);

  // --- inbox drain ---------------------------------------------------------

  const refreshInbox = useCallback(
    async (deviceId: string) => {
      try {
        const response = await axios.get(`${BACKEND_URL}/api/v1/instant/inbox`, {
          headers: { Authorization: getAuthHeader() },
          params: { deviceId },
        });
        mergeInstants((response.data?.instants ?? []) as InstantDelivery[]);
      } catch (error: unknown) {
        handleAuthError(error);
      }
    },
    [handleAuthError, mergeInstants]
  );

  const refreshHistory = useCallback(async () => {
    try {
      const response = await axios.get(`${BACKEND_URL}/api/v1/instant/conversations`, {
        headers: { Authorization: getAuthHeader() },
      });
      setServerHistory((response.data?.conversations ?? []) as InstantConversation[]);
    } catch (error: unknown) {
      handleAuthError(error);
    } finally {
      // Loaded even on a failure: offline with nothing to show, a spinner that
      // never ends says less than an empty inbox with a way to refresh.
      setHasLoaded(true);
    }
  }, [handleAuthError]);

  // --- socket --------------------------------------------------------------

  useEffect(() => {
    if (!enabled || !device) {
      return;
    }
    let cancelled = false;
    let pingTimer: number | null = null;

    const clearReconnect = () => {
      if (reconnectTimerRef.current !== null) {
        window.clearTimeout(reconnectTimerRef.current);
        reconnectTimerRef.current = null;
      }
    };

    const scheduleReconnect = () => {
      if (cancelled) {
        return;
      }
      clearReconnect();
      const delay = reconnectDelayRef.current;
      reconnectDelayRef.current = Math.min(delay * 2, MAX_RECONNECT_MS);
      reconnectTimerRef.current = window.setTimeout(() => {
        void connect();
      }, delay);
    };

    const connect = async () => {
      if (cancelled) {
        return;
      }
      if (socketRef.current && socketRef.current.readyState <= WebSocket.OPEN) {
        return;
      }

      setConnection("connecting");
      // Drain first: whatever the socket does, queued instants must arrive.
      await refreshInbox(device.deviceId);
      await refreshHistory();
      if (cancelled) {
        return;
      }

      let ticket: string;
      try {
        const response = await axios.post(
          `${BACKEND_URL}/api/v1/instant/ws-ticket`,
          { deviceId: device.deviceId },
          { headers: { Authorization: getAuthHeader() } }
        );
        ticket = String(response.data?.ticket ?? "");
        if (!ticket) {
          throw new Error("No ticket issued");
        }
      } catch (error: unknown) {
        if (handleAuthError(error)) {
          return;
        }
        // 501 means the backend is running without the Durable Object binding
        // (i.e. `tsx src/server.ts` rather than `wrangler dev`). Polling the
        // inbox still works, so say so rather than retrying forever.
        if (axios.isAxiosError(error) && error.response?.status === 501) {
          setConnection("unsupported");
          return;
        }
        setConnection("offline");
        scheduleReconnect();
        return;
      }

      const socket = new WebSocket(
        `${WS_BASE_URL}/api/v1/instant/ws?ticket=${encodeURIComponent(ticket)}`
      );
      socketRef.current = socket;

      socket.onopen = () => {
        if (cancelled) {
          socket.close();
          return;
        }
        reconnectDelayRef.current = MIN_RECONNECT_MS;
        setConnection("open");
        pingTimer = window.setInterval(() => {
          if (socket.readyState === WebSocket.OPEN) {
            // Answered by the Durable Object's auto-response, which does not
            // wake it from hibernation.
            socket.send("ping");
          }
        }, PING_INTERVAL_MS);
      };

      socket.onmessage = (event) => {
        if (typeof event.data !== "string" || event.data === "pong") {
          return;
        }
        let parsed: InstantWireEvent;
        try {
          parsed = JSON.parse(event.data) as InstantWireEvent;
        } catch {
          return;
        }
        if (parsed.type === "instant") {
          mergeInstants([parsed.instant]);
          void refreshHistory();
        }
        if (parsed.type === "opened") {
          // The sender's read receipt: a photo this client sent has just been
          // taken. It lives on the conversation, and the streak may have moved
          // with it. "ready" is the handshake and changes nothing.
          void refreshHistory();
        }
      };

      const teardown = () => {
        if (pingTimer !== null) {
          window.clearInterval(pingTimer);
          pingTimer = null;
        }
        if (socketRef.current === socket) {
          socketRef.current = null;
        }
        if (!cancelled) {
          setConnection("offline");
          scheduleReconnect();
        }
      };

      socket.onclose = teardown;
      socket.onerror = teardown;
    };

    void connect();

    const onVisible = () => {
      if (document.visibilityState === "visible") {
        reconnectDelayRef.current = MIN_RECONNECT_MS;
        void connect();
      }
    };
    const onOnline = () => {
      reconnectDelayRef.current = MIN_RECONNECT_MS;
      void connect();
    };

    document.addEventListener("visibilitychange", onVisible);
    window.addEventListener("online", onOnline);

    return () => {
      cancelled = true;
      clearReconnect();
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("online", onOnline);
      if (pingTimer !== null) {
        window.clearInterval(pingTimer);
      }
      const socket = socketRef.current;
      socketRef.current = null;
      if (socket) {
        socket.onclose = null;
        socket.onerror = null;
        socket.close();
      }
    };
  }, [enabled, device, handleAuthError, mergeInstants, refreshInbox, refreshHistory]);

  // The history with anything sent from this client folded in, so the order
  // reflects a send the moment it happens rather than on the round trip that
  // follows it.
  const history = useMemo(() => {
    if (Object.keys(sendsByUser).length === 0) {
      return serverHistory;
    }
    return serverHistory.map((entry) => {
      const sentAt = sendsByUser[entry.userId];
      return sentAt ? withSend(entry, sentAt) : entry;
    });
  }, [serverHistory, sendsByUser]);

  // One row per person, ordered by what is time-sensitive: anything waiting,
  // then a streak waiting on a send from you, then simply whoever you
  // interacted with most recently — in either direction, so somebody you have
  // just sent to leads somebody who sent to you an hour ago.
  const rows = useMemo<InstantRow[]>(() => {
    const byUser = new Map<number, InstantRow>();

    // The history is the spine: it knows about people whose streak has lapsed,
    // who were never mutual, and whose instants have long since been swept.
    for (const entry of history) {
      byUser.set(entry.userId, {
        userId: entry.userId,
        name: entry.name?.trim() || "Someone",
        themeKey: entry.themeKey,
        profilePictureUrl: entry.profilePictureUrl,
        pending: null,
        pendingCount: 0,
        streakCount: entry.streakCount,
        streakAtRisk: entry.streakAtRisk,
        lastInteractionAt: entry.lastInteractionAt,
        lastSentReceipt: entry.lastSentReceipt,
        suggestsReply: replyHints.includes(entry.userId),
        streakNeedsYourSend: needsYourSend(entry),
      });
    }

    // Then what is actually openable *here*. The server's `unopenedCount`
    // counts every device the recipient owns, including instants this browser
    // holds no envelope for, so the local list is what decides whether a row
    // can be opened. `instants` is already in send order, so the first one seen
    // per sender is the oldest — the one that expires soonest.
    for (const instant of instants) {
      const existing = byUser.get(instant.senderId);
      byUser.set(instant.senderId, {
        userId: instant.senderId,
        // An instant can arrive over the socket before the history refresh that
        // would name this person, so fall back to what the delivery carries.
        name: existing?.name ?? instant.senderName?.trim() ?? "Someone",
        themeKey: existing?.themeKey ?? instant.senderThemeKey,
        profilePictureUrl: existing?.profilePictureUrl ?? instant.senderProfilePictureUrl,
        pending: existing?.pending ?? instant,
        pendingCount: (existing?.pendingCount ?? 0) + 1,
        streakCount: existing?.streakCount ?? 0,
        streakAtRisk: existing?.streakAtRisk ?? false,
        lastInteractionAt: existing?.lastInteractionAt ?? instant.createdAt,
        lastSentReceipt: existing?.lastSentReceipt ?? null,
        suggestsReply: existing?.suggestsReply ?? replyHints.includes(instant.senderId),
        streakNeedsYourSend: existing?.streakNeedsYourSend ?? false,
      });
    }

    return [...byUser.values()].sort((left, right) => {
      const leftPending = left.pending !== null;
      const rightPending = right.pending !== null;
      if (leftPending !== rightPending) {
        return leftPending ? -1 : 1;
      }
      if (left.streakNeedsYourSend !== right.streakNeedsYourSend) {
        return left.streakNeedsYourSend ? -1 : 1;
      }
      const leftSeen = left.lastInteractionAt ?? "";
      const rightSeen = right.lastInteractionAt ?? "";
      if (leftSeen !== rightSeen) {
        return leftSeen > rightSeen ? -1 : 1;
      }
      return left.name.localeCompare(right.name);
    });
  }, [history, instants, replyHints]);

  const refreshAll = useCallback(async () => {
    if (device) {
      await refreshInbox(device.deviceId);
    }
    await refreshHistory();
  }, [device, refreshInbox, refreshHistory]);

  return {
    device,
    enrollError,
    instants,
    history,
    rows,
    hasLoaded,
    connection,
    authExpired,
    currentUserId,
    dismissInstant,
    noteOpened,
    noteSent,
    forgetUser,
    refreshHistory,
    refreshInbox,
    refreshAll,
  };
}
