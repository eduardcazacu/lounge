#if canImport(UIKit)
import Foundation
import UIKit

/// Burns the drawing and the captions into the pixels.
///
/// Neither is a field on the wire: the backend only ever sees final image
/// bytes, and since those bytes are encrypted it could not read the text even
/// if it wanted to.
///
/// A plate caption at scale 1 is the web composer's caption
/// (`frontend/src/components/instant/InstantComposer.tsx`). The bar, the
/// scale, there being more than one caption, and drawing exist only here — the
/// web composer cannot produce them, but it never has to: what arrives is
/// pixels.
public enum OverlayCompositor {
    /// Normalized position of a caption's centre, clamped to the same
    /// 0.05...0.95 range the web composer uses so a caption cannot be dragged
    /// off the image.
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

    public struct Caption: Identifiable, Equatable, Sendable {
        public enum Style: String, Sendable {
            /// A translucent band the full width of the photo — the default,
            /// and the look the editor itself has, so what was typed is what
            /// lands. It only moves up and down: it has no sides to move.
            case bar
            /// The text on its own rounded plate, which can be dragged
            /// anywhere, pinched to size and turned.
            case plate
        }

        public let id: UUID
        public var text: String
        public var style: Style
        public var placement: Placement
        /// Scale and rotation apply to the plate only. The bar is a band across
        /// the photo, and a band that grew or tilted would stop being one. Both
        /// are kept while a caption is a bar, so switching back restores them.
        public var scale: Double
        /// Radians, clockwise, about the caption's centre.
        public var rotation: Double

        public init(
            id: UUID = UUID(),
            text: String = "",
            style: Style = .bar,
            placement: Placement = .default,
            scale: Double = 1,
            rotation: Double = 0
        ) {
            self.id = id
            self.text = text
            self.style = style
            self.placement = placement
            self.scale = OverlayCompositor.clampScale(scale)
            self.rotation = rotation
        }

        /// What is actually drawn, which for a bar is always level.
        public var drawnRotation: Double {
            style == .plate ? rotation : 0
        }

        /// What gets drawn: capped, and with nothing to draw when blank.
        public var trimmed: String {
            String(text.prefix(OverlayCompositor.maxCaptionLength))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public static let maxCaptionLength = 80

    /// The drawing pen's colours. A fixed handful rather than a picker: a
    /// finger on a photo wants a few loud, distinct colours, not a spectrum.
    public enum Ink: String, CaseIterable, Sendable {
        case white, black, red, orange, yellow, green, blue, purple, pink

        public var color: UIColor {
            switch self {
            case .white: UIColor(white: 1, alpha: 1)
            case .black: UIColor(white: 0, alpha: 1)
            case .red: UIColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)
            case .orange: UIColor(red: 1, green: 0.58, blue: 0, alpha: 1)
            case .yellow: UIColor(red: 1, green: 0.84, blue: 0.04, alpha: 1)
            case .green: UIColor(red: 0.2, green: 0.84, blue: 0.29, alpha: 1)
            case .blue: UIColor(red: 0.04, green: 0.52, blue: 1, alpha: 1)
            case .purple: UIColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1)
            case .pink: UIColor(red: 1, green: 0.22, blue: 0.62, alpha: 1)
            }
        }
    }

    /// One touch of the pen, from finger down to finger up.
    public struct Stroke: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let ink: Ink
        /// Fractions of the photo, like a caption's placement, so the preview
        /// and the full-resolution render draw the same line. Unclamped: a
        /// line may run off the edge, and whatever is off it is simply not
        /// drawn.
        public var points: [CGPoint]

