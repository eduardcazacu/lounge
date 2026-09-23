import AVFoundation
import Foundation
import Testing
import UIKit
@testable import Instant

// MARK: - Helpers

/// Vertical stripes, each a different colour, so where a column went can be
/// read off the colour it arrived with.
@MainActor
private func stripes(width: CGFloat = 180, height: CGFloat = 320) -> UIImage {
    let format = UIGraphicsImageRendererFormat.preferred()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
        let band: CGFloat = 6
        var x: CGFloat = 0
        var index = 0
        while x < width {
            UIColor(hue: CGFloat(index % 17) / 17, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
            context.fill(CGRect(x: x, y: 0, width: band, height: height))
            x += band
            index += 1
        }
    }
}

/// A near disc in the middle of a far scene, at a sensor's sort of resolution.
private func disc(width: Int = 36, height: Int = 64, radius: Double = 0.3) -> DepthMap {
    let values = (0..<(width * height)).map { index -> Float in
        let x = (Double(index % width) + 0.5) / Double(width) - 0.5
        let y = ((Double(index / width) + 0.5) / Double(height) - 0.5) * Double(height) / Double(width)
        return x * x + y * y < radius * radius ? 1 : 0
    }
    return DepthMap(width: width, height: height, values: values)
}

/// The renderer with a known depth, so compose's tests do not run the network.
private let fromDisc: @Sendable (UIImage) async throws -> RecordedClip = { photo in
    try await ParallaxRenderer.makeClip(photo: photo, depth: disc())
}

/// Every row the same: `values` for the pixels, `depth` for their disparity.
private func rows(_ values: [UInt32], depth: [Float], count: Int = 5) -> (Bitmap, [Float]) {
    let bitmap = Bitmap(
        width: values.count,
        height: count,
        pixels: Array((0..<count).map { _ in values }.joined())
    )
    return (bitmap, Array((0..<count).map { _ in depth }.joined()))
}

private func pixels(of image: CGImage) throws -> [UInt32] {
    try Bitmap(UIImage(cgImage: image), longEdge: .greatestFiniteMagnitude).pixels
}

@Suite("3D", .serialized)
struct ParallaxSuites {

    // MARK: - The sequence

    @Suite("The wiggle's order and timing")
    struct SequenceTests {
        @Test("1-2-3-4-3-2, eight times, a tenth of a second a view")
        func sequence() {
            let cycle = [0, 1, 2, 3, 2, 1]
            #expect(ParallaxRenderer.sequence == Array((0..<8).map { _ in cycle }.joined()))
            #expect(abs(ParallaxRenderer.duration - 4.8) < 0.001)
            #expect(ParallaxRenderer.duration <= VideoPipeline.maximumDuration)
            #expect(Double(ParallaxRenderer.framesPerView) / Double(ParallaxRenderer.frameRate) == 0.1)
        }

        /// A clip ending on the first view would show it twice at every loop.
        @Test("It ends one step away from where it starts, so the loop is seamless")
        func loopSeam() throws {
            let first = try #require(ParallaxRenderer.sequence.first)
            let last = try #require(ParallaxRenderer.sequence.last)
            #expect(first == 0)
            #expect(last == 1, "the wrap from the last frame to the first is one ordinary step")
            for (a, b) in zip(ParallaxRenderer.sequence, ParallaxRenderer.sequence.dropFirst()) {
                #expect(abs(a - b) == 1, "never a jump, never a repeat")
            }
        }
    }

    // MARK: - The warp

    @Suite("Moving the viewpoint")
    struct WarpTests {
        @Test("The subject stays still and the background moves")
        func keyPlaneStill() {
            // Far on the left and right, near in the middle, subject is near.
            let values = (0..<60).map { UInt32(1000 + $0) }
            let depth = (0..<60).map { (20..<40).contains($0) ? Float(1) : 0 }
            let (source, disparity) = rows(values, depth: depth)
            let view = ParallaxRenderer.warp(source, disparity: disparity, key: 1, shift: 5)
            let row = Array(view.pixels[(2 * 60)..<(3 * 60)])
            for x in 20..<40 {
                #expect(row[x] == values[x], "the subject did not move")
            }
            // Far pixels move right by five, until the subject covers them.
            #expect(row[10] == values[5])
            #expect(row[50] == values[45])
        }

