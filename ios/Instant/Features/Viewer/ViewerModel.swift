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

    /// Decrypted, but hidden behind a warning because the on-device classifier
    /// flagged it. Not yet seen: no receipt and no countdown until `reveal()`.
    public private(set) var isConcealed = false

    /// The countdown is held while something is on top of the photo — a report
    /// sheet — so reporting does not cost the reporter the photo they are
    /// reporting.
    public private(set) var isPaused = false

    /// The fetch is destructive on the server, so it must happen exactly once.
    /// Not "once per render", not "once unless something re-entered" — once.
    private var hasStartedFetch = false
    private var hasSentReceipt = false
    private var countdown: Task<Void, Never>?
    private var countdownTotal: Double = 0
    /// Seconds left as of `countdownStartedAt`. Updated on every pause.
    private var countdownRemaining: Double = 0
    private var countdownStartedAt: Date?

    public let instant: InstantDelivery
    private let api: InstantAPIProtocol
    private let device: DeviceIdentity
    private let time: TimeSource
    private let sensitivity: SensitivityChecking

    public init(
        instant: InstantDelivery,
        api: InstantAPIProtocol,
        device: DeviceIdentity,
        time: TimeSource = .live,
        sensitivity: SensitivityChecking = SystemSensitivityChecker()
    ) {
        self.instant = instant
        self.api = api
        self.device = device
        self.time = time
        self.sensitivity = sensitivity
    }

    public var showsCountdown: Bool {
        instant.durationMode != .infinite && phase == .showing && !isConcealed
    }

    /// Whether the photo actually reached the screen — the same condition as the
    /// read receipt. One that was already gone, or that this device holds no
    /// envelope for, was opened by nobody, so the inbox must not go on to offer
    /// a reply to something that was never seen.
    public var wasSeen: Bool { hasSentReceipt }

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

        let decoded: UIImage
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
            guard let opened = UIImage(data: plaintext) else {
                phase = .failed("That instant could not be displayed.")
                return
            }
            decoded = opened
        } catch {
            phase = .undecryptable
            return
        }
        image = decoded

        if await sensitivity.isSensitive(decoded) {
            isConcealed = true
            phase = .showing
            return
        }

        phase = .showing
        await sendReceipt()
        startCountdown()
    }

    /// "View anyway" on a concealed photo. This is the moment it is seen, so
    /// this is when the receipt goes and the clock starts.
    public func reveal() async {
        guard isConcealed, phase == .showing, !isFinished else { return }
        isConcealed = false
        await sendReceipt()
        startCountdown()
    }

    public func pause() {
        guard !isPaused, !isFinished else { return }
        isPaused = true
        guard let countdown, let startedAt = countdownStartedAt else { return }
        countdown.cancel()
        self.countdown = nil
        countdownRemaining = max(0, countdownRemaining - time.now().timeIntervalSince(startedAt))
        countdownStartedAt = nil
    }

    public func resume() {
        guard isPaused, !isFinished else { return }
        isPaused = false
        // Only a clock that was running comes back; pausing before the photo was
        // revealed, or on an infinite instant, had nothing to hold.
        guard countdownTotal > 0 else { return }
        if countdownRemaining <= 0 {
            finish()
        } else {
            runCountdown()
        }
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
        countdownTotal = Double(total.components.seconds)
            + Double(total.components.attoseconds) / 1e18
        countdownRemaining = countdownTotal
        // Revealed while a sheet was already up: the clock starts when it closes.
        guard !isPaused else { return }
        runCountdown()
    }

    private func runCountdown() {
        let startedAt = time.now()
        let remainingAtStart = countdownRemaining
        let totalSeconds = countdownTotal
        countdownStartedAt = startedAt

        countdown = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await time.sleep(.milliseconds(50))
                guard !Task.isCancelled else { return }
                let elapsed = time.now().timeIntervalSince(startedAt)
                let remaining = max(0, remainingAtStart - elapsed)
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
