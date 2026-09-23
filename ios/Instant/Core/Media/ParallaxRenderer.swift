#if canImport(UIKit)
import Accelerate
import AVFoundation
import CoreImage
import Foundation
import UIKit

/// Turns a photo and its depth into the four-lens wiggle of a Nishika N8000:
/// four viewpoints a little apart, played 1-2-3-4-3-2 and round again.
///
/// The result is an ordinary silent clip in `CaptureScratch`, so from compose
/// onwards a 3D photo *is* a clip: the same preview, filters per frame,
/// captions and drawing in fractions of the frame, the same HEVC encode, seal
/// and viewer, and nothing new on the wire. See `wiki/decisions.md`.
///
/// **The subject stands still.** What makes a Nishika picture read as depth
/// rather than as a shaking camera is that the key subject is lined up in all
/// four frames and the rest of the scene swings around it — the background one
/// way, anything nearer the other. So each view moves a pixel in proportion to
/// how far its disparity is from the subject's, not to the disparity itself.
///
/// **Holes are filled from behind.** Moving the viewpoint uncovers scenery that
/// no lens saw, beside every near edge. It is filled from whichever side of the
/// gap is farther away, because what was hidden is the background: filling
/// from the subject smears a face into the wall.
public enum ParallaxRenderer {
    public enum RenderError: Error, Equatable {
        case noPixels
    }

    /// Where the four lenses sit, in units of the gap between two of them, so
    /// the middle two views are as far apart as each is from its outer
    /// neighbour — the camera's lenses were evenly spaced.
    static let viewOffsets: [Float] = [-1.5, -0.5, 0.5, 1.5]

    /// How far the outermost view moves the farthest-from-the-subject thing in
    /// the picture, as a share of the width. More than a couple of percent and
    /// the uncovered slivers are wide enough to see that they were invented.
    static let maxShift: Float = 0.015

    /// 1-2-3-4-3-2, as indices into `viewOffsets`. It stops one short of
    /// coming back to 1 so that coming back to 1 is the next cycle's first
    /// frame: a clip that ended on 1 would show it twice at every loop, which
    /// is a hitch at exactly the seam.
    static let cycle = [0, 1, 2, 3, 2, 1]

    /// A tenth of a second per view, the speed the camera's own GIFs go at.
    static let framesPerView = 3
    static let frameRate: Int32 = 30

    /// As many cycles as fit inside `VideoPipeline.maximumDuration`: 4.8 s.
    /// More than one, so that sent as Once it still wiggles several times
    /// before it closes.
    static let cycles = Int(VideoPipeline.maximumDuration * Double(frameRate))
        / (cycle.count * framesPerView)

    /// Every frame of the clip, by view.
    static var sequence: [Int] {
        (0..<cycles).flatMap { _ in cycle }
    }

    static var duration: Double {
        Double(sequence.count * framesPerView) / Double(frameRate)
    }

    /// The clip's long edge. `VideoPipeline` sends no more than this anyway,
    /// and a library photo can be twice it.
    static let longEdge: CGFloat = 1920

    /// Renders the four views and writes them out as a looping clip. The
    /// caller owns the file.
    public static func makeClip(photo: UIImage, depth: DepthMap) async throws -> RecordedClip {
        let views = try await Task.detached(priority: .userInitiated) {
            try renderViews(photo: photo, depth: depth)
        }.value
        let url = CaptureScratch.newURL(pathExtension: "mov")
        do {
            try await FrameSequenceWriter.write(
                views,
                sequence: sequence,
                framesPerImage: framesPerView,
                framesPerSecond: frameRate,
                to: url
            )
            return try await RecordedClip.load(from: url)
        } catch {
            CaptureScratch.remove(url)
            throw error
        }
    }

