import { useEffect, useRef, useState } from "react";
import type { MouseEvent } from "react";
import { createPortal } from "react-dom";
import { getTransformedImageUrl } from "../lib/content";
import type { PostImage } from "../hooks";

// A post's photos: one, or a carousel of up to ten. The frame takes the shape
// of the first photo, held between 4:5 and 16:9, and every photo after it is
// fitted to that frame, so swiping never makes the card jump. A photo with no
// recorded size (one carried over from before carousels) is measured when it
// loads. Swiping is the browser's own scroll snapping, so it feels native on a
// phone with no gesture code; arrows appear on a pointer device.

const TALLEST = 5 / 4;
const WIDEST = 9 / 16;

function frameRatio(image: PostImage | undefined, measured: number | null) {
  const ratio = image?.width && image?.height ? image.height / image.width : measured;
  if (!ratio) return 1;
  return Math.min(TALLEST, Math.max(WIDEST, ratio));
}

export function PostImages({
  images,
  alt,
  mode,
  onOpen,
}: {
  images: PostImage[];
  alt: string;
  /** "crop": filled to the frame, for the feed. "fit": shown whole, for the post. */
  mode: "crop" | "fit";
  /** Called with the photo's index when one is tapped. */
  onOpen?: (index: number) => void;
}) {
  const track = useRef<HTMLDivElement>(null);
  const [index, setIndex] = useState(0);
  const [measured, setMeasured] = useState<number | null>(null);
  const many = images.length > 1;

  useEffect(() => {
    const element = track.current;
    if (!element || !many) return;
    const onScroll = () => setIndex(Math.round(element.scrollLeft / element.clientWidth));
    element.addEventListener("scroll", onScroll, { passive: true });
    return () => element.removeEventListener("scroll", onScroll);
  }, [many]);

  if (images.length === 0) return null;

  const go = (event: MouseEvent, to: number) => {
    // Inside a card that opens the post on click.
    event.stopPropagation();
    const element = track.current;
    if (element) element.scrollTo({ left: to * element.clientWidth, behavior: "smooth" });
  };

  return (
    <div className="group relative mt-2.5 overflow-hidden rounded-lg bg-slate-100">
      <div
        ref={track}
        className="flex snap-x snap-mandatory overflow-x-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
        style={{ aspectRatio: `1 / ${frameRatio(images[0], measured)}` }}
      >
        {images.map((image, position) => (
          <button
            key={image.url ?? position}
            type="button"
            className="h-full w-full shrink-0 snap-center snap-always"
            onClick={(event) => {
              if (!onOpen) return;
              event.stopPropagation();
              onOpen(position);
            }}
            tabIndex={onOpen ? 0 : -1}
            aria-label={many ? `Photo ${position + 1} of ${images.length}` : "Photo"}
          >
            {image.url ? (
              <img
                src={getTransformedImageUrl(image.url, mode === "crop" ? { width: 920, fit: "cover", quality: 90 } : { width: 1280, fit: "contain", quality: 95 })}
                alt={many ? `${alt} (${position + 1} of ${images.length})` : alt}
                loading={position === 0 ? "eager" : "lazy"}
                draggable={false}
                onLoad={(event) => {
                  if (position === 0 && !(image.width && image.height)) {
                    const { naturalWidth, naturalHeight } = event.currentTarget;
                    if (naturalWidth) setMeasured(naturalHeight / naturalWidth);
                  }
                }}
                className={`h-full w-full ${mode === "crop" ? "object-cover" : "object-contain"}`}
              />
            ) : null}
          </button>
        ))}
      </div>
      {many ? (
        <>
          <span className="pointer-events-none absolute right-2 top-2 rounded-full bg-black/55 px-2 py-0.5 text-xs font-medium text-white">
            {index + 1}/{images.length}
          </span>
          <div className="pointer-events-none absolute inset-x-0 bottom-2 flex justify-center gap-1.5">
            {images.map((_, position) => (
              <span
                key={position}
                className={`h-1.5 rounded-full bg-white shadow transition-all ${position === index ? "w-4" : "w-1.5 opacity-60"}`}
              />
            ))}
          </div>
          {index > 0 ? <Arrow side="left" onClick={(event) => go(event, index - 1)} /> : null}
          {index < images.length - 1 ? <Arrow side="right" onClick={(event) => go(event, index + 1)} /> : null}
        </>
      ) : null}
    </div>
  );
}

function Arrow({ side, onClick }: { side: "left" | "right"; onClick: (event: MouseEvent) => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-label={side === "left" ? "Previous photo" : "Next photo"}
      // Only where there is a pointer to hover with: on a phone, swiping is the way.
      className={`absolute top-1/2 hidden h-8 w-8 -translate-y-1/2 items-center justify-center rounded-full bg-white/85 text-slate-800 opacity-0 shadow transition-opacity group-hover:opacity-100 [@media(hover:hover)]:flex ${
        side === "left" ? "left-2" : "right-2"
      }`}
    >
      <svg viewBox="0 0 24 24" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round">
        <path d={side === "left" ? "M15 18l-6-6 6-6" : "M9 6l6 6-6 6"} />
      </svg>
    </button>
  );
}

/** Every photo, full screen and swipeable, from a tap on a post's carousel. */
export function PhotoViewer({ images, start, onClose }: { images: PostImage[]; start: number; onClose: () => void }) {
  const track = useRef<HTMLDivElement>(null);
  const [index, setIndex] = useState(start);

  useEffect(() => {
    const element = track.current;
    if (!element) return;
    element.scrollLeft = start * element.clientWidth;
    const onScroll = () => setIndex(Math.round(element.scrollLeft / element.clientWidth));
    element.addEventListener("scroll", onScroll, { passive: true });
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
      if (event.key === "ArrowRight") element.scrollBy({ left: element.clientWidth, behavior: "smooth" });
      if (event.key === "ArrowLeft") element.scrollBy({ left: -element.clientWidth, behavior: "smooth" });
    };
    window.addEventListener("keydown", onKey);
    const previous = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      element.removeEventListener("scroll", onScroll);
      window.removeEventListener("keydown", onKey);
      document.body.style.overflow = previous;
    };
  }, [start, onClose]);

  return createPortal(
    <div className="fixed inset-0 z-50 bg-black" role="dialog" aria-modal aria-label="Photos">
      <div ref={track} className="flex h-full snap-x snap-mandatory overflow-x-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
        {images.map((image, position) => (
          <div key={image.url ?? position} className="flex h-full w-full shrink-0 snap-center snap-always items-center justify-center">
            {image.url ? (
              <img
                src={getTransformedImageUrl(image.url, { width: 1920, fit: "contain", quality: 95 })}
                alt=""
                className="max-h-full max-w-full object-contain"
              />
            ) : null}
          </div>
        ))}
      </div>
      <div className="absolute inset-x-0 top-0 flex items-center justify-between px-4" style={{ paddingTop: "max(env(safe-area-inset-top), 12px)" }}>
        <span className="text-sm font-medium text-white/80">{images.length > 1 ? `${index + 1} of ${images.length}` : ""}</span>
        <button type="button" onClick={onClose} className="rounded-full bg-white/15 px-3 py-1.5 text-sm font-medium text-white">
          Close
        </button>
      </div>
    </div>,
    document.body
  );
}
