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

    public let image: UIImage
    private let instantAPI: InstantAPIProtocol
    private let senderUserId: Int

    public init(image: UIImage, instantAPI: InstantAPIProtocol, senderUserId: Int) {
        self.image = image
        self.instantAPI = instantAPI
        self.senderUserId = senderUserId
    }

    public var isSending: Bool { sendState == .sending }

    public func setCaption(_ text: String) {
        caption = String(text.prefix(OverlayCompositor.maxCaptionLength))
    }

    public func cycleDuration() {
        duration = duration.next
    }

    /// Composites, compresses, encrypts and uploads.
    ///
    /// The caption is burned into the pixels here — it is never a field on the
    /// wire. The server only ever holds ciphertext, so it could not read the
    /// text even if the design wanted it to.
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
                image: image,
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
