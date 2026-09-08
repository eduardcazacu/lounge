// Shared canvas -> WebP compression.
//
// Previously copied verbatim into Publish.tsx (post images) and Account.tsx
// (avatars); Instant is the third caller, so it lives here now. The algorithm is
// unchanged: scale to fit, then walk a quality ladder, then shrink 15% and walk
// it again, keeping the smallest blob that lands under the target.

export type EncodeOptions = {
  maxWidth: number;
  maxHeight: number;
  // Stop as soon as a candidate lands under this. Not a hard cap.
  targetBytes: number;
  qualityLevels: number[];
  // Floor for the LONGER edge, whichever axis that happens to be. It has to be
  // orientation-independent: separate per-axis floors get applied one axis at a
  // time, which stretches anything whose shape does not match them. A 1280x720
  // webcam frame under 540x960 floors came out 918x960 — aspect 1.78 squashed
  // to 0.69.
  minLongEdge: number;
  passes?: number;
};

const DEFAULT_PASSES = 4;

export type EncodableSource = HTMLImageElement | HTMLCanvasElement;

function sourceDimensions(source: EncodableSource) {
  return source instanceof HTMLCanvasElement
    ? { width: source.width, height: source.height }
    : { width: source.naturalWidth, height: source.naturalHeight };
}

// Reads the intrinsic size of an image file without decoding it onto a canvas.
export async function loadImageDimensions(file: File) {
  const objectUrl = URL.createObjectURL(file);
  try {
    return await new Promise<{ width: number; height: number }>((resolve, reject) => {
      const image = new Image();
      image.onload = () => resolve({ width: image.naturalWidth, height: image.naturalHeight });
      image.onerror = () => reject(new Error("Unable to read image dimensions."));
      image.src = objectUrl;
    });
  } finally {
    URL.revokeObjectURL(objectUrl);
  }
}

export async function loadImageElement(file: File | Blob): Promise<HTMLImageElement> {
  const objectUrl = URL.createObjectURL(file);
  try {
    return await new Promise<HTMLImageElement>((resolve, reject) => {
      const image = new Image();
      image.onload = () => resolve(image);
      image.onerror = () => reject(new Error("Unable to load image."));
      image.src = objectUrl;
    });
  } finally {
    // The element keeps the decoded bitmap once loaded, so revoking here is safe
    // for the load path; callers that need the URL should make their own.
    setTimeout(() => URL.revokeObjectURL(objectUrl), 0);
  }
}

// Encodes to WebP, shrinking until it fits (or the passes run out). Accepts a
// canvas so callers that have already composited something — Instant's text
// overlay, for instance — do not have to round-trip through a File first.
export async function encodeToWebp(
  source: EncodableSource,
  options: EncodeOptions
): Promise<Blob> {
  const { width: sourceWidth, height: sourceHeight } = sourceDimensions(source);
  if (!sourceWidth || !sourceHeight) {
    throw new Error("Image has no dimensions.");
  }

  const baseScale = Math.min(
    1,
    options.maxWidth / sourceWidth,
    options.maxHeight / sourceHeight
  );

  // Every candidate size comes from ONE scalar, so the aspect ratio is exact by
  // construction and cannot drift as the passes shrink.
  const longEdge = Math.max(sourceWidth, sourceHeight);
  const floorScale = Math.min(baseScale, options.minLongEdge / longEdge);
  let scale = baseScale;

  let bestBlob: Blob | null = null;
  const passes = options.passes ?? DEFAULT_PASSES;

  for (let pass = 0; pass < passes; pass += 1) {
    const workingWidth = Math.max(1, Math.round(sourceWidth * scale));
    const workingHeight = Math.max(1, Math.round(sourceHeight * scale));

    const canvas = document.createElement("canvas");
    canvas.width = workingWidth;
    canvas.height = workingHeight;
    const context = canvas.getContext("2d");
    if (!context) {
      throw new Error("Canvas is unavailable in this browser.");
    }
    context.drawImage(source, 0, 0, workingWidth, workingHeight);

    for (const quality of options.qualityLevels) {
      const candidate = await new Promise<Blob | null>((resolve) => {
        canvas.toBlob(resolve, "image/webp", quality);
      });
      if (!candidate) {
        continue;
      }
      bestBlob = candidate;
      if (candidate.size <= options.targetBytes) {
        break;
      }
    }

    if (bestBlob && bestBlob.size <= options.targetBytes) {
      break;
    }

    const nextScale = Math.max(floorScale, scale * 0.85);
    if (nextScale === scale) {
      // Already at the floor; more passes would re-encode the same pixels.
      break;
    }
    scale = nextScale;
  }

  if (!bestBlob) {
    throw new Error("Failed to process image.");
  }
  return bestBlob;
}

// Convenience wrapper for the upload paths, which all work in Files.
export async function encodeFileToWebp(file: File, options: EncodeOptions): Promise<File> {
  const image = await loadImageElement(file);
  const blob = await encodeToWebp(image, options);
  return new File([blob], file.name.replace(/\.[^.]+$/, ".webp"), { type: "image/webp" });
}
