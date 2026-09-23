// The eight looks offered on the compose screen, film first — it is the look
// every capture starts in.
//
// The iOS side is `ios/Instant/Core/Media/PhotoFilter.swift`, where each look is
// a Core Image chain. These are the same eight looks by the same names and the
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

export type FilterId =
  | "film"
  | "none"
  | "vivid"
  | "warm"
  | "cool"
  | "fade"
  | "mono"
  | "noir";

export const FILTERS: { id: FilterId; name: string }[] = [
  { id: "film", name: "Film" },
  { id: "none", name: "Original" },
  { id: "vivid", name: "Vivid" },
  { id: "warm", name: "Warm" },
  { id: "cool", name: "Cool" },
  { id: "fade", name: "Fade" },
  { id: "mono", name: "Mono" },
  { id: "noir", name: "Noir" },
];

export function filterName(id: FilterId): string {
  return FILTERS.find((filter) => filter.id === id)?.name ?? "Film";
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

/// A warm portrait negative: blacks lifted off zero the way a negative's toe
/// does, highlights rolled rather than clipped, and a gentle S in between.
/// The phone spells the same curve as five points for `CIToneCurve`; here it
/// is a lookup table, which is the same shape by another name.
function toneCurve(): Recipe {
  const points = [
    [0, 0.05],
    [0.25, 0.262],
    [0.5, 0.513],
    [0.75, 0.772],
    [1, 0.972],
  ];
  const table = new Uint8ClampedArray(256);
  for (let value = 0; value < 256; value += 1) {
    const x = value / 255;
    let segment = 0;
    while (segment < points.length - 2 && x > points[segment + 1][0]) {
      segment += 1;
    }
    const [x0, y0] = points[segment];
    const [x1, y1] = points[segment + 1];
    const t = x1 === x0 ? 0 : (x - x0) / (x1 - x0);
    table[value] = clamp255((y0 + (y1 - y0) * t) * 255);
  }
  return (pixels) => {
    for (let index = 0; index < pixels.length; index += 4) {
      pixels[index] = table[pixels[index]];
      pixels[index + 1] = table[pixels[index + 1]];
      pixels[index + 2] = table[pixels[index + 2]];
    }
  };
}

/// Film grain, made rather than photographed: a lean either side of where a
/// pixel already was, so the picture keeps its exposure.
///
/// The phone seeds this, because a 3D wiggle needs one grain per viewpoint
/// and the same one in every loop. Nothing here loops, so the web takes the
/// grain it is given and spends no thought on seeding it.
function grain(strength: number): Recipe {
  return (pixels) => {
    let state = 0x9e3779b9;
    for (let index = 0; index < pixels.length; index += 4) {
      // xorshift32: cheap, and the same picture grains the same way twice.
      state ^= state << 13;
      state ^= state >>> 17;
      state ^= state << 5;
      const lean = (((state >>> 0) / 0xffffffff) * 2 - 1) * strength * 255;
      pixels[index] = clamp255(pixels[index] + lean);
      pixels[index + 1] = clamp255(pixels[index + 1] + lean);
      pixels[index + 2] = clamp255(pixels[index + 2] + lean);
    }
  };
}

const RECIPES: Record<FilterId, Recipe[]> = {
  film: [toneCurve(), channelScaled(1.035, 1, 0.975), colorControls(0.94, 1, 0), vibrance(0.18), grain(0.05)],
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
