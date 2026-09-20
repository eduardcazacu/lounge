// The seven looks offered on the compose screen.
//
// The iOS side is `ios/Instant/Core/Media/PhotoFilter.swift`, where each look is
// a Core Image chain. These are the same seven looks by the same names and the
// same intent — vibrance before saturation for vivid, a fixed per-channel gain
// for warm and cool, a lifted-blacks curve for fade — but the arithmetic cannot
// be identical, because `CIPhotoEffectMono` and friends are proprietary curves
// with no published definition.
//
// That is allowed, and it is worth being clear about why: the look is burned
// into the pixels before the photo is sealed, so what travels is an image, not
// a filter name. Two clients that render "warm" a shade apart produce two
// slightly different photos and nothing downstream can tell or care. What must
// not differ is which looks exist and what they are called — that is the part
// somebody would notice moving between their phone and their laptop.

export type FilterId = "none" | "vivid" | "warm" | "cool" | "fade" | "mono" | "noir";

export const FILTERS: { id: FilterId; name: string }[] = [
  { id: "none", name: "Original" },
  { id: "vivid", name: "Vivid" },
  { id: "warm", name: "Warm" },
  { id: "cool", name: "Cool" },
  { id: "fade", name: "Fade" },
  { id: "mono", name: "Mono" },
  { id: "noir", name: "Noir" },
];

export function filterName(id: FilterId): string {
  return FILTERS.find((filter) => filter.id === id)?.name ?? "Original";
}

/// Rec. 709, the weights Core Image's colour controls use.
function luminance(r: number, g: number, b: number): number {
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function clamp255(value: number): number {
  return value < 0 ? 0 : value > 255 ? 255 : value;
}

type Recipe = (pixels: Uint8ClampedArray) => void;

/// Saturation blends toward luminance, contrast pivots about mid-grey, and
/// brightness is added — the shape of `CIColorControls`.
function colorControls(saturation: number, contrast: number, brightness: number): Recipe {
  const offset = brightness * 255;
  return (pixels) => {
    for (let index = 0; index < pixels.length; index += 4) {
      const r = pixels[index];
      const g = pixels[index + 1];
      const b = pixels[index + 2];
      const lum = luminance(r, g, b);
      pixels[index] = clamp255((lum + (r - lum) * saturation - 128) * contrast + 128 + offset);
      pixels[index + 1] = clamp255((lum + (g - lum) * saturation - 128) * contrast + 128 + offset);
      pixels[index + 2] = clamp255((lum + (b - lum) * saturation - 128) * contrast + 128 + offset);
    }
  };
}

/// Warm and cool as a fixed per-channel gain rather than a temperature shift.
/// The temperature filter is defined against a white point the photo is assumed
/// to have, which is a guess about the scene; a multiply means "warm" is the
/// same thing in every photo.
function channelScaled(red: number, green: number, blue: number): Recipe {
  return (pixels) => {
    for (let index = 0; index < pixels.length; index += 4) {
      pixels[index] = clamp255(pixels[index] * red);
      pixels[index + 1] = clamp255(pixels[index + 1] * green);
      pixels[index + 2] = clamp255(pixels[index + 2] * blue);
    }
  };
}

/// Vibrance leaves already-saturated colour alone, so skin does not go orange
/// on the way to a brighter sky — which is why vivid runs it before it touches
/// saturation at all.
function vibrance(amount: number): Recipe {
  return (pixels) => {
    for (let index = 0; index < pixels.length; index += 4) {
      const r = pixels[index];
      const g = pixels[index + 1];
      const b = pixels[index + 2];
      const spread = (Math.max(r, g, b) - Math.min(r, g, b)) / 255;
      const boost = 1 + amount * (1 - spread);
      const lum = luminance(r, g, b);
      pixels[index] = clamp255(lum + (r - lum) * boost);
      pixels[index + 1] = clamp255(lum + (g - lum) * boost);
      pixels[index + 2] = clamp255(lum + (b - lum) * boost);
    }
  };
}

/// Grey, with a tone curve: mono is flat and photographic, noir is the same
/// grey pushed hard — which is the difference between the two Core Image
/// effects of those names.
function monochrome(contrast: number, brightness: number): Recipe {
  return (pixels) => {
    for (let index = 0; index < pixels.length; index += 4) {
      const grey = clamp255(
        (luminance(pixels[index], pixels[index + 1], pixels[index + 2]) - 128) * contrast +
          128 +
          brightness * 255
      );
      pixels[index] = grey;
      pixels[index + 1] = grey;
      pixels[index + 2] = grey;
    }
  };
}

const RECIPES: Record<FilterId, Recipe[]> = {
  none: [],
  vivid: [vibrance(0.6), colorControls(1.08, 1.1, 0)],
  warm: [channelScaled(1.08, 1.01, 0.9)],
  cool: [channelScaled(0.92, 1, 1.09)],
  fade: [colorControls(0.78, 0.88, 0.05)],
  mono: [monochrome(1, 0)],
  noir: [monochrome(1.35, -0.02)],
};

/// The photo with this look baked in, at exactly the size it came in at.
///
/// Same pixels in, same pixels out, so the result can be swapped in for the
/// original anywhere it was already being laid out. Nothing here measures the
/// image either, which is what makes a thumbnail in the strip and the frame
/// that goes on the wire one transform at two resolutions rather than two
/// approximations of one look.
export function applyFilter(
  source: CanvasImageSource,
  width: number,
  height: number,
  id: FilterId
): HTMLCanvasElement {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext("2d", { willReadFrequently: true });
  if (!context) {
    throw new Error("Canvas is unavailable in this browser.");
  }
  context.drawImage(source, 0, 0, width, height);

  const recipes = RECIPES[id];
  if (recipes.length === 0) {
    return canvas;
  }
  const frame = context.getImageData(0, 0, width, height);
  for (const recipe of recipes) {
    recipe(frame.data);
  }
  context.putImageData(frame, 0, 0);
  return canvas;
}
