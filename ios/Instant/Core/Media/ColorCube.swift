#if canImport(UIKit)
import CoreImage
import Foundation

/// A colour lookup table, read from the `.cube` files that grading tools
/// write.
///
/// A film emulation is a measurement, not a formula: somebody photographed a
/// chart on the stock, scanned it, and wrote down where every colour lands.
/// A table says that directly, where a curve and a couple of matrices can
/// only lean in the same direction — and it says it in one step, with no
/// intermediate stage to go wrong in the wrong colour space.
struct ColorCube: Sendable {
    /// Entries along each edge: a 13 × 13 × 13 table has a dimension of 13.
    let dimension: Int
    /// Red, green, blue, alpha as `Float32`, red varying fastest — which is
    /// the order both the file and `CIColorCube` use.
    let data: Data

    /// The look itself, as Core Image applies it.
    ///
    /// **In sRGB, not in linear light.** A `.cube` is authored against the
    /// picture as it is encoded, which is how the eye and the grading tool
    /// both saw it; handed to Core Image's working space it would be read as
    /// linear and land somewhere else entirely. See `wiki/gotchas.md`.
    func apply(to input: CIImage) -> CIImage? {
        let cube = CIFilter.colorCubeWithColorSpace()
        cube.inputImage = input
        cube.cubeDimension = Float(dimension)
        cube.cubeData = data
        cube.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        return cube.outputImage
    }

    /// Reads one out of the app's own resources. Nil means the file is
    /// missing or malformed, which is a packaging mistake rather than
    /// anything a photo can cause — `PhotoFilterTests` fails on it.
    static func named(_ name: String, in bundle: Bundle = .main) -> ColorCube? {
        guard let url = bundle.url(forResource: name, withExtension: "cube"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return parse(text)
    }

    /// The format is plain enough to read here: comments, a size, an optional
    /// domain, and then one line of three numbers per entry.
    static func parse(_ text: String) -> ColorCube? {
        var dimension = 0
        var lowest = SIMD3<Float>(repeating: 0)
        var highest = SIMD3<Float>(repeating: 1)
        var entries: [Float] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let keyword = fields.first, !keyword.hasPrefix("#") else { continue }
            switch keyword {
            case "LUT_3D_SIZE":
                dimension = fields.count > 1 ? Int(fields[1]) ?? 0 : 0
            case "DOMAIN_MIN":
                lowest = triple(fields.dropFirst()) ?? lowest
            case "DOMAIN_MAX":
                highest = triple(fields.dropFirst()) ?? highest
            case "TITLE", "LUT_1D_SIZE":
                continue
            default:
                guard let colour = triple(fields) else { continue }
                // Core Image wants a fourth component, and an opaque one:
                // a look changes colour, never coverage.
                let span = highest - lowest
                let scaled = (colour - lowest) / SIMD3(
                    x: span.x == 0 ? 1 : span.x,
                    y: span.y == 0 ? 1 : span.y,
                    z: span.z == 0 ? 1 : span.z
                )
                entries.append(contentsOf: [scaled.x, scaled.y, scaled.z, 1])
            }
        }

        guard dimension > 1, entries.count == dimension * dimension * dimension * 4 else { return nil }
        return ColorCube(
            dimension: dimension,
            data: entries.withUnsafeBufferPointer { Data(buffer: $0) }
        )
    }

    private static func triple(_ fields: some Collection<Substring>) -> SIMD3<Float>? {
        let numbers = fields.compactMap { Float($0) }
        guard numbers.count == 3 else { return nil }
        return SIMD3(numbers[0], numbers[1], numbers[2])
    }
}
#endif