    /// The four views, in `viewOffsets` order, each the size of the photo as
    /// it will be sent.
    static func renderViews(photo: UIImage, depth: DepthMap) throws -> [CGImage] {
        let source = try Bitmap(photo, longEdge: longEdge)
        let disparity = stepped(
            upsampled(depth, toMatch: source),
            width: source.width,
            height: source.height
        )
        let key = keyDisparity(depth)
        let (grown, grownDisparity) = enlarged(source, disparity: disparity)
        let unsure = besideNearer(grownDisparity, width: source.width, height: source.height)
        // Pixels per unit of lens offset per unit of disparity, chosen so the
        // outermost lens moves the most distant thing `maxShift` of the width.
        let gain = maxShift * Float(source.width) / (viewOffsets.map(abs).max() ?? 1)
        // Not enlarged to hide the strip each view uncovers at the frame's
        // side: that would grow the whole picture, the background with it.
        // The strip is a gap like any other, filled from what is beside it.
        return viewOffsets.map { offset in
            warp(grown, disparity: grownDisparity, key: key, shift: offset * gain, dropping: unsure).image
        }
    }

    // MARK: - Depth

    /// The subject's disparity: the three-quarter mark of what is in the middle
    /// of the frame.
    ///
    /// The middle, because that is where a subject is framed; the near side of
    /// it, because the middle of a selfie is face *and* the wall beside it, and
    /// the face is the nearer half. A still subject is the whole effect, so a
    /// guess that lands on the wall instead is a clip where the face shakes.
    static func keyDisparity(_ depth: DepthMap) -> Float {
        let x0 = Int(Double(depth.width) * 0.35)
        let x1 = max(x0 + 1, Int(Double(depth.width) * 0.65))
        let y0 = Int(Double(depth.height) * 0.35)
        let y1 = max(y0 + 1, Int(Double(depth.height) * 0.65))
        var window: [Float] = []
        for y in y0..<min(y1, depth.height) {
            for x in x0..<min(x1, depth.width) {
                window.append(depth.value(x: x, y: y))
            }
        }
        guard !window.isEmpty else { return 0.5 }
        window.sort()
        return window[Int(Double(window.count - 1) * 0.75)]
    }

    /// The map at the photo's resolution, with its edges moved onto the
    /// photo's edges.
    ///
    /// A plain stretch of a map a sixth of the photo's width blurs every depth
    /// edge across several of the photo's pixels, and each of those pixels
    /// then moves by a different amount: the outline of the subject smears.
    /// The edge-preserving upsample snaps the map's edges to the picture's.
    static func upsampled(_ depth: DepthMap, toMatch source: Bitmap) -> [Float] {
        let count = source.width * source.height
        let small = depth.values.withUnsafeBufferPointer { Data(buffer: $0) }
        let guide = CIImage(cgImage: source.image)
        let map = CIImage(
            bitmapData: small,
            bytesPerRow: depth.width * MemoryLayout<Float>.size,
            size: CGSize(width: depth.width, height: depth.height),
            format: .Rf,
            colorSpace: nil
        )
        let filter = CIFilter(name: "CIEdgePreserveUpsampleFilter", parameters: [
            kCIInputImageKey: guide,
            "inputSmallImage": map,
        ])
        var full = [Float](repeating: 0, count: count)
        // No colour management anywhere: these are disparities, and a colour
        // space would bend them like gamma.
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        if let output = filter?.outputImage {
            full.withUnsafeMutableBytes { bytes in
                context.render(
                    output,
                    toBitmap: bytes.baseAddress!,
                    rowBytes: source.width * MemoryLayout<Float>.size,
                    bounds: CGRect(x: 0, y: 0, width: source.width, height: source.height),
                    format: .Rf,
                    colorSpace: nil
                )
            }
            if full.allSatisfy(\.isFinite) { return full }
        }
        return stretched(depth, width: source.width, height: source.height)
    }

