import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import axios from "axios";
import type { InstantDurationMode } from "@blogging-app/common";
import { BACKEND_URL } from "../../config";
import { getAuthHeader } from "../../lib/auth";
import { encodeToWebp, loadImageElement } from "../../lib/image";
import { sealForDevices, type RecipientDeviceKey } from "../../lib/instantCrypto";
import type { UserListItem } from "../../hooks";
import { UsersStrip } from "../UsersStrip";

// Portrait profile. This is the whole bandwidth story for Instant: the bytes
// are encrypted and served from an authenticated endpoint, so Cloudflare's
// image transforms (lib/content.ts) cannot touch them on the way out.
const INSTANT_ENCODE_OPTIONS = {
  maxWidth: 1080,
  maxHeight: 1920,
  targetBytes: 250_000,
  qualityLevels: [0.9, 0.82, 0.74, 0.66],
  minLongEdge: 640,
};

const DURATIONS: { mode: InstantDurationMode; label: string }[] = [
  { mode: "1s", label: "1s" },
  { mode: "5s", label: "5s" },
  { mode: "infinite", label: "∞" },
];

type Overlay = {
  text: string;
  // Fractions of the image, so the overlay survives the resize below.
  x: number;
  y: number;
};

export function InstantComposer({
  image,
  currentUserId,
  users,
  usersLoading,
  onSent,
  onDiscard,
}: {
  image: Blob;
  currentUserId: number;
  users: UserListItem[];
  usersLoading: boolean;
  onSent: (recipientName: string) => void;
  onDiscard: () => void;
}) {
  const [overlay, setOverlay] = useState<Overlay>({ text: "", x: 0.5, y: 0.85 });
  const [duration, setDuration] = useState<InstantDurationMode>("5s");
  const [recipientId, setRecipientId] = useState<number | null>(null);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [encodedBytes, setEncodedBytes] = useState<number | null>(null);
  const [element, setElement] = useState<HTMLImageElement | null>(null);
  const previewRef = useRef<HTMLDivElement | null>(null);
  // Rendered width of the photo, used to size the caption so the preview
  // matches the burned-in result. Measured rather than done with container
  // queries: `container-type: inline-size` makes an element's width ignore its
  // contents, which collapses a shrink-to-fit wrapper to zero.
  const [previewWidth, setPreviewWidth] = useState(0);

  // Create and revoke in the same effect. Memoizing the URL and revoking it
  // from a cleanup meant StrictMode's mount/unmount/mount revoked the very URL
  // it then went on to render, leaving the preview permanently blank.
  const [objectUrl, setObjectUrl] = useState<string | null>(null);
  useEffect(() => {
    const url = URL.createObjectURL(image);
    setObjectUrl(url);
    return () => URL.revokeObjectURL(url);
  }, [image]);

  useEffect(() => {
    let cancelled = false;
    void loadImageElement(image).then((loaded) => {
      if (!cancelled) {
        setElement(loaded);
      }
    });
    return () => {
      cancelled = true;
    };
  }, [image]);

  useEffect(() => {
    const node = previewRef.current;
    if (!node || typeof ResizeObserver === "undefined") {
      return;
    }
    const observer = new ResizeObserver(([entry]) => {
      setPreviewWidth(entry.contentRect.width);
    });
    observer.observe(node);
    return () => observer.disconnect();
  }, [objectUrl]);

  const recipients = useMemo(
    () => users.filter((user) => user.id !== currentUserId),
    [users, currentUserId]
  );

  // Drag the caption to reposition it, in normalized coordinates.
  const moveOverlay = useCallback((clientX: number, clientY: number) => {
    const box = previewRef.current?.getBoundingClientRect();
    if (!box) {
      return;
    }
    setOverlay((current) => ({
      ...current,
      x: Math.min(0.95, Math.max(0.05, (clientX - box.left) / box.width)),
      y: Math.min(0.95, Math.max(0.05, (clientY - box.top) / box.height)),
    }));
  }, []);

  // Flattens the caption into the pixels. The backend only ever sees the
  // finished image — there is no separate text field on the wire.
  const composite = useCallback((): HTMLCanvasElement => {
    if (!element) {
      throw new Error("Image is still loading.");
    }
    const canvas = document.createElement("canvas");
    canvas.width = element.naturalWidth;
    canvas.height = element.naturalHeight;
    const context = canvas.getContext("2d");
    if (!context) {
      throw new Error("Canvas is unavailable in this browser.");
    }
    context.drawImage(element, 0, 0);

    const text = overlay.text.trim();
    if (!text) {
      return canvas;
    }

    const fontSize = Math.round(canvas.width * 0.06);
    context.font = `600 ${fontSize}px system-ui, -apple-system, sans-serif`;
    context.textAlign = "center";
    context.textBaseline = "middle";

    const x = canvas.width * overlay.x;
    const y = canvas.height * overlay.y;
    const metrics = context.measureText(text);
    const padding = fontSize * 0.4;

    context.fillStyle = "rgba(15, 23, 42, 0.55)";
    context.fillRect(
      x - metrics.width / 2 - padding,
      y - fontSize / 2 - padding * 0.6,
      metrics.width + padding * 2,
      fontSize + padding * 1.2
    );
    context.fillStyle = "#ffffff";
    context.fillText(text, x, y);

    return canvas;
  }, [element, overlay]);

  const send = useCallback(async () => {
    if (!recipientId) {
      setError("Pick someone to send this to.");
      return;
    }
    setSending(true);
    setError(null);
    try {
      const canvas = composite();
      const webp = await encodeToWebp(canvas, INSTANT_ENCODE_OPTIONS);
      setEncodedBytes(webp.size);

      // Fetch the recipient's device keys at send time, so a device enrolled
      // five minutes ago still gets a copy.
      const keysResponse = await axios.get(
        `${BACKEND_URL}/api/v1/instant/keys/${recipientId}`,
        { headers: { Authorization: getAuthHeader() } }
      );
      const devices = (keysResponse.data?.devices ?? []) as RecipientDeviceKey[];
      if (devices.length === 0) {
        throw new Error("They have not set up Instant yet, so nothing can be encrypted for them.");
      }

      const sealed = await sealForDevices(webp, currentUserId, devices);

      const form = new FormData();
      form.append("media", new Blob([sealed.ciphertext], { type: "application/octet-stream" }), "instant.bin");
      form.append(
        "payload",
        JSON.stringify({
          recipientId,
          durationMode: duration,
          mediaType: "image/webp",
          mediaIv: sealed.mediaIv,
          ephemeralPubKey: sealed.ephemeralPubKey,
          envelopes: sealed.envelopes,
        })
      );

      await axios.post(`${BACKEND_URL}/api/v1/instant`, form, {
        headers: { Authorization: getAuthHeader() },
      });

      const recipient = recipients.find((user) => user.id === recipientId);
      onSent(recipient?.name?.trim() || "them");
    } catch (sendError: unknown) {
      const message =
        axios.isAxiosError(sendError) && typeof sendError.response?.data?.msg === "string"
          ? sendError.response.data.msg
          : sendError instanceof Error
            ? sendError.message
            : "Could not send that instant.";
      setError(message);
    } finally {
      setSending(false);
    }
  }, [composite, currentUserId, duration, onSent, recipientId, recipients]);

  return (
    <div className="flex flex-col gap-4">
      {/* The wrapper shrink-wraps the image, so its box IS the rendered photo.
          With object-contain inside a fixed-shape box the caption was being
          positioned against letterbox bars: dragged to the middle of the photo
          it burned in somewhere else, and could even be placed on a bar that is
          not part of the image at all. */}
      <div className="flex justify-center">
        <div
          ref={previewRef}
          className="relative inline-block overflow-hidden rounded-2xl bg-slate-900"
          onPointerDown={(event) => {
            event.currentTarget.setPointerCapture(event.pointerId);
            moveOverlay(event.clientX, event.clientY);
          }}
          onPointerMove={(event) => {
            if (event.buttons === 1) {
              moveOverlay(event.clientX, event.clientY);
            }
          }}
        >
          {objectUrl && (
            <img
              src={objectUrl}
              alt="Instant preview"
              // The ResizeObserver below only sees later reflows; the first
              // real size arrives with the decoded image.
              onLoad={(event) =>
                setPreviewWidth(event.currentTarget.getBoundingClientRect().width)
              }
              className="block max-h-[55vh] max-w-full"
            />
          )}
          {overlay.text.trim() && (
            // 6cqw mirrors the canvas's `canvas.width * 0.06`, so the caption is
            // the same relative size here as in the file that gets sent.
            <span
              className="pointer-events-none absolute -translate-x-1/2 -translate-y-1/2 whitespace-pre rounded bg-slate-900/60 px-[0.4em] py-[0.24em] text-center font-semibold leading-none text-white"
              style={{
                left: `${overlay.x * 100}%`,
                top: `${overlay.y * 100}%`,
                // Mirrors `canvas.width * 0.06` in composite().
                fontSize: `${Math.max(10, previewWidth * 0.06)}px`,
              }}
            >
              {overlay.text}
            </span>
          )}
        </div>
      </div>

      <input
        type="text"
        value={overlay.text}
        maxLength={80}
        placeholder="Add a caption — tap the photo to move it"
        onChange={(event) => setOverlay((current) => ({ ...current, text: event.target.value }))}
        className="w-full rounded-lg border border-slate-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-slate-400"
      />

      <div className="flex flex-wrap items-center gap-2">
        <span className="text-xs font-medium text-slate-600">Visible for</span>
        {DURATIONS.map((option) => (
          <button
            key={option.mode}
            type="button"
            onClick={() => setDuration(option.mode)}
            className={`rounded-full px-3 py-1.5 text-xs font-semibold ${
              duration === option.mode
                ? "bg-slate-900 text-white"
                : "border border-slate-300 text-slate-700"
            }`}
          >
            {option.label}
          </button>
        ))}
        <span className="w-full text-[11px] text-slate-500 sm:ml-auto sm:w-auto sm:text-right">
          {duration === "infinite" ? "Until they close it" : `${durationLabel(duration)} after opening`}
        </span>
      </div>

      <div>
        <p className="mb-1.5 text-xs font-medium text-slate-600">Send to</p>
        <UsersStrip
          users={recipients}
          loading={usersLoading}
          selectedAuthorId={recipientId}
          onSelect={(id) => setRecipientId(id)}
        />
      </div>

      {error && <p className="text-sm text-rose-600">{error}</p>}
      {encodedBytes !== null && !error && (
        <p className="text-[11px] text-slate-500">
          Encoded to {(encodedBytes / 1024).toFixed(0)} KB before encryption.
        </p>
      )}

      <div className="flex gap-2">
        <button
          type="button"
          onClick={onDiscard}
          disabled={sending}
          className="rounded-lg border border-slate-300 px-4 py-2 text-sm font-medium text-slate-700 disabled:opacity-50"
        >
          Retake
        </button>
        <button
          type="button"
          onClick={() => void send()}
          disabled={sending || !recipientId || !element}
          className="flex-1 rounded-lg bg-slate-900 px-4 py-2 text-sm font-semibold text-white disabled:opacity-50"
        >
          {sending ? "Encrypting and sending…" : "Send instant"}
        </button>
      </div>
    </div>
  );
}

function durationLabel(mode: InstantDurationMode) {
  return mode === "1s" ? "1 second" : "5 seconds";
}
