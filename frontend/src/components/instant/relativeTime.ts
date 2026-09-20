// How long ago something happened, in the two words a list row has space for.
//
// The Swift original is `ios/Instant/Core/RelativeTime.swift` and this agrees
// with it phrase for phrase, because the same conversation looked at on a phone
// and on a laptop saying two different things about the same photo is exactly
// the kind of difference nobody can explain afterwards.
//
// `Intl.RelativeTimeFormat` is the obvious tool and is wrong at the end that
// matters: it has no idea that four seconds ago should read as "just now", and
// the freshest receipt is the one anybody actually reads. Units are floored
// rather than rounded, so the phrase is never ahead of the clock.

type Unit =
  | { kind: "justNow" }
  | { kind: "minutes"; value: number }
  | { kind: "hours"; value: number }
  | { kind: "days"; value: number };

function unitSince(date: Date, now: Date): Unit {
  // A clock that disagrees with the server's by a few seconds must not produce
  // a receipt from the future.
  const seconds = Math.max(0, Math.floor((now.getTime() - date.getTime()) / 1000));
  if (seconds < 60) {
    return { kind: "justNow" };
  }
  if (seconds < 3600) {
    return { kind: "minutes", value: Math.floor(seconds / 60) };
  }
  if (seconds < 86_400) {
    return { kind: "hours", value: Math.floor(seconds / 3600) };
  }
  return { kind: "days", value: Math.floor(seconds / 86_400) };
}

/// For the screen: "just now", "3m ago", "5h ago", "2d ago".
export function relativeShort(date: Date, now: Date = new Date()): string {
  const unit = unitSince(date, now);
  switch (unit.kind) {
    case "justNow":
      return "just now";
    case "minutes":
      return `${unit.value}m ago`;
    case "hours":
      return `${unit.value}h ago`;
    case "days":
      return `${unit.value}d ago`;
  }
}

/// For screen readers, which read "3m ago" as a letter rather than a duration.
export function relativeSpoken(date: Date, now: Date = new Date()): string {
  const unit = unitSince(date, now);
  switch (unit.kind) {
    case "justNow":
      return "just now";
    case "minutes":
      return `${unit.value} minute${unit.value === 1 ? "" : "s"} ago`;
    case "hours":
      return `${unit.value} hour${unit.value === 1 ? "" : "s"} ago`;
    case "days":
      return `${unit.value} day${unit.value === 1 ? "" : "s"} ago`;
  }
}
