// Burns the drawing and the captions into the pixels.
//
// The port of `ios/Instant/Core/Media/OverlayCompositor.swift`, and it has to
// stay one: neither the text nor the line is a field on the wire, so a client
// that placed them differently would produce a visibly different photo from the
// same input, with nothing to compare against afterwards. See
// wiki/parallel-implementations.md.
//
// Everything here is in fractions of the image, never pixels of the screen, so
// the preview and the full-resolution render are one transform at two sizes.

export type Placement = { x: number; y: number };

export type CaptionStyle = "bar" | "plate";

export type Caption = {
  id: string;
  text: string;
  style: CaptionStyle;
  placement: Placement;
  /// Scale and rotation apply to the plate only. A bar is a band across the
  /// photo, and a band that grew or tilted would stop being one. Both are kept
  /// while a caption is a bar, so switching back restores them.
  scale: number;
  /// Radians, clockwise, about the caption's centre.
  rotation: number;
};

export const MAX_CAPTION_LENGTH = 80;

export const DEFAULT_PLACEMENT: Placement = { x: 0.5, y: 0.85 };

/// Clamped so a caption cannot be dragged off the image.
export function clampPlacement(value: number): number {
  return Math.min(0.95, Math.max(0.05, value));
}

export function placement(x: number, y: number): Placement {
  return { x: clampPlacement(x), y: clampPlacement(y) };
}

/// Small enough to stay legible, large enough that a caption can fill most of
/// the photo's width in a few words.
export const SCALE_RANGE = { min: 0.5, max: 3 } as const;

export function clampScale(scale: number): number {
  return Math.min(SCALE_RANGE.max, Math.max(SCALE_RANGE.min, scale));
}

/// How close to square a turned caption has to come to be set exactly square.
/// Two fingers cannot let go at precisely zero, and a caption left a degree off
/// level reads as a mistake rather than a choice.
const ROTATION_SNAP = (5 * Math.PI) / 180;

/// Wraps into -π…π and snaps to the nearest quarter turn when close to it.
export function normalizedRotation(radians: number): number {
  let angle = radians % (2 * Math.PI);
  if (angle > Math.PI) {
    angle -= 2 * Math.PI;
  }
  if (angle < -Math.PI) {
    angle += 2 * Math.PI;
  }
  const quarter = Math.PI / 2;
  const square = Math.round(angle / quarter) * quarter;
  return Math.abs(angle - square) <= ROTATION_SNAP ? square : angle;
}

/// What actually gets drawn: capped, and with nothing to draw when blank.
export function trimmedText(caption: Caption): string {
  return caption.text.slice(0, MAX_CAPTION_LENGTH).trim();
}

/// A bar is always drawn level.
export function drawnRotation(caption: Caption): number {
  return caption.style === "plate" ? caption.rotation : 0;
}

// --- the pen ---------------------------------------------------------------

/// A fixed handful rather than a picker: a finger on a photo wants a few loud,
/// distinct colours, not a spectrum. The values are the iOS `Ink` cases.
export const INKS = [
  { id: "white", color: "rgb(255, 255, 255)" },
  { id: "black", color: "rgb(0, 0, 0)" },
  { id: "red", color: "rgb(255, 59, 48)" },
  { id: "orange", color: "rgb(255, 148, 0)" },
  { id: "yellow", color: "rgb(255, 214, 10)" },
  { id: "green", color: "rgb(51, 214, 74)" },
  { id: "blue", color: "rgb(10, 132, 255)" },
  { id: "purple", color: "rgb(176, 82, 222)" },
  { id: "pink", color: "rgb(255, 56, 158)" },
] as const;

export type InkId = (typeof INKS)[number]["id"];

export function inkColor(id: InkId): string {
  return INKS.find((ink) => ink.id === id)?.color ?? INKS[0].color;
}

/// One touch of the pen, from pointer down to pointer up. Points are fractions
/// of the photo and deliberately unclamped: a line may run off the edge, and
/// whatever is off it is simply not drawn.
export type Stroke = {
  id: string;
  ink: InkId;
  points: { x: number; y: number }[];
};

/// Fixed, and a fraction of the photo's width rather than of the screen, so a
/// line is the same share of the picture at any capture resolution.
export function strokeWidth(width: number): number {
  return width * 0.015;
}

