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
    /// The default, and first in the strip.
    case film
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
        case .film: "Film"
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
    public func apply(to image: UIImage, grain seed: Int = 0) -> UIImage {
        let upright = ImagePipeline.normalizingOrientation(image)
        guard self != .none, let source = upright.cgImage else { return upright }
        let input = CIImage(cgImage: source)
        guard let output = recipe(input, grain: seed),
              let rendered = Self.context.createCGImage(output, from: input.extent)
        else { return upright }
        return UIImage(cgImage: rendered, scale: upright.scale, orientation: .up)
    }

    /// The same look on a Core Image frame, which is how a video gets it: the
    /// compose screen's player and the export both run this per frame, so a
    /// clip's look is the photo's chain and not a second definition of it.
    public func apply(to input: CIImage, grain seed: Int = 0) -> CIImage {
        guard self != .none else { return input }
        return recipe(input, grain: seed)?.cropped(to: input.extent) ?? input
    }

    private func recipe(_ input: CIImage, grain seed: Int) -> CIImage? {
        switch self {
        case .none:
            return input
        case .film:
            // Colour negative film, of the warm portrait sort: skin kept
            // where it is while the greens go quiet, the blacks lifted off
            // zero the way a negative's toe does, and the highlights rolled
            // rather than clipped. Then the grain, which is most of why it
            // reads as film at all.
            guard let toned = Self.toneCurve(input),
                  let warmed = Self.channelScaled(toned, red: 1.035, green: 1, blue: 0.975),
                  // Contrast is left at one: Core Image works in linear
                  // light, where "contrast" pivots about a value far brighter
                  // than a mid-grey and drags the whole picture down. The
                  // curve above is where this look's contrast lives.
                    let calmed = Self.colorControls(warmed, saturation: 0.94, contrast: 1.08, brightness: 0)
            else { return nil }
            let vibrance = CIFilter.vibrance()
            vibrance.inputImage = calmed
            // Vibrance back up after the saturation came down: the quiet is
            // meant to be in the greens and the walls, not in a face.
            vibrance.amount = 0.18
            guard let graded = vibrance.outputImage else { return nil }
            return Self.grained(graded, seed: seed)
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

    /// The negative's toe and shoulder: blacks off zero, highlights short of
    /// one, and a gentle S in between.
    private static func toneCurve(_ input: CIImage) -> CIImage? {
        let curve = CIFilter.toneCurve()
        curve.inputImage = input
        // Read off the picture as it is encoded, which is where this filter
        // works — unlike the colour ones below it, which are in linear light.
        curve.point0 = CGPoint(x: 0, y: 0.05)
        curve.point1 = CGPoint(x: 0.25, y: 0.262)
        curve.point2 = CGPoint(x: 0.5, y: 0.513)
        curve.point3 = CGPoint(x: 0.75, y: 0.772)
        curve.point4 = CGPoint(x: 1, y: 0.972)
        return curve.outputImage
    }

    /// How coarse the grain is, in pixels of a 1080-wide frame: finer than
    /// this and the encoder throws most of it away.
    static let grainSize: CGFloat = 3
    /// How far the grain pushes a pixel either side of where it was. Soft
    /// light, so this is a lean rather than an addition.
    static let grainStrength: CGFloat = 0.20
    /// The tile the grain is made of. Big enough that its repeat is not a
    /// pattern, small enough to make in a fraction of a millisecond.
    static let grainTile = 512

    /// Film grain, made rather than photographed.
    ///
    /// Made here rather than with `CIRandomGenerator`, which has no seed to
    /// give it and hands back premultiplied noise with a random alpha — it
    /// lightens a picture rather than grains it. A seeded tile has neither
    /// problem, and the seed is the point: the same seed gives back the same
    /// grain, in this loop and every loop after it, which is what lets a
    /// wiggle hold one grain per viewpoint. See `VideoPipeline.GrainSeeding`.
    ///
    /// Soft light rather than addition, because grain is a lean either way
    /// about the middle grey and not a brightening: a mid-grey comes out a
    /// mid-grey, and the picture keeps its exposure.
    static func grained(_ input: CIImage, seed: Int) -> CIImage? {
        let extent = input.extent
        guard extent.width > 1, extent.height > 1, let tile = grain(seed: seed) else { return input }
        let scale = max(grainSize * extent.width / 1080, 0.05)
        let tiled = CIFilter.affineTile()
        tiled.inputImage = tile
        tiled.transform = CGAffineTransform(scaleX: scale, y: scale)
        guard let noise = tiled.outputImage?.cropped(to: extent) else { return input }

        let soft = CIFilter.softLightBlendMode()
        soft.inputImage = noise
        soft.backgroundImage = input
        return soft.outputImage?.cropped(to: extent)
    }

    /// The 64 bits of SplitMix64's finalizer, which is what turns a counter
    /// into something that looks like noise.
    @inline(__always)
    private static func scrambled(_ value: UInt64) -> UInt64 {
        var z = value
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// One square of grey noise, centred on the middle grey that soft light
    /// leaves alone.
    ///
    /// The seed chooses a stream rather than a place in one. Walked along a
    /// single sequence instead — each seed starting one step further along
    /// than the last — the tile for one frame comes out as the tile for the
    /// frame before it moved along by a pixel, and grain that ought to
    /// sparkle slides sideways across the picture instead. So the seed is
    /// hashed once and then mixed into every pixel's own hash, which leaves
    /// no relation between one seed's tile and the next's.
    static func grainBytes(seed: Int, side: Int) -> [UInt8] {
        let stream = scrambled(UInt64(bitPattern: Int64(seed)) &+ 0x9E37_79B9_7F4A_7C15)
        var bytes = [UInt8](repeating: 0, count: side * side)
        let spread = Double(grainStrength) * 127
        for index in bytes.indices {
            let noise = scrambled(stream ^ (UInt64(index) &* 0xD6E8_FEB8_6659_FD93))
            let centred = 128 + (Double(noise >> 56) - 127.5) / 127.5 * spread
            bytes[index] = UInt8(max(0, min(255, centred.rounded())))
        }
        return bytes
    }

    /// That square as an image Core Image can tile.
    static func grain(seed: Int) -> CIImage? {
        let side = grainTile
        let bytes = grainBytes(seed: seed, side: side)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let linear = CGColorSpace(name: CGColorSpace.linearGray),
              let image = CGImage(
                width: side,
                height: side,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: side,
                // Linear, so that the tile's middle value is the middle soft
                // light leaves alone. In a gamma-encoded grey it reads as a
                // fifth of the way up instead, and grain darkens the picture.
                space: linear,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else { return nil }
        return CIImage(cgImage: image)
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
