import { useEffect, useState } from "react";
import type { ReactNode } from "react";
import { createPortal } from "react-dom";
import { useNavigate } from "react-router-dom";
import { Avatar } from "../BlogCard";
import { getThemePalette } from "../../themes";
import { getTransformedImageUrl } from "../../lib/content";
import type { Item, Person } from "./api";
import { byline, usePalette } from "./format";

// The pieces every /books screen is built from. The look is the Lounge's own —
// white cards on the reader's palette, the accent on whatever is pressable —
// so Books reads as a room of the Lounge rather than a separate product, the
// way Instant deliberately does not (wiki/books.md).

const COVER_SIZES = {
  xs: "h-12 w-8 text-[8px]",
  sm: "h-[72px] w-12 text-[9px]",
  md: "h-24 w-16 text-[10px]",
  lg: "h-40 w-[106px] text-xs",
} as const;

// Twice the drawn width, for sharp covers on a phone's screen.
const COVER_PIXELS = { xs: 64, sm: 96, md: 128, lg: 212 } as const;

/**
 * A cover, or — for a hand-typed book or one Open Library has no picture of —
 * a coloured board with the title on it, so a shelf never shows a hole.
 */
export function Cover({ item, size = "md" }: { item: Pick<Item, "title" | "coverUrl">; size?: keyof typeof COVER_SIZES }) {
  const [failed, setFailed] = useState(false);
  const sizeClass = COVER_SIZES[size];
  if (item.coverUrl && !failed) {
    return (
      <img
        // Covers copied into our bucket are resized by Cloudflare; any other
        // URL comes back unchanged (backend/src/covers.ts).
        src={getTransformedImageUrl(item.coverUrl, { width: COVER_PIXELS[size], fit: "cover", quality: 85 })}
        alt=""
        loading="lazy"
        onError={() => setFailed(true)}
        className={`${sizeClass} shrink-0 rounded-md object-cover shadow-sm ring-1 ring-black/10`}
      />
    );
  }
  // A stable colour per title, from the Lounge's own palettes.
  let hash = 0;
  for (const char of item.title) hash = (hash * 31 + char.charCodeAt(0)) | 0;
  const keys = ["sunset", "purple", "forest", "ocean", "rose", "indigo", "gold", "boring-grey"];
  const palette = getThemePalette(keys[Math.abs(hash) % keys.length]);
  return (
    <div
      className={`${sizeClass} flex shrink-0 items-center justify-center overflow-hidden rounded-md p-1 text-center font-semibold leading-tight shadow-sm ring-1 ring-black/10`}
      style={{ background: palette.postBg, color: palette.text }}
      aria-hidden
    >
      <span className="line-clamp-4 break-words">{item.title}</span>
    </div>
  );
}

function StarGlyph({ fill, size }: { fill: 0 | 0.5 | 1; size: number }) {
  const id = `half-${size}`;
  return (
    <svg viewBox="0 0 24 24" width={size} height={size} aria-hidden className="shrink-0">
      <defs>
        <linearGradient id={id}>
          <stop offset="50%" stopColor="#f59e0b" />
          <stop offset="50%" stopColor="#e2e8f0" />
        </linearGradient>
      </defs>
      <path
        d="M12 2.5l2.9 6.1 6.6.8-4.9 4.6 1.3 6.6L12 17.3l-5.9 3.3 1.3-6.6-4.9-4.6 6.6-.8z"
        fill={fill === 1 ? "#f59e0b" : fill === 0.5 ? `url(#${id})` : "#e2e8f0"}
      />
    </svg>
  );
}

/** A rating of 1..10 half stars, drawn as five. */
export function Stars({ rating, size = 14 }: { rating: number | null; size?: number }) {
  if (rating === null) return null;
  return (
    <span className="inline-flex items-center" aria-label={`${rating / 2} out of 5 stars`}>
      {[1, 2, 3, 4, 5].map((star) => {
        const halves = rating - (star - 1) * 2;
        return <StarGlyph key={star} size={size} fill={halves >= 2 ? 1 : halves === 1 ? 0.5 : 0} />;
      })}
    </span>
  );
}

/**
 * Five stars, each two buttons: the left half for the half star. Tapping the
 * rating that is already set clears it, because every part of a review is
 * optional and there has to be a way back to "no rating".
 */