    /// Bilinear, for when Core Image has nothing to give.
    static func stretched(_ depth: DepthMap, width: Int, height: Int) -> [Float] {
        var full = [Float](repeating: 0, count: width * height)
        let sx = Float(depth.width) / Float(width)
        let sy = Float(depth.height) / Float(height)
        for y in 0..<height {
            let fy = max(0, min(Float(depth.height - 1), (Float(y) + 0.5) * sy - 0.5))
            let y0 = Int(fy), y1 = min(depth.height - 1, y0 + 1), ty = fy - Float(y0)
            for x in 0..<width {
                let fx = max(0, min(Float(depth.width - 1), (Float(x) + 0.5) * sx - 0.5))
                let x0 = Int(fx), x1 = min(depth.width - 1, x0 + 1), tx = fx - Float(x0)
                let top = depth.value(x: x0, y: y0) * (1 - tx) + depth.value(x: x1, y: y0) * tx
                let bottom = depth.value(x: x0, y: y1) * (1 - tx) + depth.value(x: x1, y: y1) * tx
                full[y * width + x] = top * (1 - ty) + bottom * ty
            }
        }
        return full
    }

    /// How far either side of a pixel to look for a depth edge, as a share of
    /// the width — about as wide as an upsampled edge is soft.
    static let edgeReach: Float = 0.012
    /// A drop in disparity this large within reach is an edge; anything
    /// gentler is a slope — a floor, a wall going away — and is left alone.
    static let edgeStep: Float = 0.12
    /// Where between the far and the near side an edge is cut. A little
    /// towards far, so the outer ring of hair goes with the head rather than
    /// being left on the wall.
    static let edgeCut: Float = 0.4

    /// Turns every depth edge from a ramp into a step.
    ///
    /// An estimated map's edges are ramps several pixels wide, however well
    /// they follow the photo, and a pixel on a ramp moves by an amount between
    /// the subject's and the wall's. Straight lines in the background bend as
    /// they approach the subject, because every pixel of the ramp is pulled a
    /// little differently. Snapping each of those pixels to the near or the
    /// far side makes the edge a clean occlusion instead: the background stays
    /// straight up to the subject and is uncovered, or covered, whole.
    ///
    /// A ramp can be wider than the reach, and then the nearest value within
    /// reach is still on the ramp. So it is done again on its own result until
    /// nothing changes: each pass carries the two sides' values further in.
    static func stepped(_ disparity: [Float], width: Int, height: Int) -> [Float] {
        var result = disparity
        for _ in 0..<edgePasses {
            guard let next = snapped(result, width: width, height: height), next != result else { break }
            result = next
        }
        return result
    }

    static let edgePasses = 4

    /// One pass of `stepped`, or nil when the picture is smaller than the
    /// window and vImage refuses it.
    private static func snapped(_ disparity: [Float], width: Int, height: Int) -> [Float]? {
        let radius = max(1, Int((edgeReach * Float(width)).rounded()))
        guard let nearest = extreme(disparity, width: width, height: height, radius: radius, nearest: true),
              let farthest = extreme(disparity, width: width, height: height, radius: radius, nearest: false)
        else { return nil }
        var result = disparity
        for index in result.indices {
            let low = farthest[index]
            let high = nearest[index]
            guard high - low > edgeStep else { continue }
            result[index] = result[index] - low >= edgeCut * (high - low) ? high : low
        }
        return result
    }

    /// How close to a nearer surface a background pixel has to be to stop
    /// being trusted, as a share of the width.
    static let edgeBand: Float = 0.006

    /// The background pixels right beside something nearer: true where a
    /// pixel is not to be carried into any view.
    ///
    /// However well the edge is placed, the pixels on it are part subject and
    /// part wall — a photo's edges are soft over a pixel or two, a hair's over
    /// more, and the estimate can miss the true outline by a few. Any of them
    /// given the wall's depth slides away with the wall and takes the
    /// subject's colour with it: a faint copy of the outline, floating a few
    /// pixels off the subject in every view but the key. Dropped instead,
    /// they are a gap like any other and are filled from clean background
    /// farther out. The worst this costs is a pixel or two off the subject's
    /// rim, which nothing shows.
    static func besideNearer(_ disparity: [Float], width: Int, height: Int) -> [Bool] {
        let radius = max(1, Int((edgeBand * Float(width)).rounded()))
        guard let nearest = extreme(disparity, width: width, height: height, radius: radius, nearest: true) else {
            return [Bool](repeating: false, count: disparity.count)
        }
        return zip(disparity, nearest).map { own, near in near - own > edgeStep }
    }

