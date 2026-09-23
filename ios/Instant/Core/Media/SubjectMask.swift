#if canImport(UIKit)
import CoreVideo
import Foundation
import UIKit
import Vision

/// Where a subject is in a photo, to the pixel, as an alpha matte.
///
/// The depth map knows roughly where the subject is; it does not know where its
/// outline is. Its edges are ramps a few pixels wide, they sit a little off the
/// true outline, and a slanted body reads to it as a depth edge. A matte says
/// exactly which pixels are the subject and, at the rim, what share of one they
/// are — which is what hair, a soft focus and an anti-aliased edge actually
/// are. See `wiki/ios-client.md`.
public struct SubjectMask: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// 0 outside the subject, 255 inside, and everything between at its rim.
    /// Row-major, top row first, the photo's own size.
    public let alpha: [UInt8]
    /// The face in it, in this mask's own pixels, when there is one. A photo
    /// of a person is a photo of their face: it is what the wiggle turns
    /// about, and the feet are allowed to swing.
    public let focus: CGRect?

    public init(width: Int, height: Int, alpha: [UInt8], focus: CGRect? = nil) {
        precondition(alpha.count == width * height, "a mask is width × height values")
        self.width = width
        self.height = height
        self.alpha = alpha
        self.focus = focus
    }

    /// How much of the picture it covers solidly, as a fraction.
    public var coverage: Double {
        guard !alpha.isEmpty else { return 0 }
        return Double(alpha.count { $0 >= 200 }) / Double(alpha.count)
    }

    /// How much of what it claims at all, it claims outright.
    ///
    /// A mask of something that is really there is nearly all solid, with a
    /// soft rim. One the model was unsure of is mostly half-values — the
    /// person request answers a photo with no people in it with a scattering
    /// of half-claimed fragments, and that is what this tells apart.
    public var decisiveness: Double {
        let touched = Double(alpha.count { $0 >= 20 })
        guard touched > 0 else { return 0 }
        return Double(alpha.count { $0 >= 200 }) / touched
    }

    /// The same outline with a rim a few pixels wide instead of a dozen.
    ///
    /// Vision scales its mask up from something much smaller, so its edge is a
    /// long ramp. Left that way, pixels that are wholly subject are half
    /// transparent, the background shows through them, and the subject wears a
    /// bright outline of whatever is behind it. Steepened about the halfway
    /// mark, which is where the outline actually is, and still soft enough to
    /// be a matte.
    public func sharpened(_ steepness: Float = 6) -> SubjectMask {
        SubjectMask(width: width, height: height, alpha: alpha.map { value in
            let centred = (Float(value) / 255 - 0.5) * steepness + 0.5
            return UInt8(max(0, min(255, (centred * 255).rounded())))
        }, focus: focus)
    }

    /// The same mask with a face noted in it, if that face is inside it.
    func focused(on faces: [CGRect]) -> SubjectMask {
        let mine = faces
            .filter { face in
                let x = Int(face.midX), y = Int(face.midY)
                guard x >= 0, x < width, y >= 0, y < height else { return false }
                return alpha[y * width + x] > 128
            }
            .max { $0.width * $0.height < $1.width * $1.height }
        guard let mine else { return self }
        return SubjectMask(width: width, height: height, alpha: alpha, focus: mine)
    }
}

/// Behind a protocol so the renderer can be tested without Vision, which is
/// the same reason `SensitivityChecking` exists.
public protocol SubjectMasking: Sendable {
    /// Nearest-looking subject first is not promised; the renderer orders them
    /// by the depth it measures. An empty answer means 3D falls back to
    /// reading the outline out of the depth map alone.
    func masks(for image: UIImage) async -> [SubjectMask]
}

/// Vision's own segmentation: whatever stands out, and people if nothing does.
///
/// The subject request first, though people are what gets sent, because on a
/// photo of a person it answers with the *same* person and a far cleaner
/// outline: the person request's edge is a wide, wispy ramp around the hair
/// and the shoulders, which composites as a bright halo. The person request
/// is the fallback for a photo the subject one finds nothing in — somebody
/// against a wall with nothing to be salient about.
///
/// Neither is trusted blindly. Both answer a photo of a houseplant with
/// "one instance, confidence 1.0"; what tells the good answer from the bad is
/// the mask itself, and `decisiveness` is the test.
public struct VisionSubjectMasker: SubjectMasking {
    /// Vision returns instances of its own; more than this in one photo is a
    /// crowd, where a wiggle is about the group rather than any one of them.
    static let mostInstances = 4
    /// Anything smaller than this share of the frame is left to the depth map:
    /// it is too small for its own parallax to read as anything but noise.
    static let smallestMask = 0.005