export function StarInput({ value, onChange }: { value: number | null; onChange: (value: number | null) => void }) {
  const size = 40;
  return (
    <div className="flex items-center gap-1" role="radiogroup" aria-label="Rating">
      {[1, 2, 3, 4, 5].map((star) => {
        const halves = (value ?? 0) - (star - 1) * 2;
        return (
          <span key={star} className="relative inline-flex">
            <StarGlyph size={size} fill={halves >= 2 ? 1 : halves === 1 ? 0.5 : 0} />
            {[star * 2 - 1, star * 2].map((rating, index) => (
              <button
                key={rating}
                type="button"
                role="radio"
                aria-checked={value === rating}
                aria-label={`${rating / 2} stars`}
                onClick={() => onChange(value === rating ? null : rating)}
                className={`absolute inset-y-0 ${index === 0 ? "left-0" : "right-0"} w-1/2`}
              />
            ))}
          </span>
        );
      })}
    </div>
  );
}

/**
 * A bottom sheet on a phone, a centred card on a wide window. Portalled to the
 * body: a sheet opened from inside the sticky header would otherwise be
 * positioned against the header, because its backdrop-filter makes it the
 * containing block for anything `fixed` inside it.
 */
export function Sheet({
  title,
  onClose,
  children,
  footer,
}: {
  title: string;
  onClose: () => void;
  children: ReactNode;
  footer?: ReactNode;
}) {
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    const previous = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      window.removeEventListener("keydown", onKey);
      document.body.style.overflow = previous;
    };
  }, [onClose]);

  return createPortal(
    <div className="fixed inset-0 z-50 flex items-end justify-center sm:items-center" role="dialog" aria-modal aria-label={title}>
      <button type="button" aria-label="Close" onClick={onClose} className="absolute inset-0 bg-slate-900/40" />
      <div
        className="relative flex max-h-[90dvh] w-full max-w-xl flex-col rounded-t-3xl bg-white shadow-xl sm:rounded-3xl"
        style={{ paddingBottom: "env(safe-area-inset-bottom)" }}
      >
        <div className="flex items-center justify-between px-5 pb-2 pt-4">
          <h2 className="text-lg font-semibold text-slate-900">{title}</h2>
          <button type="button" onClick={onClose} className="rounded-full px-3 py-1 text-sm font-medium text-slate-500 hover:bg-slate-100">
            Close
          </button>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto px-5 pb-2">{children}</div>
        {footer ? <div className="px-5 pb-5 pt-3">{footer}</div> : <div className="pb-4" />}
      </div>
    </div>,
    document.body
  );
}

export function ProgressBar({ fraction, color }: { fraction: number | null; color: string }) {
  return (
    <div className="h-1.5 w-full overflow-hidden rounded-full bg-slate-200">
      <div
        className="h-full rounded-full transition-[width] duration-500"
        style={{ width: `${Math.round((fraction ?? 0) * 100)}%`, background: color }}
      />
    </div>
  );
}

/**
 * The bar across the top of every screen but home. Back goes back when there
 * is somewhere in /books to go back to, and home otherwise — a screen opened
 * from a notification or the Lounge has no history here.
 */
export function TopBar({ title, right, back = true }: { title: ReactNode; right?: ReactNode; back?: boolean }) {
  const navigate = useNavigate();
  const goBack = () => {
    const state = window.history.state as { idx?: number } | null;
    if (state?.idx && state.idx > 0) navigate(-1);
    else navigate("/books");
  };
  return (
    <header
      className="sticky top-0 z-30 border-b border-slate-200/70 bg-white/85 backdrop-blur"
      style={{ paddingTop: "env(safe-area-inset-top)" }}
    >
      <div className="mx-auto flex h-14 max-w-xl items-center gap-2 px-3">
        {back ? (
          <button
            type="button"
            onClick={goBack}
            className="-ml-1 flex h-10 w-10 items-center justify-center rounded-full text-slate-700 hover:bg-slate-100"
            aria-label="Back"
          >
            <svg viewBox="0 0 24 24" className="h-6 w-6" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M15 18l-6-6 6-6" />
            </svg>
          </button>
        ) : null}
        <h1 className="min-w-0 flex-1 truncate text-[17px] font-semibold text-slate-900">{title}</h1>
        {right}
      </div>
    </header>
  );
}

export function PersonLine({ person, suffix }: { person: Person; suffix?: ReactNode }) {
  const palette = getThemePalette(person.themeKey);
  return (
    <span className="inline-flex min-w-0 items-center gap-1.5">
      <Avatar size="small" name={person.name ?? "?"} themeKey={person.themeKey} imageUrl={person.profilePictureUrl} />
      <span className="truncate text-sm font-medium" style={{ color: palette.text }}>
        {person.name ?? "Someone"}
      </span>
      {suffix}
    </span>
  );
}

