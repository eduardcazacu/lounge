#if canImport(UIKit)
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UIKit

/// The looks offered on the compose screen.
///
/// Post-capture rather than live, and that is a property of the preview rather
/// than a preference: `AVCaptureVideoPreviewLayer` draws buffers the capture
/// system hands it directly, with nowhere to hang a `CIFilter`, so a filtered
/// viewfinder would mean replacing the preview with a video-data-output and a
/// Metal path. The look is chosen against the photo instead, and — like the
/// caption — burned into the pixels before the instant is sealed. The server
/// holds nothing but ciphertext, so there is no later moment at which one could
/// be applied.
public enum PhotoFilter: String, CaseIterable, Identifiable, Sendable {
    case none
    case vivid
    case warm
    case cool
    case fade
    case mono
    case noir

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .none: "Original"
        case .vivid: "Vivid"
        case .warm: "Warm"
        case .cool: "Cool"
        case .fade: "Fade"
        case .mono: "Mono"
        case .noir: "Noir"
        }
    }

    /// One context for the app. Each one carries its own caches and GPU state,
    /// and building a fresh one is most of the cost of a small render — the
    /// filter strip renders one thumbnail per case and would pay it seven times.
    /// `CIContext` is documented as thread-safe.
    nonisolated(unsafe) private static let context = CIContext()

    /// The photo with this look baked in, at exactly the size it came in at.
    ///
    /// Same pixels in, same pixels out — including the scale factor, so the
    /// result can be swapped in for the original anywhere it was already being
    /// laid out. Nothing here measures the image either, so a thumbnail in the
    /// strip and the frame that goes on the wire are one transform at two
    /// resolutions rather than two approximations of one look.
    public func apply(to image: UIImage) -> UIImage {
        let upright = ImagePipeline.normalizingOrientation(image)
        guard self != .none, let source = upright.cgImage else { return upright }
        let input = CIImage(cgImage: source)
        guard let output = recipe(input),
              let rendered = Self.context.createCGImage(output, from: input.extent)
        else { return upright }
        return UIImage(cgImage: rendered, scale: upright.scale, orientation: .up)
    }

    /// The same look on a Core Image frame, which is how a video gets it: the
    /// compose screen's player and the export both run this per frame, so a
    /// clip's look is the photo's chain and not a second definition of it.
    public func apply(to input: CIImage) -> CIImage {
        guard self != .none else { return input }
        return recipe(input)?.cropped(to: input.extent) ?? input
    }

    private func recipe(_ input: CIImage) -> CIImage? {
        switch self {
        case .none:
            return input
        case .vivid:
            // Vibrance before saturation: it leaves already-saturated colour
            // alone, so skin does not go orange on the way to a brighter sky.
            let vibrance = CIFilter.vibrance()
            vibrance.inputImage = input
            vibrance.amount = 0.6
            guard let boosted = vibrance.outputImage else { return nil }
            return Self.colorControls(boosted, saturation: 1.08, contrast: 1.1, brightness: 0)
        case .warm:
            return Self.channelScaled(input, red: 1.08, green: 1.01, blue: 0.9)
        case .cool:
            return Self.channelScaled(input, red: 0.92, green: 1, blue: 1.09)
        case .fade:
            // Lifted blacks and pulled-in contrast — the washed, matte look,
            // which is a tone curve rather than a colour shift.
            return Self.colorControls(input, saturation: 0.78, contrast: 0.88, brightness: 0.05)
        case .mono:
            let mono = CIFilter.photoEffectMono()
            mono.inputImage = input
            return mono.outputImage
        case .noir:
            let noir = CIFilter.photoEffectNoir()
            noir.inputImage = input
            return noir.outputImage
        }
    }

    private static func colorControls(
        _ input: CIImage,
        saturation: Float,
        contrast: Float,
        brightness: Float
    ) -> CIImage? {
        let controls = CIFilter.colorControls()
        controls.inputImage = input
        controls.saturation = saturation
        controls.contrast = contrast
        controls.brightness = brightness
        return controls.outputImage
    }

    /// Warm and cool as a per-channel gain rather than `CITemperatureAndTint`.
    ///
    /// The temperature filter is defined against a white point the photo is
    /// assumed to have, which is a guess about the scene; this is a fixed
    /// multiply, so "warm" means the same thing in every photo and can be
    /// asserted on directly.
    private static func channelScaled(
        _ input: CIImage,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat
    ) -> CIImage? {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = input
        matrix.rVector = CIVector(x: red, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: green, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: blue, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return matrix.outputImage
    }
}
#endif