        @Test("Nearer than the subject moves the other way from farther")
        func oppositeDirections() {
            let values = (0..<60).map { UInt32(1000 + $0) }
            let depth = (0..<60).map { $0 < 30 ? Float(1) : 0 }
            let (source, disparity) = rows(values, depth: depth)
            let view = ParallaxRenderer.warp(source, disparity: disparity, key: 0.5, shift: 8)
            let row = Array(view.pixels[(2 * 60)..<(3 * 60)])
            #expect(row[6] == values[10], "near moved left by four")
            #expect(row[48] == values[44], "far moved right by four")
        }

        @Test("An uncovered gap is filled from the background, never from the subject")
        func fillsFromBehind() {
            let far = (0..<80).map { UInt32(1000 + $0) }
            let values = (0..<80).map { (30..<50).contains($0) ? UInt32(5000 + $0) : far[$0] }
            let depth = (0..<80).map { (30..<50).contains($0) ? Float(1) : 0 }
            let (source, disparity) = rows(values, depth: depth)
            let view = ParallaxRenderer.warp(source, disparity: disparity, key: 1, shift: 10)
            let row = Array(view.pixels[(2 * 80)..<(3 * 80)])
            // Right of the subject the wall moved away, leaving 50..<60 bare.
            for x in 50..<60 {
                #expect(row[x] < 5000, "column \(x) was filled from the subject")
                #expect(row[x] != 0, "column \(x) was left empty")
            }
            #expect(!row.contains(0), "nothing is left unfilled")
        }
    }

    @Suite("The subject's outline")
    struct OutlineTests {
        /// A soft edge's last pixel is subject-coloured but was given the
        /// wall's depth. Carried with the wall, it is a copy of the outline
        /// floating ten pixels off the subject.
        @Test("Background beside the subject is refilled, not carried off with the subject's colour on it")
        func noGhostOutline() {
            let width = 200
            let values = (0..<width).map { x -> UInt32 in (60..<100).contains(x) || x == 100 ? UInt32(5000 + x) : UInt32(1000 + x) }
            let depth = (0..<width).map { (60..<100).contains($0) ? Float(1) : 0 }
            let (source, disparity) = rows(values, depth: depth, count: 9)
            let dropped = ParallaxRenderer.besideNearer(disparity, width: width, height: 9)
            #expect(dropped[4 * width + 100], "the rim pixel on the wall side is not trusted")
            #expect(!dropped[4 * width + 80], "the subject itself is")
            #expect(!dropped[4 * width + 150], "and so is the wall away from it")

            let view = ParallaxRenderer.warp(source, disparity: disparity, key: 1, shift: 10, dropping: dropped)
            let row = Array(view.pixels[(4 * width)..<(5 * width)])
            for x in 100..<width {
                #expect(row[x] < 5000, "column \(x) carries the subject's colour")
            }
            #expect(!row.contains(0))
        }
    }

    @Suite("Enlarging the near layers")
    struct EnlargeTests {
        /// A 200×200 square picture: wall (1000s) with a near square of
        /// subject (5000s) at the given place.
        private func scene(subject: Range<Int>, rows: Range<Int>) -> (Bitmap, [Float]) {
            let size = 200
            var pixels = [UInt32](), depth = [Float]()
            for y in 0..<size {
                for x in 0..<size {
                    let inside = subject.contains(x) && rows.contains(y)
                    pixels.append(inside ? 0x0000_FF00 : 0x00FF_0000)
                    depth.append(inside ? 1 : 0)
                }
            }
            return (Bitmap(width: size, height: size, pixels: pixels), depth)
        }

        @Test("Nearer layers grow more; the background not at all")
        func growthByJump() {
            // A wall, a block a little in front of it, and one right up close.
            let size = 200
            var disparity = [Float](repeating: 0, count: size * size)
            for y in 70..<130 {
                for x in 20..<80 { disparity[y * size + x] = 0.4 }
                for x in 120..<180 { disparity[y * size + x] = 1 }
            }
            let (labels, _, growths) = ParallaxRenderer.growingLayers(disparity, width: size, height: size)
            let middle = labels[100 * size + 50], near = labels[100 * size + 150]
            #expect(labels[5 * size + 5] == -1, "the wall does not grow")
            #expect(middle >= 0 && near >= 0)
            guard middle >= 0, near >= 0 else { return }
            #expect(growths[Int(near)] > growths[Int(middle)], "the nearer block grows more")
            #expect(growths[Int(middle)] > 0)
            #expect(abs(growths[Int(near)] - ParallaxRenderer.maxGrowth) < 0.001)
        }

