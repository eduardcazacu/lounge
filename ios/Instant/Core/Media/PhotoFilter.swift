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
    private static let context = CIContext()

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
            // Colour negative film of the warm portrait sort, as a lookup
            // table somebody measured off the stock rather than a curve and
            // a couple of matrices leaning in roughly its direction. Then the
            // halation around whatever is bright, and then the grain, which is
            // most of why it reads as film at all.
            let graded = Self.stock?.apply(to: input) ?? input
            guard let bloomed = Self.halated(graded) else { return nil }
            return Self.grained(bloomed, seed: seed)
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

    /// The stock the film look is of, read once out of the app's resources.
    /// See `ColorCube`.
    static let stock = ColorCube.named("kodak_portra_400")

    /// How far the halo reaches, as a fraction of the frame's width — so a
    /// thumbnail in the strip blooms by as much of itself as the frame on the
    /// wire does, rather than by the same number of pixels.
    static let halationSize: CGFloat = 0.025
    /// How much of the halo is added back on top of the picture.
    static let halationStrength: CGFloat = 0.7
    /// How bright a thing has to be before it blooms, in linear light — which
    /// is about 0.95 of the way up the picture as you see it, so a lamp, a
    /// window or a specular hit, and not a white wall. Lower than this and a
    /// big bright surface passes the threshold across the whole of itself,
    /// where a blur has no edge to work with: the wall does not glow, it just
    /// turns pink.
    static let halationThreshold: CGFloat = 0.88
    /// What it comes back as. Red is nearly all of it: red light is what
    /// reaches the back of the base and returns through the emulsion.
    static let halationTint = (red: CGFloat(1), green: CGFloat(0.22), blue: CGFloat(0.08))

    /// The red bleed around a bright source.
    ///
    /// On film this is light that went through the emulsion, reflected off the
    /// back of the base and exposed the picture a second time from behind,
    /// spread out by the trip. It survives reddest because red penetrates
    /// furthest and the anti-halation backing absorbs it least, which is why a
    /// street light on Portra has a warm ring and a hard digital highlight has
    /// nothing.
    ///
    /// Core Image works in linear light, which is the trap everywhere else in
    /// this file and exactly right here: light adds, so a threshold, a blur and
    /// an addition are all the arithmetic the physical thing does. The picture
    /// as it is encoded would spread the glow by the wrong amount and grey it.
    ///
    /// It goes on after the grade, not before. Halation happens in the negative
    /// and the table is a measurement of the print, so the physical order is
    /// the other way round — but a table that has already rolled the highlights
    /// would grade the halo too, and the red we asked for would come back as
    /// whatever the stock does to red. Tunable and predictable beats
    /// chronological.
    static func halated(_ input: CIImage) -> CIImage? {
        let extent = input.extent
        guard !extent.isInfinite, extent.width > 1, extent.height > 1,
              halationStrength > 0, halationSize > 0
        else { return input }

        // Everything above the threshold, rescaled so that the threshold is
        // nothing and white is all of it. Judged on brightness rather than per
        // channel, so a saturated blue light blooms like any other light —
        // what scatters is the light, not one of its channels.
        let gain = 1 / max(1 - halationThreshold, 0.01)
        let knee = CIFilter.colorMatrix()
        knee.inputImage = input
        let luma = CIVector(x: 0.2126 * gain, y: 0.7152 * gain, z: 0.0722 * gain, w: 0)
        knee.rVector = luma
        knee.gVector = luma
        knee.bVector = luma
        knee.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        knee.biasVector = CIVector(
            x: -halationThreshold * gain,
            y: -halationThreshold * gain,
            z: -halationThreshold * gain,
            w: 0
        )
        guard let above = knee.outputImage else { return input }

        // Clamped before the tint, so that everything darker than the
        // threshold is nothing at all rather than a negative that the blur
        // would then smear as a hole.
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = above
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        guard let sources = clamp.outputImage else { return input }

        let tint = CIFilter.colorMatrix()
        tint.inputImage = sources
        tint.rVector = CIVector(x: halationTint.red * halationStrength, y: 0, z: 0, w: 0)
        tint.gVector = CIVector(x: 0, y: halationTint.green * halationStrength, z: 0, w: 0)
        tint.bVector = CIVector(x: 0, y: 0, z: halationTint.blue * halationStrength, w: 0)
        tint.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let coloured = tint.outputImage else { return input }

        let blur = CIFilter.gaussianBlur()
        // Clamped to the extent first, or the blur mixes the glow with the
        // nothing outside the frame and a bright edge loses half its halo.
        blur.inputImage = coloured.clampedToExtent()
        blur.radius = Float(max(halationSize * extent.width, 0.5))
        guard let spread = blur.outputImage?.cropped(to: extent) else { return input }

        // Linear dodge, which is addition as a blend mode — and not
        // `CIAdditionCompositing`, which adds the alpha channel along with the
        // colour. Two opaque images make one of alpha two, which brightens
        // what it was supposed to leave alone and hands the grain after it a
        // picture it renders black. Nothing about that says so.
        let add = CIFilter.linearDodgeBlendMode()
        add.inputImage = spread
        add.backgroundImage = input
        return add.outputImage?.cropped(to: extent) ?? input
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