/// The line through a stroke's points, at `size`. The compose screen strokes
/// this same path over the preview, which is what keeps it honest.
///
/// Curved through the midpoints between samples, with each sample as the
/// control point. Joined straight, a pointer sampled sixty to a hundred and
/// twenty times a second draws a visible corner at every sample.
export function strokePath(stroke: Stroke, width: number, height: number): Path2D {
  const points = stroke.points.map((point) => ({ x: point.x * width, y: point.y * height }));
  const path = new Path2D();
  const first = points[0];
  const last = points[points.length - 1];
  if (!first || !last) {
    return path;
  }
  path.moveTo(first.x, first.y);
  // A tap is a stroke of one point; a round cap on a line of no length is a dot.
  if (points.length === 1) {
    path.lineTo(first.x, first.y);
    return path;
  }
  for (let index = 1; index < points.length; index += 1) {
    const previous = points[index - 1];
    const current = points[index];
    path.quadraticCurveTo(
      previous.x,
      previous.y,
      (previous.x + current.x) / 2,
      (previous.y + current.y) / 2
    );
  }
  path.lineTo(last.x, last.y);
  return path;
}

// --- measuring -------------------------------------------------------------

export type Metrics = {
  fontSize: number;
  horizontalPadding: number;
  verticalPadding: number;
  cornerRadius: number;
  /// Where the text wraps. The plate is held inside 90% of the photo at any
  /// scale, so a larger caption breaks into more lines rather than running off
  /// the edge.
  maxTextWidth: number;
  lineHeight: number;
};

/// Scales with the image width, not the screen, so the caption occupies the
/// same fraction of the photo at any capture resolution.
export function captionFontSize(width: number): number {
  return Math.round(width * 0.06);
}

/// The system stack, matching what the iOS side draws with. Weight 600 is
/// `.semibold`.
export function fontString(metrics: Metrics): string {
  return `600 ${metrics.fontSize}px system-ui, -apple-system, "Segoe UI", sans-serif`;
}

/// A caption's box, in the units of whatever width it was asked for — the
/// photo's pixels when burning in, the preview's CSS pixels on screen. Both
/// read this, and that is the whole of what keeps the preview honest.
export function metricsFor(style: CaptionStyle, scale: number, width: number): Metrics {
  if (style === "bar") {
    const fontSize = width * 0.05;
    const horizontal = fontSize * 0.8;
    return {
      fontSize,
      horizontalPadding: horizontal,
      verticalPadding: fontSize * 0.4,
      cornerRadius: 0,
      maxTextWidth: Math.max(fontSize, width - horizontal * 2),
      lineHeight: fontSize * LINE_HEIGHT_RATIO,
    };
  }
  const fontSize = captionFontSize(width) * clampScale(scale);
  const padding = fontSize * 0.4;
  return {
    fontSize,
    horizontalPadding: padding,
    verticalPadding: padding,
    cornerRadius: padding * 0.75,
    maxTextWidth: Math.max(fontSize, width * 0.9 - padding * 2),
    lineHeight: fontSize * LINE_HEIGHT_RATIO,
  };
}

/// What `usesFontLeading` comes to for the system font. It is an approximation
/// of the iOS line box, and it does not need to be more than that: the preview
/// and the burn-in on *this* client both read it, which is what decides whether
/// the lines break where the sender saw them break.
const LINE_HEIGHT_RATIO = 1.2;

let measuringContext: CanvasRenderingContext2D | null = null;

function measurer(): CanvasRenderingContext2D | null {
  if (measuringContext) {
    return measuringContext;
  }
  measuringContext = document.createElement("canvas").getContext("2d");
  return measuringContext;
}

/// The lines a caption breaks into, greedily by word — and the single source of
/// that answer. The preview renders exactly these lines rather than letting the
/// browser wrap the text itself, so there is no second wrapping implementation
/// to drift from this one.
export function wrapLines(text: string, metrics: Metrics): string[] {
  const context = measurer();
  if (!context || !text) {
    return text ? [text] : [];
  }
  context.font = fontString(metrics);
  const lines: string[] = [];
  for (const paragraph of text.split("\n")) {
    let line = "";
    for (const word of paragraph.split(" ")) {
      const candidate = line ? `${line} ${word}` : word;
      if (line && context.measureText(candidate).width > metrics.maxTextWidth) {
        lines.push(line);
        line = word;
      } else {
        line = candidate;
      }
    }
    lines.push(line);
  }
  return lines;
}

