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
