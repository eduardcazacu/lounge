#if canImport(UIKit)
import AVFoundation
import Foundation
import Observation
import UIKit

@MainActor
@Observable
public final class ComposeModel {
    /// Every piece of text on the photo, bottom to top.
    public private(set) var captions: [OverlayCompositor.Caption] = []
    /// The drawing, oldest line first. Undo takes from the end.
    public private(set) var strokes: [OverlayCompositor.Stroke] = []
    /// The pen's colour for the next line. Lines already drawn keep theirs.
    public var ink: OverlayCompositor.Ink = .white
    public var duration: InstantDurationMode = .fiveSeconds
    /// Whether a clip goes with its sound. Off means off everywhere: the
    /// preview goes quiet, and the audio track is left out of the encode
    /// rather than sent silenced — the recipient's device never holds sound
    /// the sender took back.
    public private(set) var includesSound = true

    /// The chosen look, applied to the photo on the way out.
    public private(set) var filter: PhotoFilter = .none

    /// What the compose screen actually draws: the photo, with whatever look is
    /// chosen.
    ///
    /// It starts as the photo itself, untouched, and stays that way until a
    /// look is picked. Nothing between the shutter going down and the picture
    /// appearing is allowed to do image work — that window is the shutter
    /// holding black, so every millisecond of it is visible.
    ///
    /// Once a look is picked this is rendered at display size: a library photo
    /// can be 4000px on its long edge, and re-filtering that on every tap of
    /// the strip is a hitch per tap for pixels no screen shows. The
    /// full-resolution render happens once, on send.
    public private(set) var preview: UIImage

    /// One render per look — a strip of the actual picture rather than
    /// swatches, which is the only way to choose a filter without applying it
    /// first. Empty until the strip is first opened.
    public private(set) var filterThumbnails: [FilterThumbnail] = []

    public struct FilterThumbnail: Identifiable {
        public let filter: PhotoFilter
        public let image: UIImage
        public var id: String { filter.id }
    }

    /// Who this is already going to, when the camera was opened from a
    /// conversation. The send button names them instead of opening a picker,
    /// which is the whole point of having tapped them in the first place.
    public var recipient: InstantRecipient?

    /// What the shutter produced. Everything below about "the photo" is about
    /// `.photo`; a clip is drawn by a player, and only its first frame is ever
    /// a picture here — for the filter strip.
    public let capture: Capture
    /// The photo. Empty for a clip, which has no one picture to be.
    public let image: UIImage
    /// The photo at display size, unfiltered — what every preview render starts
    /// from, so switching looks never compounds one on top of another. Built on
    /// first use rather than up front, for the same reason `preview` is not.
    /// For a clip, its first frame, once the strip asks for it.
    private var previewBase: UIImage?
    /// The clip's first frame being read, for the filter strip. Kept so a test
    /// can wait for it.
    private(set) var thumbnailWork: Task<Void, Never>?

    /// Big enough for the viewport on the densest phone screen, and no bigger.
    static let previewLongEdge: CGFloat = 1440
    static let thumbnailLongEdge: CGFloat = 180

    public init(capture: Capture, recipient: InstantRecipient? = nil) {
        self.capture = capture
        self.recipient = recipient
        switch capture {
        case .photo(let photo):
            image = photo
            // Deliberately the photo itself, and no work at all: this
            // initialiser runs between the shutter and the picture appearing.
            preview = photo
        case .video:
            image = UIImage()
            preview = UIImage()
            // A clip plays once and closes unless told otherwise — the
            // nearest thing to the photo's five seconds.
            duration = .playOnce
        }
    }

    public convenience init(image: UIImage, recipient: InstantRecipient? = nil) {
        self.init(capture: .photo(image), recipient: recipient)
    }

    public var clip: RecordedClip? {
        if case .video(let clip) = capture { clip } else { nil }
    }

    public var isVideo: Bool { capture.isVideo }

    /// The shape the compose screen lays the capture out at.
    public var contentSize: CGSize {
        clip?.size ?? preview.size
    }

    /// Builds the strip, and is called when it is first opened rather than from
    /// `init` — seven renders is a visible pause, and it would be spent on
    /// every capture for a control most captures never touch.
    public func prepareThumbnails() {
        guard filterThumbnails.isEmpty else { return }
        if let clip, previewBase == nil {
            // A clip's strip is its first frame, which has to be read off the
            // file before anything can be filtered.
            guard thumbnailWork == nil else { return }
            thumbnailWork = Task { [weak self] in
                let frame = await Self.firstFrame(of: clip)
                guard let self, let frame else { return }
                previewBase = frame
                prepareThumbnails()
            }
            return
        }
        // Off the display-sized copy rather than the photo, and these are shown
        // at 58pt.
        let swatch = Self.fitted(base, longEdge: Self.thumbnailLongEdge)
        filterThumbnails = PhotoFilter.allCases.map {
            FilterThumbnail(filter: $0, image: $0.apply(to: swatch))
        }
    }

