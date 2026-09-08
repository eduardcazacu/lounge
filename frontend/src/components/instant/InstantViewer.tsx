import { useCallback, useEffect, useRef, useState } from "react";
import axios from "axios";
import type { InstantDelivery } from "@blogging-app/common";
import { BACKEND_URL } from "../../config";
import { getAuthHeader } from "../../lib/auth";
import { openInstant } from "../../lib/instantCrypto";
import type { InstantDevice } from "../../lib/instantKeystore";

// Full-screen viewer.
//
// Fetching the media is what consumes it: the server claims the row, hands over
// the ciphertext once, and deletes both the object and every wrapped key. There
// is no second look, so everything below is about showing it and then letting
// go cleanly.

type ViewerState =
  | { kind: "loading" }
  | { kind: "showing"; url: string }
  | { kind: "error"; message: string; undecryptable: boolean };

const DURATION_MS: Record<string, number | null> = {
  "1s": 1000,
  "5s": 5000,
  infinite: null,
};

export function InstantViewer({
  instant,
  device,
  onClose,
}: {
  instant: InstantDelivery;
  device: InstantDevice;
  onClose: () => void;
}) {
  const [state, setState] = useState<ViewerState>({ kind: "loading" });
  const [remaining, setRemaining] = useState<number | null>(null);
  const urlRef = useRef<string | null>(null);
  const closedRef = useRef(false);
  const startedRef = useRef(false);
  const receiptSentRef = useRef(false);
  const finishRef = useRef<() => void>(() => undefined);

  const finish = useCallback(() => {
    if (closedRef.current) {
      return;
    }
    closedRef.current = true;
    if (urlRef.current) {
      URL.revokeObjectURL(urlRef.current);
      urlRef.current = null;
    }
    onClose();
  }, [onClose]);

  // Read through a ref so the countdown below does not restart every time the
  // parent re-renders and hands us a fresh onClose.
  finishRef.current = finish;

  useEffect(() => {
    // Fetching the media destroys it server-side, so this must fire exactly
    // once. React runs effects twice under StrictMode (and may re-run them at
    // any time), which would consume the instant on the first call and render
    // the second call's 410 — the instant would look lost the moment it was
    // opened. A ref survives the double-invoke; a cleanup flag would not,
    // because the request has already been sent by then.
    if (startedRef.current) {
      return;
    }
    startedRef.current = true;

    const load = async () => {
      if (!instant.envelope) {
        // Nothing here can be unwrapped: this device's keypair was replaced
        // after the instant was sent. Tell the server so it stops holding it.
        setState({
          kind: "error",
          undecryptable: true,
          message:
            "This instant was locked to a key this browser no longer has, so it can never be opened.",
        });
        await axios
          .post(
            `${BACKEND_URL}/api/v1/instant/${instant.id}/undecryptable`,
            {},
            { headers: { Authorization: getAuthHeader() } }
          )
          .catch(() => undefined);
        return;
      }

      try {
        const response = await axios.get(`${BACKEND_URL}/api/v1/instant/${instant.id}/media`, {
          headers: { Authorization: getAuthHeader() },
          responseType: "arraybuffer",
        });
        const blob = await openInstant(response.data as ArrayBuffer, {
          mediaIv: instant.mediaIv,
          ephemeralPubKey: instant.ephemeralPubKey,
          senderId: instant.senderId,
          mediaType: instant.mediaType,
          envelope: instant.envelope,
        }, device);

        const url = URL.createObjectURL(blob);
        urlRef.current = url;
        setState({ kind: "showing", url });
      } catch (error: unknown) {
        if (axios.isAxiosError(error) && error.response?.status === 410) {
          setState({
            kind: "error",
            undecryptable: false,
            message: "This instant was already opened somewhere else, or it expired.",
          });
          return;
        }
        setState({
          kind: "error",
          undecryptable: false,
          message: "That instant could not be opened. It is gone either way.",
        });
      }
    };

    void load();
  }, [instant, device]);

  // Timer starts when the image is actually on screen, not when the fetch began.
  useEffect(() => {
    if (state.kind !== "showing") {
      return;
    }
    const total = DURATION_MS[instant.durationMode] ?? null;

    // Tell the sender it was seen, once.
    if (!receiptSentRef.current) {
      receiptSentRef.current = true;
      void axios
        .post(
          `${BACKEND_URL}/api/v1/instant/${instant.id}/viewed`,
          {},
          { headers: { Authorization: getAuthHeader() } }
        )
        .catch(() => undefined);
    }

    if (total === null) {
      setRemaining(null);
      return;
    }

    const startedAt = Date.now();
    setRemaining(total);
    const tick = window.setInterval(() => {
      const left = total - (Date.now() - startedAt);
      setRemaining(Math.max(0, left));
      if (left <= 0) {
        window.clearInterval(tick);
        finishRef.current();
      }
    }, 50);

    return () => window.clearInterval(tick);
  }, [state.kind, instant.durationMode, instant.id]);

  // Backgrounding the tab closes the instant, same as walking away from it.
  useEffect(() => {
    const onHidden = () => {
      if (document.visibilityState !== "visible" && state.kind === "showing") {
        finish();
      }
    };
    document.addEventListener("visibilitychange", onHidden);
    return () => document.removeEventListener("visibilitychange", onHidden);
  }, [state.kind, finish]);

  useEffect(() => () => {
    if (urlRef.current) {
      URL.revokeObjectURL(urlRef.current);
    }
  }, []);

  const total = DURATION_MS[instant.durationMode] ?? null;
  const progress = total && remaining !== null ? remaining / total : 0;
  const senderName = instant.senderName?.trim() || "Someone";

  return (
    <div className="fixed inset-0 z-50 flex flex-col bg-black">
      <div className="flex items-center justify-between px-4 py-3 text-white">
        <span className="text-sm font-medium">{senderName}</span>
        <button
          type="button"
          onClick={finish}
          className="rounded-full bg-white/10 px-3 py-1.5 text-xs font-semibold"
        >
          Close
        </button>
      </div>

      {total !== null && state.kind === "showing" && (
        <div className="mx-4 h-1 overflow-hidden rounded-full bg-white/20">
          <div
            className="h-full bg-white transition-[width] duration-75 ease-linear"
            style={{ width: `${progress * 100}%` }}
          />
        </div>
      )}

      <div
        className="flex flex-1 items-center justify-center p-4"
        onClick={() => {
          if (instant.durationMode === "infinite" || state.kind === "error") {
            finish();
          }
        }}
      >
        {state.kind === "loading" && (
          <p className="text-sm text-white/70">Decrypting…</p>
        )}
        {state.kind === "showing" && (
          <img src={state.url} alt="" className="max-h-full max-w-full object-contain" />
        )}
        {state.kind === "error" && (
          <div className="max-w-sm text-center">
            <p className="text-sm text-white/80">{state.message}</p>
            {state.undecryptable && (
              <p className="mt-2 text-xs text-white/50">
                Instant keys never leave the device that made them, and there is no recovery.
              </p>
            )}
          </div>
        )}
      </div>

      {instant.durationMode === "infinite" && state.kind === "showing" && (
        <p className="pb-6 text-center text-xs text-white/50">Tap anywhere to close</p>
      )}
    </div>
  );
}