    /// The nearest (or farthest) disparity within `radius` of every pixel, or
    /// nil when the picture is smaller than the window and vImage refuses it.
    private static func extreme(
        _ values: [Float],
        width: Int,
        height: Int,
        radius: Int,
        nearest: Bool
    ) -> [Float]? {
        let kernel = vImagePixelCount(2 * radius + 1)
        var source = values
        var result = [Float](repeating: 0, count: values.count)
        let succeeded = source.withUnsafeMutableBytes { input in
            result.withUnsafeMutableBytes { output in
                var from = vImage_Buffer(
                    data: input.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * MemoryLayout<Float>.size
                )
                var to = vImage_Buffer(
                    data: output.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * MemoryLayout<Float>.size
                )
                let flags = vImage_Flags(kvImageNoFlags)
                let error = nearest
                    ? vImageMax_PlanarF(&from, &to, nil, 0, 0, kernel, kernel, flags)
                    : vImageMin_PlanarF(&from, &to, nil, 0, 0, kernel, kernel, flags)
                return error == kvImageNoError
            }
        }
        return succeeded ? result : nil
    }

    // MARK: - Enlarging the near layers

    /// How much larger a layer is drawn for each unit of disparity it stands
    /// in front of what is behind it — the way Apple's spatial scenes do it,
    /// and for their reason. The moving viewpoint uncovers a band beside every
    /// near edge as wide as the jump in depth across it, so a layer grown by
    /// its jump already covers most of that band, and most of what would have
    /// been invented is simply more of the layer. A head against a far wall
    /// stands a long way in front and grows by most of this; a hand against
    /// the face it is held up to grows a little; the wall not at all.
    static let maxGrowth: Float = 0.08

    /// A layer's depth may drift this far from where it started and still be
    /// the same layer. Without a limit a floor running from the subject's
    /// feet to the back wall joins them into one layer, and the layer that
    /// grew would be the whole picture.
    static let layerBand: Float = 0.15

    /// Layers this small — a fraction of the picture — are left their size:
    /// a speck of the estimate's noise is not worth growing.
    static let smallestGrown = 0.001

