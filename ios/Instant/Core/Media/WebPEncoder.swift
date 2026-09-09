#if canImport(UIKit)
import CoreGraphics
import Foundation
import UIKit
import libwebp

/// Encodes to WebP with libwebp.
///
/// ImageIO cannot write WebP — `CGImageDestinationCopyTypeIdentifiers()` has no
/// `org.webmproject.webp` entry on any current OS. Since the web client hardcodes
/// `mediaType: "image/webp"` and its viewer decodes whatever `mediaType` says,
/// matching the format here keeps one code path on both ends rather than adding
/// a second one for iOS.
public enum WebPEncoder {
    public enum EncodeError: Error, Equatable {
        case noImageData
        case encodeFailed
    }

    /// Straight RGBA8888, one byte per channel.
    ///
    /// The bitmap is premultiplied, which is only equivalent to straight alpha
    /// because everything Instant encodes is drawn onto an opaque background
    /// first — the caption's translucent backing plate is flattened by the
    /// compositor before this sees it.
    static func rgbaBytes(from image: CGImage, width: Int, height: Int) -> Data? {
        let bytesPerRow = width * 4
        var buffer = Data(count: bytesPerRow * height)
        let success = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return success ? buffer : nil
    }

    /// - Parameter quality: 0...1, matching the canvas `toBlob` quality argument
    ///   the web client passes, so the two ladders mean the same thing.
    public static func encode(_ image: UIImage, quality: Double) throws -> Data {
        guard let cgImage = image.cgImage else { throw EncodeError.noImageData }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0,
              let rgba = rgbaBytes(from: cgImage, width: width, height: height)
        else { throw EncodeError.noImageData }

        var output: UnsafeMutablePointer<UInt8>?
        let written = rgba.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return WebPEncodeRGBA(
                base,
                Int32(width),
                Int32(height),
                Int32(width * 4),
                Float(quality * 100.0),
                &output
            )
        }

        guard written > 0, let output else { throw EncodeError.encodeFailed }
        defer { WebPFree(output) }
        return Data(bytes: output, count: written)
    }
}
#endif
