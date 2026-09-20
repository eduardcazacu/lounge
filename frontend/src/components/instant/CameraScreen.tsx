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
        // No size asked for at all. Every dimension in a constraint is a
        // dimension the browser may deliver by *cropping* the sensor, and each
        // one crops a different edge: both axes together cost Safari the sides
        // of the picture, and a height on its own costs Firefox the top and the
        // bottom. The shape is the camera's to state, and `upgradeResolution`
        // asks for more pixels of it afterwards.
        const stream = await navigator.mediaDevices.getUserMedia({
          video: { facingMode: facing },
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
        const track = stream.getVideoTracks()[0];
        // After the preview is live, not before it: the element sizes itself
        // from the frame, so a larger one arriving a moment later simply
        // re-lays it out.
        void upgradeResolution(track);
        const capabilities = track?.getCapabilities?.() as ExtendedCapabilities | undefined;
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
        {/* The frame fills the viewport, which costs it the sides. That is the
            same trade the phone app makes — `AVCaptureSession` frames 16:9 out
            of a sensor that is 4:3 — and it is only a quarter of the width of a
            camera standing up. The earlier version of this filled the viewport
            with a *landscape* frame, which is the same rule applied to a frame
            three times the wrong shape, and that is what read as a photo zoomed
            into its own middle. The frame is portrait now because nothing asks
            the camera to be anything else; see `openCamera`. */}
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
          className={`h-full w-full touch-none select-none object-cover transition-opacity duration-300 ${
            ready && !noCamera ? "opacity-100" : "opacity-0"
          } ${facing === "user" ? "-scale-x-100" : ""}`}
        />
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

/// Enough for a photo, and no more than the encode ladder will keep.
const IDEAL_LONG_EDGE = 1920;

/// Asks an open camera for more pixels **of the shape it already has**.
///
/// Unconstrained, a browser hands over its default mode, which is often 640×480
/// — fine for a video call and soft for a photo. The way to ask for better
/// without asking for a crop is to let the camera answer first: read the frame
/// it chose, work out its aspect, and ask for a bigger frame of exactly that
/// aspect, which it can serve by scaling rather than by cutting something off.
///
/// If the shape moves anyway, the browser cropped to reach it, and the frame it
/// started with is asked for back — it has just proved it can deliver that one.
/// A browser that does not implement `getCapabilities` keeps its default, which
/// is the whole picture at a modest size: the right way round of the trade.
async function upgradeResolution(track: MediaStreamTrack | undefined) {
  const initial = track?.getSettings();
  if (!track || !initial?.width || !initial?.height) {
    return;
  }
  const aspect = initial.width / initial.height;
  const capabilities = track.getCapabilities?.();
  const ceiling = Math.min(
    IDEAL_LONG_EDGE,
    Math.max(capabilities?.width?.max ?? 0, capabilities?.height?.max ?? 0)
  );
  if (ceiling <= Math.max(initial.width, initial.height)) {
    return;
  }

  const [width, height] =
    aspect >= 1
      ? [ceiling, Math.round(ceiling / aspect)]
      : [Math.round(ceiling * aspect), ceiling];
  try {
    await track.applyConstraints({ width: { ideal: width }, height: { ideal: height } });
  } catch {
    return;
  }

  const settled = track.getSettings();
  if (
    settled.width &&
    settled.height &&
    Math.abs(settled.width / settled.height - aspect) > 0.01
  ) {
    await track
      .applyConstraints({
        width: { ideal: initial.width },
        height: { ideal: initial.height },
      })
      .catch(() => undefined);
  }
}

/// The frame as it was framed: the viewport's 16:9 out of the middle of it.
///
/// This is the same arithmetic `object-cover` is doing on the preview, and it
/// has to be, because the preview *is* the framing. A photo cropped differently
/// from the picture the sender was looking at is a photo they never took.
async function captureFrame(video: HTMLVideoElement, mirrored: boolean): Promise<Blob | null> {
  const sourceWidth = video.videoWidth;
  const sourceHeight = video.videoHeight;
  const target = 9 / 16;
  const sourceAspect = sourceWidth / sourceHeight;

  // Wider than the frame loses its sides, which is every camera; taller than it
  // loses its ends, which is nothing in practice and is here for completeness.
  const cropWidth = sourceAspect > target ? sourceHeight * target : sourceWidth;
  const cropHeight = sourceAspect > target ? sourceHeight : sourceWidth / target;
  const cropX = (sourceWidth - cropWidth) / 2;
  const cropY = (sourceHeight - cropHeight) / 2;

  // The encode ladder shrinks from here anyway; this only stops a 4K webcam
  // painting megapixels nobody will send.
  const scale = Math.min(1, 1920 / cropHeight);
  const canvas = document.createElement("canvas");
  canvas.width = Math.round(cropWidth * scale);
  canvas.height = Math.round(cropHeight * scale);
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
  context.drawImage(video, cropX, cropY, cropWidth, cropHeight, 0, 0, canvas.width, canvas.height);
  return new Promise((resolve) => canvas.toBlob((blob) => resolve(blob), "image/png"));
}