    /// Layers that grow, and how: every pixel labelled with the growing layer
    /// it belongs to (or -1), each layer's middle, and how much it grows by.
    ///
    /// A layer is a region the disparity crosses smoothly — split at every
    /// real edge, and wherever it has drifted more than `layerBand` from
    /// where it began. Its growth is `maxGrowth` times its jump averaged over
    /// its whole outline, not counting the frame: the part of the outline
    /// with something farther behind it counts by how much farther, and the
    /// part that runs smoothly on into a floor or a wall counts nothing. So
    /// the farthest layers do not grow, and a surface fading into the
    /// distance, outlined nowhere, does not either.
    ///
    /// Two layers joined smoothly that both grow are merged and grow as one,
    /// about one middle: a face split in two by its own relief, each half
    /// grown about its own middle, would open a seam down the nose.
    ///
    /// Each layer grows about its own middle, never about one shared centre.
    /// Grown about the subject's, a hand off to one side would also be pushed
    /// outwards, uncovering a strip along its inner side — more to invent,
    /// not less. Grown about its own, a layer only ever gets bigger.
    static func growingLayers(
        _ disparity: [Float],
        width: Int,
        height: Int
    ) -> (labels: [Int32], centres: [(x: Float, y: Float)], growths: [Float]) {
        let count = disparity.count
        let continuous = edgeStep / 2

        // Flood into layers.
        var layerOf = [Int32](repeating: -1, count: count)
        var layers = 0
        var stack: [Int] = []
        for seed in 0..<count where layerOf[seed] < 0 {
            let layer = Int32(layers)
            layers += 1
            let start = disparity[seed]
            layerOf[seed] = layer
            stack.append(seed)
            while let index = stack.popLast() {
                let x = index % width
                let y = index / width
                let here = disparity[index]
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                    where nx >= 0 && nx < width && ny >= 0 && ny < height {
                    let neighbour = ny * width + nx
                    let there = disparity[neighbour]
                    guard layerOf[neighbour] < 0,
                          abs(there - here) < continuous,
                          abs(there - start) <= layerBand
                    else { continue }
                    layerOf[neighbour] = layer
                    stack.append(neighbour)
                }
            }
        }

        // Each layer's growth, from its outline.
        func growths(of layerOf: [Int32], layers: Int) -> [Float] {
            var outline = [Int](repeating: 0, count: layers)
            var jumps = [Float](repeating: 0, count: layers)
            var sizes = [Int](repeating: 0, count: layers)
            for index in 0..<count {
                let layer = Int(layerOf[index])
                sizes[layer] += 1
                let x = index % width
                for neighbour in [x + 1 < width ? index + 1 : -1, index + width < count ? index + width : -1]
                    where neighbour >= 0 {
                    let other = Int(layerOf[neighbour])
                    guard other != layer else { continue }
                    let step = disparity[index] - disparity[neighbour]
                    outline[layer] += 1
                    outline[other] += 1
                    if step > continuous { jumps[layer] += min(step, 1) }
                    if -step > continuous { jumps[other] += min(-step, 1) }
                }
            }
            let minimum = Int(Double(count) * smallestGrown)
            return (0..<layers).map { layer in
                guard sizes[layer] >= minimum, outline[layer] > 0 else { return 0 }
                return maxGrowth * jumps[layer] / Float(outline[layer])
            }
        }
        let firstGrowths = growths(of: layerOf, layers: layers)

        // Merge growing layers that meet smoothly.
        var parent = Array(0..<layers)
        func root(_ layer: Int) -> Int {
            var layer = layer
            while parent[layer] != layer {
                parent[layer] = parent[parent[layer]]
                layer = parent[layer]
            }
            return layer
        }
        for index in 0..<count {
            let layer = Int(layerOf[index])
            guard firstGrowths[layer] > 0 else { continue }
            let x = index % width
            for neighbour in [x + 1 < width ? index + 1 : -1, index + width < count ? index + width : -1]
                where neighbour >= 0 {
                let other = Int(layerOf[neighbour])
                guard other != layer, firstGrowths[other] > 0,
                      abs(disparity[index] - disparity[neighbour]) < continuous
                else { continue }
                parent[root(layer)] = root(other)
            }
        }
        var merged = [Int32](repeating: 0, count: layers)
        var roots: [Int: Int32] = [:]
        for layer in 0..<layers {
            let top = root(layer)
            if roots[top] == nil { roots[top] = Int32(roots.count) }
            merged[layer] = roots[top]!
        }
        let mergedOf = layerOf.map { merged[Int($0)] }
        let finalGrowths = growths(of: mergedOf, layers: roots.count)

        // Keep the layers that grow, with their middles.
        var sums = [(x: Double, y: Double, n: Int)](repeating: (0, 0, 0), count: roots.count)
        for index in 0..<count {
            let layer = Int(mergedOf[index])
            guard finalGrowths[layer] > 0.001 else { continue }
            sums[layer].x += Double(index % width)
            sums[layer].y += Double(index / width)
            sums[layer].n += 1
        }
        var growing = [Int32](repeating: -1, count: roots.count)
        var centres: [(x: Float, y: Float)] = []
        var kept: [Float] = []
        for layer in 0..<roots.count where finalGrowths[layer] > 0.001 && sums[layer].n > 0 {
            growing[layer] = Int32(kept.count)
            centres.append((Float(sums[layer].x / Double(sums[layer].n)), Float(sums[layer].y / Double(sums[layer].n))))
            kept.append(finalGrowths[layer])
        }
        return (mergedOf.map { growing[Int($0)] }, centres, kept)
    }

