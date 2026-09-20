// The look, ported from `ios/Shared/Theme.swift`.
//
// Instant does not look like the rest of the Lounge and should not: it is a
// black, full-bleed, camera-first surface, and the iOS app is where that shape
// was worked out. Holding the two to the same numbers is what stops the web
// client reading as a different product with the same name.

export const INSTANT_COLORS = {
  background: "#000000",
  surface: "#171717",
  surfaceRaised: "#262626",
  primaryText: "#ffffff",
  secondaryText: "#9e9e9e",
  unread: "#F43F5E",
  flame: "#F59E0B",
} as const;

/// The camera viewport and the compose preview are the same rectangle, and it
/// is the same shape as the photo that comes out of it: 16:9, standing up.
/// Framing and reviewing a shot on differently shaped surfaces means the sender
/// never quite knows what they took.
export const VIEWPORT_ASPECT = "9 / 16";

/// Enough to read as a card against the black, not so much that it reads as a
/// widget.
export const VIEWPORT_RADIUS = 22;

/// How far the controls sit inside the viewport's edge. Clear of the corner
/// radius, and clear of the photo's own edge.
export const VIEWPORT_INSET = 16;

/// Where the viewport lands: as wide as the window until 16:9 would run off the
/// bottom, then as tall as the window, centred either way.
///
/// This is the whole of what makes the desktop case work. On a phone the width
/// wins and the app is full-bleed; on a laptop the height wins and the same
/// layout becomes a phone-shaped card on black, with every control still inside
/// the frame it belongs to. `dvh` rather than `vh` because mobile browser chrome
/// slides in and out, and a viewport measured against the taller of the two
/// puts the shutter under the address bar.
export const viewportSizing = {
  width: `min(100vw, calc(100dvh * 9 / 16))`,
  height: `min(100dvh, calc(100vw * 16 / 9))`,
  /// The black band above the viewport, which is everything left over when the
  /// window is taller than 16:9 — a phone, usually — and zero when it is not.
  ///
  /// Anything positioned against the *window* rather than against the viewport
  /// needs this, or it lands on a different line from the controls inside the
  /// frame. That is the whole of what keeps the inbox's header level with the
  /// account button pinned over it.
  topBand: `max(0px, (100dvh - min(100dvh, 100vw * 16 / 9)) / 2)`,
} as const;

/// Where the viewport's top line is, plus the inset the controls sit at — the
/// line the account button, the camera's tools and the inbox's header all share.
export const viewportTopLine = `calc(${viewportSizing.topBand} + ${VIEWPORT_INSET}px)`;

/// Tailwind cannot express the above, and the controls are positioned from the
/// viewport rather than from the window — on a tall phone the window's margins
/// are the black band outside the photo, which is not where a control for the
/// photo belongs.
export const viewportStyle: React.CSSProperties = {
  width: viewportSizing.width,
  height: viewportSizing.height,
  borderRadius: VIEWPORT_RADIUS,
};
