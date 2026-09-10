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
        // In-memory, and seeded: the picker orders by who you last talked to,
        // so a UI test needs a known history that does not leak between runs.
        let recentContacts = InMemoryRecentContactsStore()
        recentContacts.record(peerUserId: StubBackend.recentPeerId, for: 1, at: Date())

        let store = InstantStore(
            api: instantAPI,
            identities: identities,
            recentContacts: recentContacts,
            makeSocket: { _ in StubInboxSocket() }
        )
        return AppEnvironment(
            config: .localWorker,
            session: session,
            userAPI: UserAPI(client: client),
            instantAPI: instantAPI,
            identities: identities,
            store: store,
            recentContacts: recentContacts,
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
