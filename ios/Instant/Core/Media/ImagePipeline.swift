#if canImport(UIKit)
import Foundation
import UIKit

/// The compression ladder, ported from `encodeToWebp` in
/// `frontend/src/lib/image.ts` so a photo costs about the same wherever it was
/// sent from.
public struct EncodeOptions: Equatable, Sendable {
    public var maxWidth: Int
    public var maxHeight: Int
    /// Stop as soon as a candidate lands under this. Not a hard cap.
    public var targetBytes: Int
    public var qualityLevels: [Double]
    /// Floor for the LONGER edge, whichever axis that happens to be.
    ///
    /// It has to be orientation-independent: separate per-axis floors get
    /// applied one axis at a time, which stretches anything whose shape does not
    /// match them. The web client hit exactly this — a 1280x720 frame under
    /// 540x960 floors came out 918x960, aspect 1.78 squashed to 0.69.
    public var minLongEdge: Int
    public var passes: Int

    public init(
        maxWidth: Int,
        maxHeight: Int,
        targetBytes: Int,
        qualityLevels: [Double],
        minLongEdge: Int,
        passes: Int = 4
    ) {
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.targetBytes = targetBytes
        self.qualityLevels = qualityLevels
        self.minLongEdge = minLongEdge
        self.passes = passes
    }

    /// `INSTANT_ENCODE_OPTIONS` in `frontend/src/components/instant/InstantComposer.tsx`.
    public static let instant = EncodeOptions(
        maxWidth: 1080,
        maxHeight: 1920,
        targetBytes: 250_000,
        qualityLevels: [0.9, 0.82, 0.74, 0.66],
        minLongEdge: 640
    )
}

public enum ImagePipeline {
    public enum PipelineError: Error, Equatable {
        case noDimensions
        case encodeFailed
    }

    /// Camera and library images carry an EXIF orientation rather than rotated
    /// pixels. Everything downstream — the overlay geometry, the scale maths,
    /// the encoder — works in pixel space, so the orientation has to be baked in
    /// before any of it runs.
    public static func normalizingOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    static func resized(_ image: UIImage, to size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Every candidate size comes from ONE scalar, so the aspect ratio is exact
    /// by construction and cannot drift as the passes shrink.
    static func scales(
        sourceWidth: Int,
        sourceHeight: Int,
        options: EncodeOptions
    ) -> (base: Double, floor: Double) {
        let base = min(
            1.0,
            Double(options.maxWidth) / Double(sourceWidth),
            Double(options.maxHeight) / Double(sourceHeight)
        )
        let longEdge = Double(max(sourceWidth, sourceHeight))
        return (base, min(base, Double(options.minLongEdge) / longEdge))
    }

    public static func encode(_ image: UIImage, options: EncodeOptions = .instant) throws -> Data {
        let normalized = normalizingOrientation(image)
        let sourceWidth = Int(normalized.size.width.rounded())
        let sourceHeight = Int(normalized.size.height.rounded())
        guard sourceWidth > 0, sourceHeight > 0 else { throw PipelineError.noDimensions }

        let (baseScale, floorScale) = scales(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            options: options
        )
        var scale = baseScale
        var best: Data?

        for _ in 0..<options.passes {
            let workingWidth = max(1, Int((Double(sourceWidth) * scale).rounded()))
            let workingHeight = max(1, Int((Double(sourceHeight) * scale).rounded()))
            let working = resized(
                normalized,
                to: CGSize(width: workingWidth, height: workingHeight)
            )

            for quality in options.qualityLevels {
                guard let candidate = try? WebPEncoder.encode(working, quality: quality) else {
                    continue
                }
                best = candidate
                if candidate.count <= options.targetBytes { break }
            }

            if let best, best.count <= options.targetBytes { break }

            let nextScale = max(floorScale, scale * 0.85)
            if nextScale == scale {
                // Already at the floor; more passes would re-encode the same pixels.
                break
            }
            scale = nextScale
        }

        guard let best else { throw PipelineError.encodeFailed }
        return best
    }
}
#endif
