import { useCallback, useEffect, useRef, useState } from "react";
import { loadImageElement } from "../../lib/image";
import { ComposeScreen } from "./ComposeScreen";
import { CircleIconButton, Viewport, ViewportOverlay } from "./chrome";
import {
  IconBolt,
  IconBoltOff,
  IconChat,
  IconClose,
  IconFlip,
  IconPhotos,
  IconSend,
} from "./icons";
import { INSTANT_COLORS } from "./style";
import type { InstantDraft, InstantRecipient } from "./useOutbox";
import type { UserListItem } from "../../hooks";
import type { InstantConversation } from "@blogging-app/common";

// The home screen, ported from `ios/Instant/Features/Camera/CameraScreen.swift`:
// a rounded 16:9 viewport on black with the controls inside it, flip and flash
// top-right, shutter at the bottom, and the account button facing them from the
// opposite corner. Snapchat's arrangement, because it puts the one action that
// matters under the thumb and everything else out of the way.

type Facing = "user" | "environment";

/// What a `MediaStreamTrack` will actually admit to. Neither zoom nor torch is
/// in the DOM types, and neither exists on a laptop webcam — so both controls
/// are offered only once the track has said it has them, rather than being
/// drawn and then doing nothing.
type ExtendedCapabilities = MediaTrackCapabilities & {
  zoom?: { min: number; max: number; step?: number };
  torch?: boolean;
};

/// The same two, on the way back in. Neither is in the DOM's constraint types
/// either, so the cast is the only way to ask for them — and it goes through
/// `unknown` because the DOM type genuinely does not overlap.
type ExtendedConstraints = { advanced: ({ zoom: number } | { torch: boolean })[] };

function extended(constraints: ExtendedConstraints): MediaTrackConstraints {
  return constraints as unknown as MediaTrackConstraints;
}