        @Test("The subject grows over the wall beside it, in place")
        func subjectGrows() {
            let (source, disparity) = scene(subject: 30..<170, rows: 30..<170)
            let (grown, depth) = ParallaxRenderer.enlarged(source, disparity: disparity)
            // Standing a whole unit in front of the wall, it grows by the
            // most: 8% of the 70 pixels from its middle to its edge is 5.6.
            for (x, y) in [(28, 100), (171, 100), (100, 28), (100, 171)] {
                #expect(grown.pixels[y * 200 + x] == 0x0000_FF00, "(\(x), \(y)) is subject now")
                #expect(depth[y * 200 + x] == 1)
            }
            #expect(grown.pixels[100 * 200 + 100] == 0x0000_FF00, "the middle stays the middle")
            #expect(grown.pixels[5 * 200 + 5] == 0x00FF_0000, "the far wall does not grow")
            #expect(depth.allSatisfy { $0 >= 0 }, "nothing left unfilled")
        }

        /// Grown about the subject's middle, a block at the left would be
        /// pushed three pixels further left, uncovering wall along its right
        /// side. Grown about its own, its right side does not recede.
        @Test("A near thing off to one side grows in place rather than drifting")
        func offCentre() {
            var (source, disparity) = scene(subject: 80..<120, rows: 80..<120)
            for y in 80..<120 {
                for x in 10..<40 {
                    source.pixels[y * 200 + x] = 0x0000_FF00
                    disparity[y * 200 + x] = 1
                }
            }
            let (grown, depth) = ParallaxRenderer.enlarged(source, disparity: disparity)
            #expect(grown.pixels[100 * 200 + 38] == 0x0000_FF00, "the block's inner side is where it was")
            #expect(grown.pixels[100 * 200 + 11] == 0x0000_FF00, "and so is its outer side")
            #expect(depth.allSatisfy { $0 >= 0 })
            #expect(!grown.pixels.contains(0), "nothing was uncovered")
        }

        @Test("A floor running from the subject into the distance does not grow")
        func surfacesStay() {
            // Nearer towards the bottom, smoothly: no outline anywhere.
            let size = 200
            let pixels = (0..<(size * size)).map { UInt32(0x0001_0000 * ($0 / size % 256)) }
            let disparity = (0..<(size * size)).map { Float($0 / size) / Float(size - 1) }
            let source = Bitmap(width: size, height: size, pixels: pixels)
            let (grown, depth) = ParallaxRenderer.enlarged(source, disparity: disparity)
            #expect(grown.pixels == source.pixels)
            #expect(depth == disparity)
        }

        @Test("The background keeps its size")
        func backgroundStill() {
            let (source, disparity) = scene(subject: 80..<120, rows: 80..<120)
            let (grown, _) = ParallaxRenderer.enlarged(source, disparity: disparity)
            for (x, y) in [(5, 5), (190, 20), (30, 180), (75, 100)] {
                #expect(grown.pixels[y * 200 + x] == source.pixels[y * 200 + x])
            }
        }
    }

    // MARK: - The views

    @MainActor
    @Suite("Rendering the four views")
    struct ViewTests {
        @Test("Four views, the photo's size, the subject still and the rest moving")
        func fourViews() throws {
            let photo = stripes()
            let views = try ParallaxRenderer.renderViews(photo: photo, depth: disc())
            #expect(views.count == 4)
            for view in views {
                #expect(view.width == 180 && view.height == 320)
            }
            let first = try pixels(of: views[0])
            let last = try pixels(of: views[3])
            let centre = 160 * 180 + 90
            #expect(first[centre] == last[centre], "the subject is in the same place in every view")
            let edge = 30 * 180 + 20
            #expect(first[edge] != last[edge], "the background swung between the outer views")
        }

