import type { ReactNode } from "react";
import { getThemePalette } from "../../themes";
import { IconPerson } from "./icons";
import { INSTANT_COLORS, VIEWPORT_INSET, viewportStyle } from "./style";

// The pieces every Instant screen is built from, ported from
// `ios/Instant/Features/Components.swift`.

/// The rounded 16:9 frame, centred on black.
///
/// Every screen puts its photo in this and its controls inside it, which is
/// what makes the camera and the compose screen read as one surface with
/// different tools on it — and what makes the desktop case fall out for free:
/// the same rectangle, height-limited instead of width-limited.
export function Viewport({
  children,
  className = "",
}: {
  children: ReactNode;
  className?: string;
}) {
  return (
    <div className="pointer-events-none absolute inset-0 flex items-center justify-center">
      <div
        className={`pointer-events-auto relative overflow-hidden ${className}`}
        style={viewportStyle}
      >
        {children}
      </div>
    </div>
  );
}

/// The controls layer: the same rectangle again, inset, with nothing in it
/// catching a tap that was meant for the photo underneath.
export function ViewportOverlay({ children }: { children: ReactNode }) {
  return (
    <div className="pointer-events-none absolute inset-0 flex items-center justify-center">
      <div
        className="pointer-events-none relative flex flex-col"
        style={{ ...viewportStyle, padding: VIEWPORT_INSET }}
      >
        {children}
      </div>
    </div>
  );
}

export function CircleIconButton({
  children,
  onClick,
  isOn = false,
  diameter = 44,
  label,
  disabled = false,
  id,
  preventsBlur = false,
}: {
  children: ReactNode;
  onClick: () => void;
  isOn?: boolean;
  diameter?: number;
  label: string;
  disabled?: boolean;
  id?: string;
  /// For a control that acts on whatever is being typed: the default action of
  /// a mousedown is to move focus, which takes the caret out of the caption
  /// before the click is delivered.
  preventsBlur?: boolean;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      onMouseDown={preventsBlur ? (event) => event.preventDefault() : undefined}
      disabled={disabled}
      aria-label={label}
      aria-pressed={isOn}
      data-testid={id}
      className="pointer-events-auto flex shrink-0 items-center justify-center rounded-full transition disabled:opacity-40"
      style={{
        width: diameter,
        height: diameter,
        color: isOn ? "#000" : "#fff",
        background: isOn ? "#fff" : "rgba(0, 0, 0, 0.35)",
      }}
    >
      {children}
    </button>
  );
}

/// A person, tinted with their Lounge theme when they have no picture.
export function InstantAvatar({
  name,
  themeKey,
  url,
  size = 52,
}: {
  name: string;
  themeKey: string;
  url?: string | null;
  size?: number;
}) {
  const palette = getThemePalette(themeKey);
  const initials = name
    .split(" ")
    .slice(0, 2)
    .map((part) => part.trim()[0])
    .filter(Boolean)
    .join("")
    .toUpperCase();

  return (
    <span
      className="relative flex shrink-0 items-center justify-center overflow-hidden rounded-full bg-cover bg-center"
      style={{
        width: size,
        height: size,
        background: palette.accent,
        boxShadow: `inset 0 0 0 2px ${palette.border}b3`,
      }}
      aria-hidden="true"
    >
      {url ? (
        <img src={url} alt="" draggable={false} className="h-full w-full object-cover" />
      ) : initials ? (
        <span
          className="font-bold text-white"
          style={{ fontSize: size * 0.38, lineHeight: 1 }}
        >
          {initials}
        </span>
      ) : (
        // A name that is not known yet gets a person rather than a character —
        // a lone punctuation mark reads as a glyph that failed to load.
        <IconPerson size={size * 0.46} className="text-white/85" />
      )}
    </span>
  );
}

/// Snapchat shows a flame and a day count; a streak about to lapse is the one
/// thing in the list worth shouting about, so it gets colour.
export function StreakBadge({ count, atRisk }: { count: number; atRisk: boolean }) {
  const color = atRisk ? INSTANT_COLORS.unread : INSTANT_COLORS.flame;
  return (
    <span
      className="flex items-center gap-[3px] rounded-full px-2 py-[3px] text-[13px] font-bold"
      style={{ color, background: `${color}29` }}
      aria-label={atRisk ? `${count} day streak, about to end` : `${count} day streak`}
    >
      <span aria-hidden="true">🔥</span>
      {count}
    </span>
  );
}

/// The ring the viewer counts down with.
export function CountdownRing({ progress, size = 34 }: { progress: number; size?: number }) {
  const radius = size / 2 - 2;
  const circumference = 2 * Math.PI * radius;
  return (
    <svg width={size} height={size} aria-hidden="true" className="-rotate-90">
      <circle
        cx={size / 2}
        cy={size / 2}
        r={radius}
        fill="none"
        stroke="rgba(255,255,255,0.25)"
        strokeWidth={3}
      />
      <circle
        cx={size / 2}
        cy={size / 2}
        r={radius}
        fill="none"
        stroke="#fff"
        strokeWidth={3}
        strokeLinecap="round"
        strokeDasharray={circumference}
        strokeDashoffset={circumference * (1 - Math.max(0, Math.min(1, progress)))}
      />
    </svg>
  );
}

/// A sheet that comes up from the bottom of the viewport, which is where iOS
/// puts the picker, the report form and the settings.
export function InstantSheet({
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
  return (
    <div className="absolute inset-0 z-30 flex items-end justify-center" data-sheet>
      <button
        type="button"
        aria-label="Close"
        onClick={onClose}
        className="absolute inset-0 bg-black/60"
      />
      <div
        className="relative flex max-h-[88%] w-full flex-col rounded-t-3xl"
        style={{ background: INSTANT_COLORS.surface }}
      >
        <div className="flex items-center justify-between px-5 pb-2 pt-4">
          <h2 className="text-[17px] font-bold text-white">{title}</h2>
          <button
            type="button"
            onClick={onClose}
            className="rounded-full px-3 py-1 text-sm font-semibold"
            style={{ color: INSTANT_COLORS.secondaryText }}
          >
            Close
          </button>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto px-5">{children}</div>
        {footer ? <div className="px-5 pb-6 pt-3">{footer}</div> : <div className="pb-4" />}
      </div>
    </div>
  );
}