    /// The photo with every growing layer enlarged about its own middle, and
    /// the disparity to go with it.
    ///
    /// Drawn backwards, from each output pixel to where it came from, so an
    /// enlarged layer is sampled smoothly rather than stretched with a
    /// duplicated pixel every few dozen. An output pixel may be the pixel
    /// that was there, if that one does not grow, or a point of any layer
    /// whose growth brings it here; the nearest of those wins, which is what
    /// makes a grown subject cover the wall beside it.
    static func enlarged(_ source: Bitmap, disparity: [Float]) -> (Bitmap, [Float]) {
        let width = source.width
        let height = source.height
        let (labels, centres, growths) = growingLayers(disparity, width: width, height: height)
        guard !centres.isEmpty else { return (source, disparity) }
        var pixels = [UInt32](repeating: 0, count: width * height)
        var depth = [Float](repeating: -1, count: width * height)

        source.pixels.withUnsafeBufferPointer { input in
            disparity.withUnsafeBufferPointer { near in
                labels.withUnsafeBufferPointer { patchOf in
                    pixels.withUnsafeMutableBufferPointer { output in
                        depth.withUnsafeMutableBufferPointer { landed in
                            let input = input, near = near, patchOf = patchOf, output = output, landed = landed
                            func colourAt(_ x: Float, _ y: Float) -> UInt32 {
                                let fx = min(max(x, 0), Float(width - 1))
                                let fy = min(max(y, 0), Float(height - 1))
                                let x0 = Int(fx), y0 = Int(fy)
                                let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
                                let top = mix(input[y0 * width + x0], input[y0 * width + x1], fx - Float(x0))
                                let bottom = mix(input[y1 * width + x0], input[y1 * width + x1], fx - Float(x0))
                                return mix(top, bottom, fy - Float(y0))
                            }

                            DispatchQueue.concurrentPerform(iterations: height) { y in
                                let row = y * width
                                for x in 0..<width {
                                    var colour: UInt32 = 0
                                    var nearest: Float = -1
                                    if patchOf[row + x] < 0 {
                                        colour = input[row + x]
                                        nearest = near[row + x]
                                    }
                                    for (patch, centre) in centres.enumerated() {
                                        let full = 1 + growths[patch]
                                        let px = centre.x + (Float(x) - centre.x) / full
                                        let py = centre.y + (Float(y) - centre.y) / full
                                        let column = Int(px.rounded()), line = Int(py.rounded())
                                        guard column >= 0, column < width, line >= 0, line < height else { continue }
                                        let index = line * width + column
                                        guard patchOf[index] == Int32(patch), near[index] > nearest else { continue }
                                        colour = colourAt(px, py)
                                        nearest = near[index]
                                    }
                                    guard nearest >= 0 else { continue }
                                    output[row + x] = colour
                                    landed[row + x] = nearest
                                }
                                // A layer with a hollow can uncover a little of
                                // it; that takes the background's colour and
                                // depth like any other gap.
                                fill(row: row, width: width, pixels: output, nearness: landed)
                                var x = 0
                                while x < width {
                                    guard landed[row + x] < 0 else { x += 1; continue }
                                    let start = x
                                    while x < width, landed[row + x] < 0 { x += 1 }
                                    let sides = [start > 0 ? landed[row + start - 1] : nil, x < width ? landed[row + x] : nil]
                                    let background = sides.compactMap { $0 }.min() ?? 0
                                    for gap in start..<x { landed[row + gap] = background }
                                }
                            }
                        }
                    }
                }
            }
        }
        return (Bitmap(width: width, height: height, pixels: pixels), depth)
    }

    // MARK: - Views