        /// The bilinear fallback is silent by design, so this is the only
        /// thing that notices Core Image has stopped doing the upsample.
        @Test("Depth is upsampled along the photo's edges, not just stretched")
        func edgePreservingUpsample() throws {
            let source = try Bitmap(stripes(), longEdge: 1920)
            let depth = disc()
            let upsampled = ParallaxRenderer.upsampled(depth, toMatch: source)
            #expect(upsampled.count == 180 * 320)
            #expect(upsampled != ParallaxRenderer.stretched(depth, width: 180, height: 320))
            #expect(upsampled[160 * 180 + 90] > 0.9, "the middle of the disc is still near")
            #expect(upsampled[5 * 180 + 5] < 0.1, "the corner is still far")
        }

        @Test("A flat scene does not move at all")
        func flatScene() throws {
            let flat = DepthMap(width: 9, height: 16, values: [Float](repeating: 0, count: 144))
            let views = try ParallaxRenderer.renderViews(photo: stripes(), depth: flat)
            #expect(try pixels(of: views[0]) == pixels(of: views[3]))
        }

        @Test("It makes a silent clip of exactly 4.8 seconds, the photo's size")
        func makesClip() async throws {
            let clip = try await ParallaxRenderer.makeClip(photo: stripes(width: 90, height: 160), depth: disc())
            defer { CaptureScratch.remove(clip.url) }
            #expect(clip.size == CGSize(width: 90, height: 160))
            #expect(abs(clip.duration - 4.8) < 0.02)
            let asset = AVURLAsset(url: clip.url)
            #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        }
    }

    // MARK: - Depth

    @MainActor
    @Suite("Estimating depth", .serialized)
    struct DepthTests {
        @Test("Outliers do not squash the scene, and anything not finite reads as far")
        func normalizes() throws {
            var raw = (0..<100).map { Float($0) }
            raw[99] = 10_000
            raw[0] = .nan
            let map = try #require(DepthMap.normalized(width: 10, height: 10, raw: raw))
            #expect(map.values[0] == 0, "a hole is far")
            #expect(map.values[50] > 0.4 && map.values[50] < 0.6, "the middle of the scene stays in the middle")
            #expect(map.values.allSatisfy { $0 >= 0 && $0 <= 1 })
        }

        @Test("A portrait photo is fitted upright into the model's landscape input")
        func letterbox() {
            let portrait = DepthEstimator.letterbox(width: 1080, height: 1920)
            #expect(portrait.height == 392, "as tall as the input")
            #expect(abs(portrait.width / portrait.height - 1080.0 / 1920.0) < 0.01, "not stretched")
            #expect(abs(portrait.midX - 259) <= 1, "centred")
            let landscape = DepthEstimator.letterbox(width: 1920, height: 1080)
            #expect(landscape.width == 518)
            #expect(abs(landscape.midY - 196) <= 1)
        }

        /// The real network, on the Simulator's CPU.
        @Test("The bundled model answers with a map the photo's shape")
        func estimates() async throws {
            let map = try await DepthEstimator().estimate(stripes(width: 360, height: 640))
            let content = DepthEstimator.letterbox(width: 360, height: 640)
            #expect(map.width == Int(content.width) && map.height == Int(content.height))
            #expect(map.values.allSatisfy { $0 >= 0 && $0 <= 1 })
            // A model that silently answers zeros still passes everything
            // above.
            #expect((map.values.max() ?? 0) - (map.values.min() ?? 0) > 0.5, "the map is not flat")
        }
    }

    @Suite("Edges are steps, slopes are left alone")
    struct EdgeTests {
        @Test("A soft edge becomes a hard one")
        func ramp() {
            // Far, a ten-pixel ramp, near.
            let width = 200, height = 9
            let row = (0..<width).map { x -> Float in
                x < 95 ? 0 : x >= 105 ? 1 : Float(x - 95) / 10
            }
            let stepped = ParallaxRenderer.stepped(Array((0..<height).map { _ in row }.joined()), width: width, height: height)
            let middle = Array(stepped[(4 * width)..<(5 * width)])
            #expect(middle.allSatisfy { $0 == 0 || $0 == 1 }, "nothing left between near and far")
            #expect(middle[90] == 0 && middle[110] == 1)
        }

