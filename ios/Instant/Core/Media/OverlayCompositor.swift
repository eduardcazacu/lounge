#if canImport(UIKit)
import Foundation
import UIKit

/// Burns the caption into the pixels.
///
/// The caption is deliberately not a field on the wire: the backend only ever
/// sees final image bytes, and since those bytes are encrypted it could not read
/// the text even if it wanted to. Geometry matches
/// `frontend/src/components/instant/InstantComposer.tsx` so a photo looks the
/// same whichever client composed it.
public enum OverlayCompositor {
    /// Normalized position, clamped to the same 0.05...0.95 range the web
    /// composer uses so the caption cannot be dragged off the image.
    public struct Placement: Equatable, Sendable {
        public var x: Double
        public var y: Double

        public static let `default` = Placement(x: 0.5, y: 0.85)

        public init(x: Double, y: Double) {
            self.x = Placement.clamp(x)
            self.y = Placement.clamp(y)
        }

        public static func clamp(_ value: Double) -> Double {
            min(0.95, max(0.05, value))
        }
    }

    public static let maxCaptionLength = 80

    /// `600 ${Math.round(canvas.width * 0.06)}px` in the web composer. It scales
    /// with the image width, not the screen, so the caption occupies the same
    /// fraction of the photo at any capture resolution.
    public static func fontSize(forWidth width: Double) -> Double {
        (width * 0.06).rounded()
    }

    /// `rgba(15, 23, 42, 0.55)` — slate-900 at 55%.
    static let plateColor = UIColor(red: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 0.55)

    public static func composite(
        image: UIImage,
        caption: String,
        placement: Placement
    ) -> UIImage {
        let base = ImagePipeline.normalizingOrientation(image)
        let trimmed = String(caption.prefix(maxCaptionLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }

        let size = base.size
        let fontSize = fontSize(forWidth: Double(size.width))
        let padding = fontSize * 0.4

        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            base.draw(in: CGRect(origin: .zero, size: size))

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
            ]

            // Wrap inside the image rather than letting a long caption run off
            // the edge; the web canvas measures a single line, but an 80-char
            // caption on a narrow photo needs to break.
            let available = CGSize(width: size.width - padding * 4, height: .greatestFiniteMagnitude)
            let bounds = (trimmed as NSString).boundingRect(
                with: available,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            )

            let centerX = size.width * placement.x
            let centerY = size.height * placement.y
            let plate = CGRect(
                x: centerX - bounds.width / 2 - padding,
                y: centerY - bounds.height / 2 - padding,
                width: bounds.width + padding * 2,
                height: bounds.height + padding * 2
            )

            context.cgContext.setFillColor(plateColor.cgColor)
            UIBezierPath(roundedRect: plate, cornerRadius: padding * 0.75).fill()

            (trimmed as NSString).draw(
                with: CGRect(
                    x: centerX - bounds.width / 2,
                    y: centerY - bounds.height / 2,
                    width: bounds.width,
                    height: bounds.height
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            )
        }
    }
}
#endif