/// The text's own box once wrapped — no padding.
export function textSize(text: string, metrics: Metrics): { width: number; height: number } {
  const context = measurer();
  const lines = wrapLines(text, metrics);
  if (!context || lines.length === 0) {
    return { width: 0, height: 0 };
  }
  context.font = fontString(metrics);
  const width = Math.ceil(
    lines.reduce((widest, line) => Math.max(widest, context.measureText(line).width), 0)
  );
  return { width, height: Math.ceil(lines.length * metrics.lineHeight) };
}

/// The width a caption's backing is drawn at — **padding included**, so it is
/// the box rather than the text inside it.
///
/// The bar is the whole photo and the plate hugs its text, held inside 90% of
/// the photo at any scale. All three places that draw a caption read this: the
/// preview, the editor and the burn-in. They used to compute it separately, and
/// the editor's was short by its own padding on each side — a gap down both
/// sides of a band that is supposed to span the photo.
export function captionBoxWidth(
  style: CaptionStyle,
  metrics: Metrics,
  textWidth: number,
  photoWidth: number,
  /// Room for the caret at the end of a full line. Only the editor has one.
  caretSlack = 0
): number {
  if (style === "bar") {
    return photoWidth;
  }
  return (
    Math.min(metrics.maxTextWidth, textWidth + caretSlack) + metrics.horizontalPadding * 2
  );
}

/// `rgba(15, 23, 42, 0.55)` — slate-900 at 55% — and black at 55% for the band.
export function backingColor(style: CaptionStyle): string {
  return style === "bar" ? "rgba(0, 0, 0, 0.55)" : "rgba(15, 23, 42, 0.55)";
}

// --- burning in ------------------------------------------------------------

/// The photo with the drawing and the captions in its pixels.
///
/// The drawing lies **under** the captions, as it does on screen, so a scribble
/// cannot make text unreadable.
export function composite(
  source: CanvasImageSource,
  width: number,
  height: number,
  strokes: Stroke[],
  captions: Caption[]
): HTMLCanvasElement {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext("2d");
  if (!context) {
    throw new Error("Canvas is unavailable in this browser.");
  }
  context.drawImage(source, 0, 0, width, height);

  const lines = strokes.filter((stroke) => stroke.points.length > 0);
  if (lines.length > 0) {
    context.save();
    context.lineWidth = strokeWidth(width);
    context.lineCap = "round";
    context.lineJoin = "round";
    for (const stroke of lines) {
      context.strokeStyle = inkColor(stroke.ink);
      context.stroke(strokePath(stroke, width, height));
    }
    context.restore();
  }

  // In order, so a later caption lands on top — as it does on the compose
  // screen.
  for (const caption of captions) {
    const text = trimmedText(caption);
    if (text) {
      drawCaption(context, caption, text, width, height);
    }
  }
  return canvas;
}

function drawCaption(
  context: CanvasRenderingContext2D,
  caption: Caption,
  text: string,
  width: number,
  height: number
) {
  const metrics = metricsFor(caption.style, caption.scale, width);
  const lines = wrapLines(text, metrics);
  const size = textSize(text, metrics);

  const centerX = caption.style === "bar" ? width / 2 : width * caption.placement.x;
  const centerY = height * caption.placement.y;
  const backingWidth = captionBoxWidth(caption.style, metrics, size.width, width);

  context.save();
  // Turned about its own centre, the way the preview turns it.
  context.translate(centerX, centerY);
  context.rotate(drawnRotation(caption));
  context.translate(-centerX, -centerY);

  context.fillStyle = backingColor(caption.style);
  const box = {
    x: centerX - backingWidth / 2,
    y: centerY - size.height / 2 - metrics.verticalPadding,
    width: backingWidth,
    height: size.height + metrics.verticalPadding * 2,
  };
  context.beginPath();
  context.roundRect(box.x, box.y, box.width, box.height, metrics.cornerRadius);
  context.fill();

  context.fillStyle = "#ffffff";
  context.font = fontString(metrics);
  context.textAlign = "center";
  context.textBaseline = "middle";
  lines.forEach((line, index) => {
    const lineCenter =
      centerY - size.height / 2 + metrics.lineHeight * (index + 0.5);
    context.fillText(line, centerX, lineCenter);
  });
  context.restore();
}
