#if canImport(UIKit)
import Accelerate
import CoreML
import CoreVideo
import UIKit

/// Guesses how near each part of a photo is, from its pixels alone, with
/// Depth Anything V2 Small — Apple's Core ML conversion, 8-bit palettized,
/// Apache-2.0 (`Resources/DepthAnythingV2SmallF32P8.mlpackage`).
///
/// Estimated rather than measured because measuring costs the camera its zoom:
/// a capture device delivering depth restricts `videoZoomFactor`, and the pinch
/// stalls or does nothing. See `wiki/decisions.md`. Estimating after the shot
/// leaves the camera exactly as it was, and works on any photo — zoomed, from
/// the library, from a phone with one lens.
///
/// An actor so the model is loaded once and never run twice at the same time.
/// Loading it is most of a second, so it waits for the first 3D tap rather
/// than slowing every launch.
public actor DepthEstimator {
    public static let shared = DepthEstimator()

    public enum EstimateError: Error, Equatable {
        case modelMissing
        case noPixels
        case noOutput
    }

    static let modelName = "DepthAnythingV2SmallF32P8"
    /// The model takes exactly this, and nothing else.
    static let inputWidth = 518
    static let inputHeight = 392

    private var model: MLModel?

    public init() {}

    public func estimate(_ photo: UIImage) throws -> DepthMap {
        let model = try loaded()
        guard let image = ImagePipeline.normalizingOrientation(photo).cgImage,
              image.width > 0, image.height > 0
        else { throw EstimateError.noPixels }

        let content = Self.letterbox(width: image.width, height: image.height)
        let input = try Self.inputBuffer(image, in: content)
        let prediction = try model.prediction(from: MLDictionaryFeatureProvider(
            dictionary: ["image": MLFeatureValue(pixelBuffer: input)]
        ))
        guard let output = prediction.featureValue(for: "depth")?.imageBufferValue,
              let depth = Self.read(output, in: content)
        else { throw EstimateError.noOutput }
        return depth
    }

    private func loaded() throws -> MLModel {
        if let model { return model }
        guard let url = Bundle.main.url(forResource: Self.modelName, withExtension: "mlmodelc") else {
            throw EstimateError.modelMissing
        }
        let configuration = MLModelConfiguration()
        #if targetEnvironment(simulator)
        // The Simulator's GPU path runs this model to an answer of all zeros,
        // without an error. A flat map is a 3D clip where nothing moves.
        configuration.computeUnits = .cpuOnly
        #else
        configuration.computeUnits = .all
        #endif
        let loaded = try MLModel(contentsOf: url, configuration: configuration)
        model = loaded
        return loaded
    }

    /// Where the photo sits inside the model's input, top-left origin: as large
    /// as fits, centred, the right way up.
    ///
    /// Fitted, not stretched or turned. The input is landscape and nearly every
    /// photo is portrait; stretching one into it makes every face twice as
    /// wide as a face, and turning it lays people on their sides — the network
    /// was trained on neither, and its guesses about both are worse than about
    /// a smaller picture of the right shape. The bands either side are grey
    /// and are never read back.
    static func letterbox(width: Int, height: Int) -> CGRect {
        let scale = min(Double(inputWidth) / Double(width), Double(inputHeight) / Double(height))
        let fittedWidth = max(1, min(inputWidth, Int((Double(width) * scale).rounded())))
        let fittedHeight = max(1, min(inputHeight, Int((Double(height) * scale).rounded())))
        return CGRect(
            x: (inputWidth - fittedWidth) / 2,
            y: (inputHeight - fittedHeight) / 2,
            width: fittedWidth,
            height: fittedHeight
        )
    }

    private static func inputBuffer(_ image: CGImage, in content: CGRect) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, inputWidth, inputHeight, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary, &buffer)
        guard let buffer else { throw EstimateError.noPixels }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: inputWidth,
            height: inputHeight,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw EstimateError.noPixels }
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: inputWidth, height: inputHeight))
        context.interpolationQuality = .high
        // Core Graphics counts rows from the bottom.
        context.draw(image, in: CGRect(
            x: content.minX,
            y: CGFloat(inputHeight) - content.maxY,
            width: content.width,
            height: content.height
        ))
        return buffer
    }

    /// The part of the model's answer that is the photo, as a normalized map.
    /// The model answers in relative disparity — larger is nearer — which is
    /// what `DepthMap` holds.
    static func read(_ buffer: CVPixelBuffer, in content: CGRect) -> DepthMap? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              CVPixelBufferGetWidth(buffer) >= Int(content.maxX),
              CVPixelBufferGetHeight(buffer) >= Int(content.maxY)
        else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let width = Int(content.width)
        let height = Int(content.height)
        let x0 = Int(content.minX)
        let y0 = Int(content.minY)
        var raw = [Float](repeating: 0, count: width * height)

        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent16Half:
            // Through vImage rather than `Float16`, which the Simulator on an
            // Intel Mac does not have.
            raw.withUnsafeMutableBytes { destination in
                var source = vImage_Buffer(
                    data: base.advanced(by: y0 * rowBytes + x0 * 2),
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: rowBytes
                )
                var target = vImage_Buffer(
                    data: destination.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * MemoryLayout<Float>.size
                )
                vImageConvert_Planar16FtoPlanarF(&source, &target, 0)
            }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<height {
                let row = base.advanced(by: (y0 + y) * rowBytes).assumingMemoryBound(to: Float.self)
                for x in 0..<width {
                    raw[y * width + x] = row[x0 + x]
                }
            }
        default:
            return nil
        }
        return DepthMap.normalized(width: width, height: height, raw: raw)
    }
}
#endif