    /// One view: every pixel moved sideways by `shift × (key − disparity)`,
    /// except those in `dropped`, which are left for `fill`.
    ///
    /// Row by row, because a sideways move never crosses rows — which makes
    /// every row its own small problem, and all of them run at once. Each
    /// pixel is carried to where it lands, and where two land on the same spot
    /// the nearer wins, as it would in front of a lens. Whatever nothing lands
    /// on is a gap, filled in `fill`.
    static func warp(
        _ source: Bitmap,
        disparity: [Float],
        key: Float,
        shift: Float,
        dropping dropped: [Bool]? = nil
    ) -> Bitmap {
        let width = source.width
        let height = source.height
        var pixels = [UInt32](repeating: 0, count: width * height)
        // Doubles as the gap mask: below zero is a place nothing landed.
        var nearness = [Float](repeating: -1, count: width * height)
        let dropped = dropped ?? []

        source.pixels.withUnsafeBufferPointer { input in
            disparity.withUnsafeBufferPointer { depth in
                pixels.withUnsafeMutableBufferPointer { output in
                    nearness.withUnsafeMutableBufferPointer { landed in
                        let input = input, depth = depth, output = output, landed = landed
                        DispatchQueue.concurrentPerform(iterations: height) { y in
                            let row = y * width
                            for x in 0..<width where dropped.isEmpty || !dropped[row + x] {
                                let d = depth[row + x]
                                let move = shift * (key - d)
                                let target = x + Int(move.rounded())
                                guard target >= 0, target < width, d > landed[row + target] else { continue }
                                // The colour at exactly where this pixel came
                                // from, between two source pixels. Rounded to
                                // the nearest one instead, a slope's gradual
                                // move comes out as one-pixel stairs down every
                                // vertical edge.
                                let from = min(max(Float(target) - move, 0), Float(width - 1))
                                let left = Int(from)
                                let right = min(left + 1, width - 1)
                                output[row + target] = mix(input[row + left], input[row + right], from - Float(left))
                                landed[row + target] = d
                            }
                            fill(row: row, width: width, pixels: output, nearness: landed)
                        }
                    }
                }
            }
        }
        return Bitmap(width: width, height: height, pixels: softened(pixels, gaps: nearness, width: width))
    }

    /// Closes each gap in a row with the background beside it.
    ///
    /// The farther of the gap's two neighbours is the background, and the gap
    /// is a copy of the background's own pixels just beyond it, not one pixel
    /// drawn out: a stretched pixel is a streak, a copied run is more wall.
    /// Where that run itself reaches into something nearer, the edge pixel is
    /// used instead, so the subject is never copied into its own shadow.
    static func fill(
        row: Int,
        width: Int,
        pixels: UnsafeMutableBufferPointer<UInt32>,
        nearness: UnsafeMutableBufferPointer<Float>
    ) {
        var x = 0
        while x < width {
            guard nearness[row + x] < 0 else { x += 1; continue }
            let start = x
            while x < width, nearness[row + x] < 0 { x += 1 }
            let end = x - 1
            let length = end - start + 1
            let left = start - 1
            let right = end + 1
            let hasLeft = left >= 0
            let hasRight = right < width
            guard hasLeft || hasRight else { continue }

            let fromLeft = hasLeft && (!hasRight || nearness[row + left] <= nearness[row + right])
            let edge = fromLeft ? left : right
            let background = nearness[row + edge]
            for k in 0..<length {
                let target = start + k
                // The run beyond the edge, laid into the gap in order.
                let copied = fromLeft ? left - length + 1 + k : right + k
                let usable = copied >= 0 && copied < width
                    && nearness[row + copied] >= 0
                    && nearness[row + copied] <= background + 0.05
                pixels[row + target] = pixels[row + (usable ? copied : edge)]
            }
            // Left marked as a gap on purpose: `softened` looks for exactly
            // these pixels.
        }
    }

