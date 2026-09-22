#if canImport(UIKit)
import Foundation
import UIKit

/// Launch-argument wiring, used only by the UI tests.
///
/// UI tests need to be deterministic and offline: a real backend would make them
/// depend on network, on a live account, and on the destructive
/// `GET /:id/media` semantics — you cannot open the same instant twice, so a
/// re-run would fail. The stub swaps the API and camera seams and leaves every
/// screen, view model and navigation path exactly as shipped.
public enum LaunchOptions {
    public static let stubFlag = "-instantUITestStubs"
    public static let signedInFlag = "-instantUITestSignedIn"
    /// Points a normal (unstubbed) build at `npm run dev:worker`, so the app can
    /// be driven against a local backend without editing the shipped default.
    public static let localBackendFlag = "-instantLocalBackend"

    public static var isStubbed: Bool {
        ProcessInfo.processInfo.arguments.contains(stubFlag)
    }

    /// Lets a UI test put the app through the real notification-permission
    /// prompt, which is the only way to authorise pushes on a Simulator —
    /// `simctl privacy` has no notifications service.
    public static let requestPushFlag = "-instantUITestRequestPush"

    public static var requestsPush: Bool {
        ProcessInfo.processInfo.arguments.contains(requestPushFlag)
    }

    /// Serves an account that has not agreed to the Community Guidelines, so a
    /// UI test can drive the gate.
    public static let termsPendingFlag = "-instantUITestTermsPending"

    public static var termsPending: Bool {
        ProcessInfo.processInfo.arguments.contains(termsPendingFlag)
    }

    /// Upload behaviour for the outbox tests: slow enough to see the spinner,
    /// never finishing so the app can be killed mid-send, or failing once.
    public static let slowSendFlag = "-instantUITestSlowSend"
    public static let stallSendFlag = "-instantUITestStallSend"
    public static let failFirstSendFlag = "-instantUITestFailFirstSend"
    /// Keeps what the previous launch left in the outbox. Every other stubbed
    /// launch starts with it empty, so one test's unsent photo is never sent by
    /// the next.
    public static let keepOutboxFlag = "-instantUITestKeepOutbox"

    /// Seconds the upload takes. `-instantUITestSendDelay 10` sets it through
    /// the arguments domain; the slow-send flag alone means three.
    static var sendDelay: Double? {
        let configured = UserDefaults.standard.double(forKey: "instantUITestSendDelay")
        if configured > 0 { return configured }
        return ProcessInfo.processInfo.arguments.contains(slowSendFlag) ? 3 : nil
    }
    static var stallsSend: Bool { ProcessInfo.processInfo.arguments.contains(stallSendFlag) }
    static var failsFirstSend: Bool { ProcessInfo.processInfo.arguments.contains(failFirstSendFlag) }

    /// On disk even under the stubs, because surviving a relaunch is the
    /// behaviour under test — but in a directory of its own.
    @MainActor
    static func stubOutboxStore() -> PendingSendStoring {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("outbox-uitest", isDirectory: true)
        let store = PendingSendStore(directory: directory)
        if !ProcessInfo.processInfo.arguments.contains(keepOutboxFlag) {
            store.clear()
        }
        return store
    }

    /// The instant waiting in the stubbed inbox is a clip rather than a photo:
    /// a real one, encoded by `VideoPipeline` and sealed like any other, so the
    /// viewer under test decrypts and plays what a phone would send.
    public static let videoInstantFlag = "-instantUITestVideoInstant"

    static var servesVideoInstant: Bool {
        ProcessInfo.processInfo.arguments.contains(videoInstantFlag)
    }

    /// Shows the update notes. Every other stubbed launch has already seen
    /// them, so a sheet never lands on top of a test that is not about it.
    public static let whatsNewFlag = "-instantUITestWhatsNew"

    @MainActor
    static func stubWhatsNew() -> WhatsNewTracker {
        let defaults = UserDefaults(suiteName: "instant-uitest-whatsnew")!
        defaults.removePersistentDomain(forName: "instant-uitest-whatsnew")
        let tracker = WhatsNewTracker(defaults: defaults)
        if !ProcessInfo.processInfo.arguments.contains(whatsNewFlag) {
            tracker.markSeen()
        }
        return tracker
    }

    public static var startsSignedIn: Bool {
        ProcessInfo.processInfo.arguments.contains(signedInFlag)
    }

    @MainActor
    public static func makeEnvironment() -> AppEnvironment {
        guard isStubbed else {
            return .live(
                config: ProcessInfo.processInfo.arguments.contains(localBackendFlag)
                    ? .localWorker
                    : .production
            )
        }

        let tokens = InMemoryTokenStore(token: startsSignedIn ? StubBackend.token : nil)
        let session = SessionStore(keychain: InMemoryKeychain(
            seed: startsSignedIn
                ? ["session:access-token": Data(StubBackend.token.utf8)]
                : [:]
        ))
        _ = tokens

        let client = StubAPIClient()
        let instantAPI = InstantAPI(client: client)
        let identities = DeviceIdentityStore(
            keychain: InMemoryKeychain(),
            secureEnclaveAvailable: { false }
        )
        let store = InstantStore(
            api: instantAPI,
            identities: identities,
            makeSocket: { _ in StubInboxSocket() }
        )
        return AppEnvironment(
            config: .localWorker,
            session: session,
            userAPI: UserAPI(client: client),
            instantAPI: instantAPI,
            moderationAPI: ModerationAPI(client: client),
            identities: identities,
            store: store,
            pendingSends: stubOutboxStore(),
            whatsNew: stubWhatsNew(),
            ownsCaptureScratch: true,
            makeCamera: { StubCameraController(frame: StubBackend.cameraFrame()) }
        )
    }
}

/// A socket that never connects, so the stubbed UI relies on the inbox drain —
/// which is the path a real cold start takes anyway.
final class StubInboxSocket: InboxSocketProtocol, @unchecked Sendable {
    let events: AsyncStream<InboxSocketEvent>
    private let continuation: AsyncStream<InboxSocketEvent>.Continuation

    init() {
        (events, continuation) = AsyncStream<InboxSocketEvent>.makeStream()
    }

    func start(deviceId: String) {
        continuation.yield(.shouldDrainInbox)
        continuation.yield(.state(.open))
    }

    func stop() {
        continuation.finish()
    }
}
#endif
