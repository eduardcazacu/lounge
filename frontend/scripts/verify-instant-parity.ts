// Checks the Instant rules the web client now shares with the iOS app.
//
//   cd backend && npx tsx ../frontend/scripts/verify-instant-parity.ts
//
// The two clients draw the same screens from the same numbers, and most of that
// is only checkable by looking at them. This covers the part that is not: the
// pure arithmetic and phrasing that exist twice, where a difference is invisible
// on either client alone and obvious the moment somebody opens both.
//
// Every expectation here is the answer the Swift side gives, taken from
// `ios/InstantTests/MediaAndStoreTests.swift` (`RelativeTimeTests`,
// `SendReceiptTests`) and from `OverlayCompositor`. Nothing that needs a canvas
// is checked — wrapping and measuring need a real font — so this deliberately
// stops at the boundary of what Node can answer.

import { relativeShort, relativeSpoken } from "../src/components/instant/relativeTime";
import { receiptStatus } from "../src/components/instant/sendReceipt";
import {
  captionBoxWidth,
  clampPlacement,
  clampScale,
  captionFontSize,
  metricsFor,
  normalizedRotation,
  strokeWidth,
} from "../src/components/instant/overlay";
import { FILTERS } from "../src/components/instant/filters";

let checks = 0;
let failures = 0;
function check(label: string, ok: boolean, detail?: unknown) {
  checks += 1;
  if (ok) {
    console.log(`  ok   ${label}`);
  } else {
    failures += 1;
    console.log(`  FAIL ${label}${detail === undefined ? "" : ` -> ${JSON.stringify(detail)}`}`);
  }
}

const now = new Date("2026-09-20T12:00:00.000Z");
const ago = (seconds: number) => new Date(now.getTime() - seconds * 1000);

console.log("\nrelative time");
{
  // The one `Intl.RelativeTimeFormat` spells worst and the one most often read.
  check("under a minute is just now", relativeShort(ago(4), now) === "just now");
  check("and still is at 59 seconds", relativeShort(ago(59), now) === "just now");
  check("a minute is 1m ago", relativeShort(ago(60), now) === "1m ago");
  check("units floor rather than round", relativeShort(ago(119), now) === "1m ago");
  check("59 minutes stays in minutes", relativeShort(ago(3599), now) === "59m ago");
  check("an hour becomes hours", relativeShort(ago(3600), now) === "1h ago");
  check("23 hours stays in hours", relativeShort(ago(86_399), now) === "23h ago");
  check("a day becomes days", relativeShort(ago(86_400), now) === "1d ago");
  check("a future time reads as just now", relativeShort(ago(-60), now) === "just now");
  check("the spoken form spells the unit", relativeSpoken(ago(180), now) === "3 minutes ago");
  check("and singularises one of them", relativeSpoken(ago(3600), now) === "1 hour ago");
  check("and says days", relativeSpoken(ago(172_800), now) === "2 days ago");
}

console.log("\nsend receipts");
{
  const sentAt = ago(600);
  const receipt = (openedAt: Date | null, expiresAt: Date) => ({
    sentAt: sentAt.toISOString(),
    openedAt: openedAt ? openedAt.toISOString() : null,
    expiresAt: expiresAt.toISOString(),
  });
  const alive = new Date(sentAt.getTime() + 24 * 3_600_000);

  const waiting = receiptStatus(receipt(null, alive), now);
  check("a photo nobody has opened reports when it went", waiting?.kind === "waiting", waiting);
  check(
    "dated from the send",
    waiting?.kind === "waiting" && waiting.since.getTime() === sentAt.getTime()
  );

  const opened = receiptStatus(receipt(ago(300), alive), now);
  check("an opened one reports when it was taken", opened?.kind === "opened", opened);
  check(
    "not when it was sent",
    opened?.kind === "opened" && opened.at.getTime() === ago(300).getTime()
  );

  const expired = receiptStatus(receipt(null, ago(60)), now);
  check("one that ran out says nobody opened it", expired?.kind === "expiredUnopened", expired);

  const openedLongAgo = receiptStatus(receipt(ago(500), ago(60)), now);
  check("an opened one outlives the photo's expiry", openedLongAgo?.kind === "opened");

  const stale = {
    sentAt: ago(49 * 3600).toISOString(),
    openedAt: null,
    expiresAt: ago(25 * 3600).toISOString(),
  };
  check("past the window there is nothing to say", receiptStatus(stale, now) === null);
  check("and nothing to say about nothing", receiptStatus(null, now) === null);
}

