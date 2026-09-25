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
    /// The clip, when the instant is one. Played from memory: the plaintext
    /// never touches the disk, as a photo's never does.
    public private(set) var video: VideoPlaying?
    /// A clip opens the way the last one was left: silent until the speaker
    /// has once been turned up, and with sound from then on until it is turned
    /// back down.
    public private(set) var isMuted: Bool
    /// 1 down to 0 for timed instants and a clip that plays once; stays at 1
    /// for `.infinite` and a loop.
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
    /// The receipt in flight. Nothing on screen waits for it; tests do.
    private(set) var receiptDelivery: Task<Void, Never>?
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
    private let makeVideoPlayer: @MainActor (Data, _ loops: Bool) -> VideoPlaying
    private let preferences: Preferences

    public init(
        instant: InstantDelivery,
        api: InstantAPIProtocol,
        device: DeviceIdentity,
        time: TimeSource = .live,
        sensitivity: SensitivityChecking = SystemSensitivityChecker(),
        preferences: Preferences = .inMemory(),
        makeVideoPlayer: @escaping @MainActor (Data, _ loops: Bool) -> VideoPlaying = {
            AVVideoPlayback(data: $0, loops: $1)
        }
    ) {
        self.instant = instant
        self.api = api
        self.device = device
        self.time = time
        self.sensitivity = sensitivity
        self.makeVideoPlayer = makeVideoPlayer
        self.preferences = preferences
        isMuted = preferences.viewerMuted
    }

    /// Decided by what the bytes are, not by the duration mode: the server
    /// holds the two together, and the media type is what a decoder cares
    /// about.
    public var isVideo: Bool {
        instant.mediaType.lowercased().hasPrefix("video/")
    }

    public var showsCountdown: Bool {
        guard phase == .showing, !isConcealed else { return false }
        switch instant.durationMode {
        case .infinite, .loop: return false
        case .oneSecond, .fiveSeconds, .playOnce: return true
        }
    }

    /// "Tap anywhere to close" — for anything that will not close itself.
    public var staysOpen: Bool {
        instant.durationMode == .infinite || instant.durationMode == .loop
    }

    /// Whether the photo actually reached the screen — the same condition as the
    /// read receipt. One that was already gone, or that this device holds no
    /// envelope for, was opened by nobody, so the inbox must not go on to offer
    /// a reply to something that was never seen.
    public var wasSeen: Bool { hasSentReceipt }

    public func start() async {
        guard !hasStartedFetch else { return }
        hasStartedFetch = true
        journey("viewerStarted")
        JourneyLog.shared.annotate(.openInstant, key: instant.id, [
            "media": isVideo ? "video" : "photo",
            "duration": instant.durationMode.rawValue,
        ])

        guard let envelope = instant.envelope else {
            // Nothing here can ever open this. Tell the server so it stops
            // holding ciphertext no one can read.
            phase = .undecryptable
            endJourney("undecryptable")
            try? await api.markUndecryptable(instantId: instant.id)
            return
        }

        let ciphertext: Data
        do {
            ciphertext = try await api.media(instantId: instant.id)
        } catch let error as APIError where error.isGone {
            phase = .gone("This instant was already opened somewhere else, or it expired.")
            endJourney("gone")
            return
        } catch {
            // The server claimed the row before it read the object, so the
            // instant is spent either way — the same trade Snapchat makes, and
            // the reason a half-finished download loses the photo.
            phase = .failed("That instant could not be opened. It is gone either way.")
            endJourney("downloadFailed")
            return
        }
        journey("downloaded")
        JourneyLog.shared.annotate(.openInstant, key: instant.id, ["kb": String(ciphertext.count / 1024)])

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
            journey("decrypted")
            if isVideo {
                await showVideo(plaintext)
                return
            }
            guard let opened = UIImage(data: plaintext) else {
                phase = .failed("That instant could not be displayed.")
                endJourney("undisplayable")
                return
            }
            decoded = opened
        } catch {
            phase = .undecryptable
            endJourney("undecryptable")
            return
        }
        image = decoded

        if await sensitivity.isSensitive(decoded) {
            isConcealed = true
            phase = .showing
            endJourney("concealed")
            return
        }
        journey("checked")

        phase = .showing
        journey("shown")
        sendReceipt()
        startCountdown()
        endJourney("shown")
    }

    /// The clip's counterpart of the photo path: the same check, the same
    /// receipt, and playback in place of the clock.
    ///
    /// The classifier takes pictures, so it is shown two — the first frame and
    /// the middle one. Either flagged conceals the clip.
    private func showVideo(_ plaintext: Data) async {
        let player = makeVideoPlayer(plaintext, instant.durationMode == .loop)
        player.isMuted = isMuted
        video = player
        var flagged = false
        for fraction in [0, 0.5] {
            if let frame = await player.frame(at: fraction), await sensitivity.isSensitive(frame) {
                flagged = true
                break
            }
        }
        // Closed while the frames were being read.
        guard !isFinished else { return }
        journey("checked")
        phase = .showing
        if flagged {
            isConcealed = true
            endJourney("concealed")
            return
        }
        journey("shown")
        sendReceipt()
        startPlayback()
    }

    private func startPlayback() {
        guard let video, !isFinished else { return }
        video.onProgress = { [weak self] played in
            guard let self, instant.durationMode == .playOnce else { return }
            progress = 1 - played
        }
        video.onEnded = { [weak self] in
            guard let self, instant.durationMode != .loop else { return }
            finish()
        }
        // The end is the picture moving, which is later than being asked to.
        video.onPlaying = { [weak self] in
            guard let self else { return }
            endJourney("playing")
        }
        // Revealed while a sheet was already up: it plays when the sheet goes.
        guard !isPaused else { return }
        journey("playRequested")
        video.play()
    }

    public func toggleMute() {
        guard let video else { return }
        isMuted.toggle()
        video.isMuted = isMuted
        preferences.viewerMuted = isMuted
    }

    /// What a report attaches for a clip: the frame on screen when it was
    /// made, since the evidence endpoint takes a picture.
    public func reportableImage() async -> UIImage? {
        guard phase == .showing else { return nil }
        if let video { return await video.currentFrame() }
        return image
    }

    /// "View anyway" on a concealed photo. This is the moment it is seen, so
    /// this is when the receipt goes and the clock starts.
    public func reveal() async {
        guard isConcealed, phase == .showing, !isFinished else { return }
        isConcealed = false
        sendReceipt()
        if video != nil {
            startPlayback()
        } else {
            startCountdown()
        }
    }

    public func pause() {
        guard !isPaused, !isFinished else { return }
        isPaused = true
        video?.pause()
        guard let countdown, let startedAt = countdownStartedAt else { return }
        countdown.cancel()
        self.countdown = nil
        countdownRemaining = max(0, countdownRemaining - time.now().timeIntervalSince(startedAt))
        countdownStartedAt = nil
    }

    public func resume() {
        guard isPaused, !isFinished else { return }
        isPaused = false
        if let video {
            // Only a clip that was already playing comes back; one still
            // concealed is waiting for "View anyway".
            if !isConcealed, phase == .showing, hasSentReceipt { video.play() }
            return
        }
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
    ///
    /// Not awaited. The clock and the clip used to wait for it, which held a
    /// timed photo's ring full, and a clip on its first frame, for a round trip
    /// (0.2–0.35 s measured) that protects nothing: the sender's receipt is
    /// the claim on the media, not this call (`wiki/decisions.md`). The flag
    /// still flips here, synchronously, because `wasSeen` reads it.
    private func sendReceipt() {
        guard !hasSentReceipt else { return }
        hasSentReceipt = true
        receiptDelivery = Task { [api, instant] in
            try? await api.markViewed(instantId: instant.id)
        }
    }

    private func journey(_ mark: String) {
        JourneyLog.shared.mark(.openInstant, key: instant.id, mark)
    }

    private func endJourney(_ outcome: String) {
        JourneyLog.shared.end(.openInstant, key: instant.id, outcome: outcome)
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
        // Closed before anything was shown. Does nothing once it has been.
        endJourney("closed")
        countdown?.cancel()
        countdown = nil
        video?.stop()
        video = nil
        image = nil
        progress = 0
        isFinished = true
    }
}
#endif