/**
 * A book's cover, title, author, year, length and genres, at the top of its
 * page. `children` go under the length: the edition line, on your own copy.
 */
export function BookHeader({ item, children }: { item: Item; children?: ReactNode }) {
  const palette = usePalette();
  const pages = item.edition?.totalUnits ?? item.totalUnits;
  return (
    <div className="flex gap-4 pt-5">
      <Cover item={item} size="lg" />
      <div className="min-w-0 flex-1">
        <h2 className="text-xl font-semibold leading-snug">{item.title}</h2>
        <p className="text-[15px] text-slate-600">{byline(item)}</p>
        <p className="mt-1 text-sm text-slate-500">{[item.year, pages ? `${pages} pages` : null].filter(Boolean).join(" · ")}</p>
        {children}
        {item.genres.length ? (
          <div className="mt-2 flex flex-wrap gap-1">
            {item.genres.map((genre) => (
              <span key={genre} className="rounded-full px-2 py-0.5 text-xs" style={{ background: palette.postBg, color: palette.text }}>
                {genre}
              </span>
            ))}
          </div>
        ) : null}
      </div>
    </div>
  );
}

export function Card({ children, className = "", onClick }: { children: ReactNode; className?: string; onClick?: () => void }) {
  return (
    <div
      className={`rounded-2xl border border-slate-200/70 bg-white p-4 shadow-sm ${onClick ? "cursor-pointer transition-shadow hover:shadow-md" : ""} ${className}`}
      onClick={onClick}
      role={onClick ? "button" : undefined}
      tabIndex={onClick ? 0 : undefined}
      onKeyDown={
        onClick
          ? (event) => {
              if (event.key === "Enter") onClick();
            }
          : undefined
      }
    >
      {children}
    </div>
  );
}

export function SectionTitle({ children, action }: { children: ReactNode; action?: ReactNode }) {
  return (
    <div className="mb-2 mt-6 flex items-baseline justify-between px-1">
      <h2 className="text-[13px] font-semibold uppercase tracking-wide text-slate-500">{children}</h2>
      {action}
    </div>
  );
}

export function Spinner() {
  return <div className="py-16 text-center text-sm text-slate-400">Loading…</div>;
}

export function EmptyNote({ children }: { children: ReactNode }) {
  return <p className="rounded-2xl border border-dashed border-slate-300 px-4 py-6 text-center text-sm text-slate-500">{children}</p>;
}

/**
 * In place of a review marked as a spoiler, for a reader who hasn't finished
 * the book. It never stops them: "Show anyway" is one tap. Clicks stay here,
 * because the cover often sits inside a card that opens on click.
 */
export function SpoilerCover({ onShow, what = "This review" }: { onShow: () => void; what?: string }) {
  return (
    <button
      type="button"
      onClick={(event) => {
        event.preventDefault();
        event.stopPropagation();
        onShow();
      }}
      className="mt-3 block w-full rounded-xl border border-dashed border-slate-300 bg-slate-50 px-3 py-2.5 text-left text-sm text-slate-600"
    >
      {what} gives the book away, and you haven't finished it. <span className="font-semibold text-slate-800 underline">Show anyway</span>
    </button>
  );
}

/** A review's text, behind `SpoilerCover` when it is covered for this viewer. */
export function ReviewBody({ review, className }: { review: { body: string | null; covered: boolean }; className: string }) {
  const [shown, setShown] = useState(false);
  if (!review.body) return null;
  if (review.covered && !shown) return <SpoilerCover onShow={() => setShown(true)} />;
  return <p className={className}>{review.body}</p>;
}

/** Marks a spoiler for the people it isn't covered for: the reviewer, and those who've read it. */
export function SpoilerTag() {
  return <span className="rounded bg-amber-50 px-1.5 py-0.5 text-xs font-medium text-amber-800">Spoilers</span>;
}

/** Thumbs up or down, as a recommendation reads in a sentence. */
export function RecommendBadge({ recommend }: { recommend: boolean | null }) {
  if (recommend === null) return null;
  return (
    <span
      className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium ${
        recommend ? "bg-emerald-50 text-emerald-700" : "bg-rose-50 text-rose-700"
      }`}
    >
      {recommend ? "👍 Recommends" : "👎 Doesn't recommend"}
    </span>
  );
}