        public init(id: UUID = UUID(), ink: Ink, points: [CGPoint]) {
            self.id = id
            self.ink = ink
            self.points = points
        }
    }

    /// Fixed, and a fraction of the photo's width rather than of the screen,
    /// so a line is the same share of the picture at any capture resolution.
    public static func strokeWidth(forWidth width: Double) -> Double {
        width * 0.015
    }

    /// The line through a stroke's points, at `size`. The compose screen draws
    /// this same path over the preview, which is what keeps it honest.
    ///
    /// Curved through the midpoints between samples, with each sample as the
    /// control point. Joined straight, a finger sampled sixty to a hundred and
    /// twenty times a second draws a visible corner at every sample.
    public static func path(for stroke: Stroke, size: CGSize) -> CGPath {
        let points = stroke.points.map {
            CGPoint(x: $0.x * size.width, y: $0.y * size.height)
        }
        let path = CGMutablePath()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: first)
        // A tap is a stroke of one point; a round cap on a line of no length
        // is a dot.
        guard points.count > 1 else {
            path.addLine(to: first)
            return path
        }
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            path.addQuadCurve(
                to: CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2),
                control: previous
            )
        }
        path.addLine(to: last)
        return path
    }

    /// Small enough to stay legible, large enough that a caption can fill most
    /// of the photo's width in a few words.
    public static let scaleRange: ClosedRange<Double> = 0.5...3

    public static func clampScale(_ scale: Double) -> Double {
        min(scaleRange.upperBound, max(scaleRange.lowerBound, scale))
    }

    /// How close to square a turned caption has to come to be set exactly
    /// square. Two fingers cannot let go at precisely zero, and a caption left
    /// a degree off level reads as a mistake rather than a choice.
    public static let rotationSnap = 5 * Double.pi / 180

    /// Wraps into -π...π and snaps to the nearest quarter turn when close to it.
    public static func normalizedRotation(_ radians: Double) -> Double {
        var angle = radians.truncatingRemainder(dividingBy: 2 * .pi)
        if angle > .pi { angle -= 2 * .pi }
        if angle < -.pi { angle += 2 * .pi }
        let quarter = Double.pi / 2
        let square = (angle / quarter).rounded() * quarter
        return abs(angle - square) <= rotationSnap ? square : angle
    }

    /// `600 ${Math.round(canvas.width * 0.06)}px` in the web composer. It scales
    /// with the image width, not the screen, so the caption occupies the same
    /// fraction of the photo at any capture resolution.
    public static func fontSize(forWidth width: Double) -> Double {
        (width * 0.06).rounded()
    }

    /// A caption's box, in the units of whatever width it was asked for — the
    /// photo's pixels here, the preview's points on the compose screen. Both
    /// read it, and that is the whole of what keeps the preview honest: the
    /// text wraps at the same fraction of the photo in both, so the lines break
    /// in the same places.
    public struct Metrics: Equatable, Sendable {
        public let fontSize: Double
        public let horizontalPadding: Double
        public let verticalPadding: Double
        public let cornerRadius: Double
        /// Where the text wraps. The plate is held inside 90% of the photo at
        /// any scale, so a larger caption breaks into more lines rather than
        /// running off the edge.
        public let maxTextWidth: Double
    }

    public static func metrics(for style: Caption.Style, scale: Double, width: Double) -> Metrics {
        switch style {
        case .bar:
            let font = width * 0.05
            let horizontal = font * 0.8
            return Metrics(
                fontSize: font,
                horizontalPadding: horizontal,
                verticalPadding: font * 0.4,
                cornerRadius: 0,
                maxTextWidth: max(font, width - horizontal * 2)
            )
        case .plate:
            let font = fontSize(forWidth: width) * clampScale(scale)
            let padding = font * 0.4
            return Metrics(
                fontSize: font,
                horizontalPadding: padding,
                verticalPadding: padding,
                cornerRadius: padding * 0.75,
                maxTextWidth: max(font, width * 0.9 - padding * 2)
            )
        }
    }

    /// `rgba(15, 23, 42, 0.55)` — slate-900 at 55%, the web composer's plate.
    static let plateColor = UIColor(red: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 0.55)
    static let barColor = UIColor(white: 0, alpha: 0.55)

    public static func backing(for style: Caption.Style) -> UIColor {
        style == .bar ? barColor : plateColor
    }

    public static func composite(
        image: UIImage,
        strokes: [Stroke] = [],
        captions: [Caption]
    ) -> UIImage {
        let base = ImagePipeline.normalizingOrientation(image)
        let drawn = captions.filter { !$0.trimmed.isEmpty }
        let lines = strokes.filter { !$0.points.isEmpty }
        guard !drawn.isEmpty || !lines.isEmpty else { return base }

        let size = base.size
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            base.draw(in: CGRect(origin: .zero, size: size))
            drawOverlay(lines, drawn, in: context.cgContext, size: size)
        }
    }

    /// The drawing and the captions alone, on a transparent canvas of `size`
    /// — what a video carries over every frame. The same draw calls as
    /// `composite`, so a caption on a clip lands exactly where it would on a
    /// photo of the same shape. Nil when there is nothing to draw, so a plain
    /// clip is not composited against an empty layer thirty times a second.
    public static func overlay(
        size: CGSize,
        strokes: [Stroke] = [],
        captions: [Caption]
    ) -> UIImage? {
        let drawn = captions.filter { !$0.trimmed.isEmpty }
        let lines = strokes.filter { !$0.points.isEmpty }
        guard !drawn.isEmpty || !lines.isEmpty, size.width > 0, size.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = false

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            drawOverlay(lines, drawn, in: context.cgContext, size: size)
        }
    }

    private static func drawOverlay(
        _ lines: [Stroke],
        _ captions: [Caption],
        in context: CGContext,
        size: CGSize
    ) {
        // Under the captions, as on the compose screen, so a scribble never
        // makes the text unreadable.
        draw(lines, in: context, size: size)
        // In order, so a later caption lands on top — as it does on the
        // compose screen.
        for caption in captions {
            draw(caption, in: context, size: size)
        }
    }

    public static func font(for metrics: Metrics) -> UIFont {
        UIFont.systemFont(ofSize: metrics.fontSize, weight: .semibold)
    }

    /// The text's own box once wrapped — no padding. The compose screen sizes
    /// its preview with this rather than letting SwiftUI measure, so a line
    /// breaks where it will break in the pixels.
    public static func textSize(_ text: String, metrics: Metrics) -> CGSize {
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: metrics.maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes(for: metrics),
            context: nil
        )
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    private static func attributes(for metrics: Metrics) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return [
            .font: font(for: metrics),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph,
        ]
    }

    private static func draw(_ strokes: [Stroke], in context: CGContext, size: CGSize) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineWidth(strokeWidth(forWidth: Double(size.width)))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes {
            context.addPath(path(for: stroke, size: size))
            context.setStrokeColor(stroke.ink.color.cgColor)
            context.strokePath()
        }
    }

    private static func draw(_ caption: Caption, in context: CGContext, size: CGSize) {
        let text = caption.trimmed
        let metrics = metrics(for: caption.style, scale: caption.scale, width: Double(size.width))
        let textSize = textSize(text, metrics: metrics)

        let centerX = caption.style == .bar ? size.width / 2 : size.width * caption.placement.x
        let centerY = size.height * caption.placement.y
        let backingWidth = caption.style == .bar
            ? size.width
            : textSize.width + metrics.horizontalPadding * 2
        let box = CGRect(
            x: centerX - backingWidth / 2,
            y: centerY - textSize.height / 2 - metrics.verticalPadding,
            width: backingWidth,
            height: textSize.height + metrics.verticalPadding * 2
        )

        // Turned about its own centre, as `rotationEffect` turns it on screen.
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: centerX, y: centerY)
        context.rotate(by: caption.drawnRotation)
        context.translateBy(x: -centerX, y: -centerY)

        context.setFillColor(backing(for: caption.style).cgColor)
        UIBezierPath(roundedRect: box, cornerRadius: metrics.cornerRadius).fill()

        (text as NSString).draw(
            with: CGRect(
                x: centerX - textSize.width / 2,
                y: centerY - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes(for: metrics),
            context: nil
        )
    }
}
#endif