        @Test("A floor running away into the distance keeps its slope")
        func slope() {
            let width = 200, height = 9
            let row = (0..<width).map { Float($0) / Float(width) * 0.5 }
            let depth = Array((0..<height).map { _ in row }.joined())
            #expect(ParallaxRenderer.stepped(depth, width: width, height: height) == depth)
        }
    }

    // MARK: - Compose

    @MainActor
    @Suite("The 3D button")
    struct ComposeParallaxTests {
        @Test("A recording has no 3D button")
        func noneForAClip() async throws {
            let url = CaptureScratch.newURL(pathExtension: "mov")
            try await StillClipWriter.write(stripes(width: 90, height: 160), duration: 0.2, to: url)
            let clip = try await RecordedClip.load(from: url)
            defer { CaptureScratch.remove(url) }
            let model = ComposeModel(capture: .video(clip))
            #expect(!model.canMakeParallax)
            model.toggleParallax()
            #expect(!model.isParallax && model.parallaxWork == nil)
        }

        @Test("It turns the photo into a silent clip that plays like one, and back")
        func togglesToClip() async throws {
            let preferences = Preferences.inMemory()
            let model = ComposeModel(
                capture: .photo(stripes(width: 90, height: 160)),
                preferences: preferences,
                makeParallax: fromDisc
            )
            #expect(model.canMakeParallax)
            #expect(model.duration == .fiveSeconds)

            model.toggleParallax()
            #expect(model.isRenderingParallax)
            await model.parallaxWork?.value
            let clip = try #require(model.parallaxClip)
            defer { CaptureScratch.remove(clip.url) }
            #expect(model.isParallax && model.isVideo)
            #expect(!model.hasSound)
            #expect(model.duration == .playOnce, "a clip's duration, not a photo's")
            model.cycleDuration()
            #expect(model.duration == .loop)

            guard case .video(let drafted) = model.draft.media else {
                Issue.record("expected a video draft")
                return
            }
            #expect(drafted == clip)
            #expect(!model.draft.includesSound)

            model.toggleParallax()
            #expect(!model.isParallax && !model.isVideo)
            #expect(model.duration == .fiveSeconds, "the photo's own duration is back")
            #expect(preferences.photoDuration == .fiveSeconds, "Loop never leaked into it")
            #expect(preferences.videoDuration == .loop)
            guard case .photo = model.draft.media else {
                Issue.record("expected a photo draft")
                return
            }

            model.toggleParallax()
            #expect(model.isParallax && !model.isRenderingParallax)
            #expect(model.parallaxClip == clip, "not rendered twice")
            #expect(model.duration == .loop)
        }

        @Test("A clip nobody sent is deleted; a sent one is left for the outbox")
        func cleansUp() async throws {
            let discarded = ComposeModel(capture: .photo(stripes(width: 90, height: 160)), makeParallax: fromDisc)
            discarded.toggleParallax()
            await discarded.parallaxWork?.value
            let thrownAway = try #require(discarded.parallaxClip)
            discarded.close(sent: false)
            #expect(!FileManager.default.fileExists(atPath: thrownAway.url.path))

            let sent = ComposeModel(capture: .photo(stripes(width: 90, height: 160)), makeParallax: fromDisc)
            sent.toggleParallax()
            await sent.parallaxWork?.value
            let kept = try #require(sent.parallaxClip)
            sent.close(sent: true)
            #expect(FileManager.default.fileExists(atPath: kept.url.path))
            CaptureScratch.remove(kept.url)

            let backToPhoto = ComposeModel(capture: .photo(stripes(width: 90, height: 160)), makeParallax: fromDisc)
            backToPhoto.toggleParallax()
            await backToPhoto.parallaxWork?.value
            let unused = try #require(backToPhoto.parallaxClip)
            backToPhoto.toggleParallax()
            backToPhoto.close(sent: true)
            #expect(!FileManager.default.fileExists(atPath: unused.url.path), "the photo was sent, not the clip")
        }

        @Test("A render that finishes after the screen closed leaves nothing behind")
        func lateRender() async {
            let model = ComposeModel(capture: .photo(stripes(width: 90, height: 160)), makeParallax: fromDisc)
            model.toggleParallax()
            model.close(sent: false)
            await model.parallaxWork?.value
            #expect(model.parallaxClip == nil)
            #expect(!model.isParallax)
        }
    }
}