    /// A filled gap is copied row by row, and rows copied independently do
    /// not quite agree with one another — a fine horizontal combing. One
    /// vertical 1-2-1 pass over the filled pixels, and only those, hides it.
    static func softened(_ pixels: [UInt32], gaps: [Float], width: Int) -> [UInt32] {
        let height = pixels.count / width
        guard height > 2 else { return pixels }
        var result = pixels
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 0..<width where gaps[row + x] < 0 {
                result[row + x] = blend(pixels[row - width + x], pixels[row + x], pixels[row + width + x])
            }
        }
        return result
    }

    /// a × (1 − t) + b × t, per byte.
    @inline(__always)
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Float) -> UInt32 {
        guard t > 0.004 else { return a }
        guard t < 0.996 else { return b }
        let weight = UInt32(t * 256)
        var out: UInt32 = 0
        for shift in stride(from: UInt32(0), to: 32, by: 8) {
            let channel = (((a >> shift) & 0xFF) * (256 - weight) + ((b >> shift) & 0xFF) * weight + 128) >> 8
            out |= channel << shift
        }
        return out
    }

    /// (a + 2b + c) / 4, per byte.
    private static func blend(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> UInt32 {
        var out: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) {
            let channel = ((a >> shift) & 0xFF) + 2 * ((b >> shift) & 0xFF) + ((c >> shift) & 0xFF)
            out |= ((channel + 2) / 4) << shift
        }
        return out
    }
}

/// An opaque picture as one `UInt32` per pixel, top row first, which is all a
/// sideways move needs to know about colour.
struct Bitmap {
    let width: Int
    let height: Int
    var pixels: [UInt32]

    init(width: Int, height: Int, pixels: [UInt32]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// The photo upright, fitted inside `longEdge`, with even sides — the
    /// video encoder refuses an odd one.
    init(_ photo: UIImage, longEdge: CGFloat) throws {
        let upright = ImagePipeline.normalizingOrientation(photo)
        guard let cgImage = upright.cgImage, cgImage.width > 1, cgImage.height > 1 else {
            throw ParallaxRenderer.RenderError.noPixels
        }
        let longest = CGFloat(max(cgImage.width, cgImage.height))
        let scale = min(1, longEdge / longest)
        let width = max(2, Int(CGFloat(cgImage.width) * scale / 2) * 2)
        let height = max(2, Int(CGFloat(cgImage.height) * scale / 2) * 2)
        var pixels = [UInt32](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = Self.context(width: width, height: height, data: bytes.baseAddress) else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ParallaxRenderer.RenderError.noPixels }
        self.init(width: width, height: height, pixels: pixels)
    }

    var image: CGImage {
        let data = pixels.withUnsafeBytes { Data($0) }
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: Self.bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
    }

    static let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    )

    static func context(width: Int, height: Int, data: UnsafeMutableRawPointer?) -> CGContext? {
        CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        )
    }
}

/// Writes a handful of pictures out as a clip, in a given order, each held for
/// a whole number of frames.
///
/// H.264 at the writer's default quality, like `StillClipWriter`: this file is
/// an intermediate that `VideoPipeline` re-encodes on send, and only has to be
/// good enough to preview. The session ends exactly on the last frame's end,
/// so a player looping it steps from the last frame to the first with nothing
/// in between.
enum FrameSequenceWriter {
    static func write(
        _ images: [CGImage],
        sequence: [Int],
        framesPerImage: Int,
        framesPerSecond: Int32,
        to url: URL
    ) async throws {
        guard let first = images.first else { throw VideoPipeline.PipelineError.writeFailed }
        let width = first.width / 2 * 2
        let height = first.height / 2 * 2

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        // One buffer per picture, however many times it is shown.
        let buffers = try images.map { image in
            guard let buffer = StillClipWriter.pixelBuffer(image, width: width, height: height) else {
                throw VideoPipeline.PipelineError.writeFailed
            }
            return buffer
        }
        guard writer.startWriting() else { throw VideoPipeline.PipelineError.writeFailed }
        writer.startSession(atSourceTime: .zero)

        var frame: CMTimeValue = 0
        for index in sequence {
            for _ in 0..<framesPerImage {
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(2))
                }
                let time = CMTime(value: frame, timescale: framesPerSecond)
                guard adaptor.append(buffers[index], withPresentationTime: time) else {
                    throw VideoPipeline.PipelineError.writeFailed
                }
                frame += 1
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: frame, timescale: framesPerSecond))
        await writer.finishWriting()
        guard writer.status == .completed else { throw VideoPipeline.PipelineError.writeFailed }
    }
}
#endif