    /// Switches the look. Cheap enough to be synchronous: it is one Core Image
    /// pass over an image already cut down to the size of the screen. A clip's
    /// look is applied by its player, per frame, from `filter`.
    public func select(_ filter: PhotoFilter) {
        guard filter != self.filter else { return }
        self.filter = filter
        guard !isVideo else { return }
        preview = filter.apply(to: base)
    }

    private static func firstFrame(of clip: RecordedClip) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: previewLongEdge, height: previewLongEdge)
        guard let (frame, _) = try? await generator.image(at: .zero) else { return nil }
        return UIImage(cgImage: frame)
    }

    /// The unfiltered photo at display size. A library photo carries an EXIF
    /// orientation, and baking that in is a full-frame redraw, so this is built
    /// once — on the first tap that needs it, never on the way in.
    private var base: UIImage {
        if let previewBase { return previewBase }
        let built = Self.fitted(
            ImagePipeline.normalizingOrientation(image),
            longEdge: Self.previewLongEdge
        )
        previewBase = built
        return built
    }

    /// Downscales to fit `longEdge`, leaving anything already smaller alone.
    private static func fitted(_ image: UIImage, longEdge: CGFloat) -> UIImage {
        let upright = ImagePipeline.normalizingOrientation(image)
        let size = upright.size
        let longest = max(size.width, size.height)
        guard longest > longEdge, longest > 0 else { return upright }
        let scale = longEdge / longest
        return ImagePipeline.resized(
            upright,
            to: CGSize(
                width: max(1, (size.width * scale).rounded()),
                height: max(1, (size.height * scale).rounded())
            )
        )
    }

    // MARK: - Captions

    public func caption(_ id: UUID) -> OverlayCompositor.Caption? {
        captions.first { $0.id == id }
    }

    /// A new, empty caption on top of the others. It starts as the bar, which
    /// has no horizontal position to speak of, so only the height of the tap
    /// that made it matters until it becomes a plate.
    @discardableResult
    public func addCaption(at placement: OverlayCompositor.Placement) -> UUID {
        let caption = OverlayCompositor.Caption(placement: placement)
        captions.append(caption)
        return caption.id
    }

    public func setText(_ text: String, of id: UUID) {
        update(id) { $0.text = String(text.prefix(OverlayCompositor.maxCaptionLength)) }
    }

    public func toggleStyle(of id: UUID) {
        update(id) { $0.style = $0.style == .bar ? .plate : .bar }
    }

    /// A bar keeps its horizontal centre where it was, because it has none on
    /// screen: were it to take the finger's, it would jump sideways the moment
    /// it became a plate.
    public func move(_ id: UUID, to placement: OverlayCompositor.Placement) {
        update(id) { caption in
            caption.placement = caption.style == .bar
                ? OverlayCompositor.Placement(x: caption.placement.x, y: placement.y)
                : placement
        }
    }

    public func rescale(_ id: UUID, to scale: Double) {
        update(id) { caption in
            guard caption.style == .plate else { return }
            caption.scale = OverlayCompositor.clampScale(scale)
        }
    }

    public func removeCaption(_ id: UUID) {
        captions.removeAll { $0.id == id }
    }

    public func rotate(_ id: UUID, to radians: Double) {
        update(id) { caption in
            guard caption.style == .plate else { return }
            caption.rotation = OverlayCompositor.normalizedRotation(radians)
        }
    }

    /// Called when the editor closes. A caption left blank is removed rather
    /// than kept as an invisible thing that can still be tapped.
    public func finishEditing(_ id: UUID) {
        guard let caption = caption(id) else { return }
        if caption.trimmed.isEmpty {
            removeCaption(id)
        }
    }

    private func update(_ id: UUID, _ change: (inout OverlayCompositor.Caption) -> Void) {
        guard let index = captions.firstIndex(where: { $0.id == id }) else { return }
        change(&captions[index])
    }

    // MARK: - Drawing

    /// A new line in the current ink, starting where the finger went down.
    /// Points are fractions of the photo.
    public func beginStroke(at point: CGPoint) {
        strokes.append(OverlayCompositor.Stroke(ink: ink, points: [point]))
    }

    /// Continues the line being drawn, which is always the newest.
    public func extendStroke(to point: CGPoint) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].points.append(point)
    }

    /// Takes back the last whole line, not the last few points: a line is
    /// what the finger drew in one go, and that is the thing that went wrong.
    public func undoStroke() {
        _ = strokes.popLast()
    }

    public func toggleSound() {
        guard isVideo else { return }
        includesSound.toggle()
    }

    public func cycleDuration() {
        duration = duration.next
    }

    /// What `Outbox` sends: the original photo and every choice made about it,
    /// none of them applied yet. The full-resolution render happens there, off
    /// the main actor, after this screen has already closed.
    public var draft: InstantDraft {
        InstantDraft(
            media: clip.map(InstantDraft.Media.video) ?? .photo(image),
            filter: filter,
            strokes: strokes,
            captions: captions.filter { !$0.trimmed.isEmpty },
            duration: duration,
            includesSound: includesSound
        )
    }
}
#endif