export function CameraScreen({
  aimedAt,
  onClearAim,
  unreadCount,
  onOpenInbox,
  onComposingChange,
  onSend,
  users,
  usersLoading,
  history,
  currentUserId,
}: {
  aimedAt: InstantRecipient | null;
  onClearAim: () => void;
  unreadCount: number;
  onOpenInbox: () => void;
  onComposingChange: (composing: boolean) => void;
  onSend: (draft: InstantDraft, recipients: InstantRecipient[]) => void;
  users: UserListItem[];
  usersLoading: boolean;
  history: InstantConversation[];
  currentUserId: number | null;
}) {
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const [facing, setFacing] = useState<Facing>("environment");
  const [ready, setReady] = useState(false);
  const [noCamera, setNoCamera] = useState(false);
  const [torch, setTorch] = useState<{ on: boolean; available: boolean }>({
    on: false,
    available: false,
  });
  const [zoom, setZoom] = useState<{ value: number; min: number; max: number } | null>(null);
  const [showsZoom, setShowsZoom] = useState(false);
  /// Black over the frame, from the press until there is a photo to look at.
  /// Not a blink: a blink ends on a timer, and whatever is left between the end
  /// of it and the picture appearing is the live camera still moving under a
  /// frame captured a moment ago — which reads as the shutter having missed.
  const [shuttered, setShuttered] = useState(false);
  const [captured, setCaptured] = useState<HTMLImageElement | null>(null);

  const stop = useCallback(() => {
    streamRef.current?.getTracks().forEach((track) => track.stop());
    streamRef.current = null;
  }, []);

  useEffect(() => {
    let cancelled = false;

    const start = async () => {
      stop();
      setReady(false);
      if (!navigator.mediaDevices?.getUserMedia) {
        setNoCamera(true);
        return;
      }
      try {
        // One axis only, and deliberately so. Asking for both — 1080×1920,
        // say — states an aspect ratio as well as a size, and a browser that
        // cannot serve that shape natively satisfies it by *cropping* the
        // sensor: on a phone whose camera hands back a landscape frame that is
        // a threefold crop of the middle of the picture, and on a laptop it
        // trims the sides off a 16:9 webcam. A single ideal height asks for a
        // sharp frame and leaves the shape to the camera.
        const stream = await navigator.mediaDevices.getUserMedia({
          video: { facingMode: facing, height: { ideal: 1440 } },
          audio: false,
        });
        if (cancelled) {
          stream.getTracks().forEach((track) => track.stop());
          return;
        }
        streamRef.current = stream;
        setNoCamera(false);
        if (videoRef.current) {
          videoRef.current.srcObject = stream;
          await videoRef.current.play().catch(() => undefined);
        }
        const capabilities = stream
          .getVideoTracks()[0]
          ?.getCapabilities?.() as ExtendedCapabilities | undefined;
        setTorch({ on: false, available: Boolean(capabilities?.torch) });
        setZoom(
          capabilities?.zoom
            ? { value: capabilities.zoom.min, min: capabilities.zoom.min, max: capabilities.zoom.max }
            : null
        );
      } catch {
        if (!cancelled) {
          // The same path a phone takes when camera permission is refused, and
          // the one a desktop without a webcam always takes.
          setNoCamera(true);
        }
      }
    };

    void start();
    return () => {
      cancelled = true;
      stop();
    };
  }, [facing, stop]);

  const flip = useCallback(() => {
    setFacing((current) => (current === "user" ? "environment" : "user"));
  }, []);

  const toggleTorch = useCallback(() => {
    const track = streamRef.current?.getVideoTracks()[0];
    if (!track) {
      return;
    }
    const next = !torch.on;
    void track
      .applyConstraints(extended({ advanced: [{ torch: next }] }))
      .then(() => setTorch((current) => ({ ...current, on: next })))
      .catch(() => undefined);
  }, [torch.on]);

  const applyZoom = useCallback((value: number) => {
    const track = streamRef.current?.getVideoTracks()[0];
    if (!track) {
      return;
    }
    setZoom((current) => (current ? { ...current, value } : current));
    void track
      .applyConstraints(extended({ advanced: [{ zoom: value }] }))
      .catch(() => undefined);
  }, []);

  // Two fingers on the frame, the way it works on the phone. Zoom belongs to
  // the track rather than to the preview, so the photo comes out magnified
  // without the capture path knowing anything about it.
  const pinch = useRef<{ distance: number; start: number } | null>(null);
  const onPointers = useRef(new Map<number, { x: number; y: number }>());

  const handlePointerDown = (event: React.PointerEvent) => {
    onPointers.current.set(event.pointerId, { x: event.clientX, y: event.clientY });
  };

  const handlePointerMove = (event: React.PointerEvent) => {
    if (!onPointers.current.has(event.pointerId)) {
      return;
    }
    onPointers.current.set(event.pointerId, { x: event.clientX, y: event.clientY });
    const points = [...onPointers.current.values()];
    if (points.length !== 2 || !zoom) {
      return;
    }
    const distance = Math.hypot(points[0].x - points[1].x, points[0].y - points[1].y);
    if (!pinch.current) {
      pinch.current = { distance, start: zoom.value };
      setShowsZoom(true);
      return;
    }
    const scale = distance / pinch.current.distance;
    const span = zoom.max - zoom.min;
    applyZoom(Math.min(zoom.max, Math.max(zoom.min, pinch.current.start * scale)));
    // Keep the label alive while the fingers are still on the glass.
    if (span > 0) {
      setShowsZoom(true);
    }
  };

  const handlePointerUp = (event: React.PointerEvent) => {
    onPointers.current.delete(event.pointerId);
    if (onPointers.current.size < 2) {
      pinch.current = null;
      window.setTimeout(() => setShowsZoom(false), 700);
    }
  };

  const adopt = useCallback(
    async (blob: Blob) => {
      const element = await loadImageElement(blob);
      setCaptured(element);
      onComposingChange(true);
      setShuttered(false);
    },
    [onComposingChange]
  );

  const shoot = useCallback(async () => {
    const video = videoRef.current;
    setShuttered(true);
    if (!video || !video.videoWidth) {
      setShuttered(false);
      return;
    }
    const blob = await captureFrame(video, facing === "user");
    if (blob) {
      await adopt(blob);
    } else {
      setShuttered(false);
    }
  }, [adopt, facing]);

  const discard = useCallback(() => {
    setCaptured(null);
    onComposingChange(false);
  }, [onComposingChange]);

  return (
    // The compose screen is drawn *over* the camera rather than instead of it,
    // so the video element stays mounted and the stream stays open. Tearing the
    // session down and building it again on every retake is most of a second of
    // black, which is the one thing the shutter cover exists to avoid.
    <div className={`absolute inset-0 ${captured ? "invisible" : ""}`}>
      <Viewport className="bg-gradient-to-b from-neutral-800 to-neutral-950">
        {/* The frame is shown whole, at whatever shape the camera gives, rather
            than filled to the viewport and cropped — what is framed is what is
            taken. A phone's camera is 4:3 standing up, so it fills the width
            and leaves a band at each end, which is where the controls sit
            anyway; a laptop's is 16:9 lying down and lands as a strip across
            the middle. The size is the video's own: an element told its
            dimensions cannot correct itself when iOS revises `videoWidth` and
            `videoHeight` after the fact (see wiki/gotchas.md), and one that
            lays itself out does. */}
        <div className="flex h-full w-full items-center justify-center">
          <video
            ref={videoRef}
            playsInline
            muted
            onLoadedMetadata={() => setReady(true)}
            onDoubleClick={flip}
            onPointerDown={handlePointerDown}
            onPointerMove={handlePointerMove}
            onPointerUp={handlePointerUp}
            onPointerCancel={handlePointerUp}
            className={`block max-h-full max-w-full touch-none select-none transition-opacity duration-300 ${
              ready && !noCamera ? "opacity-100" : "opacity-0"
            } ${facing === "user" ? "-scale-x-100" : ""}`}
          />
        </div>
        {noCamera && (
          <div className="absolute inset-0 flex flex-col items-center justify-center gap-2 px-8 text-center">
            <IconPhotos size={40} className="text-white" />
            <p className="text-base font-semibold text-white">No camera here</p>
            <p className="text-sm" style={{ color: INSTANT_COLORS.secondaryText }}>
              Pick a photo from this device instead.
            </p>
          </div>
        )}
        {/* Above the frame, so it outlasts the handover to the compose screen:
            anything visible in between is the live camera still moving under a
            photo that has already been taken. */}
        <div
          className={`pointer-events-none absolute inset-0 bg-black transition-opacity ${
            shuttered ? "opacity-100 duration-[40ms]" : "opacity-0 duration-100"
          }`}
        />
      </Viewport>

      <ViewportOverlay>
        <div className="flex justify-end gap-3">
          <div className="flex flex-col gap-3">
            {torch.available && (
              <CircleIconButton
                label="Flash"
                isOn={torch.on}
                onClick={toggleTorch}
                id="camera.flash"
              >
                {torch.on ? <IconBolt /> : <IconBoltOff />}
              </CircleIconButton>
            )}
            <CircleIconButton label="Flip camera" onClick={flip} id="camera.flip">
              <IconFlip />
            </CircleIconButton>
          </div>
        </div>

        {aimedAt && (
          <div className="mt-3 flex justify-center">
            {/* Who the shot is already for, shown while framing rather than
                only on the send button — an aim set a few taps ago in the inbox
                must not be a surprise discovered after the photo is taken. */}
            <span className="pointer-events-auto flex items-center gap-2 rounded-full bg-black/45 py-1.5 pl-3.5 pr-1.5 text-white">
              <IconSend size={12} />
              <span className="text-sm font-semibold">Sending to {aimedAt.name}</span>
              <button
                type="button"
                onClick={onClearAim}
                aria-label={`Stop sending to ${aimedAt.name}`}
                className="rounded-full bg-white/20 p-1.5"
              >
                <IconClose size={11} />
              </button>
            </span>
          </div>
        )}

        <div className="flex-1" />

        {showsZoom && zoom && (
          <div className="mb-4 flex justify-center">
            <span className="rounded-full bg-black/45 px-3.5 py-1.5 text-[15px] font-bold tabular-nums text-white">
              {(zoom.value / Math.max(zoom.min, 1)).toFixed(1)}×
            </span>
          </div>
        )}

        <div className="flex items-center justify-between">
          <button
            type="button"
            onClick={onOpenInbox}
            aria-label="Conversations"
            data-testid="camera.inbox"
            className="pointer-events-auto relative flex h-12 w-12 items-center justify-center rounded-full bg-black/35 text-white"
          >
            <IconChat />
            {unreadCount > 0 && (
              <span
                className="absolute -right-0.5 -top-0.5 min-w-[20px] rounded-full px-1 text-[11px] font-bold leading-5 text-white"
                style={{ background: INSTANT_COLORS.unread }}
              >
                {unreadCount}
              </span>
            )}
          </button>

          {noCamera ? (
            <label className="pointer-events-auto cursor-pointer" aria-label="Take a photo">
              <Shutter enabled />
              <input
                type="file"
                accept="image/*"
                capture="environment"
                className="hidden"
                onChange={(event) => {
                  const file = event.target.files?.[0];
                  event.target.value = "";
                  if (file) {
                    void adopt(file);
                  }
                }}
              />
            </label>
          ) : (
            <button
              type="button"
              onClick={() => void shoot()}
              disabled={!ready}
              aria-label="Take a photo"
              data-testid="camera.shutter"
              className="pointer-events-auto"
            >
              <Shutter enabled={ready} />
            </button>
          )}

          {/* Balances the chat button. The streak count lives with the person
              it belongs to, on the conversation row. */}
          <span className="h-12 w-12" />
        </div>
      </ViewportOverlay>

      {captured && (
        <div className="visible">
          <ComposeScreen
            image={captured}
            aimedAt={aimedAt}
            onDiscard={discard}
            onSend={(draft, recipients) => {
              onSend(draft, recipients);
              discard();
            }}
            users={users}
            usersLoading={usersLoading}
            history={history}
            currentUserId={currentUserId}
          />
        </div>
      )}
    </div>
  );
}

