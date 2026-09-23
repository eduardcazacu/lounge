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
    public var ink: OverlayCompositor.Ink = .white {
        didSet { preferences.ink = ink }
    }
    public var duration: InstantDurationMode = .fiveSeconds {
        didSet {
            if duration.isVideoMode {
                preferences.videoDuration = duration
            } else {
                preferences.photoDuration = duration
            }
        }
    }
    /// Whether a clip goes with its sound. Off means off everywhere: the
    /// preview goes quiet, and the audio track is left out of the encode
    /// rather than sent silenced — the recipient's device never holds sound
    /// the sender took back.
    public private(set) var includesSound = true

    /// Where every choice above starts from, and where each one is written
    /// back to as it is made.
    private let preferences: Preferences

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

    // MARK: 3D

    /// Estimates the photo's depth and renders the clip. A seam so the model
    /// tests do not run the network.
    private let makeParallax: @Sendable (UIImage) async throws -> RecordedClip
    /// Whether the photo is being shown, and will be sent, as its 3D clip.
    public private(set) var isParallax = false
    /// The 3D clip, made on the first tap and kept, so turning 3D off and on
    /// again does not render it twice.
    public private(set) var parallaxClip: RecordedClip?
    public private(set) var isRenderingParallax = false
    /// The render in flight, kept so a test can wait for it.
    private(set) var parallaxWork: Task<Void, Never>?
    /// The screen has closed. A render that finishes after that deletes what
    /// it made, because nothing else will.
    private var isClosed = false
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

    public init(
        capture: Capture,
        recipient: InstantRecipient? = nil,
        preferences: Preferences = .inMemory(),
        makeParallax: @escaping @Sendable (UIImage) async throws -> RecordedClip = ComposeModel.parallax
    ) {
        self.capture = capture
        self.recipient = recipient
        self.preferences = preferences
        self.makeParallax = makeParallax
        ink = preferences.ink
        switch capture {
        case .photo(let photo):
            image = photo
            // Deliberately the photo itself, and no work at all: this
            // initialiser runs between the shutter and the picture appearing.
            preview = photo
            duration = preferences.photoDuration
        case .video:
            image = UIImage()
            preview = UIImage()
            duration = preferences.videoDuration
            includesSound = preferences.sendsSound
        }
    }

    public convenience init(
        image: UIImage,
        recipient: InstantRecipient? = nil,
        preferences: Preferences = .inMemory()
    ) {
        self.init(capture: .photo(image), recipient: recipient, preferences: preferences)
    }

    /// What the player shows: the recorded clip, or the 3D one while it is on.
    public var clip: RecordedClip? {
        if case .video(let clip) = capture { return clip }
        return isParallax ? parallaxClip : nil
    }

    /// True for a 3D photo too — from here on it is a clip in every respect
    /// but sound.
    public var isVideo: Bool { clip != nil }

    /// Only a recording has sound. A 3D clip is four stills.
    public var hasSound: Bool { capture.isVideo }

    /// Any photo. A recording already moves.
    public var canMakeParallax: Bool { !capture.isVideo }

    /// The real thing: the photo's depth and its subjects' outlines, then the
    /// four views.
    public static let parallax: @Sendable (UIImage) async throws -> RecordedClip = { photo in
        // Vision runs beside the depth model rather than after it: they read
        // the same photo and neither needs the other's answer.
        async let masks = VisionSubjectMasker().masks(for: photo)
        let depth = try await DepthEstimator.shared.estimate(photo)
        return try await ParallaxRenderer.makeClip(photo: photo, depth: depth, masks: await masks)
    }

    /// The shape the compose screen lays the capture out at.
    public var contentSize: CGSize {
        clip?.size ?? preview.size
    }

    /// Builds the strip, and is called when it is first opened rather than from
    /// `init` — seven renders is a visible pause, and it would be spent on
    /// every capture for a control most captures never touch.
    public func prepareThumbnails() {
        guard filterThumbnails.isEmpty else { return }
        // A recording's, not a 3D clip's: a 3D photo's strip is the photo.
        if case .video(let clip) = capture, previewBase == nil {
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
        // Kept up to date under a 3D clip as well, so that turning 3D off
        // shows the photo in the look that was chosen.
        guard !capture.isVideo else { return }
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
        guard hasSound else { return }
        includesSound.toggle()
        preferences.sendsSound = includesSound
    }

    public func cycleDuration() {
        duration = duration.next
    }

    // MARK: - 3D

    /// Shows the photo as its 3D clip, rendering it the first time; or goes
    /// back to the photo, keeping the clip for next time.
    ///
    /// The duration changes family with it. A 3D photo is sent as a clip, so
    /// it plays Once or Loops like one — and each family is remembered on its
    /// own, so a Loop never leaks into the next photo's seconds.
    public func toggleParallax() {
        guard canMakeParallax, !isRenderingParallax else { return }
        if isParallax {
            isParallax = false
            duration = preferences.photoDuration
            return
        }
        if parallaxClip != nil {
            showParallax()
            return
        }
        isRenderingParallax = true
        let photo = image
        let makeParallax = makeParallax
        parallaxWork = Task { [weak self] in
            let made = try? await makeParallax(photo)
            guard let self, !isClosed else {
                if let made { CaptureScratch.remove(made.url) }
                return
            }
            isRenderingParallax = false
            // A render that failed leaves the photo as it was. There is
            // nothing the sender could do differently on a second try.
            guard let made else { return }
            parallaxClip = made
            showParallax()
        }
    }

    private func showParallax() {
        isParallax = true
        duration = preferences.videoDuration
    }

    /// The screen is closing. A 3D clip that is not what was sent is deleted
    /// here; one that was sent belongs to the outbox now, which deletes it
    /// once it is encoded.
    public func close(sent: Bool) {
        isClosed = true
        guard let parallaxClip, !(sent && isParallax) else { return }
        CaptureScratch.remove(parallaxClip.url)
        self.parallaxClip = nil
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
            includesSound: hasSound && includesSound
        )
    }
}
#endif
