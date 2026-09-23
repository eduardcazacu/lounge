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

        /// And further, which is a Nishika's whole look: a lens moving
        /// sideways shifts what it sees by the difference in disparity, and
        /// disparity is one over distance, so something close to the lens
        /// swings across the frame.
        @Test("Nearer than the subject moves the other way from farther, and further")
        func oppositeDirections() {
            let values = (0..<60).map { UInt32(1000 + $0) }
            let depth = (0..<60).map { $0 < 30 ? Float(1) : 0 }
            let (source, disparity) = rows(values, depth: depth)
            let view = ParallaxRenderer.warp(source, disparity: disparity, key: 0.5, shift: 8)
            let row = Array(view.pixels[(2 * 60)..<(3 * 60)])
            // Both are half a unit of disparity from the key plane.
            let near = ParallaxRenderer.move(1, key: 0.5, shift: 8)
            let far = ParallaxRenderer.move(0, key: 0.5, shift: 8)
            #expect(near < 0 && far > 0, "they part company")
            #expect(abs(near) > abs(far) * 1.5, "and the near one swings further")
            #expect(row[6] == values[6 - Int(near.rounded())])
            #expect(row[48] == values[48 - Int(far.rounded())])
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

    // MARK: - The masks themselves

    @Suite("Judging a mask")
    struct MaskTests {
        private func mask(_ value: (Int, Int) -> UInt8, size: Int = 100) -> SubjectMask {
            SubjectMask(
                width: size, height: size,
                alpha: (0..<(size * size)).map { value($0 % size, $0 / size) }
            )
        }

        /// Both requests answer a photo of a houseplant with "one instance,
        /// confidence 1.0". The person one's answer is a scatter of
        /// half-claimed leaf fragments, and this is what tells them apart.
        @Test("A solid outline is decisive; a scatter of half-claims is not")
        func decisiveness() {
            let solid = mask { x, y in (20..<80).contains(x) && (20..<80).contains(y) ? 255 : 0 }
            #expect(solid.decisiveness > 0.9)
            #expect(solid.coverage > 0.35)

            let unsure = mask { x, y in (20..<80).contains(x) && (20..<80).contains(y) ? (x % 3 == 0 ? 200 : 90) : 0 }
            #expect(unsure.decisiveness < VisionSubjectMasker.leastDecisive)
        }

        /// Vision scales its mask up from something much smaller, so a wholly
        /// covered pixel can come back half transparent, and the background
        /// shows through the subject as a bright outline.
        @Test("Sharpening narrows the rim without moving it")
        func sharpening() {
            let ramp = mask { x, _ in UInt8(max(0, min(255, (x - 40) * 6))) }
            let sharp = ramp.sharpened()
            let rim = { (m: SubjectMask) in m.alpha.count { $0 > 20 && $0 < 235 } }
            #expect(rim(sharp) < rim(ramp) / 2, "the rim is narrower")
            // And in the same place: the outline is where the mask crosses
            // half, and steepening turns about exactly that.
            func crossing(_ m: SubjectMask) -> Int? { (0..<100).first { m.alpha[50 * 100 + $0] >= 128 } }
            #expect(crossing(sharp) != nil)
            #expect(abs((crossing(sharp) ?? 0) - (crossing(ramp) ?? 0)) <= 1, "and still where it was")
        }

        @Test("Judging comes before sharpening")
        func judgedRaw() {
            let unsure = mask { x, y in (20..<80).contains(x) && (20..<80).contains(y) ? (x % 3 == 0 ? 200 : 90) : 0 }
            #expect(unsure.sharpened().decisiveness > VisionSubjectMasker.leastDecisive,
                    "sharpening makes anything look decisive, which is why it is judged first")
        }

        @Test("A face inside the mask is kept; one in a picture on the wall is not")
        func focus() {
            let subject = mask { x, y in (20..<80).contains(x) && (20..<80).contains(y) ? 255 : 0 }
            let his = CGRect(x: 40, y: 30, width: 20, height: 20)
            let painted = CGRect(x: 85, y: 10, width: 12, height: 12)
            #expect(subject.focused(on: [painted, his]).focus == his)
            #expect(subject.focused(on: [painted]).focus == nil)
        }
    }

    // MARK: - Grain and fringing

    @Suite("Grain follows the viewpoint, not the frame")
    struct GrainTests {
        /// A wiggle shows its four viewpoints over and over. Grain that
        /// changed every frame would boil on a picture that is otherwise
        /// still — and would cost the encoder a fortune in bits for noise
        /// nobody asked for.
        @Test("Each viewpoint keeps one grain, in every loop")
        func perViewpoint() {
            let frames = ParallaxRenderer.framesPerView
            // The first frame of each held view, through two whole cycles.
            let seeds = stride(from: 0, to: ParallaxRenderer.cycle.count * 2, by: 1).map {
                ParallaxRenderer.viewIndex(atFrame: $0 * frames)
            }
            #expect(Array(seeds.prefix(6)) == ParallaxRenderer.cycle)
            #expect(Array(seeds.suffix(6)) == ParallaxRenderer.cycle, "and the same again next loop")
            #expect(Set(seeds).count == 4, "four viewpoints, four grains")
            // A view held for three frames keeps its grain across them.
            #expect(ParallaxRenderer.viewIndex(atFrame: 0) == ParallaxRenderer.viewIndex(atFrame: frames - 1))
            #expect(ParallaxRenderer.viewIndex(atFrame: 0) != ParallaxRenderer.viewIndex(atFrame: frames))
        }

        @Test("A recording gets a new grain every frame")
        func perFrame() {
            func seed(_ frame: Int, _ seeding: VideoPipeline.GrainSeeding) -> Int {
                VideoPipeline.grainSeed(
                    at: CMTime(value: CMTimeValue(frame), timescale: VideoPipeline.frameRate),
                    grain: seeding
                )
            }
            #expect(seed(7, .perFrame) == 7)
            #expect(seed(8, .perFrame) != seed(7, .perFrame))
            // The wiggle's, by contrast, comes back round.
            let cycle = ParallaxRenderer.cycle.count * ParallaxRenderer.framesPerView
            #expect(seed(3, .perViewpoint) == seed(3 + cycle, .perViewpoint))
        }
    }

    @Suite("A lens that does not quite agree with itself")
    struct FringeTests {
        /// The warp moves pixels sideways in whole steps, so an outline comes
        /// out as a stair. Red and blue a pixel apart put a soft colour edge
        /// over it.
        @Test("Red and blue are pulled apart sideways, green left alone")
        func splitsTheChannels() {
            // Full width, because the fringe is measured as a share of it.
            let width = 1080, height = 4
            // A white block on black: every channel has the same hard edge.
            let pixels = (0..<(width * height)).map { ($0 % width) < 500 ? UInt32(0x00FF_FFFF) : 0 }
            let split = ParallaxRenderer.split(Bitmap(width: width, height: height, pixels: pixels))
            let row = (0..<width).map { split.pixels[2 * width + $0] }
            let redEdge = row.firstIndex { ParallaxRenderer.red($0) == 0 } ?? -1
            let greenEdge = row.firstIndex { ParallaxRenderer.green($0) == 0 } ?? -1
            let blueEdge = row.firstIndex { ParallaxRenderer.blue($0) == 0 } ?? -1
            #expect(greenEdge == 500, "green stays where the edge was")
            #expect(redEdge != greenEdge && blueEdge != greenEdge, "red and blue do not")
            #expect((redEdge - greenEdge) == -(blueEdge - greenEdge), "and part evenly, either side")
        }

        @Test("A picture with no edges is left as it was")
        func flatIsUntouched() {
            let flat = [UInt32](repeating: 0x0080_8080, count: 1080 * 4)
            let source = Bitmap(width: 1080, height: 4, pixels: flat)
            #expect(ParallaxRenderer.split(source).pixels == flat)
        }
    }

    // MARK: - Layers from a mask

    @Suite("Layers from a subject's mask")
    struct LayerTests {
        static let size = 200

        /// A picture whose subject is a rectangle: the background carries its
        /// column in the red channel and the subject in the green, so where
        /// any pixel of either ended up can be read off the colour. The
        /// subject's depth ramps down its height unless `slant` is off, and
        /// `rim` makes its left and right columns half-covered.
        static func scene(
            slant: ClosedRange<Float> = 0.9...0.9,
            rim: Bool = false
        ) -> (source: Bitmap, disparity: [Float], mask: SubjectMask) {
            let size = Self.size
            let subject = 60..<140
            var pixels = [UInt32](repeating: 0, count: size * size)
            var disparity = [Float](repeating: 0.05, count: size * size)
            var alpha = [UInt8](repeating: 0, count: size * size)
            for y in 0..<size {
                let down = Float(y - 60) / 80
                for x in 0..<size {
                    let index = y * size + x
                    let inside = subject.contains(x) && subject.contains(y)
                    // Column in one channel, so a pixel can be followed.
                    // Its column in green if it is the subject, in red if it
                    // is the background, so any pixel can be followed.
                    pixels[index] = inside
                        ? UInt32(x) << 8 | ParallaxRenderer.opaque
                        : UInt32(x) | 0x0040_0000 | ParallaxRenderer.opaque
                    guard inside else { continue }
                    disparity[index] = slant.lowerBound
                        + (slant.upperBound - slant.lowerBound) * min(max(down, 0), 1)
                    // Four columns of rim, so one is still half-covered
                    // after the subject claims a pixel beyond the mask.
                    let edge = x < subject.lowerBound + 4 || x >= subject.upperBound - 4
                    alpha[index] = rim && edge ? 128 : 255
                }
            }
            return (
                Bitmap(width: size, height: size, pixels: pixels),
                disparity,
                SubjectMask(width: size, height: size, alpha: alpha)
            )
        }

        @Test("A mask makes a background layer and a subject layer, near last")
        func twoLayers() throws {
            let (source, disparity, mask) = Self.scene()
            let layers = try #require(ParallaxRenderer.layers(source: source, disparity: disparity, masks: [mask]))
            #expect(layers.count == 2)
            #expect(layers[0].fillsGaps, "the background is first and closes its own gaps")
            #expect(!layers[1].fillsGaps)
            #expect(layers[1].median > layers[0].median, "the subject is nearer")
            #expect(layers[1].growth > 0, "and stands in front of it, so it grows")
            #expect(ParallaxRenderer.keyDisparity(of: layers) == layers[1].median, "the wiggle turns about the subject")
        }

        /// The bug this layering is for: a subject leaning towards the camera
        /// used to be terraced into flat cards by the depth stepping, and cut
        /// into bands that each moved on their own.
        @Test("A slanted subject stays one layer, and its near end moves further")
        func slantedSubject() throws {
            let (source, disparity, mask) = Self.scene(slant: 0.4...0.95)
            let layers = try #require(ParallaxRenderer.layers(source: source, disparity: disparity, masks: [mask]))
            #expect(layers.count == 2, "one subject, not a card per depth")

            let key = try #require(ParallaxRenderer.keyDisparity(of: layers))
            let view = ParallaxRenderer.composited(layers, key: key, shift: 40)
            // Where the subject's own column 100 landed, at its far top and
            // its near bottom.
            func landed(row: Int) -> Int? {
                let start = row * Self.size
                return (0..<Self.size).first { ParallaxRenderer.green(view.pixels[start + $0]) == 100 }
            }
            let far = try #require(landed(row: 62))
            let near = try #require(landed(row: 137))
            // The wiggle turns about the subject's near side, so it is the
            // far end of the slant that swings — a flat card would move all
            // of one piece, which is the thing being ruled out.
            #expect(abs(far - 100) > abs(near - 100), "the far end of the slant moves further")
            #expect((far - 100) * (near - 100) < 0, "and the two ends part company, as a slant should")
            let bare = view.pixels.indices.filter { ParallaxRenderer.coverage(view.pixels[$0]) != 0xFF }
            #expect(bare.isEmpty, "\(bare.count) pixels are covered by nothing")
        }

        /// At the subject's own depth, so it does not grow: a grown subject
        /// covers its own rim, and the blend under test would have moved.
        /// The outermost rim column is the one still half-covered once the
        /// subject has claimed its extra pixel.
        @Test("A half-covered rim comes out as a blend of subject and background")
        func softRim() throws {
            let (source, disparity, mask) = Self.scene(slant: 0.05...0.05, rim: true)
            let layers = try #require(ParallaxRenderer.layers(source: source, disparity: disparity, masks: [mask]))
            let key = try #require(ParallaxRenderer.keyDisparity(of: layers))
            // No movement at all: the rim is the only thing under test.
            let view = ParallaxRenderer.composited(layers, key: key, shift: 0)
            let rim = view.pixels[100 * Self.size + 60]
            #expect(ParallaxRenderer.green(rim) > 0, "part subject")
            #expect(ParallaxRenderer.red(rim) > 0, "and part background")
            let solid = view.pixels[100 * Self.size + 70]
            #expect(ParallaxRenderer.red(solid) == 0, "where the subject is whole, none of the background shows")
        }

        @Test("The background under the mask is never carried into a view")
        func noGhost() throws {
            let (source, disparity, mask) = Self.scene()
            let layers = try #require(ParallaxRenderer.layers(source: source, disparity: disparity, masks: [mask]))
            let key = try #require(ParallaxRenderer.keyDisparity(of: layers))
            let view = ParallaxRenderer.composited(layers, key: key, shift: 40)
            let row = (0..<Self.size).map { view.pixels[100 * Self.size + $0] }
            for x in 0..<Self.size where ParallaxRenderer.green(row[x]) == 0 {
                // Outside the subject every pixel is background, and the
                // background's columns are the ones it started with: 60 to
                // 139 were under the mask and can never appear.
                let column = ParallaxRenderer.red(row[x])
                #expect(!(60..<140).contains(Int(column)), "column \(column) was under the subject")
            }
        }

        /// A layer blended with the nothing beyond its own edge fades out over
        /// its last pixel, and whatever is behind it shows through the seam.
        @Test("A layer does not fade out at its edge")
        func noSeam() throws {
            let (source, disparity, mask) = Self.scene()
            let layers = try #require(ParallaxRenderer.layers(source: source, disparity: disparity, masks: [mask]))
            let background = layers[0]
            let warped = ParallaxRenderer.warp(
                background.bitmap,
                disparity: background.disparity,
                key: 0.9,
                shift: 37,
                fills: true
            )
            let partial = warped.pixels.count { ParallaxRenderer.coverage($0) != 0 && ParallaxRenderer.coverage($0) != 0xFF }
            #expect(partial == 0, "\(partial) pixels came out half transparent")
        }

        /// The face is what a photo of a person is of, and a wiggle that
        /// swings it about is a wiggle of the wrong thing.
        @Test("The wiggle turns about the face when there is one")
        func facePins() throws {
            let (source, disparity, _) = Self.scene(slant: 0.4...0.95)
            let plain = Self.scene(slant: 0.4...0.95).mask
            // A face over the subject's top, which is its far half here.
            let withFace = SubjectMask(
                width: plain.width, height: plain.height, alpha: plain.alpha,
                focus: CGRect(x: 80, y: 62, width: 40, height: 20)
            )
            let layers = try #require(ParallaxRenderer.layers(source: source, disparity: disparity, masks: [withFace]))
            let key = try #require(ParallaxRenderer.keyDisparity(of: layers))
            let atFace = disparity[70 * Self.size + 100]
            #expect(abs(key - atFace) < 0.05, "the key plane is the face's own depth")
        }

        /// The bug that made a subject look doubled: the half-covered pixels
        /// at an outline kept the wall's depth, so they travelled at the
        /// wall's speed and trailed the subject by a few pixels — a second
        /// copy of the outline, wiggling out of step with the first.
        @Test("The rim of a subject travels at the subject's speed")
        func rimTravelsWithTheSubject() throws {
            let (source, disparity, _) = Self.scene(rim: true)
            let mask = Self.scene(rim: true).mask
            let layers = try #require(ParallaxRenderer.layers(source: source, disparity: disparity, masks: [mask]))
            let subject = layers[1]
            let row = 100 * Self.size
            // The mask's own rim column, half covered, and the solid column
            // just inside it.
            #expect(mask.alpha[row + 60] == 128)
            #expect(abs(subject.disparity[row + 60] - subject.disparity[row + 61]) < 0.05,
                    "the rim moves with what it is the edge of, not with the wall")
            #expect(subject.disparity[row + 60] > 0.5, "and not at the wall's depth")
        }

        @Test("A mask that is most of a bigger one is dropped")
        func overlappingInstances() {
            let size = 40
            func block(_ range: Range<Int>) -> SubjectMask {
                SubjectMask(
                    width: size, height: size,
                    alpha: (0..<(size * size)).map { range.contains($0 % size) ? 255 : 0 }
                )
            }
            let person = block(5..<35)
            let head = block(15..<25)
            let elsewhere = block(36..<40)
            let kept = VisionSubjectMasker.distinct([person, head, elsewhere])
            #expect(kept.count == 2, "the head is already part of the person")
            #expect(kept.first?.coverage == person.coverage)
        }

        @Test("A mask is resampled to the size the renderer works at")
        func resampling() throws {
            let (_, _, mask) = Self.scene()
            let smaller = try #require(ParallaxRenderer.resampled(mask, width: 100, height: 100))
            #expect(smaller.width == 100 && smaller.height == 100)
            #expect(abs(smaller.coverage - mask.coverage) < 0.02)
        }

        /// Whether these requests answer on the Simulator is not promised,
        /// and this is what records it: either masks, or none and the
        /// depth-only path. What must never happen is a throw reaching the
        /// render.
        @MainActor
        @Test("Vision either finds subjects or finds none")
        func visionAnswers() async {
            let masks = await VisionSubjectMasker().masks(for: stripes(width: 360, height: 640))
            #expect(masks.count <= VisionSubjectMasker.mostInstances)
            for mask in masks {
                #expect(mask.coverage > 0 && mask.coverage <= 1)
                #expect(mask.alpha.count == mask.width * mask.height)
            }
        }

        @Test("No mask, and the picture renders the way it did before there were any")
        func withoutMasks() throws {
            let (source, disparity, _) = Self.scene()
            #expect(ParallaxRenderer.layers(source: source, disparity: disparity, masks: []) == nil)
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

    @Suite("How much of the frame is given up")
    struct MarginTests {
        /// A hand at the edge of the frame moving inwards uncovers the
        /// frame's own edge, and what fills it is invented. Every view is
        /// enlarged by the largest move instead, which puts that strip
        /// outside the picture.
        @Test("The crop is the largest move, and no more than the cap")
        func margin() {
            let flat = [Float](repeating: 0.5, count: 100)
            #expect(ParallaxRenderer.edgeMargin(flat, key: 0.5, shift: 20, width: 1000) == 0,
                    "nothing moves in a flat scene, so nothing is given up")

            let scene = [Float](repeating: 0.1, count: 99) + [0.9]
            let margin = ParallaxRenderer.edgeMargin(scene, key: 0.5, shift: 20, width: 1000)
            #expect(margin > 0.005 && margin <= CGFloat(ParallaxRenderer.maxMargin))

            let wild = [Float](repeating: 0, count: 50) + [Float](repeating: 1, count: 50)
            #expect(ParallaxRenderer.edgeMargin(wild, key: 0.5, shift: 2000, width: 1000)
                    == CGFloat(ParallaxRenderer.maxMargin), "and never more than the cap")
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