function Shutter({ enabled }: { enabled: boolean }) {
  return (
    <span
      className="flex h-[78px] w-[78px] items-center justify-center rounded-full border-[5px] transition"
      style={{
        borderColor: enabled ? "#fff" : "rgba(255,255,255,0.4)",
      }}
    >
      <span
        className="h-[62px] w-[62px] rounded-full"
        style={{ background: enabled ? "rgba(255,255,255,0.15)" : "rgba(255,255,255,0.05)" }}
      />
    </span>
  );
}

/// The whole frame, at the camera's own shape.
///
/// Nothing is cropped here, because nothing is cropped on screen either: the
/// preview shows the frame whole, so the photo is the picture the sender was
/// looking at. The compose screen and the viewer both letterbox whatever shape
/// arrives, and a caption's place in it is stored as a fraction of the photo,
/// so no part of the app has an opinion about 16:9 except the frame it draws
/// the photo inside.
async function captureFrame(video: HTMLVideoElement, mirrored: boolean): Promise<Blob | null> {
  // The encode ladder shrinks from here anyway; this only stops a 4K webcam
  // painting eight megapixels nobody will send.
  const scale = Math.min(1, 1920 / Math.max(video.videoWidth, video.videoHeight));
  const canvas = document.createElement("canvas");
  canvas.width = Math.round(video.videoWidth * scale);
  canvas.height = Math.round(video.videoHeight * scale);
  const context = canvas.getContext("2d");
  if (!context) {
    return null;
  }
  if (mirrored) {
    // A selfie reads as mirrored on screen, the way a mirror does; the capture
    // un-mirrors to match what was framed.
    context.translate(canvas.width, 0);
    context.scale(-1, 1);
  }
  context.drawImage(video, 0, 0, canvas.width, canvas.height);
  return new Promise((resolve) => canvas.toBlob((blob) => resolve(blob), "image/png"));
}
