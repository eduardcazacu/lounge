#if canImport(UIKit)
import Foundation
import Observation
import UIKit

@MainActor
@Observable
public final class ComposeModel {
    public enum SendState: Equatable {
        case idle
        case sending
        case sent(delivered: Bool)
        case failed(String)
    }

    public var caption = ""
    public var placement = OverlayCompositor.Placement.default
    public var duration: InstantDurationMode = .fiveSeconds
    public private(set) var sendState: SendState = .idle

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

    public let image: UIImage
    /// The photo at display size, unfiltered — what every preview render starts
    /// from, so switching looks never compounds one on top of another. Built on
    /// first use rather than up front, for the same reason `preview` is not.
    private var previewBase: UIImage?
    private let instantAPI: InstantAPIProtocol
    private let senderUserId: Int

    /// Big enough for the viewport on the densest phone screen, and no bigger.
    static let previewLongEdge: CGFloat = 1440
    static let thumbnailLongEdge: CGFloat = 180

    public init(
        image: UIImage,
        instantAPI: InstantAPIProtocol,
        senderUserId: Int,
        recipient: InstantRecipient? = nil
    ) {
        self.image = image
        self.instantAPI = instantAPI
        self.senderUserId = senderUserId
        self.recipient = recipient
        // Deliberately the photo itself, and no work at all: this initialiser
        // runs between the shutter and the picture appearing.
        preview = image
    }

    /// Builds the strip, and is called when it is first opened rather than from
    /// `init` — seven renders is a visible pause, and it would be spent on
    /// every capture for a control most captures never touch.
    public func prepareThumbnails() {
        guard filterThumbnails.isEmpty else { return }
        // Off the display-sized copy rather than the photo, and these are shown
        // at 58pt.
        let swatch = Self.fitted(base, longEdge: Self.thumbnailLongEdge)
        filterThumbnails = PhotoFilter.allCases.map {
            FilterThumbnail(filter: $0, image: $0.apply(to: swatch))
        }
    }

    /// Switches the look. Cheap enough to be synchronous: it is one Core Image
    /// pass over an image already cut down to the size of the screen.
    public func select(_ filter: PhotoFilter) {
        guard filter != self.filter else { return }
        self.filter = filter
        preview = filter.apply(to: base)
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

    public var isSending: Bool { sendState == .sending }

    public func setCaption(_ text: String) {
        caption = String(text.prefix(OverlayCompositor.maxCaptionLength))
    }

    public func cycleDuration() {
        duration = duration.next
    }

    /// Filters, composites, compresses, encrypts and uploads.
    ///
    /// The look goes on before the caption, so the caption plate keeps its own
    /// contrast instead of being tinted along with the photo — and both are
    /// burned into the pixels here rather than sent as fields. The server only
    /// ever holds ciphertext, so it could not read the caption, or apply the
    /// filter, even if the design wanted it to.
    public func send(to recipientId: Int) async {
        guard sendState != .sending else { return }
        sendState = .sending

        do {
            let devices = try await instantAPI.keys(forUserId: recipientId).theirs
            guard !devices.isEmpty else {
                sendState = .failed("They haven't set up Instant yet.")
                return
            }

            let flattened = OverlayCompositor.composite(
                image: filter.apply(to: image),
                caption: caption,
                placement: placement
            )
            let encoded = try ImagePipeline.encode(flattened)
            let sealed = try InstantCrypto.seal(
                media: encoded,
                senderUserId: senderUserId,
                devices: devices.map {
                    InstantCrypto.RecipientDeviceKey(
                        id: $0.id, deviceId: $0.deviceId, publicKey: $0.publicKey
                    )
                }
            )

            let delivered = try await instantAPI.send(
                ciphertext: sealed.ciphertext,
                recipientId: recipientId,
                durationMode: duration,
                mediaType: "image/webp",
                mediaIv: sealed.mediaIv,
                ephemeralPubKey: sealed.ephemeralPubKey,
                envelopes: sealed.envelopes
            )
            sendState = .sent(delivered: delivered)
        } catch let error as APIError {
            sendState = .failed(error.message)
        } catch InstantCrypto.CryptoError.noRecipientDevices {
            sendState = .failed("They haven't set up Instant yet.")
        } catch {
            sendState = .failed("That instant could not be sent.")
        }
    }
}
#endif
