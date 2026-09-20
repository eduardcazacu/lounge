import { useCallback, useEffect, useRef, useState } from "react";
import axios from "axios";
import type { InstantDelivery } from "@blogging-app/common";
import { BACKEND_URL } from "../../config";
import { getAuthHeader } from "../../lib/auth";
import { openInstant } from "../../lib/instantCrypto";
import type { InstantDevice } from "../../lib/instantKeystore";
import { ReportSheet } from "./ReportSheet";
import { CountdownRing } from "./chrome";
import { IconExpired, IconMore, IconWarning } from "./icons";
import { INSTANT_COLORS } from "./style";

// Full-screen, black, one photo, one countdown. Tap anywhere to close — the
// same screen as `ios/Instant/Features/Viewer/ViewerScreen.swift`.
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
  onBlocked,
}: {
  instant: InstantDelivery;
  device: InstantDevice;
  /// `seen` is false for an instant that was already gone or could not be
  /// decrypted: it was opened by nobody, so the inbox must not go on to offer a
  /// reply to something nobody saw.
  onClose: (seen: boolean) => void;
  onBlocked: (userId: number) => void;
}) {
  const [state, setState] = useState<ViewerState>({ kind: "loading" });
  const [remaining, setRemaining] = useState<number | null>(null);
  const [reporting, setReporting] = useState(false);
  const urlRef = useRef<string | null>(null);
  const blobRef = useRef<Blob | null>(null);
  const closedRef = useRef(false);
  const startedRef = useRef(false);
  const receiptSentRef = useRef(false);
  const seenRef = useRef(false);
  const finishRef = useRef<() => void>(() => undefined);
  /// The countdown is held while something is on top of the photo — a report
  /// form — so reporting does not cost the reporter the photo they are
  /// reporting.
  const [paused, setPaused] = useState(false);

  const finish = useCallback(() => {
    if (closedRef.current) {
      return;
    }
    closedRef.current = true;
    if (urlRef.current) {
      URL.revokeObjectURL(urlRef.current);
      urlRef.current = null;
    }
    onClose(seenRef.current);
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
        // Nothing here can be unwrapped: this browser's keypair was replaced
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
        const blob = await openInstant(
          response.data as ArrayBuffer,
          {
            mediaIv: instant.mediaIv,
            ephemeralPubKey: instant.ephemeralPubKey,
            senderId: instant.senderId,
            mediaType: instant.mediaType,
            envelope: instant.envelope,
          },
          device
        );

        const url = URL.createObjectURL(blob);
        urlRef.current = url;
        blobRef.current = blob;
        seenRef.current = true;
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
          // The server claimed the row before it read the object, so the
          // instant is spent either way.
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

    // Records that the photo reached a screen, which the claim on /media cannot
    // know. The sender was already told by then.
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

    if (total === null || paused) {
      setRemaining(paused ? remaining : null);
      return;
    }

    const startedAt = Date.now();
    const from = remaining ?? total;
    setRemaining(from);
    const tick = window.setInterval(() => {
      const left = from - (Date.now() - startedAt);
      setRemaining(Math.max(0, left));
      if (left <= 0) {
        window.clearInterval(tick);
        finishRef.current();
      }
    }, 50);

    return () => window.clearInterval(tick);
    // `remaining` is deliberately not a dependency: it is read once to resume
    // from where a pause left off, and listing it would restart the clock on
    // every tick.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state.kind, instant.durationMode, instant.id, paused]);

  // Backgrounding the tab closes the instant, same as walking away from it.
  // No pausing the clock by switching tabs.
  useEffect(() => {
    const onHidden = () => {
      if (document.visibilityState !== "visible" && state.kind === "showing" && !paused) {
        finish();
      }
    };
    document.addEventListener("visibilitychange", onHidden);
    return () => document.removeEventListener("visibilitychange", onHidden);
  }, [state.kind, finish, paused]);

  useEffect(
    () => () => {
      if (urlRef.current) {
        URL.revokeObjectURL(urlRef.current);
      }
    },
    []
  );

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        finishRef.current();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const total = DURATION_MS[instant.durationMode] ?? null;
  const progress = total && remaining !== null ? remaining / total : 0;
  const senderName = instant.senderName?.trim() || "Someone";

  return (
    <div
      data-sheet
      className="fixed inset-0 z-50 bg-black"
      onClick={() => {
        if (!reporting) {
          finish();
        }
      }}
    >
      {state.kind === "loading" && (
        <p className="absolute inset-0 flex items-center justify-center text-sm text-white/70">
          Decrypting…
        </p>
      )}

      {state.kind === "showing" && (
        <img
          src={state.url}
          alt={`An instant from ${senderName}`}
          draggable={false}
          // An instant is meant to be gone after one look; the browser's own
          // Save Image callout is not the place to argue about that, but it
          // should not be the first thing a held finger finds either.
          style={{ WebkitTouchCallout: "none" }}
          className="absolute inset-0 h-full w-full select-none object-contain"
        />
      )}

      {state.kind === "error" && (
        <div className="absolute inset-0 flex flex-col items-center justify-center gap-3 px-9 text-center">
          {state.undecryptable ? <IconWarning size={38} /> : <IconExpired size={38} />}
          <p className="text-[15px]" style={{ color: "#d9d9d9" }}>
            {state.message}
          </p>
          {state.undecryptable && (
            <p className="text-[13px]" style={{ color: INSTANT_COLORS.secondaryText }}>
              Instant keys never leave the device that made them, and there is no recovery.
            </p>
          )}
        </div>
      )}

      <div className="absolute inset-x-0 top-0 flex items-start gap-3 p-4">
        {/* A photo is letterboxed, so this usually straddles its top edge: a
            blurred capsule reads as one thing over both halves where a flat
            translucent black vanished on the black one. */}
        <span className="rounded-full bg-white/15 px-3 py-1.5 text-[15px] font-semibold text-white backdrop-blur">
          {senderName}
        </span>
        <span className="flex-1" />
        {total !== null && state.kind === "showing" && <CountdownRing progress={progress} />}
        {/* Always offered, whatever state the photo is in: somebody who sent
            something that would not open is no less reportable. */}
        <button
          type="button"
          aria-label={`Report ${senderName}`}
          onClick={(event) => {
            event.stopPropagation();
            setPaused(true);
            setReporting(true);
          }}
          className="flex h-[34px] w-[34px] items-center justify-center rounded-full bg-white/15 text-white backdrop-blur"
        >
          <IconMore size={17} />
        </button>
      </div>

      {instant.durationMode === "infinite" && state.kind === "showing" && (
        <p
          className="absolute inset-x-0 bottom-6 text-center text-[13px]"
          style={{ color: "#bfbfbf" }}
        >
          Tap anywhere to close
        </p>
      )}

      {reporting && (
        <div className="absolute inset-0" onClick={(event) => event.stopPropagation()}>
          <ReportSheet
            reportedUserId={instant.senderId}
            reportedName={senderName}
            instantId={instant.id}
            photo={blobRef.current ?? undefined}
            onClose={() => {
              setReporting(false);
              setPaused(false);
            }}
            onBlocked={(userId) => {
              // A reported photo is closed rather than resumed: nobody who has
              // just reported something wants the rest of its countdown.
              onBlocked(userId);
              finish();
            }}
          />
        </div>
      )}
    </div>
  );
}