console.log("\noverlay geometry");
{
  check("a placement is clamped inside the photo", clampPlacement(1.4) === 0.95);
  check("at both ends", clampPlacement(-2) === 0.05);
  check("a scale is clamped to the range", clampScale(9) === 3 && clampScale(0.1) === 0.5);
  check("a caption's font is 6% of the photo", captionFontSize(1000) === 60);
  check("a line is 1.5% of it", strokeWidth(1000) === 15);

  // Two fingers cannot let go at precisely zero, so a turn that ends within 5°
  // of square is set exactly there.
  const degrees = (value: number) => (value * Math.PI) / 180;
  check("a turn within 5° of level is set level", normalizedRotation(degrees(3)) === 0);
  check(
    "and within 5° of a quarter turn is set square",
    Math.abs(normalizedRotation(degrees(88)) - Math.PI / 2) < 1e-9
  );
  check("a deliberate angle is left alone", Math.abs(normalizedRotation(degrees(30)) - degrees(30)) < 1e-9);
  check("and it wraps into -π…π", Math.abs(normalizedRotation(degrees(200)) - degrees(-160)) < 1e-9);

  // The bar spans the photo; the plate hugs its text inside 90% of it.
  const bar = metricsFor("bar", 1, 1000);
  const plate = metricsFor("plate", 1, 1000);
  check("the bar has no corner radius", bar.cornerRadius === 0);
  check("and wraps within the photo's width", bar.maxTextWidth === 1000 - bar.horizontalPadding * 2);
  check("the plate is rounded", plate.cornerRadius > 0);
  check("and wraps within 90% of the photo", plate.maxTextWidth === 900 - plate.horizontalPadding * 2);
  check(
    "a scaled plate wraps within 90% too, so it breaks into more lines",
    metricsFor("plate", 2, 1000).maxTextWidth < 900
  );
}

console.log("\nthe caption box");
{
  // The width a caption is *drawn* at, padding included. Read by the preview,
  // the editor and the burn-in, which is the point: the editor used to work it
  // out for itself and came up short by its own padding on each side.
  const photo = 400;
  const bar = metricsFor("bar", 1, photo);
  const plate = metricsFor("plate", 1, photo);

  check("a bar spans the photo", captionBoxWidth("bar", bar, 10, photo) === photo);
  check(
    "however long the text is",
    captionBoxWidth("bar", bar, 100_000, photo) === photo
  );
  check(
    "and its text wraps inside the padding",
    photo - bar.horizontalPadding * 2 === bar.maxTextWidth
  );

  check(
    "a plate hugs its text",
    captionBoxWidth("plate", plate, 100, photo) === 100 + plate.horizontalPadding * 2
  );
  check(
    "and stops at 90% of the photo",
    Math.abs(captionBoxWidth("plate", plate, 100_000, photo) - photo * 0.9) < 1e-9,
    captionBoxWidth("plate", plate, 100_000, photo)
  );
  check(
    "the editor's caret slack is inside that cap",
    captionBoxWidth("plate", plate, 100_000, photo, plate.fontSize * 0.2) ===
      captionBoxWidth("plate", plate, 100_000, photo)
  );
}

console.log("\nthe looks");
{
  // Same seven, same names, same order as `PhotoFilter.allCases`.
  check(
    "seven looks, in the iOS order",
    FILTERS.map((filter) => filter.id).join(",") === "none,vivid,warm,cool,fade,mono,noir",
    FILTERS.map((filter) => filter.id)
  );
  check(
    "named as they are on the phone",
    FILTERS.map((filter) => filter.name).join(",") ===
      "Original,Vivid,Warm,Cool,Fade,Mono,Noir",
    FILTERS.map((filter) => filter.name)
  );
}

console.log(`\n${checks - failures}/${checks} checks passed\n`);
process.exit(failures === 0 ? 0 : 1);
