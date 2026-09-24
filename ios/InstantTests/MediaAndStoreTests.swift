import CryptoKit
import Foundation
import Testing
import UserNotifications
import UIKit
@testable import Instant

@Suite("Photo filters")
struct PhotoFilterTests {
    /// A mid-grey field: every channel equal, so any shift a filter makes shows
    /// up as a difference between them rather than having to be separated from
    /// the picture's own colour.
    private func grey(_ side: Int = 32) -> UIImage {
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// A colourful one, for the filters that only move saturation around.
    private func colourful(_ side: Int = 32) -> UIImage {
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor.systemPink.cgColor, UIColor.systemTeal.cgColor] as CFArray,
                locations: [0, 1]
            )!
            cg.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )
        }
    }

    /// Mean red, green and blue over the whole image, 0...255.
    /// The look as a function, so a test can run one without naming it.
    private func apply(_ filter: PhotoFilter) -> (UIImage) -> (red: Double, green: Double, blue: Double) {
        { self.channels(filter.apply(to: $0)) }
    }

    private func channels(_ image: UIImage) -> (red: Double, green: Double, blue: Double) {
        let cg = image.cgImage!
        let width = cg.width
        let height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        var totals = (red: 0.0, green: 0.0, blue: 0.0)
        for pixel in stride(from: 0, to: pixels.count, by: 4) {
            totals.red += Double(pixels[pixel])
            totals.green += Double(pixels[pixel + 1])
            totals.blue += Double(pixels[pixel + 2])
        }
        let count = Double(width * height)
        return (totals.red / count, totals.green / count, totals.blue / count)
    }

    @Test("The original is left alone, pixel for pixel")
    func noneIsIdentity() {
        let source = colourful()
        let before = channels(source)
        let after = channels(PhotoFilter.none.apply(to: source))
        #expect(abs(before.red - after.red) < 0.5)
        #expect(abs(before.green - after.green) < 0.5)
        #expect(abs(before.blue - after.blue) < 0.5)
    }

    /// The whole point of picking the look before the send: what the strip
    /// shows has to be what goes on the wire, at a different size.
    @Test("Every look keeps the photo's shape")
    func preservesDimensions() {
        let source = colourful(48)
        for filter in PhotoFilter.allCases {
            #expect(filter.apply(to: source).size == source.size, "\(filter.name) resized the photo")
        }
    }

    /// What a look *is* belongs to whoever chose it, and pinning its numbers
    /// in a test only freezes one person's taste. What a test can say is that
    /// picking a look does something, and does the same thing twice.
    @Test("Every look but the original changes the picture, the same way each time")
    func everyLookIsApplied() {
        for filter in PhotoFilter.allCases where filter != .none {
            let once = apply(filter)(colourful())
            #expect(once != channels(colourful()), "\(filter.name) left the photo as it was")
            #expect(once == apply(filter)(colourful()), "\(filter.name) is not the same look twice")
        }
    }

    /// The look itself is the stock's business, not this test's. What is
    /// checked is that the table ships and is the one the look asks for: a
    /// `.cube` missing from the app's resources is a packaging mistake, and
    /// the film look would quietly become grain on an ungraded photo.
    @Test("The stock's table ships with the app")
    func stockShips() throws {
        let stock = try #require(PhotoFilter.stock, "the .cube is missing from the app's resources")
        #expect(stock.dimension == 13)
        #expect(stock.data.count == 13 * 13 * 13 * 4 * MemoryLayout<Float>.size)
    }

    /// A table read wrong is a look that lands somewhere else entirely, and
    /// nothing says so — so the parsing is checked on a table small enough to
    /// know by heart.
    @Test("A .cube is read as written: size, domain, red fastest")
    func parsesACube() throws {
        let text = """
        # a toy
        TITLE "toy"
        LUT_3D_SIZE 2
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
        let cube = try #require(ColorCube.parse(text))
        #expect(cube.dimension == 2)
        let values = cube.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(values.count == 8 * 4)
        #expect(Array(values.prefix(8)) == [0, 0, 0, 1, 1, 0, 0, 1], "red varies fastest, and alpha is added")
        #expect(Array(values.suffix(4)) == [1, 1, 1, 1])

        // A domain that is not 0…1 is scaled into it.
        let scaled = try #require(ColorCube.parse(text.replacingOccurrences(of: "DOMAIN_MAX 1.0 1.0 1.0", with: "DOMAIN_MAX 2.0 2.0 2.0")))
        let halved = scaled.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(Array(halved.suffix(4)) == [0.5, 0.5, 0.5, 1])

        #expect(ColorCube.parse("LUT_3D_SIZE 2\n0 0 0") == nil, "a table with entries missing is no table")
    }

    /// A dark frame with one bright thing in the middle of it, which is the
    /// only picture halation has anything to say about.
    private func lamp(_ side: Int) -> UIImage {
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(
                x: side * 3 / 8, y: side * 3 / 8, width: side / 4, height: side / 4
            ))
        }
    }

    /// An image's bytes, so that a test can look at one pixel rather than at
    /// the average of all of them.
    private struct Sampled {
        let width: Int
        let bytes: [UInt8]

        func at(_ x: Int, _ y: Int) -> (red: Double, green: Double, blue: Double) {
            let base = (y * width + x) * 4
            return (Double(bytes[base]), Double(bytes[base + 1]), Double(bytes[base + 2]))
        }
    }

    private func sampled(_ image: UIImage) -> Sampled {
        let cg = image.cgImage!
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = CGContext(
            data: &bytes,
            width: cg.width,
            height: cg.height,
            bitsPerComponent: 8,
            bytesPerRow: cg.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return Sampled(width: cg.width, bytes: bytes)
    }

    private func halated(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage,
              let bloomed = PhotoFilter.halated(CIImage(cgImage: cg)),
              let rendered = CIContext().createCGImage(
                bloomed, from: CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
              )
        else { return nil }
        return UIImage(cgImage: rendered)
    }

    /// Not what the halo looks like — that is taste, and tunable — but that it
    /// is a halo at all: red rather than white, outside the bright thing
    /// rather than on it, and gone by the far corner. Every way this can fail
    /// fails silently: a threshold judged in the wrong colour space blooms the
    /// whole picture, and a blur over an unclamped extent eats the halo at the
    /// frame's edge.
    @Test("A bright source bleeds red into the dark beside it")
    func halationRingsWhatIsBright() throws {
        let side = 256
        let source = lamp(side)
        let plain = sampled(source)
        let bloomed = sampled(try #require(halated(source)))

        // Just outside the bright square's right edge, level with its middle.
        let x = side * 5 / 8 + 4
        let y = side / 2
        #expect(plain.at(x, y).red < 2, "the picture is not dark where the halo is looked for")

        let halo = bloomed.at(x, y)
        #expect(halo.red > 12, "nothing bled out of the bright square")
        #expect(halo.red > halo.blue * 2, "the halo is not red: \(halo)")
        #expect(bloomed.at(x + 24, y).red < halo.red, "the halo does not fall off with distance")
        #expect(bloomed.at(side - 2, 2).red < 2, "the halo reached the far corner")
    }

    /// One seed, one grain — which is what lets a wiggle keep the same grain
    /// on a viewpoint every time it comes round, instead of boiling.
    @Test("Grain is the same for a seed and different between seeds")
    func grainFollowsItsSeed() {
        let same = (
            channels(PhotoFilter.film.apply(to: grey(), grain: 3)),
            channels(PhotoFilter.film.apply(to: grey(), grain: 3))
        )
        #expect(abs(same.0.green - same.1.green) < 0.01, "the same seed gives back the same grain")

        // Averages hide noise, so the difference is looked for pixel by pixel.
        let first = PhotoFilter.film.apply(to: grey(), grain: 3)
        let second = PhotoFilter.film.apply(to: grey(), grain: 4)
        #expect(pixelsDiffer(first, second), "a different seed gives a different grain")
    }

    /// The bug this is for: a seed that was a step along one shared sequence
    /// gave the next frame the last frame's grain moved along by a pixel, so
    /// the grain slid sideways across the picture instead of sparkling.
    @Test("One seed's grain is no part of another's, at any offset")
    func grainIsNotTheSameNoiseSlidAlong() {
        let side = 64
        let first = PhotoFilter.grainBytes(seed: 11, side: side)
        let second = PhotoFilter.grainBytes(seed: 12, side: side)
        #expect(first == PhotoFilter.grainBytes(seed: 11, side: side), "the same seed is the same grain")
        #expect(first != second)

        // Slid against each other, one way and the other, they must still
        // look like two different pictures.
        for shift in 1...8 {
            for pair in [(first, second), (second, first)] {
                let overlap = zip(pair.0.dropFirst(shift), pair.1).count { $0 == $1 }
                let share = Double(overlap) / Double(pair.0.count - shift)
                #expect(share < 0.2, "shifted by \(shift), \(Int(share * 100))% of the grain matched")
            }
        }
    }

    @Test("Grain is the film look's alone")
    func grainIsFilmsAlone() {
        #expect(!pixelsDiffer(PhotoFilter.fade.apply(to: grey(), grain: 1), PhotoFilter.fade.apply(to: grey(), grain: 2)))
    }

    private func pixelsDiffer(_ first: UIImage, _ second: UIImage) -> Bool {
        func bytes(_ image: UIImage) -> [UInt8] {
            let width = Int(image.size.width), height = Int(image.size.height)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes { raw in
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )!
                context.draw(image.cgImage!, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return pixels
        }
        return bytes(first) != bytes(second)
    }

    @Test("Every look is offered, and named")
    func allCasesAreNamed() {
        #expect(PhotoFilter.allCases.first == PhotoFilter.film, "the look every capture starts in comes first")
        #expect(Set(PhotoFilter.allCases.map(\.name)).count == PhotoFilter.allCases.count)
        #expect(PhotoFilter.allCases.allSatisfy { !$0.name.isEmpty })
    }
}

@MainActor
@Suite("Image pipeline")
struct ImagePipelineTests {
    /// A photo-like test image: smooth gradients with enough structure that the
    /// encoder has real work to do, but compressible the way a camera frame is.
    ///
    /// Per-pixel noise would be quicker to write and completely misleading — it
    /// is incompressible, so it would neither exercise the quality ladder
    /// realistically nor ever reach the byte target. `incompressible(_:_:)`
    /// below covers that case deliberately.
    private func image(_ width: Int, _ height: Int) -> UIImage {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let gradient = CGGradient(
                colorsSpace: space,
                colors: [
                    UIColor.systemTeal.cgColor,
                    UIColor.systemIndigo.cgColor,
                    UIColor.systemOrange.cgColor,
                ] as CFArray,
                locations: [0, 0.55, 1]
            )!
            cg.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )
            // Some edges and shapes, so it is not a pure gradient either.
            for index in 0..<24 {
                let inset = CGFloat(index) * CGFloat(min(width, height)) / 48
                UIColor(white: index.isMultiple(of: 2) ? 0.95 : 0.15, alpha: 0.35).setFill()
                cg.fillEllipse(
                    in: CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
                )
            }
        }
    }

    /// Deliberately hostile to the encoder: per-pixel hue changes leave WebP
    /// nothing to predict, so no quality in the ladder gets it small.
    private func incompressible(_ width: Int, _ height: Int) -> UIImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        for index in stride(from: 0, to: pixels.count, by: 4) {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            pixels[index] = UInt8(truncatingIfNeeded: seed)
            pixels[index + 1] = UInt8(truncatingIfNeeded: seed >> 8)
            pixels[index + 2] = UInt8(truncatingIfNeeded: seed >> 16)
            pixels[index + 3] = 255
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    @Test("Encodes real WebP bytes")
    func producesWebP() throws {
        let data = try WebPEncoder.encode(image(64, 64), quality: 0.8)
        #expect(data.count > 0)
        // RIFF....WEBP
        #expect(data.prefix(4) == Data("RIFF".utf8))
        #expect(data.dropFirst(8).prefix(4) == Data("WEBP".utf8))
        #expect(UIImage(data: data) != nil, "and iOS can decode them back")
    }

    @Test("Lower quality means fewer bytes")
    func qualityLadderShrinks() throws {
        let source = image(256, 256)
        let high = try WebPEncoder.encode(source, quality: 0.9)
        let low = try WebPEncoder.encode(source, quality: 0.4)
        #expect(low.count < high.count)
    }

    /// The web client hit exactly this: separate per-axis floors squashed a
    /// 1280x720 frame to 918x960, turning aspect 1.78 into 0.69. Every candidate
    /// size now comes from one scalar, so the ratio is exact by construction.
    @Test("Aspect ratio survives at any orientation")
    func preservesAspectRatio() throws {
        for (width, height) in [(1280, 720), (720, 1280), (4000, 3000), (1000, 1000), (3000, 500)] {
            let encoded = try ImagePipeline.encode(image(width, height))
            let decoded = try #require(UIImage(data: encoded))
            let sourceAspect = Double(width) / Double(height)
            let encodedAspect = Double(decoded.size.width) / Double(decoded.size.height)
            #expect(
                abs(sourceAspect - encodedAspect) / sourceAspect < 0.01,
                "\(width)x\(height) became \(decoded.size)"
            )
        }
    }

    /// The camera viewport is 16:9 and so is the capture, so the crop is a
    /// no-op for a photo taken in the app. A library pick is whatever shape the
    /// library had, and it has to end up in the same frame — otherwise compose
    /// shows a picture the viewport never promised.
    @Test("Crops to 16:9 in the photo's own orientation")
    func cropsToTheFrame() throws {
        let cases: [(CGSize, CGSize)] = [
            (CGSize(width: 1200, height: 1600), CGSize(width: 900, height: 1600)),
            (CGSize(width: 1600, height: 1200), CGSize(width: 1600, height: 900)),
            (CGSize(width: 1000, height: 1000), CGSize(width: 1000, height: 563)),
            // Wider than 16:9 already, so the long edge is what gives.
            (CGSize(width: 2000, height: 500), CGSize(width: 889, height: 500)),
        ]
        for (source, expected) in cases {
            let cropped = ImagePipeline.croppedToFrame(
                image(Int(source.width), Int(source.height))
            )
            #expect(cropped.size == expected, "\(source) became \(cropped.size)")
        }
    }

    @Test("Leaves a frame that is already 16:9 alone")
    func leavesTheFrameAlone() throws {
        let portrait = image(1080, 1920)
        #expect(ImagePipeline.croppedToFrame(portrait).size == CGSize(width: 1080, height: 1920))
        let landscape = image(1920, 1080)
        #expect(ImagePipeline.croppedToFrame(landscape).size == CGSize(width: 1920, height: 1080))
    }

    /// A photo out of the camera carries its rotation in EXIF rather than in
    /// pixels. Cropping before that is baked in takes the crop off the wrong
    /// axis, which is a portrait selfie arriving letterboxed.
    @Test("Crops against the upright photo, not the sensor's")
    func cropsAfterOrientation() throws {
        let sideways = UIImage(
            cgImage: try #require(image(1600, 1200).cgImage), scale: 1, orientation: .right
        )
        #expect(sideways.size == CGSize(width: 1200, height: 1600), "it reads as portrait")
        #expect(ImagePipeline.croppedToFrame(sideways).size == CGSize(width: 900, height: 1600))
    }

    @Test("Fits inside the bounding box without upscaling")
    func respectsBounds() throws {
        let big = try #require(UIImage(data: try ImagePipeline.encode(image(4000, 3000))))
        #expect(big.size.width <= 1080)
        #expect(big.size.height <= 1920)

        // A small photo is not blown up to fill the box.
        let small = try #require(UIImage(data: try ImagePipeline.encode(image(320, 240))))
        #expect(small.size == CGSize(width: 320, height: 240))
    }

    @Test("A photo-sized frame lands under the byte target")
    func hitsTheByteTarget() throws {
        let encoded = try ImagePipeline.encode(image(2000, 3000))
        #expect(
            encoded.count <= EncodeOptions.instant.targetBytes,
            "2000x3000 encoded to \(encoded.count) bytes"
        )
    }

    /// `targetBytes` is where the ladder stops early, not a cap it enforces, and
    /// `passes` bounds how far it will shrink trying: four passes at 0.85 each
    /// may run out before reaching the long-edge floor. Both are true of the web
    /// implementation too — the alternative would be discarding a photo rather
    /// than sending a slightly larger one.
    ///
    /// So the guarantees worth pinning are: it terminates, it returns something
    /// decodable, it did shrink, the shape survived, and it is inside what the
    /// server will actually accept.
    @Test("An incompressible frame still returns something sendable")
    func incompressibleImageStillEncodes() throws {
        let encoded = try ImagePipeline.encode(incompressible(1200, 1600))
        let decoded = try #require(UIImage(data: encoded))

        let (baseScale, floorScale) = ImagePipeline.scales(
            sourceWidth: 1200, sourceHeight: 1600, options: .instant
        )
        let smallestReachable = max(floorScale, baseScale * pow(0.85, 3))
        let longEdge = max(decoded.size.width, decoded.size.height)

        #expect(longEdge <= (1600 * baseScale).rounded() + 1, "it never upscales past the box")
        #expect(longEdge >= (1600 * smallestReachable).rounded() - 1, "and cannot shrink past its pass budget")
        #expect(abs(decoded.size.width / decoded.size.height - 0.75) < 0.01, "aspect survives even here")
        // MAX_INSTANT_BYTES on the server is 3 MB; anything larger is a 400.
        #expect(encoded.count < 3 * 1024 * 1024)
    }

    @Test("The long-edge floor is orientation-independent")
    func floorAppliesToTheLongerEdge() {
        let landscape = ImagePipeline.scales(
            sourceWidth: 1280, sourceHeight: 720, options: .instant
        )
        let portrait = ImagePipeline.scales(
            sourceWidth: 720, sourceHeight: 1280, options: .instant
        )
        // Same pixels, rotated: the same floor scale must come out.
        #expect(abs(landscape.floor - portrait.floor) < 1e-12)
        #expect(abs(landscape.floor - 640.0 / 1280.0) < 1e-12)
    }

    @Test("Bakes in EXIF orientation before anything measures the image")
    func normalizesOrientation() throws {
        let base = image(100, 50)
        let cg = try #require(base.cgImage)

        for orientation in [
            UIImage.Orientation.up, .down, .left, .right,
            .upMirrored, .downMirrored, .leftMirrored, .rightMirrored,
        ] {
            let rotated = UIImage(cgImage: cg, scale: 1, orientation: orientation)
            let normalized = ImagePipeline.normalizingOrientation(rotated)
            #expect(normalized.imageOrientation == .up)
            // `size` already reports the rotated extent; normalizing must not
            // change what the image measures.
            #expect(normalized.size == rotated.size)
        }
    }

    @Test("A zero-sized image is an error, not a crash")
    func rejectsEmptyImage() {
        #expect(throws: (any Error).self) {
            _ = try ImagePipeline.encode(UIImage())
        }
    }
}

@MainActor
@Suite("Caption overlay")
struct OverlayCompositorTests {
    private func photo(_ width: Int, _ height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        return UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: format
        ).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @Test("Font size follows image width, as it does on the web")
    func fontScalesWithWidth() {
        #expect(OverlayCompositor.fontSize(forWidth: 1080) == 65)
        #expect(OverlayCompositor.fontSize(forWidth: 720) == 43)
        // Same fraction at any resolution, so the caption occupies the same
        // share of the photo whatever camera took it.
        #expect(OverlayCompositor.fontSize(forWidth: 500) / 500 == 0.06)
    }

    @Test("Placement is clamped inside the frame")
    func clampsPlacement() {
        #expect(OverlayCompositor.Placement(x: -5, y: 12).x == 0.05)
        #expect(OverlayCompositor.Placement(x: -5, y: 12).y == 0.95)
        #expect(OverlayCompositor.Placement.default == OverlayCompositor.Placement(x: 0.5, y: 0.85))
    }

    @Test("An empty caption leaves the pixels alone")
    func skipsEmptyCaption() throws {
        let base = photo(80, 120)
        let composited = OverlayCompositor.composite(
            image: base, captions: [OverlayCompositor.Caption(text: "   ")]
        )
        #expect(composited.size == base.size)

        let before = try WebPEncoder.encode(base, quality: 1)
        let after = try WebPEncoder.encode(composited, quality: 1)
        #expect(before == after)
    }

    @Test("A caption changes the pixels but not the dimensions")
    func burnsCaptionIn() throws {
        let base = photo(200, 300)
        let composited = OverlayCompositor.composite(
            image: base, captions: [OverlayCompositor.Caption(text: "hello")]
        )
        #expect(composited.size == base.size)
        #expect(
            try WebPEncoder.encode(composited, quality: 1) != (try WebPEncoder.encode(base, quality: 1))
        )
    }

    @Test("Moving the caption moves the pixels")
    func placementAffectsOutput() throws {
        let base = photo(200, 300)
        let top = OverlayCompositor.composite(
            image: base,
            captions: [OverlayCompositor.Caption(text: "hi", placement: OverlayCompositor.Placement(x: 0.5, y: 0.1))]
        )
        let bottom = OverlayCompositor.composite(
            image: base,
            captions: [OverlayCompositor.Caption(text: "hi", placement: OverlayCompositor.Placement(x: 0.5, y: 0.9))]
        )
        #expect(try WebPEncoder.encode(top, quality: 1) != (try WebPEncoder.encode(bottom, quality: 1)))
    }

    @Test("Style, scale and a second caption each change the pixels")
    func stylesScaleAndCount() throws {
        let base = photo(200, 300)
        func encoded(_ captions: [OverlayCompositor.Caption]) throws -> Data {
            try WebPEncoder.encode(OverlayCompositor.composite(image: base, captions: captions), quality: 1)
        }
        let bar = OverlayCompositor.Caption(text: "hi", style: .bar)
        let plate = OverlayCompositor.Caption(text: "hi", style: .plate)
        let bigPlate = OverlayCompositor.Caption(text: "hi", style: .plate, scale: 2.5)
        let another = OverlayCompositor.Caption(
            text: "there", placement: OverlayCompositor.Placement(x: 0.5, y: 0.2)
        )

        #expect(try encoded([bar]) != (try encoded([plate])))
        #expect(try encoded([plate]) != (try encoded([bigPlate])))
        #expect(try encoded([bar]) != (try encoded([bar, another])))

        let turned = OverlayCompositor.Caption(text: "hi", style: .plate, rotation: .pi / 5)
        #expect(try encoded([plate]) != (try encoded([turned])))
        // A bar ignores its rotation: it is drawn level whatever it holds.
        let turnedBar = OverlayCompositor.Caption(text: "hi", style: .bar, rotation: .pi / 5)
        #expect(try encoded([bar]) == (try encoded([turnedBar])))
    }

    @Test("The bar spans the photo; the plate hugs its text and stays inside it")
    func metricsByStyle() {
        let bar = OverlayCompositor.metrics(for: .bar, scale: 3, width: 1000)
        #expect(bar.fontSize == 50)
        #expect(bar.maxTextWidth == 1000 - bar.horizontalPadding * 2)

        // At scale 1 the plate is the web composer's caption.
        let plate = OverlayCompositor.metrics(for: .plate, scale: 1, width: 1080)
        #expect(plate.fontSize == OverlayCompositor.fontSize(forWidth: 1080))

        let big = OverlayCompositor.metrics(for: .plate, scale: 3, width: 1000)
        #expect(big.fontSize == 180)
        #expect(big.maxTextWidth + big.horizontalPadding * 2 <= 900)

        // Out-of-range scales are clamped rather than trusted.
        #expect(OverlayCompositor.metrics(for: .plate, scale: 99, width: 1000) == big)
    }

    @Test("A drawn line changes the pixels, and its ink and path both matter")
    func burnsStrokesIn() throws {
        let base = photo(200, 300)
        func encoded(_ strokes: [OverlayCompositor.Stroke]) throws -> Data {
            try WebPEncoder.encode(
                OverlayCompositor.composite(image: base, strokes: strokes, captions: []),
                quality: 1
            )
        }
        let line = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.5, y: 0.4), CGPoint(x: 0.8, y: 0.3)]
        let red = OverlayCompositor.Stroke(ink: .red, points: line)
        let blue = OverlayCompositor.Stroke(ink: .blue, points: line)
        let elsewhere = OverlayCompositor.Stroke(
            ink: .red, points: line.map { CGPoint(x: $0.x, y: $0.y + 0.4) }
        )

        #expect(try encoded([red]) != (try WebPEncoder.encode(base, quality: 1)))
        #expect(try encoded([red]) != (try encoded([blue])))
        #expect(try encoded([red]) != (try encoded([elsewhere])))
        // A tap is a dot, not nothing.
        let dot = OverlayCompositor.Stroke(ink: .white, points: [CGPoint(x: 0.5, y: 0.5)])
        #expect(try encoded([dot]) != (try WebPEncoder.encode(base, quality: 1)))
        // A line with no points leaves the photo as it was.
        let empty = OverlayCompositor.Stroke(ink: .white, points: [])
        #expect(try encoded([empty]) == (try WebPEncoder.encode(base, quality: 1)))
    }

    @Test("A line is sized and placed from the photo, not from the screen")
    func strokeScalesWithWidth() {
        #expect(OverlayCompositor.strokeWidth(forWidth: 1000) == 15)
        #expect(OverlayCompositor.strokeWidth(forWidth: 400) / 400 == 0.015)

        let stroke = OverlayCompositor.Stroke(
            ink: .white, points: [CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.75, y: 0.5)]
        )
        let small = OverlayCompositor.path(for: stroke, size: CGSize(width: 100, height: 200))
        let large = OverlayCompositor.path(for: stroke, size: CGSize(width: 1000, height: 2000))
        #expect(small.boundingBoxOfPath == CGRect(x: 25, y: 100, width: 50, height: 0))
        #expect(large.boundingBoxOfPath == CGRect(x: 250, y: 1000, width: 500, height: 0))
    }

    @Test("Long captions are truncated to the wire limit")
    func truncatesLongCaption() {
        let composited = OverlayCompositor.composite(
            image: photo(400, 400),
            captions: [OverlayCompositor.Caption(text: String(repeating: "a", count: 500))]
        )
        #expect(composited.size == CGSize(width: 400, height: 400))
    }
}

@MainActor
@Suite("Compose layout")
struct ComposeLayoutTests {
    /// The overlay is positioned against the image rect, not the container.
    /// Anchoring to the container puts the caption somewhere else once the photo
    /// is letterboxed, so what the sender framed is not what arrives.
    @Test("Finds where a scaledToFit image actually lands")
    func computesFittedRect() {
        let portrait = UIImage(
            cgImage: UIGraphicsImageRenderer(size: CGSize(width: 100, height: 200))
                .image { _ in }.cgImage!
        )
        let rect = ComposeScreen.fittedRect(
            image: portrait, in: CGSize(width: 400, height: 400)
        )
        #expect(rect.size == CGSize(width: 200, height: 400))
        #expect(rect.origin == CGPoint(x: 100, y: 0))

        let landscape = UIImage(
            cgImage: UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100))
                .image { _ in }.cgImage!
        )
        let wide = ComposeScreen.fittedRect(
            image: landscape, in: CGSize(width: 400, height: 400)
        )
        #expect(wide.size == CGSize(width: 400, height: 200))
        #expect(wide.origin == CGPoint(x: 0, y: 100))
    }
}

@MainActor
@Suite("Instant store")
struct InstantStoreTests {
    private func makeStore(
        api: FakeInstantAPI,
        socket: InboxSocketProtocol = StubSocket(),
        widgets: WidgetSnapshotPublishing = RecordingWidgetPublisher(),
        cache: InboxCaching = InMemoryInboxCache()
    ) -> InstantStore {
        InstantStore(
            api: api,
            identities: DeviceIdentityStore(
                keychain: InMemoryKeychain(),
                secureEnclaveAvailable: { false }
            ),
            widgets: widgets,
            cache: cache,
            makeSocket: { _ in socket }
        )
    }

    // MARK: Cache

    private static let cacheNow = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z

    /// A tapped notification lands on the inbox, and on a cold start that used
    /// to be "No conversations yet" for as long as three round trips took.
    @Test("A cold start draws the cached inbox before anything is fetched")
    func restoresFromCache() {
        let cache = InMemoryInboxCache(InboxCacheContents(
            userId: 1,
            instants: [.fixture(id: "waiting", expiresAt: "2026-01-02T00:00:00.000Z")],
            history: [.fixture(userId: 2)]
        ))
        let store = makeStore(api: FakeInstantAPI(), cache: cache)
        #expect(!store.hasLoaded)

        store.restore(userId: 1, now: Self.cacheNow)

        #expect(store.hasLoaded)
        #expect(store.instants.map(\.id) == ["waiting"])
        #expect(store.conversations.first?.hasPending == true)
    }

    @Test("An instant that expired while the app was closed is not restored")
    func restoreSkipsExpired() {
        let cache = InMemoryInboxCache(InboxCacheContents(
            userId: 1,
            instants: [
                .fixture(id: "gone", expiresAt: "2025-12-31T23:59:59.000Z"),
                .fixture(id: "live", expiresAt: "2026-01-01T00:00:01.000Z"),
            ],
            history: []
        ))
        let store = makeStore(api: FakeInstantAPI(), cache: cache)
        store.restore(userId: 1, now: Self.cacheNow)
        #expect(store.instants.map(\.id) == ["live"])
    }

    @Test("Another account's cached inbox is never shown")
    func restoreChecksAccount() {
        let cache = InMemoryInboxCache(InboxCacheContents(
            userId: 7, instants: [.fixture(id: "theirs")], history: [.fixture(userId: 2)]
        ))
        let store = makeStore(api: FakeInstantAPI(), cache: cache)
        store.restore(userId: 1, now: Self.cacheNow)
        #expect(store.instants.isEmpty)
        #expect(store.history.isEmpty)
        #expect(!store.hasLoaded)
    }

    /// Opened on another device, or swept, while this one was closed.
    @Test("The first drain drops cached instants the server no longer has")
    func drainReplacesCache() async {
        let cache = InMemoryInboxCache(InboxCacheContents(
            userId: 1,
            instants: [.fixture(id: "stale"), .fixture(id: "kept")],
            history: []
        ))
        let api = FakeInstantAPI()
        api.inboxPages = [[.fixture(id: "kept"), .fixture(id: "new")], [.fixture(id: "stale")]]
        let store = makeStore(api: api, cache: cache)
        store.restore(userId: 1, now: Self.cacheNow)

        await store.refreshInbox(deviceId: "d")
        #expect(store.instants.map(\.id) == ["kept", "new"])
        #expect(cache.contents?.instants.map(\.id) == ["kept", "new"], "the cache follows")

        // The inbox is paged, so a dropped id is allowed back when it turns up.
        await store.refreshInbox(deviceId: "d")
        #expect(store.instants.map(\.id).contains("stale"))
    }

    @Test("A drain that fails leaves the cached inbox alone")
    func failedDrainKeepsCache() async {
        let cache = InMemoryInboxCache(InboxCacheContents(
            userId: 1, instants: [.fixture(id: "cached")], history: []
        ))
        let api = FakeInstantAPI()
        api.inboxError = URLError(.notConnectedToInternet)
        let store = makeStore(api: api, cache: cache)
        store.restore(userId: 1, now: Self.cacheNow)

        await store.refreshInbox(deviceId: "d")
        #expect(store.instants.map(\.id) == ["cached"])
    }

    @Test("Changes are written to the cache, and signing out clears it")
    func writesAndClearsCache() async {
        let cache = InMemoryInboxCache()
        let api = FakeInstantAPI()
        api.conversationsResult = [.fixture(userId: 2)]
        let store = makeStore(api: api, cache: cache)
        await store.start(userId: 1)

        store.merge([.fixture(id: "a"), .fixture(id: "b")])
        store.dismiss("a")
        await store.refreshHistory()
        #expect(cache.contents?.userId == 1)
        #expect(cache.contents?.instants.map(\.id) == ["b"], "a viewed instant must not come back on relaunch")
        #expect(cache.contents?.history.map(\.userId) == [2])

        store.reset()
        #expect(cache.contents == nil)
        #expect(!store.hasLoaded)
    }

    /// Previously the inbox waited for registration, a socket ticket and the
    /// connect before it was fetched at all.
    @Test("With a cached inbox, start fetches without waiting for the socket")
    func startFetchesImmediately() async {
        let api = FakeInstantAPI()
        api.inboxPages = [[.fixture(id: "waiting")]]
        api.conversationsResult = [.fixture(userId: 2)]
        let cache = InMemoryInboxCache(InboxCacheContents(userId: 1, instants: [], history: []))
        let store = makeStore(api: api, cache: cache)  // StubSocket never asks for a drain
        store.restore(userId: 1)

        await store.start(userId: 1)
        for _ in 0..<100 where store.instants.isEmpty { await Task.yield() }

        #expect(store.instants.map(\.id) == ["waiting"])
    }

    /// Nothing is sealed to a device that has never registered, so fetching
    /// early would draw rows that claim something is waiting and cannot open it.
    @Test("A first launch waits for the socket's drain")
    func firstLaunchWaitsForDrain() async {
        let api = FakeInstantAPI()
        api.conversationsResult = [.fixture(userId: 2, unopenedCount: 1)]
        let store = makeStore(api: api)

        await store.start(userId: 1)
        for _ in 0..<100 { await Task.yield() }

        #expect(api.inboxCallCount == 0)
        #expect(api.conversationsCallCount == 0)
        #expect(!store.hasLoaded)
    }

    /// The startup fetch runs on its own, so it can outlive the account it was
    /// started for.
    @Test("A fetch that finishes after switching accounts is thrown away")
    func ignoresFetchForPreviousAccount() async {
        let api = FakeInstantAPI()
        let store = makeStore(api: api)
        await store.start(userId: 1)

        let (released, release) = AsyncStream<Void>.makeStream()
        api.conversationsResult = [.fixture(userId: 99, name: "Account one's friend")]
        api.conversationsGate = { for await _ in released { break } }
        let stale = Task { await store.refreshHistory() }
        for _ in 0..<20 { await Task.yield() }

        api.conversationsGate = nil
        api.conversationsResult = []
        await store.start(userId: 2)
        release.yield()
        await stale.value

        #expect(store.history.isEmpty)
    }

    @Test("Enrolls this device on start")
    func enrollsOnStart() async {
        let api = FakeInstantAPI()
        let store = makeStore(api: api)
        await store.start(userId: 1)

        #expect(api.registeredDevices.count == 1)
        #expect(store.device?.deviceId == api.registeredDevices.first?.0)
        #expect(store.enrollmentError == nil)
    }

    /// The inbox is drained on every connect, so the same instant arrives more
    /// than once by design. The dedup set is what stops it appearing twice.
    @Test("Merges without duplicating")
    func dedupesById() {
        let store = makeStore(api: FakeInstantAPI())
        let instant = InstantDelivery.fixture(id: "a")

        store.merge([instant])
        store.merge([instant])
        store.merge([instant, InstantDelivery.fixture(id: "b")])

        #expect(store.instants.map(\.id) == ["a", "b"])
    }

    /// A viewed instant must not reappear on the next drain — the server has no
    /// idea the client already dealt with it until the receipt lands.
    @Test("A dismissed instant does not come back")
    func dismissedStaysDismissed() {
        let store = makeStore(api: FakeInstantAPI())
        store.merge([InstantDelivery.fixture(id: "a")])
        store.dismiss("a")
        #expect(store.instants.isEmpty)

        store.merge([InstantDelivery.fixture(id: "a")])
        #expect(store.instants.isEmpty, "the seen-set is deliberately never pruned")
    }

    @Test("Keeps the list in send order")
    func sortsByCreatedAt() {
        let store = makeStore(api: FakeInstantAPI())
        store.merge([
            InstantDelivery.fixture(id: "late", createdAt: "2026-01-03T00:00:00.000Z"),
            InstantDelivery.fixture(id: "early", createdAt: "2026-01-01T00:00:00.000Z"),
        ])
        store.merge([InstantDelivery.fixture(id: "middle", createdAt: "2026-01-02T00:00:00.000Z")])

        #expect(store.instants.map(\.id) == ["early", "middle", "late"])
    }

    @Test("Drains the inbox when the socket asks")
    func drainsOnRequest() async {
        let api = FakeInstantAPI()
        api.inboxPages = [[InstantDelivery.fixture(id: "queued")]]
        api.conversationsResult = [.fixture(userId: 2, name: "Ana", streakCount: 3)]
        let store = makeStore(api: api)

        await store.handle(.shouldDrainInbox, deviceId: "d")

        #expect(store.instants.map(\.id) == ["queued"])
        #expect(store.streaks.first?.count == 3, "a live streak is derived from the history")
        #expect(store.history.first?.userId == 2)
    }

    @Test("A pushed instant lands in the list")
    func handlesPushedInstant() async {
        let api = FakeInstantAPI()
        let store = makeStore(api: api)
        await store.handle(.wire(.instant(InstantDelivery.fixture(id: "live"))), deviceId: "d")

        #expect(store.instants.map(\.id) == ["live"])
        #expect(api.conversationsCallCount == 1, "a new instant may have moved the conversation")
    }

    /// Without a Durable Object nothing is ever pushed, so the app has to poll
    /// or the inbox stays stale forever.
    @Test("Falls back to polling when realtime is unsupported")
    func pollsWhenUnsupported() async {
        let api = FakeInstantAPI()
        api.inboxPages = [[InstantDelivery.fixture(id: "polled")]]
        let store = makeStore(api: api)

        await store.handle(.state(.unsupported), deviceId: "d")

        #expect(store.connection == .unsupported)
        #expect(store.instants.map(\.id) == ["polled"])
    }

    @Test("Switching accounts wipes everything")
    func resetsBetweenAccounts() async {
        let api = FakeInstantAPI()
        let store = makeStore(api: api)
        await store.start(userId: 1)
        store.merge([InstantDelivery.fixture(id: "a")])
        let firstDevice = store.device?.deviceId

        await store.start(userId: 2)

        #expect(store.instants.isEmpty)
        // A different account must never inherit the first one's keypair.
        #expect(store.device?.deviceId != firstDevice)
    }

    @Test("Marks the session expired on a 403 rather than silently failing")
    func detectsExpiredSession() async {
        let api = FakeInstantAPI()
        api.inboxError = APIError(status: 403, message: "You are not logged in")
        let store = makeStore(api: api)
        await store.refreshInbox(deviceId: "d")
        #expect(store.sessionExpired)
    }

    // MARK: - Conversations

    @Test("Merges a person's waiting instants and their streak into one row")
    func mergesInstantsAndStreaks() {
        let store = makeStore(api: FakeInstantAPI())
        store.merge([InstantDelivery.fixture(id: "a", senderId: 2)])
        store.applyHistory([.fixture(userId: 2, name: "Ana", streakCount: 9)])

        #expect(store.conversations.count == 1, "one person, one row")
        let conversation = try! #require(store.conversations.first)
        #expect(conversation.userId == 2)
        #expect(conversation.pending?.id == "a")
        #expect(conversation.streak?.count == 9)
    }

    @Test("Shows people from history and people who only have an instant")
    func includesBothSources() {
        let store = makeStore(api: FakeInstantAPI())
        store.merge([InstantDelivery.fixture(id: "a", senderId: 2)])
        store.applyHistory([.fixture(userId: 5, name: "Bo", streakCount: 3)])

        #expect(Set(store.conversations.map(\.userId)) == [2, 5])
        #expect(store.conversations.first { $0.userId == 5 }?.hasPending == false)
    }

    /// The gap this endpoint closes: someone you talked to whose streak has
    /// lapsed, with nothing waiting, still has a conversation.
    @Test("A lapsed conversation with nothing waiting is still listed")
    func showsHistoryWithoutStreakOrInstants() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([.fixture(userId: 7, name: "Old Friend", streakCount: 0)])

        let conversation = try! #require(store.conversations.first)
        #expect(conversation.userId == 7)
        #expect(conversation.name == "Old Friend")
        #expect(conversation.streak == nil, "no streak to draw")
        #expect(conversation.hasPending == false)
    }

    /// An instant can arrive over the socket before the history refresh that
    /// would name the sender, so the row has to stand up on the delivery alone.
    @Test("A first-ever instant shows before history catches up")
    func handlesUnknownSender() {
        let store = makeStore(api: FakeInstantAPI())
        store.merge([InstantDelivery.fixture(id: "a", senderId: 42)])

        let conversation = try! #require(store.conversations.first)
        #expect(conversation.userId == 42)
        #expect(conversation.name == "Ana", "falls back to what the delivery carries")
        #expect(conversation.hasPending)
    }

    @Test("Counts multiple instants from one person and offers the oldest first")
    func groupsMultipleInstants() {
        let store = makeStore(api: FakeInstantAPI())
        store.merge([
            InstantDelivery.fixture(id: "first", senderId: 2, createdAt: "2026-01-01T00:00:00.000Z"),
            InstantDelivery.fixture(id: "second", senderId: 2, createdAt: "2026-01-02T00:00:00.000Z"),
        ])

        let conversation = try! #require(store.conversations.first)
        #expect(conversation.pendingCount == 2)
        // The oldest expires soonest, so it is the one to open.
        #expect(conversation.pending?.id == "first")
    }

    /// Waiting first, then a streak about to lapse, then simply whoever you
    /// spoke to most recently.
    @Test("Orders by what is time-sensitive, then by recency")
    func ordersByUrgency() {
        let store = makeStore(api: FakeInstantAPI())
        store.merge([InstantDelivery.fixture(id: "a", senderId: 3)])
        store.applyHistory([
            .fixture(userId: 3, name: "Cal", lastInteractionAt: "2026-01-01T00:00:00.000Z", streakCount: 1),
            .fixture(userId: 4, name: "Dee", lastInteractionAt: "2026-01-02T00:00:00.000Z", streakCount: 2, streakAtRisk: true),
            .fixture(userId: 5, name: "Eve", lastInteractionAt: "2026-01-09T00:00:00.000Z", streakCount: 0),
            .fixture(userId: 6, name: "Fay", lastInteractionAt: "2026-01-05T00:00:00.000Z", streakCount: 0),
        ])

        // Cal is waiting, Dee is about to lapse, then Eve and Fay by recency —
        // note Eve leads Fay despite neither having a streak at all.
        #expect(store.conversations.map(\.userId) == [3, 4, 5, 6])
    }

    @Test("Opening the last waiting instant leaves the person on the list")
    func keepsPersonAfterOpening() {
        let store = makeStore(api: FakeInstantAPI())
        store.merge([InstantDelivery.fixture(id: "a", senderId: 2)])
        store.applyHistory([.fixture(userId: 2, name: "Ana", streakCount: 4)])
        store.dismiss("a")

        // The conversation survives; only the "waiting" state goes away.
        #expect(store.conversations.map(\.userId) == [2])
        #expect(store.conversations.first?.hasPending == false)
    }

    // MARK: - Reply hints

    /// Opening somebody's photo is the moment a reply is most likely, so their
    /// row stops being inert and offers one.
    @Test("Opening an instant leaves the sender offering a reply")
    func suggestsReplyAfterOpening() {
        let store = makeStore(api: FakeInstantAPI())
        store.merge([InstantDelivery.fixture(id: "a", senderId: 2)])
        store.applyHistory([.fixture(userId: 2, name: "Ana", streakCount: 4)])
        #expect(store.conversations.first?.suggestsReply == false)

        store.dismiss("a")
        store.noteOpened(senderId: 2)

        let conversation = try! #require(store.conversations.first)
        #expect(conversation.suggestsReply)
        #expect(conversation.hasPending == false, "the prompt replaces the unread marker")
    }

    @Test("Sending one back answers the prompt")
    func sendingClearsTheReplyHint() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([.fixture(userId: 2, name: "Ana")])
        store.noteOpened(senderId: 2)
        #expect(store.conversations.first?.suggestsReply == true)

        store.noteSent(toUserId: 2)
        #expect(store.conversations.first?.suggestsReply == false)
    }

    /// Only the person whose instant was opened, and only for as long as this
    /// session: a prompt that outlived a sign-out would be somebody else's.
    @Test("A prompt belongs to one person and does not survive a reset")
    func replyHintsAreScoped() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([.fixture(userId: 2, name: "Ana"), .fixture(userId: 3, name: "Bo")])
        store.noteOpened(senderId: 2)

        #expect(store.conversations.first { $0.userId == 3 }?.suggestsReply == false)

        store.reset()
        store.applyHistory([.fixture(userId: 2, name: "Ana")])
        #expect(store.conversations.first?.suggestsReply == false)
    }

    /// Something new from the same person outranks the prompt: the row says one
    /// thing, and what is waiting is the more urgent of the two.
    @Test("A new instant from them still shows as waiting")
    func waitingOutranksTheReplyHint() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([.fixture(userId: 2, name: "Ana")])
        store.noteOpened(senderId: 2)
        store.merge([InstantDelivery.fixture(id: "b", senderId: 2)])

        #expect(store.conversations.first?.hasPending == true)
    }

    // MARK: - Recency

    /// Later than every fixture timestamp, so "after" is not a question of when
    /// the suite happens to run.
    private let afterwards = Date(timeIntervalSince1970: 1_800_000_000)

    /// Recency is about the conversation, not about one direction of it: a photo
    /// you have just sent is the most recent thing between you.
    @Test("Sending makes that person the most recent conversation")
    func sendingLeadsTheOrder() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([
            .fixture(userId: 2, name: "Ana", lastInteractionAt: "2026-01-09T00:00:00.000Z"),
            .fixture(userId: 3, name: "Bo", lastInteractionAt: "2026-01-01T00:00:00.000Z"),
        ])
        #expect(store.conversations.map(\.userId) == [2, 3])

        store.noteSent(toUserId: 3, at: afterwards)

        #expect(store.conversations.map(\.userId) == [3, 2], "the one just sent to leads")
    }

    /// The stamp is local, and the server's view of the same conversation can
    /// come back a moment behind. The later of the two marks wins, so a refresh
    /// cannot walk a send that has already happened backwards.
    @Test("A refresh that hasn't caught up does not undo a send")
    func staleHistoryKeepsTheSend() {
        let store = makeStore(api: FakeInstantAPI())
        let stale: [InstantConversationSummary] = [
            .fixture(userId: 2, name: "Ana", lastInteractionAt: "2026-01-09T00:00:00.000Z"),
            .fixture(userId: 3, name: "Bo", lastInteractionAt: "2026-01-01T00:00:00.000Z"),
        ]
        store.applyHistory(stale)
        store.noteSent(toUserId: 3, at: afterwards)

        store.applyHistory(stale)

        #expect(store.conversations.map(\.userId) == [3, 2])
        let bo = try! #require(store.history.first { $0.userId == 3 })
        #expect(bo.lastSentAt == WireTimestamp.string(from: afterwards))
        #expect(bo.lastInteractionAt == WireTimestamp.string(from: afterwards))
    }

    /// The receipt has to be there the moment the inbox is next looked at,
    /// which is usually before any refresh has come back. Nothing newer than
    /// this send can have been opened, so waiting is the only honest state.
    @Test("A send shows as waiting before the server has answered for it")
    func sendReadsAsWaitingAtOnce() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([.fixture(userId: 3, name: "Bo")])

        store.noteSent(toUserId: 3, at: afterwards)

        let receipt = try! #require(store.conversations.first?.sentReceipt)
        #expect(receipt.status(now: afterwards.addingTimeInterval(120)) == .waiting(since: afterwards))
        // Carrying the wire's own rule: unopened, it is swept 24 hours on.
        #expect(
            receipt.status(now: afterwards.addingTimeInterval(25 * 3600)) == .expiredUnopened,
            "the local receipt expires on the same schedule the server's would"
        )
    }

    /// Only the server can say a photo has been taken — the claim happens on
    /// somebody else's phone.
    @Test("The server's receipt replaces the local one once it catches up")
    func serverReceiptWinsOverTheLocalOne() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([.fixture(userId: 3, name: "Bo")])
        store.noteSent(toUserId: 3, at: afterwards)

        let opened = afterwards.addingTimeInterval(60)
        store.applyHistory([
            .fixture(
                userId: 3, name: "Bo",
                lastSentReceipt: InstantSendReceipt(
                    sentAt: WireTimestamp.string(from: afterwards),
                    openedAt: WireTimestamp.string(from: opened),
                    expiresAt: WireTimestamp.string(from: afterwards.addingTimeInterval(24 * 3600))
                )
            ),
        ])

        let receipt = try! #require(store.conversations.first?.sentReceipt)
        #expect(receipt.status(now: opened.addingTimeInterval(60)) == .opened(at: opened))
    }

    /// The rows for people who have something waiting are rebuilt from the
    /// inbox rather than from the history, and used to drop everything the
    /// history knew that the delivery does not carry.
    @Test("An arriving instant does not wipe the receipt on that row")
    func receiptSurvivesAnArrival() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([
            .fixture(
                userId: 2, name: "Ana",
                lastSentReceipt: InstantSendReceipt(
                    sentAt: "2026-01-01T00:00:00.000Z",
                    openedAt: "2026-01-01T00:01:00.000Z",
                    expiresAt: "2026-01-02T00:00:00.000Z"
                )
            ),
        ])

        store.merge([.fixture(id: "a", senderId: 2)])

        #expect(store.conversations.first?.sentReceipt?.openedAt == "2026-01-01T00:01:00.000Z")
    }

    /// The picker's "Recent" section reads the same history, so a send has to
    /// move somebody there too.
    @Test("The send shows up in the history the recipient picker reads")
    func historyCarriesTheSend() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([.fixture(userId: 3, name: "Bo", lastInteractionAt: "2026-01-01T00:00:00.000Z")])
        store.noteSent(toUserId: 3, at: afterwards)

        let ordered = SendToModel.ordered(
            [
                UserSummary(id: 2, name: "Ana", themeKey: "rose", profilePictureUrl: nil),
                UserSummary(id: 3, name: "Bo", themeKey: "forest", profilePictureUrl: nil),
            ],
            history: store.history
        )
        #expect(ordered.map(\.id) == [3, 2])
    }

    /// A streak lapses on whichever side went quiet first. One waiting on them
    /// is not something the reader can act on, so it neither nags nor outranks
    /// somebody they have just sent to.
    @Test("A streak waiting on them does not jump the queue")
    func onlyYourOwnMoveIsUrgent() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([
            // You sent an hour ago, they went quiet a day ago: their move.
            .fixture(
                userId: 2, name: "Ana",
                lastInteractionAt: "2026-01-09T00:00:00.000Z",
                lastSentAt: "2026-01-09T00:00:00.000Z",
                lastReceivedAt: "2026-01-08T00:00:00.000Z",
                streakCount: 9, streakAtRisk: true
            ),
            // The other way round: yours to keep alive.
            .fixture(
                userId: 3, name: "Bo",
                lastInteractionAt: "2026-01-07T00:00:00.000Z",
                lastSentAt: "2026-01-06T00:00:00.000Z",
                lastReceivedAt: "2026-01-07T00:00:00.000Z",
                streakCount: 4, streakAtRisk: true
            ),
        ])

        let ana = try! #require(store.conversations.first { $0.userId == 2 })
        let bo = try! #require(store.conversations.first { $0.userId == 3 })
        #expect(ana.streakNeedsYourSend == false, "already sent: nothing to nag about")
        #expect(bo.streakNeedsYourSend)
        #expect(store.conversations.map(\.userId) == [3, 2], "the one waiting on you leads")
    }

    @Test("Sending settles a streak that was waiting on you")
    func sendingSettlesTheStreak() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([.fixture(
            userId: 3, name: "Bo",
            lastInteractionAt: "2026-01-07T00:00:00.000Z",
            lastSentAt: "2026-01-06T00:00:00.000Z",
            lastReceivedAt: "2026-01-07T00:00:00.000Z",
            streakCount: 4, streakAtRisk: true
        )])
        #expect(store.conversations.first?.streakNeedsYourSend == true)

        store.noteSent(toUserId: 3, at: afterwards)

        #expect(store.conversations.first?.streakNeedsYourSend == false)
        #expect(store.conversations.first?.streak?.atRisk == true, "the streak is still at risk")
    }

    /// Never sent, and the streak is about to lapse: there is nobody else it
    /// could be waiting on.
    @Test("A streak with nothing sent from here is yours to answer")
    func noSendMeansYourMove() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([.fixture(userId: 3, name: "Bo", streakCount: 4, streakAtRisk: true)])
        #expect(store.conversations.first?.streakNeedsYourSend == true)
    }

    @Test("Signing out forgets what was sent")
    func resetClearsSends() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([.fixture(userId: 3, name: "Bo", lastInteractionAt: "2026-01-01T00:00:00.000Z")])
        store.noteSent(toUserId: 3, at: afterwards)
        store.reset()

        store.applyHistory([.fixture(userId: 3, name: "Bo", lastInteractionAt: "2026-01-01T00:00:00.000Z")])
        #expect(store.history.first?.lastInteractionAt == "2026-01-01T00:00:00.000Z")
    }

    // MARK: - Widget

    /// The widget shows who is waiting, so only people with something unopened
    /// belong in the snapshot.
    @Test("The snapshot holds only people with something waiting")
    func snapshotHoldsOnlyWaiting() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([
            .fixture(userId: 2, name: "Ana", unopenedCount: 1, streakCount: 9),
            .fixture(userId: 3, name: "Bo", unopenedCount: 0, streakCount: 4),
        ])

        let snapshot = store.makeWidgetSnapshot()
        #expect(snapshot.contacts.map(\.userId) == [2])
        #expect(snapshot.contacts.first?.name == "Ana")
        #expect(snapshot.contacts.first?.streakCount == 9)
        #expect(snapshot.contacts.first?.themeKey == "rose")
    }

    /// Neither count is reliably ahead: the local list is behind before the
    /// first drain, and the server's is behind an instant that just arrived.
    @Test("Takes the larger of the local and server counts")
    func snapshotTakesLargerCount() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([.fixture(userId: 2, name: "Ana", unopenedCount: 3)])
        store.merge([InstantDelivery.fixture(id: "a", senderId: 2)])

        #expect(store.makeWidgetSnapshot().contacts.first?.unopenedCount == 3)

        store.applyHistory([.fixture(userId: 2, name: "Ana", unopenedCount: 0)])
        #expect(
            store.makeWidgetSnapshot().contacts.first?.unopenedCount == 1,
            "a socket delivery the server has not caught up on still counts"
        )
    }

    /// Over-reporting is the worse failure: it sends you into the app to find
    /// nothing there.
    @Test("Opening an instant stops the widget claiming it is still waiting")
    func dismissDropsTheStaleServerCount() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([.fixture(userId: 2, name: "Ana", unopenedCount: 1)])
        store.merge([InstantDelivery.fixture(id: "a", senderId: 2)])
        #expect(store.makeWidgetSnapshot().contacts.first?.unopenedCount == 1)

        store.dismiss("a")

        #expect(store.makeWidgetSnapshot().isEmpty, "the server's count is stale by one until it refreshes")
        #expect(store.history.first?.unopenedCount == 0)
    }

    @Test("Dismissing one of several leaves the rest waiting")
    func dismissDecrementsByOne() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([.fixture(userId: 2, name: "Ana", unopenedCount: 3)])
        store.merge([
            InstantDelivery.fixture(id: "a", senderId: 2, createdAt: "2026-01-01T00:00:00.000Z"),
            InstantDelivery.fixture(id: "b", senderId: 2, createdAt: "2026-01-02T00:00:00.000Z"),
        ])

        store.dismiss("a")

        #expect(store.makeWidgetSnapshot().contacts.first?.unopenedCount == 2)
    }

    @Test("A lapsed streak reports zero rather than being hidden")
    func snapshotIncludesLapsedStreak() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([.fixture(userId: 2, unopenedCount: 1, streakCount: 0)])
        #expect(store.makeWidgetSnapshot().contacts.first?.streakCount == 0)
        #expect(store.makeWidgetSnapshot().contacts.first?.hasStreak == false)
    }

    @Test("Snapshot order follows the inbox order")
    func snapshotFollowsInboxOrder() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([
            .fixture(userId: 2, name: "Ana", lastInteractionAt: "2026-01-01T00:00:00.000Z", unopenedCount: 1),
            .fixture(userId: 3, name: "Bo", lastInteractionAt: "2026-01-05T00:00:00.000Z", unopenedCount: 1),
        ])
        #expect(store.makeWidgetSnapshot().contacts.map(\.userId) == [3, 2])
    }

    @Test("Publishes when an instant arrives and when one is dismissed")
    func publishesOnChange() async {
        let publisher = RecordingWidgetPublisher()
        let store = makeStore(api: FakeInstantAPI(), widgets: publisher)
        store.applyHistory([.fixture(userId: 2, name: "Ana", unopenedCount: 1)])

        store.merge([InstantDelivery.fixture(id: "a", senderId: 2)])
        #expect(await eventually { publisher.latest?.contacts.map(\.userId) == [2] })

        store.dismiss("a")
        #expect(await eventually { publisher.snapshots.count >= 2 })
        #expect(
            await eventually { publisher.latest?.contacts.isEmpty == true },
            "dismissing the last one empties the widget"
        )
    }

    /// Signing out must not leave a stranger's name on someone's home screen.
    @Test("Clears the widget on reset")
    func clearsOnReset() async {
        let publisher = RecordingWidgetPublisher()
        let store = makeStore(api: FakeInstantAPI(), widgets: publisher)
        store.reset()
        #expect(await eventually { publisher.clearCount >= 1 })
    }

    @Test("Unread count tracks the waiting list")
    func tracksUnreadCount() {
        let store = makeStore(api: FakeInstantAPI())
        #expect(store.unreadCount == 0)
        store.merge([InstantDelivery.fixture(id: "a"), InstantDelivery.fixture(id: "b")])
        #expect(store.unreadCount == 2)
        store.dismiss("a")
        #expect(store.unreadCount == 1)
    }
}

@Suite("Send receipts")
struct SendReceiptTests {
    private let sentAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func receipt(openedAfter seconds: TimeInterval? = nil) -> InstantSendReceipt {
        InstantSendReceipt(
            sentAt: WireTimestamp.string(from: sentAt),
            openedAt: seconds.map { WireTimestamp.string(from: sentAt.addingTimeInterval($0)) },
            expiresAt: WireTimestamp.string(from: sentAt.addingTimeInterval(24 * 3600))
        )
    }

    @Test("A photo nobody has opened yet reports when it went")
    func waiting() {
        #expect(
            receipt().status(now: sentAt.addingTimeInterval(600)) == .waiting(since: sentAt)
        )
    }

    @Test("An opened one reports when it was taken, not when it was sent")
    func opened() {
        let openedAt = sentAt.addingTimeInterval(300)
        #expect(
            receipt(openedAfter: 300).status(now: sentAt.addingTimeInterval(3600))
                == .opened(at: openedAt)
        )
    }

    /// The most informative of the three: they never looked, and now they
    /// cannot. It is why the window outlives the photo by a day.
    @Test("One that ran out of its 24 hours says nobody opened it")
    func expiredUnopened() {
        #expect(receipt().status(now: sentAt.addingTimeInterval(25 * 3600)) == .expiredUnopened)
    }

    @Test("An opened one stays opened after the photo's own expiry")
    func openedOutlivesTheExpiry() {
        let openedAt = sentAt.addingTimeInterval(300)
        #expect(
            receipt(openedAfter: 300).status(now: sentAt.addingTimeInterval(30 * 3600))
                == .opened(at: openedAt)
        )
    }

    /// Past the window there is nothing left to say, and a row saying it anyway
    /// would be reporting on a photo nobody is thinking about any more. This is
    /// also what stops a send this client recorded locally, and that the server
    /// has since stopped reporting, from sitting on a row for good.
    @Test("Nothing is said about a send older than the window")
    func tooOldToMention() {
        #expect(receipt().status(now: sentAt.addingTimeInterval(49 * 3600)) == nil)
        #expect(receipt(openedAfter: 60).status(now: sentAt.addingTimeInterval(49 * 3600)) == nil)
    }

    @Test("A clock a little behind the server's does not report the future")
    func skewedClock() {
        #expect(receipt().status(now: sentAt.addingTimeInterval(-5)) == .waiting(since: sentAt))
    }
}

@Suite("Relative time")
struct RelativeTimeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func short(_ secondsAgo: TimeInterval) -> String {
        RelativeTime.short(since: now.addingTimeInterval(-secondsAgo), now: now)
    }

    /// The one `RelativeDateTimeFormatter` spells worst, and the one most
    /// often read: a photo sent four seconds ago.
    @Test("Under a minute is just now, not zero of anything")
    func floorIsJustNow() {
        #expect(short(0) == "just now")
        #expect(short(4) == "just now")
        #expect(short(59) == "just now")
    }

    @Test("Units are floored, so the phrase is never ahead of the clock")
    func floorsRatherThanRounds() {
        #expect(short(60) == "1m ago")
        #expect(short(119) == "1m ago")
        #expect(short(3599) == "59m ago")
        #expect(short(3600) == "1h ago")
        #expect(short(86_399) == "23h ago")
        #expect(short(86_400) == "1d ago")
    }

    @Test("A time in the future reads as just now rather than counting up")
    func neverNegative() {
        #expect(RelativeTime.short(since: now.addingTimeInterval(60), now: now) == "just now")
    }

    /// VoiceOver reads "3m ago" as a letter, so the spoken form spells the unit
    /// and agrees with the written one about the number.
    @Test("The spoken form spells the unit and singularises one of them")
    func spokenForm() {
        let spoken = { (secondsAgo: TimeInterval) in
            RelativeTime.spoken(since: now.addingTimeInterval(-secondsAgo), now: now)
        }
        #expect(spoken(30) == "just now")
        #expect(spoken(60) == "1 minute ago")
        #expect(spoken(180) == "3 minutes ago")
        #expect(spoken(3600) == "1 hour ago")
        #expect(spoken(7200) == "2 hours ago")
        #expect(spoken(86_400) == "1 day ago")
        #expect(spoken(172_800) == "2 days ago")
    }
}

/// A socket that connects to nothing; store tests drive events directly.
final class StubSocket: InboxSocketProtocol, @unchecked Sendable {
    let events: AsyncStream<InboxSocketEvent>
    private let continuation: AsyncStream<InboxSocketEvent>.Continuation
    private(set) var startedDeviceIds: [String] = []

    init() {
        (events, continuation) = AsyncStream<InboxSocketEvent>.makeStream()
    }

    func start(deviceId: String) { startedDeviceIds.append(deviceId) }
    func stop() { continuation.finish() }
}

/// Records what the registrar asks the system to do.
@MainActor
final class RecordingAuthorizer: NotificationAuthorizing {
    var requestedOptions: [UNAuthorizationOptions] = []
    var registeredForRemote = 0
    var delegateSet = false
    var grant = true
    var failure: Error?

    func setDelegate(_ delegate: UNUserNotificationCenterDelegate?) {
        delegateSet = delegate != nil
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestedOptions.append(options)
        if let failure { throw failure }
        return grant
    }

    func registerForRemoteNotifications() { registeredForRemote += 1 }
}

@MainActor
@Suite("Push authorization")
struct PushAuthorizationTests {
    private func registrar(_ authorizer: RecordingAuthorizer) -> PushRegistrar {
        PushRegistrar(userAPI: FakeUserAPI(), notifications: authorizer) { _ in }
    }

    /// The regression this exists for: an `#if INSTANT_PUSH` that was defined in
    /// no build configuration compiled the prompt out of every build, so the app
    /// could never ask. Nothing caught it because the call went straight to the
    /// system.
    @Test("Actually asks for permission")
    func asksForPermission() async {
        let authorizer = RecordingAuthorizer()
        await registrar(authorizer).requestAuthorizationAndRegister()

        #expect(authorizer.requestedOptions.count == 1, "the prompt must be requested")
        #expect(authorizer.requestedOptions.first?.contains(.alert) == true)
        #expect(authorizer.requestedOptions.first?.contains(.sound) == true)
        #expect(authorizer.requestedOptions.first?.contains(.badge) == true)
    }

    @Test("Registers for a token once permission is given")
    func registersWhenGranted() async {
        let authorizer = RecordingAuthorizer()
        authorizer.grant = true
        await registrar(authorizer).requestAuthorizationAndRegister()
        #expect(authorizer.registeredForRemote == 1)
    }

    /// Registering without permission would ask APNs for a token the user has
    /// refused to let us use.
    @Test("Does not register when permission is refused")
    func skipsRegistrationWhenDenied() async {
        let authorizer = RecordingAuthorizer()
        authorizer.grant = false
        await registrar(authorizer).requestAuthorizationAndRegister()
        #expect(authorizer.requestedOptions.count == 1)
        #expect(authorizer.registeredForRemote == 0)
    }

    @Test("A failed request is not treated as consent")
    func treatsFailureAsDenied() async {
        let authorizer = RecordingAuthorizer()
        authorizer.failure = NSError(domain: "test", code: 1)
        await registrar(authorizer).requestAuthorizationAndRegister()
        #expect(authorizer.registeredForRemote == 0)
    }

    /// Without a delegate a tapped notification opens the app but never routes
    /// to the instant it names — and on a cold start the tap is dropped
    /// outright, leaving the app on the camera.
    @Test("Observing taps sets the notification delegate")
    func setsDelegate() async {
        let authorizer = RecordingAuthorizer()
        registrar(authorizer).observeTaps()
        #expect(authorizer.delegateSet)
    }

    /// The regression that made a cold-start tap land on the camera: the
    /// delegate was only set on the way through the permission prompt, which
    /// happens several awaits after launch. Listening has to stand on its own.
    @Test("Listening for taps does not depend on the permission prompt")
    func observesTapsWithoutPrompting() async {
        let authorizer = RecordingAuthorizer()
        registrar(authorizer).observeTaps()
        #expect(authorizer.requestedOptions.isEmpty)
        #expect(authorizer.registeredForRemote == 0)
    }
}

@Suite("Push registration")
struct PushRegistrarTests {
    /// APNs tokens are hex; getting the formatting wrong produces a token Apple
    /// rejects with a status the app never sees.
    @Test("Formats the device token as lowercase hex")
    func formatsToken() {
        #expect(PushRegistrar.hexToken(from: Data([0x00, 0x0F, 0xA0, 0xFF])) == "000fa0ff")
        #expect(PushRegistrar.hexToken(from: Data()) == "")
        #expect(PushRegistrar.hexToken(from: Data(repeating: 0xAB, count: 32)).count == 64)
    }

    @Test("Reads the instant id out of the payload")
    func extractsInstantId() {
        let payload: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Ana sent you an instant"]],
            "data": ["openUrl": "/instant", "instantId": "abc-123"],
        ]
        #expect(PushRegistrar.instantId(from: payload) == "abc-123")
    }

    @Test("A streak warning carries no instant, and that is fine")
    func toleratesMissingInstantId() {
        #expect(PushRegistrar.instantId(from: ["data": ["streakCount": 12]]) == nil)
        #expect(PushRegistrar.instantId(from: [:]) == nil)
    }
}

@Suite("Theme")
struct ThemeTests {
    @Test("Covers the eight Lounge themes")
    func hasAllThemes() {
        #expect(ThemePalette.all.count == 8)
        #expect(Set(ThemePalette.all.map(\.key)) == [
            "boring-grey", "sunset", "purple", "forest", "ocean", "rose", "indigo", "gold",
        ])
    }

    @Test("An unknown or missing theme falls back rather than failing")
    func fallsBack() {
        #expect(ThemePalette.palette(for: nil).key == "boring-grey")
        #expect(ThemePalette.palette(for: "not-a-theme").key == "boring-grey")
        #expect(ThemePalette.palette(for: "ocean").key == "ocean")
    }
}
