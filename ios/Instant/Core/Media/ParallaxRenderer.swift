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
    static let maxShift: Float = 0.022

    /// How much further than the arithmetic says a thing nearer than the
    /// subject swings.
    ///
    /// A lens moving sideways shifts what it sees by the difference in
    /// *disparity*, and disparity is one over distance: a hand at arm's
    /// length is as far in front of a face as the face is in front of the
    /// far wall, so on a Nishika it swings about as far as the wall does, the
    /// other way. An estimated map does not keep those proportions — it
    /// spends most of its range on the scene and crowds everything close to
    /// the lens into the top of it — so the near half of it is stretched back
    /// out here. Without this, a hand held up to the camera barely moves.
    static let nearBoost: Float = 2.2

    /// How far a pixel of this disparity moves for a lens this far off centre.
    @inline(__always)
    static func move(_ disparity: Float, key: Float, shift: Float) -> Float {
        let difference = key - disparity
        return shift * (difference < 0 ? difference * nearBoost : difference)
    }

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

    /// Which of the four viewpoints a frame of the clip is showing.
    ///
    /// The film grain hangs off this: one grain per viewpoint, the same every
    /// time that viewpoint comes round, so a picture that is meant to be
    /// still does not crawl. Views 2 and 3 of the cycle are the same
    /// viewpoint coming back, and get the same grain.
    static func viewIndex(atFrame frame: Int) -> Int {
        let step = max(0, frame) / framesPerView
        return cycle[step % cycle.count]
    }

    static var duration: Double {
        Double(sequence.count * framesPerView) / Double(frameRate)
    }

    /// The clip's long edge. `VideoPipeline` sends no more than this anyway,
    /// and a library photo can be twice it.
    static let longEdge: CGFloat = 1920

    /// Renders the four views and writes them out as a looping clip. The
    /// caller owns the file.
    public static func makeClip(
        photo: UIImage,
        depth: DepthMap,
        masks: [SubjectMask] = []
    ) async throws -> RecordedClip {
        let views = try await Task.detached(priority: .userInitiated) {
            try renderViews(photo: photo, depth: depth, masks: masks)
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
    static func renderViews(photo: UIImage, depth: DepthMap, masks: [SubjectMask] = []) throws -> [CGImage] {
        let source = try Bitmap(photo, longEdge: longEdge)
        let measured = upsampled(depth, toMatch: source)
        // Pixels per unit of lens offset per unit of disparity, chosen so the
        // outermost lens moves the most distant thing `maxShift` of the width.
        let outermost = viewOffsets.map(abs).max() ?? 1
        let gain = maxShift * Float(source.width) / outermost
        if let layers = layers(source: source, disparity: measured, masks: masks) {
            // Told where the subject is, the depth inside it is left alone —
            // a body leaning towards the camera is meant to have a gradient,
            // and stepping one into flat cards is what used to tear it.
            let key = keyDisparity(of: layers) ?? keyDisparity(depth)
            let margin = edgeMargin(measured, key: key, shift: outermost * gain, width: source.width)
            return try viewOffsets.map {
                try zoomed(split(composited(layers, key: key, shift: $0 * gain)), margin: margin)
            }
        }
        // Nothing found to segment by — no face, no animal, nothing that
        // stands out — so the outline comes out of the depth map, and what
        // the wiggle turns about is whatever is in the middle of the frame
        // (`keyDisparity`), which is what the photographer pointed at.
        let disparity = stepped(measured, width: source.width, height: source.height)
        let key = keyDisparity(depth)
        let (grown, grownDisparity) = enlarged(source, disparity: disparity)
        let unsure = besideNearer(grownDisparity, width: source.width, height: source.height)
        let margin = edgeMargin(grownDisparity, key: key, shift: outermost * gain, width: source.width)
        return try viewOffsets.map { offset in
            try zoomed(
                split(warp(grown, disparity: grownDisparity, key: key, shift: offset * gain, dropping: unsure)),
                margin: margin
            )
        }
    }

    /// The most any pixel moves in the outermost view, as a share of the
    /// width — which is how much has to be cropped off every side.
    ///
    /// Anything that moves inwards uncovers the frame's own edge, and a thing
    /// close to the lens at the edge of the picture — a hand holding the
    /// phone — moves the most of all, so what it uncovers is a strip of
    /// invented picture where its own edge used to be. Enlarging every view
    /// by exactly that much puts the frame's edge outside the picture, and
    /// costs the few percent of the photo that would otherwise be made up.
    static func edgeMargin(_ disparity: [Float], key: Float, shift: Float, width: Int) -> CGFloat {
        var furthest: Float = 0
        for value in disparity { furthest = max(furthest, abs(move(value, key: key, shift: shift))) }
        return CGFloat(min(furthest / Float(width), maxMargin))
    }

    /// However far things move, no more of the picture than this is given up
    /// to hide the frame's edge.
    static let maxMargin: Float = 0.05

    /// A view enlarged about its middle by `margin` on every side, so nothing
    /// shows the strip at the frame's edge that it had no picture for. Evenly,
    /// so the shape and size are the photo's and a caption's placement, kept
    /// in fractions of the frame, still lands where it was put.
    static func zoomed(_ view: Bitmap, margin: CGFloat) throws -> CGImage {
        guard margin > 0.0005 else { return view.image }
        let width = CGFloat(view.width)
        let height = CGFloat(view.height)
        let inset = CGRect(x: 0, y: 0, width: width, height: height)
            .insetBy(dx: (width * margin).rounded(), dy: (height * margin).rounded())
        guard let cropped = view.image.cropping(to: inset),
              let context = Bitmap.context(width: view.width, height: view.height, data: nil)
        else { throw RenderError.noPixels }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw RenderError.noPixels }
        return image
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

    /// How far apart the red and the blue are pulled, in pixels of a
    /// 1080-wide frame.
    static let fringe: Float = 3

    /// A lens that does not quite bring every colour to the same place.
    ///
    /// Real glass does this, mildly, and it is on purpose here: the warp
    /// moves pixels sideways in whole steps, so what it leaves along an
    /// outline is a hard stair. Red and blue pulled a pixel apart put a soft
    /// colour edge over that stair, and the eye reads the softness rather
    /// than the steps. Sideways only, because sideways is the way the cut
    /// lines run.
    static func split(_ view: Bitmap) -> Bitmap {
        let width = view.width
        let height = view.height
        let offset = Int((fringe * Float(width) / 1080).rounded())
        guard offset > 0 else { return view }
        var pixels = view.pixels
        view.pixels.withUnsafeBufferPointer { input in
            pixels.withUnsafeMutableBufferPointer { output in
                let input = input, output = output
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    let row = y * width
                    for x in 0..<width {
                        let redAt = min(width - 1, x + offset)
                        let blueAt = max(0, x - offset)
                        output[row + x] = (input[row + x] & 0xFF00_FF00)
                            | (input[row + redAt] & 0x0000_00FF)
                            | (input[row + blueAt] & 0x00FF_0000)
                    }
                }
            }
        }
        return Bitmap(width: width, height: height, pixels: pixels, isMatted: view.isMatted)
    }

    // MARK: - Layers

    /// One plane of the picture: its pixels, premultiplied by the share of it
    /// they are, and the depth to move them by.
    ///
    /// The background is one, and every subject Vision found is another. Each
    /// is warped on its own and they are composited back to front, so an
    /// outline is a matte rather than a cut, and nothing has to be guessed
    /// about which side of an edge a half-covered pixel belongs to: it is on
    /// both, in its own proportion.
    struct RenderLayer {
        var bitmap: Bitmap
        var disparity: [Float]
        var centre: (x: Float, y: Float)
        var growth: Float
        /// What this layer's own depth is, for ordering it against the others.
        var median: Float
        /// Its near side, which is the part of a person a photo is of: the
        /// face, not the feet. The wiggle turns about this.
        var nearSide: Float
        /// The share of the picture it covers, for picking the main subject.
        var coverage: Double
        /// The background closes the gaps a view uncovers. A subject leaves
        /// its own uncovered edges transparent, so the layer behind shows
        /// through — which is what is actually behind it.
        var fillsGaps: Bool
    }

    /// Anything the masks cover this faintly is still the subject's, so the
    /// background gives it up rather than carry a rim of subject colour.
    static let maskTouch: UInt8 = 8

    /// How wide a band around a mask the background gives up as well, as a
    /// share of the width.
    ///
    /// A balance, measured on photographs rather than guessed. Vision's mask
    /// arrives as a ramp a dozen pixels wide and `SubjectMask.sharpened` cuts
    /// the outer half of it off; the pixels it cuts are the subject's — the
    /// wisps of somebody's hair. Left in the background they travel at the
    /// background's speed and show up as a second, slightly larger copy of
    /// the outline moving out of step with it. Given up too generously, on
    /// the other hand, the band around the subject is all invented wall, and
    /// the invention has an edge of its own. Six pixels in a thousand is
    /// where the outline stopped doubling and the invented band was still
    /// small enough not to show.
    static let maskSkirt: Float = 0.006
    /// How far outside a mask to read the depth of whatever it stands in
    /// front of, as a share of the width.
    static let behindReach: Float = 0.015

    /// The picture cut into layers by the masks, background first and then the
    /// subjects from farthest to nearest. Nil when there is nothing usable to
    /// cut it with, and 3D reads the outline out of the depth map as before.
    static func layers(
        source: Bitmap,
        disparity: [Float],
        masks: [SubjectMask]
    ) -> [RenderLayer]? {
        let width = source.width
        let height = source.height
        let fitted = masks.compactMap { resampled($0, width: width, height: height) }
        guard !fitted.isEmpty else { return nil }

        // The background gives up every pixel any mask touches, and a skirt
        // all round: its colour there is part subject, and carrying it into a
        // view is how the outline leaves a ghost of itself behind.
        var union = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            union[index] = fitted.reduce(UInt8(0)) { max($0, $1.alpha[index]) }
        }
        let skirt = max(1, Int((maskSkirt * Float(width)).rounded()))
        let claimedAll = grown(union, width: width, height: height, radius: skirt)
        var backgroundPixels = source.pixels
        var covered = 0
        for index in 0..<(width * height) {
            let claimed = claimedAll[index]
            if claimed >= maskTouch {
                backgroundPixels[index] = 0
                covered += 1
            } else {
                backgroundPixels[index] |= opaque
            }
        }
        guard covered < width * height else { return nil }
        // What is behind the subject, invented where it has to be. The
        // subject's own rim is read against this, and every view is drawn
        // over it.
        let behind = closed(backgroundPixels, width: width, height: height, disparity: disparity)

        var subjects: [RenderLayer] = []
        for mask in fitted {
            guard let layer = subjectLayer(mask, source: source, backdrop: behind, disparity: disparity)
            else { continue }
            subjects.append(layer)
        }
        guard !subjects.isEmpty else { return nil }

        let background = RenderLayer(
            bitmap: Bitmap(width: width, height: height, pixels: backgroundPixels, isMatted: true),
            disparity: disparity,
            centre: (Float(width) / 2, Float(height) / 2),
            growth: 0,
            median: median(of: disparity, where: { _ in true }, step: 7) ?? 0,
            nearSide: 0,
            coverage: Double(width * height - covered) / Double(width * height),
            fillsGaps: true
        )
        return [background] + subjects.sorted { $0.median < $1.median }
    }

    /// The background with the hole the subject leaves closed up, in the
    /// picture's own frame — the wall as it would look with nobody in front
    /// of it. Mirrored inwards, exactly as a gap is closed in a view.
    static func closed(
        _ pixels: [UInt32],
        width: Int,
        height: Int,
        disparity: [Float]
    ) -> [UInt32] {
        var filled = pixels
        var nearness = (0..<pixels.count).map { coverage(pixels[$0]) > 0 ? disparity[$0] : -1 }
        filled.withUnsafeMutableBufferPointer { output in
            nearness.withUnsafeMutableBufferPointer { landed in
                for y in 0..<height {
                    fill(row: y * width, width: width, pixels: output, nearness: landed)
                }
            }
        }
        return filled
    }

    /// One subject: its own pixels, its own depth, and how much it grows.
    private static func subjectLayer(
        _ mask: SubjectMask,
        source: Bitmap,
        backdrop: [UInt32],
        disparity: [Float]
    ) -> RenderLayer? {
        let width = source.width
        let height = source.height
        let inside = median(of: disparity, where: { mask.alpha[$0] > 200 }, step: 3)
        guard let inside else { return nil }
        // A person is not a plane: the face is a long way in front of the
        // feet, and pinning the wiggle to the middle of them leaves the face
        // drifting. The face where Vision found one, and the near side of the
        // subject otherwise — which is what the depth-only path does too.
        let nearSide = mask.focus
            .flatMap { face in
                median(of: disparity, where: { index in
                    let x = index % width, y = index / width
                    return mask.alpha[index] > 200 && face.contains(CGPoint(x: x, y: y))
                }, step: 2)
            }
            ?? percentile(0.75, of: disparity, where: { mask.alpha[$0] > 200 }, step: 3)
            ?? inside

        // What the subject stands in front of: the depth of a ring just
        // outside its outline. The jump across that outline is both how much
        // the background will move behind it and how much it grows, which is
        // not a coincidence — the band a view uncovers beside it is exactly
        // that wide.
        let reach = max(1, Int((behindReach * Float(width)).rounded()))
        let ring = grown(mask.alpha, width: width, height: height, radius: reach)
        let behind = median(of: disparity, where: { ring[$0] > 128 && mask.alpha[$0] < maskTouch }, step: 3)
        let jump = min(1, max(0, inside - (behind ?? 0)))
        // The mask's own inner rim, where the depth map is still reading the
        // wall. Only there: a subject is allowed to be as deep as it likes in
        // the middle — that is the slant this layering is for.
        let shrunk = shrunk(mask.alpha, width: width, height: height, radius: reach)
        // The subject claims one pixel more than the mask does.
        //
        // What is left half-claimed at an outline is drawn as part subject
        // and part invented background, and the invention is never quite the
        // wall that was really behind the hair — the difference shows as a
        // thin bright line all the way round. Covered by the subject instead,
        // the edge is drawn from the photograph, which is where the true
        // mixture of hair and wall already is.
        let claiming = grown(mask.alpha, width: width, height: height, radius: 1)
        // What the subject's depth is just inside its outline, for the rim to
        // borrow. Its own local depth, not the whole subject's middle, so a
        // slanted one keeps its slant right out to the edge.
        let nearby = extreme(disparity, width: width, height: height, radius: reach, nearest: true)
            ?? disparity

        var sumX = 0.0, sumY = 0.0, weight = 0.0
        var pixels = [UInt32](repeating: 0, count: width * height)
        var depth = disparity
        for index in 0..<(width * height) {
            let alpha = claiming[index]
            guard alpha > 0 else { continue }
            pixels[index] = matted(source.pixels[index], alpha: alpha, over: backdrop[index])
            // The depth map's outline is not the mask's, so the rim of the
            // mask holds the wall's depth. Every pixel of this layer — the
            // half-covered ones at its edge most of all — has to travel at
            // the subject's speed. Left at the wall's, they trail a pixel
            // behind the outline and read as a second copy of the subject,
            // wiggling out of step with it.
            if shrunk[index] < 128, depth[index] < nearby[index] - edgeStep {
                depth[index] = nearby[index]
            }
            if alpha > 128 {
                let w = Double(alpha) / 255
                sumX += Double(index % width) * w
                sumY += Double(index / width) * w
                weight += w
            }
        }
        guard weight > 0 else { return nil }
        return RenderLayer(
            bitmap: Bitmap(width: width, height: height, pixels: pixels, isMatted: true),
            disparity: depth,
            centre: (Float(sumX / weight), Float(sumY / weight)),
            growth: maxGrowth * jump,
            median: inside,
            nearSide: nearSide,
            coverage: mask.coverage,
            fillsGaps: false
        )
    }

    /// The middle disparity of the pixels a test picks out, sampled every
    /// `step` to keep the sort cheap.
    static func median(of disparity: [Float], where include: (Int) -> Bool, step: Int) -> Float? {
        percentile(0.5, of: disparity, where: include, step: step)
    }

    /// The value a given way up the pixels a test picks out, sampled every
    /// `step` to keep the sort cheap.
    static func percentile(
        _ fraction: Double,
        of disparity: [Float],
        where include: (Int) -> Bool,
        step: Int
    ) -> Float? {
        var picked: [Float] = []
        picked.reserveCapacity(disparity.count / (step * step))
        for index in stride(from: 0, to: disparity.count, by: step) where include(index) {
            picked.append(disparity[index])
        }
        guard !picked.isEmpty else { return nil }
        picked.sort()
        return picked[Int(Double(picked.count - 1) * fraction)]
    }

    /// A mask shrunk by `radius`, for telling its rim from its middle.
    static func shrunk(_ alpha: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        morphology(alpha, width: width, height: height, radius: radius, grow: false)
    }

    /// A mask grown by `radius`, for reading what lies just outside it.
    static func grown(_ alpha: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        morphology(alpha, width: width, height: height, radius: radius, grow: true)
    }

    private static func morphology(
        _ alpha: [UInt8],
        width: Int,
        height: Int,
        radius: Int,
        grow: Bool
    ) -> [UInt8] {
        var source = alpha
        var result = [UInt8](repeating: 0, count: alpha.count)
        let kernel = vImagePixelCount(2 * radius + 1)
        let ok = source.withUnsafeMutableBufferPointer { input in
            result.withUnsafeMutableBufferPointer { output in
                var from = vImage_Buffer(
                    data: input.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                var to = vImage_Buffer(
                    data: output.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                let flags = vImage_Flags(kvImageNoFlags)
                let error = grow
                    ? vImageMax_Planar8(&from, &to, nil, 0, 0, kernel, kernel, flags)
                    : vImageMin_Planar8(&from, &to, nil, 0, 0, kernel, kernel, flags)
                return error == kvImageNoError
            }
        }
        return ok ? result : alpha
    }

    /// A mask at the size the renderer works at. Vision answers at the photo's
    /// size, which is not the size a big library photo is rendered at.
    static func resampled(_ mask: SubjectMask, width: Int, height: Int) -> SubjectMask? {
        guard mask.width > 1, mask.height > 1 else { return nil }
        guard mask.width != width || mask.height != height else { return mask }
        // Averaged over the box each pixel came from, not sampled at its
        // middle: a matte shrunk by nearest neighbour loses the rim that
        // makes it a matte, and gains a staircase.
        var alpha = [UInt8](repeating: 0, count: width * height)
        let scaleX = Double(mask.width) / Double(width)
        let scaleY = Double(mask.height) / Double(height)
        for y in 0..<height {
            let y0 = min(mask.height - 1, Int(Double(y) * scaleY))
            let y1 = max(y0 + 1, min(mask.height, Int(Double(y + 1) * scaleY)))
            for x in 0..<width {
                let x0 = min(mask.width - 1, Int(Double(x) * scaleX))
                let x1 = max(x0 + 1, min(mask.width, Int(Double(x + 1) * scaleX)))
                var total = 0
                for sy in y0..<y1 {
                    for sx in x0..<x1 { total += Int(mask.alpha[sy * mask.width + sx]) }
                }
                alpha[y * width + x] = UInt8(total / ((y1 - y0) * (x1 - x0)))
            }
        }
        return SubjectMask(
            width: width,
            height: height,
            alpha: alpha,
            focus: mask.focus.map {
                CGRect(
                    x: $0.minX * CGFloat(width) / CGFloat(mask.width),
                    y: $0.minY * CGFloat(height) / CGFloat(mask.height),
                    width: $0.width * CGFloat(width) / CGFloat(mask.width),
                    height: $0.height * CGFloat(height) / CGFloat(mask.height)
                )
            }
        )
    }

    /// The key plane the whole wiggle turns about: the biggest subject's own
    /// depth, which is what a Nishika's user would have focused on.
    static func keyDisparity(of layers: [RenderLayer]) -> Float? {
        layers.filter { !$0.fillsGaps }.max { $0.coverage < $1.coverage }?.nearSide
    }

    /// One view of a layered picture: each layer moved on its own, then laid
    /// over the one behind it.
    static func composited(_ layers: [RenderLayer], key: Float, shift: Float) -> Bitmap {
        var result: Bitmap?
        for layer in layers {
            let (bitmap, disparity) = layer.growth > 0
                ? enlargedLayer(layer)
                : (layer.bitmap, layer.disparity)
            let warped = warp(
                bitmap,
                disparity: disparity,
                key: key,
                shift: shift,
                fills: layer.fillsGaps
            )
            result = result.map { over(warped, $0) } ?? warped
        }
        return result ?? Bitmap(width: 1, height: 1, pixels: [0])
    }

    /// A layer enlarged about its own middle, sampled backwards so it stays
    /// smooth. Its alpha grows with it, so the matte is enlarged too.
    static func enlargedLayer(_ layer: RenderLayer) -> (Bitmap, [Float]) {
        let width = layer.bitmap.width
        let height = layer.bitmap.height
        let full = 1 + layer.growth
        var pixels = [UInt32](repeating: 0, count: width * height)
        var depth = [Float](repeating: 0, count: width * height)
        layer.bitmap.pixels.withUnsafeBufferPointer { input in
            layer.disparity.withUnsafeBufferPointer { near in
                pixels.withUnsafeMutableBufferPointer { output in
                    depth.withUnsafeMutableBufferPointer { landed in
                        let input = input, near = near, output = output, landed = landed
                        let centre = layer.centre
                        DispatchQueue.concurrentPerform(iterations: height) { y in
                            let row = y * width
                            let py = centre.y + (Float(y) - centre.y) / full
                            for x in 0..<width {
                                let px = centre.x + (Float(x) - centre.x) / full
                                guard px >= 0, px <= Float(width - 1), py >= 0, py <= Float(height - 1) else { continue }
                                let x0 = Int(px), y0 = Int(py)
                                let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
                                let top = mix(input[y0 * width + x0], input[y0 * width + x1], px - Float(x0))
                                let bottom = mix(input[y1 * width + x0], input[y1 * width + x1], px - Float(x0))
                                output[row + x] = mix(top, bottom, py - Float(y0))
                                landed[row + x] = near[y0 * width + x0]
                            }
                        }
                    }
                }
            }
        }
        return (Bitmap(width: width, height: height, pixels: pixels, isMatted: true), depth)
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
        dropping dropped: [Bool]? = nil,
        fills: Bool = true
    ) -> Bitmap {
        let width = source.width
        let height = source.height
        var pixels = [UInt32](repeating: 0, count: width * height)
        // Doubles as the gap mask: below zero is a place nothing landed.
        var nearness = [Float](repeating: -1, count: width * height)
        let dropped = dropped ?? []
        let matted = source.isMatted

        source.pixels.withUnsafeBufferPointer { input in
            disparity.withUnsafeBufferPointer { depth in
                pixels.withUnsafeMutableBufferPointer { output in
                    nearness.withUnsafeMutableBufferPointer { landed in
                        let input = input, depth = depth, output = output, landed = landed
                        DispatchQueue.concurrentPerform(iterations: height) { y in
                            let row = y * width
                            for x in 0..<width where dropped.isEmpty || !dropped[row + x] {
                                // A layer carries only its own pixels; what
                                // belongs to another is not its to move.
                                if matted, coverage(input[row + x]) == 0 { continue }
                                let d = depth[row + x]
                                let move = move(d, key: key, shift: shift)
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
                                // Never across a pixel that is not this
                                // layer's: blended with the nothing on the
                                // other side of its edge, a layer fades out
                                // over its last pixel and lets what is behind
                                // show through a seam.
                                let both = !matted
                                    || (coverage(input[row + left]) > 0 && coverage(input[row + right]) > 0)
                                output[row + target] = both
                                    ? mix(input[row + left], input[row + right], from - Float(left))
                                    : (coverage(input[row + left]) > 0 ? input[row + left] : input[row + right])
                                landed[row + target] = d
                            }
                            fill(
                                row: row,
                                width: width,
                                pixels: output,
                                nearness: landed,
                                // A subject closes the cracks its own slant
                                // opens, and leaves its edges to the layer
                                // behind it.
                                insideOnly: !fills
                            )
                        }
                    }
                }
            }
        }
        let closed = fills
            ? softened(pixels, gaps: nearness, width: width)
            : pixels
        return Bitmap(width: width, height: height, pixels: closed, isMatted: matted)
    }

    /// Closes each gap in a row with the background beside it.
    ///
    /// The farther of the gap's two neighbours is the background, and the gap
    /// is the background just beyond it mirrored back in, not one pixel drawn
    /// out: a stretched pixel is a streak, and a mirror carries the texture on
    /// across the edge without a seam at it. Mirrored rather than slid along,
    /// because a gap can be as wide as a person: slid, the pixel next to the
    /// subject — the only part of a wide gap anybody ever sees — would come
    /// from the far side of the picture. Where the mirror reaches into
    /// something nearer, the edge pixel is used instead, so the subject is
    /// never copied into its own shadow.
    static func fill(
        row: Int,
        width: Int,
        pixels: UnsafeMutableBufferPointer<UInt32>,
        nearness: UnsafeMutableBufferPointer<Float>,
        insideOnly: Bool = false
    ) {
        let widest = max(3, Int(Self.widestCrack * Double(width)))
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
            if insideOnly {
                // Only a crack: a run with the layer solid on both sides of
                // it. Its outer edge is not a gap at all, it is where the
                // layer ends.
                guard hasLeft, hasRight, length <= widest,
                      Self.coverage(pixels[row + left]) > 250, Self.coverage(pixels[row + right]) > 250
                else { continue }
            }

            // The farther side is the background. Where both sides are the
            // background — a gap as wide as a person, with wall either side —
            // each half is filled from its own edge, because the only part of
            // a wide gap anybody sees is where it meets the subject.
            let farther = min(
                hasLeft ? nearness[row + left] : .greatestFiniteMagnitude,
                hasRight ? nearness[row + right] : .greatestFiniteMagnitude
            )
            let leftIsBackground = hasLeft && nearness[row + left] <= farther + 0.05
            let rightIsBackground = hasRight && nearness[row + right] <= farther + 0.05
            for k in 0..<length {
                let nearerLeft = k < length - 1 - k
                let fromLeft = leftIsBackground && (nearerLeft || !rightIsBackground)
                let edge = fromLeft ? left : right
                // Counted out from that edge, and taken from the same
                // distance the other side of it.
                let step = fromLeft ? k : length - 1 - k
                let copied = fromLeft ? left - step : right + step
                let usable = copied >= 0 && copied < width
                    && nearness[row + copied] >= 0
                    && nearness[row + copied] <= farther + 0.05
                pixels[row + start + k] = pixels[row + (usable ? copied : edge)]
            }
            // Left marked as a gap on purpose: `softened` looks for exactly
            // these pixels.
        }
    }

    /// The widest run of missing pixels inside a layer that is taken for a
    /// crack its own stretching opened, rather than for a gap in its own
    /// outline — the daylight between an arm and a body, which the layer
    /// behind is meant to show through. A stretch can only open a crack as
    /// wide as the move it stretched by, which is a fraction of this.
    static let widestCrack = 0.01

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

    /// The channels of a pixel. Core Graphics fills the bitmap red first, so
    /// red is the *low* byte of the word and the byte it does not use — the
    /// top one — is where a layer keeps its coverage.
    @inline(__always) static func red(_ pixel: UInt32) -> UInt32 { pixel & 0xFF }
    @inline(__always) static func green(_ pixel: UInt32) -> UInt32 { (pixel >> 8) & 0xFF }
    @inline(__always) static func blue(_ pixel: UInt32) -> UInt32 { (pixel >> 16) & 0xFF }
    @inline(__always) static func coverage(_ pixel: UInt32) -> UInt32 { pixel >> 24 }
    static let opaque: UInt32 = 0xFF00_0000

    /// A colour scaled by the share of a pixel it covers, with that share
    /// kept in the low byte. Premultiplied, because a matte scaled or moved
    /// any other way picks up a dark or a light fringe wherever it is partly
    /// transparent.
    @inline(__always)
    static func premultiplied(_ colour: UInt32, alpha: UInt8) -> UInt32 {
        guard alpha < 255 else { return colour | opaque }
        var out = UInt32(alpha) << 24
        for shift in stride(from: UInt32(0), to: 24, by: 8) {
            let channel = (((colour >> shift) & 0xFF) * UInt32(alpha) + 127) / 255
            out |= channel << shift
        }
        return out
    }

    /// A pixel of a layer, premultiplied, with what the picture already had
    /// of the background taken back out of it.
    ///
    /// A pixel on an outline is part subject and part wall to begin with:
    /// `C = αF + (1 − α)B`. Premultiplying `C` and laying it over a wall again
    /// counts the wall twice, and the subject wears a bright line of it. So
    /// the subject's own colour is recovered first — `F = (C − (1 − α)B) / α`
    /// — and that is what the layer carries. Only the rim needs it; a pixel
    /// wholly inside the mask is already `F`.
    @inline(__always)
    static func matted(_ colour: UInt32, alpha: UInt8, over background: UInt32) -> UInt32 {
        guard alpha < 255 else { return colour | opaque }
        // Below this there is too little subject in the pixel to divide by,
        // and what comes out is noise.
        guard alpha > 40 else { return 0 }
        let a = UInt32(alpha)
        var out = a << 24
        for shift in stride(from: UInt32(0), to: 24, by: 8) {
            let mixed = Int(((colour >> shift) & 0xFF) * 255)
            let wall = Int((((background >> shift) & 0xFF)) * (255 - a))
            // α × F, which is what a premultiplied layer holds anyway, so
            // the division by α and the multiplication by it cancel.
            let own = max(0, min(255, (mixed - wall) / 255))
            out |= UInt32(own) << shift
        }
        return out
    }

    /// One premultiplied layer laid over another: `top + bottom × (1 − α)`.
    static func over(_ top: Bitmap, _ bottom: Bitmap) -> Bitmap {
        var pixels = bottom.pixels
        for index in 0..<min(top.pixels.count, pixels.count) {
            let above = top.pixels[index]
            let alpha = coverage(above)
            if alpha == 0 { continue }
            if alpha == 0xFF {
                pixels[index] = above
                continue
            }
            let rest = 255 - alpha
            var out = opaque
            for shift in stride(from: UInt32(0), to: 24, by: 8) {
                let channel = ((above >> shift) & 0xFF) + (((pixels[index] >> shift) & 0xFF) * rest + 127) / 255
                out |= min(channel, 0xFF) << shift
            }
            pixels[index] = out
        }
        return Bitmap(width: bottom.width, height: bottom.height, pixels: pixels, isMatted: bottom.isMatted)
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
    /// Whether the low byte of each pixel is a share of coverage rather than
    /// padding: true for a layer, false for the photo and for a finished view.
    var isMatted: Bool

    init(width: Int, height: Int, pixels: [UInt32], isMatted: Bool = false) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.isMatted = isMatted
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
