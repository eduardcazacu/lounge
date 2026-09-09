#if canImport(UIKit)
import Foundation
import Observation
import UIKit

@MainActor
@Observable
public final class ViewerModel {
    public enum Phase: Equatable {
        case loading
        case showing
        /// Already opened (possibly on another of this user's devices), or expired.
        case gone(String)
        /// No envelope for this device — the identity was replaced after the
        /// sender wrapped the content key.
        case undecryptable
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var image: UIImage?
    /// 1 down to 0 for timed instants; stays at 1 for `.infinite`.
    public private(set) var progress: Double = 1
    public private(set) var isFinished = false

    /// The fetch is destructive on the server, so it must happen exactly once.
    /// Not "once per render", not "once unless something re-entered" — once.
    private var hasStartedFetch = false
    private var hasSentReceipt = false
    private var countdown: Task<Void, Never>?

    public let instant: InstantDelivery
    private let api: InstantAPIProtocol
    private let device: DeviceIdentity
    private let time: TimeSource

    public init(
        instant: InstantDelivery,
        api: InstantAPIProtocol,
        device: DeviceIdentity,
        time: TimeSource = .live
    ) {
        self.instant = instant
        self.api = api
        self.device = device
        self.time = time
    }

    public var showsCountdown: Bool {
        instant.durationMode != .infinite && phase == .showing
    }

    public func start() async {
        guard !hasStartedFetch else { return }
        hasStartedFetch = true

        guard let envelope = instant.envelope else {
            // Nothing here can ever open this. Tell the server so it stops
            // holding ciphertext no one can read.
            phase = .undecryptable
            try? await api.markUndecryptable(instantId: instant.id)
            return
        }

        let ciphertext: Data
        do {
            ciphertext = try await api.media(instantId: instant.id)
        } catch let error as APIError where error.isGone {
            phase = .gone("This instant was already opened somewhere else, or it expired.")
            return
        } catch {
            // The server claimed the row before it read the object, so the
            // instant is spent either way — the same trade Snapchat makes, and
            // the reason a half-finished download loses the photo.
            phase = .failed("That instant could not be opened. It is gone either way.")
            return
        }

        do {
            let plaintext = try InstantCrypto.open(
                ciphertext: ciphertext,
                instant: InstantCrypto.OpenableInstant(
                    mediaIv: instant.mediaIv,
                    ephemeralPubKey: instant.ephemeralPubKey,
                    senderId: instant.senderId,
                    envelopeWrappedKey: envelope.wrappedKey,
                    envelopeWrapIv: envelope.wrapIv
                ),
                device: device
            )
            guard let decoded = UIImage(data: plaintext) else {
                phase = .failed("That instant could not be displayed.")
                return
            }
            image = decoded
            phase = .showing
        } catch {
            phase = .undecryptable
            return
        }

        await sendReceipt()
        startCountdown()
    }

    /// Sent once the image is actually on screen, not when the fetch began —
    /// a read receipt should mean "they saw it".
    private func sendReceipt() async {
        guard !hasSentReceipt else { return }
        hasSentReceipt = true
        try? await api.markViewed(instantId: instant.id)
    }

    private func startCountdown() {
        guard let total = instant.durationMode.duration else { return }
        let totalSeconds = Double(total.components.seconds)
            + Double(total.components.attoseconds) / 1e18
        let startedAt = time.now()

        countdown = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await time.sleep(.milliseconds(50))
                guard !Task.isCancelled else { return }
                let elapsed = time.now().timeIntervalSince(startedAt)
                let remaining = max(0, totalSeconds - elapsed)
                progress = totalSeconds > 0 ? remaining / totalSeconds : 0
                if remaining <= 0 {
                    finish()
                    return
                }
            }
        }
    }

    /// Backgrounding closes the instant, matching the web client's
    /// `visibilitychange` handling: leaving the app should not pause the clock.
    public func finish() {
        countdown?.cancel()
        countdown = nil
        image = nil
        progress = 0
        isFinished = true
    }
}
#endif
