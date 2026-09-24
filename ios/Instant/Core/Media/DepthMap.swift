#if canImport(UIKit)
import Foundation

/// How near each part of a photo is, in the photo's own frame.
///
/// Normalized disparity, 0 for the farthest thing in the picture and 1 for the
/// nearest. Disparity rather than depth because that is what parallax is: how
/// far a point moves when the eye does falls off as one over distance, and
/// disparity already is one over distance. Normalized because the renderer
/// wants a picture-relative "near" and "far" — a selfie at arm's length and a
/// street at thirty metres should wiggle about as much as each other.
///
/// Small on purpose: `DepthEstimator`'s map is a few hundred pixels across, and
/// it is only blown up to the photo's size when the clip is rendered.
public struct DepthMap: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// Row-major, top row first.
    public let values: [Float]

    public init(width: Int, height: Int, values: [Float]) {
        precondition(values.count == width * height, "a depth map is width × height values")
        self.width = width
        self.height = height
        self.values = values
    }

    public func value(x: Int, y: Int) -> Float {
        values[y * width + x]
    }

    /// Stretches raw disparity to 0…1 between its 2nd and 98th percentiles.
    ///
    /// Percentiles rather than the extremes, because an estimated map has a
    /// few wild values — a reflection, a sliver of sky read as very near — and
    /// one of them at the top of the range squashes the whole real scene into
    /// the bottom tenth of it: a clip that barely moves. Anything not finite
    /// is read as far.
    static func normalized(width: Int, height: Int, raw: [Float]) -> DepthMap? {
        let finite = raw.filter(\.isFinite).sorted()
        guard !finite.isEmpty else { return nil }
        let low = finite[Int(Double(finite.count - 1) * 0.02)]
        let high = finite[Int(Double(finite.count - 1) * 0.98)]
        let span = high - low
        // A flat scene — a wall, a sheet of paper — has no depth to speak of,
        // and nothing in it moves.
        guard span > .ulpOfOne else {
            return DepthMap(width: width, height: height, values: [Float](repeating: 0, count: raw.count))
        }
        let values = raw.map { value -> Float in
            guard value.isFinite else { return 0 }
            return min(1, max(0, (value - low) / span))
        }
        return DepthMap(width: width, height: height, values: values)
    }
}
#endif