    public init() {}

    /// Under this, a mask is a guess rather than an outline, and the photo is
    /// better off rendered from its depth alone.
    static let leastDecisive = 0.6

    /// How much of a mask may already belong to a bigger one before it is
    /// dropped. Vision will hand back a person and, separately, their head:
    /// kept as two layers they grow about different middles and wiggle out of
    /// step, which at the outline looks like the subject twice.
    static let mostOverlap = 0.4

    public func masks(for image: UIImage) async -> [SubjectMask] {
        guard let cgImage = ImagePipeline.normalizingOrientation(image).cgImage else { return [] }
        let handler = ImageRequestHandler(cgImage)
        let subjects = await Self.instances(GenerateForegroundInstanceMaskRequest(), from: handler)
        let found = subjects.isEmpty
            ? await Self.instances(GeneratePersonInstanceMaskRequest(), from: handler)
            : subjects
        let faces = await Self.faces(
            from: handler,
            size: CGSize(width: cgImage.width, height: cgImage.height)
        )
        return Self.distinct(found.sorted { $0.coverage > $1.coverage })
            .prefix(Self.mostInstances)
            .map { $0.focused(on: faces) }
    }

    /// The masks that are not already most of a bigger one, biggest first.
    static func distinct(_ masks: [SubjectMask]) -> [SubjectMask] {
        var kept: [SubjectMask] = []
        for mask in masks {
            let mine = mask.alpha.count { $0 > 128 }
            guard mine > 0 else { continue }
            let overlaps = kept.contains { bigger in
                guard bigger.width == mask.width, bigger.height == mask.height else { return false }
                var shared = 0
                for index in 0..<mask.alpha.count where mask.alpha[index] > 128 && bigger.alpha[index] > 128 {
                    shared += 1
                }
                return Double(shared) / Double(mine) > mostOverlap
            }
            if !overlaps { kept.append(mask) }
        }
        return kept
    }

    /// Every face in the photo, in its pixels, top-left origin.
    private static func faces(from handler: ImageRequestHandler, size: CGSize) async -> [CGRect] {
        guard let observations = try? await handler.perform(DetectFaceRectanglesRequest()) else {
            return []
        }
        return observations.map { $0.boundingBox.toImageCoordinates(size, origin: .upperLeft) }
    }

    /// One mask per instance, at the photo's size. Anything Vision refuses —
    /// an unsupported device, a picture it finds nothing in — is no masks,
    /// and 3D renders the way it did before there were any.
    private static func instances<Request: ImageProcessingRequest>(
        _ request: Request,
        from handler: ImageRequestHandler
    ) async -> [SubjectMask] where Request.Result == InstanceMaskObservation? {
        guard let observation = try? await handler.perform(request) else { return [] }
        return observation.allInstances.compactMap { instance in
            guard let buffer = try? observation.generateScaledMask(
                for: IndexSet(integer: instance),
                scaledToImageFrom: handler
            ) else { return nil }
            // Judged as Vision drew it, and steepened after: sharpening a
            // scatter of half-claimed fragments makes it look decisive.
            guard let mask = read(buffer),
                  mask.coverage >= smallestMask,
                  mask.decisiveness >= leastDecisive
            else { return nil }
            return mask.sharpened()
        }
    }

    /// Copies a mask buffer out as bytes. Vision hands these over as one
    /// channel, either 8-bit or float, depending on the request.
    static func read(_ buffer: CVPixelBuffer) -> SubjectMask? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 1, height > 1, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        var alpha = [UInt8](repeating: 0, count: width * height)

        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { alpha[y * width + x] = row[x] }
            }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                for x in 0..<width {
                    alpha[y * width + x] = UInt8(max(0, min(255, (row[x] * 255).rounded())))
                }
            }
        default:
            return nil
        }
        return SubjectMask(width: width, height: height, alpha: alpha)
    }
}

/// Hands over whatever masks a test gave it, so the renderer's layering can be
/// checked without running Vision.
public struct StubSubjectMasker: SubjectMasking {
    private let stored: [SubjectMask]

    public init(_ masks: [SubjectMask] = []) {
        stored = masks
    }

    public func masks(for image: UIImage) async -> [SubjectMask] { stored }
}
#endif
