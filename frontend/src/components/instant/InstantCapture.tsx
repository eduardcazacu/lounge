import { useCallback, useEffect, useRef, useState } from "react";

// Camera capture with a file-picker fallback. getUserMedia needs a secure
// context, so plain-HTTP dev and locked-down browsers land on the picker.

type Facing = "user" | "environment";

export function InstantCapture({ onCaptured }: { onCaptured: (image: Blob) => void }) {
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const [facing, setFacing] = useState<Facing>("environment");
  // The real camera aspect ratio. A hard-coded portrait frame would crop a
  // landscape webcam in the preview while shoot() still captured the full
  // sensor frame — you would frame one photo and send a different one.
  const [aspect, setAspect] = useState<number | null>(null);
  const [cameraError, setCameraError] = useState<string | null>(null);
  const [starting, setStarting] = useState(true);

  const stopStream = useCallback(() => {
    streamRef.current?.getTracks().forEach((track) => track.stop());
    streamRef.current = null;
  }, []);

  useEffect(() => {
    let cancelled = false;

    const start = async () => {
      setStarting(true);
      stopStream();
      setAspect(null);
      if (!navigator.mediaDevices?.getUserMedia) {
        setCameraError("This browser has no camera access here. Pick a photo instead.");
        setStarting(false);
        return;
      }
      try {
        const stream = await navigator.mediaDevices.getUserMedia({
          video: { facingMode: facing, width: { ideal: 1080 }, height: { ideal: 1920 } },
          audio: false,
        });
        if (cancelled) {
          stream.getTracks().forEach((track) => track.stop());
          return;
        }
        streamRef.current = stream;
        if (videoRef.current) {
          videoRef.current.srcObject = stream;
          await videoRef.current.play().catch(() => undefined);
        }
        setCameraError(null);
      } catch {
        if (!cancelled) {
          setCameraError("Camera unavailable. Pick a photo instead.");
        }
      } finally {
        if (!cancelled) {
          setStarting(false);
        }
      }
    };

    void start();
    return () => {
      cancelled = true;
      stopStream();
    };
  }, [facing, stopStream]);

  const shoot = useCallback(() => {
    const video = videoRef.current;
    if (!video || !video.videoWidth) {
      return;
    }
    const canvas = document.createElement("canvas");
    canvas.width = video.videoWidth;
    canvas.height = video.videoHeight;
    const context = canvas.getContext("2d");
    if (!context) {
      return;
    }
    if (facing === "user") {
      // Mirror the selfie camera so the photo matches the preview.
      context.translate(canvas.width, 0);
      context.scale(-1, 1);
    }
    context.drawImage(video, 0, 0, canvas.width, canvas.height);
    canvas.toBlob((blob) => {
      if (blob) {
        onCaptured(blob);
      }
    }, "image/png");
  }, [facing, onCaptured]);

  return (
    <div className="flex flex-col gap-3">
      <div
        className="relative mx-auto max-h-[60vh] w-full overflow-hidden rounded-2xl bg-slate-900"
        // Falls back to portrait only until the camera reports its real shape.
        style={{ aspectRatio: aspect ?? 9 / 16 }}
      >
        <video
          ref={videoRef}
          playsInline
          muted
          onLoadedMetadata={(event) => {
            const el = event.currentTarget;
            if (el.videoWidth && el.videoHeight) {
              setAspect(el.videoWidth / el.videoHeight);
            }
          }}
          className={`h-full w-full object-contain ${facing === "user" ? "-scale-x-100" : ""}`}
        />
        {(cameraError || starting) && (
          <div className="absolute inset-0 flex items-center justify-center p-6 text-center text-sm text-slate-300">
            {cameraError ?? "Starting camera…"}
          </div>
        )}
      </div>

      <div className="flex items-center justify-between gap-3">
        <button
          type="button"
          onClick={() => setFacing((current) => (current === "user" ? "environment" : "user"))}
          disabled={Boolean(cameraError)}
          className="rounded-full border border-slate-300 px-3 py-2 text-xs font-medium text-slate-700 disabled:opacity-40"
        >
          Flip
        </button>

        <button
          type="button"
          onClick={shoot}
          disabled={Boolean(cameraError) || starting}
          className="h-16 w-16 rounded-full border-4 border-slate-900 bg-white disabled:opacity-40"
          aria-label="Take a photo"
        />

        <label className="cursor-pointer rounded-full border border-slate-300 px-3 py-2 text-xs font-medium text-slate-700">
          Pick
          <input
            type="file"
            accept="image/*"
            capture="environment"
            className="hidden"
            onChange={(event) => {
              const selected = event.target.files?.[0];
              if (selected) {
                onCaptured(selected);
              }
              event.target.value = "";
            }}
          />
        </label>
      </div>
    </div>
  );
}
