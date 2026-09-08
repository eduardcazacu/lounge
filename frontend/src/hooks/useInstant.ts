import { useCallback, useEffect, useRef, useState } from "react";
import axios from "axios";
import type { InstantDelivery, InstantStreakSummary, InstantWireEvent } from "@blogging-app/common";
import { BACKEND_URL, WS_BASE_URL } from "../config";
import { clearAuthStorage, getAuthHeader, getCurrentUserId } from "../lib/auth";
import { getOrCreateDevice, type InstantDevice } from "../lib/instantKeystore";

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
  const [streaks, setStreaks] = useState<InstantStreakSummary[]>([]);
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
    setInstants((previous) => previous.filter((instant) => instant.id !== instantId));
  }, []);

  // --- enrollment ----------------------------------------------------------

  // Nothing from the previous account may survive a switch: its instants were
  // wrapped to a different key and its socket belonged to a different inbox.
  useEffect(() => {
    setDevice(null);
    setInstants([]);
    setStreaks([]);
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

  const refreshStreaks = useCallback(async () => {
    try {
      const response = await axios.get(`${BACKEND_URL}/api/v1/instant/streaks`, {
        headers: { Authorization: getAuthHeader() },
      });
      setStreaks((response.data?.streaks ?? []) as InstantStreakSummary[]);
    } catch (error: unknown) {
      handleAuthError(error);
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
      await refreshStreaks();
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
          void refreshStreaks();
        }
        // "opened" is the sender's read receipt; "ready" is the handshake.
        // Neither changes the inbox, so nothing else to do here yet.
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
  }, [enabled, device, handleAuthError, mergeInstants, refreshInbox, refreshStreaks]);

  return {
    device,
    enrollError,
    instants,
    streaks,
    connection,
    authExpired,
    currentUserId,
    dismissInstant,
    refreshStreaks,
    refreshInbox,
  };
}
