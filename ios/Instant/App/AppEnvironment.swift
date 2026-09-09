import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Everything the views need, assembled once.
///
/// It is a concrete type rather than a protocol soup because the seams that
/// matter for testing are one level down — `APIClientProtocol`, `CameraControlling`,
/// `DeviceIdentityProviding` — and those are what the tests replace.
@MainActor
@Observable
public final class AppEnvironment {
    public let config: AppConfig
    public let session: SessionStore
    public let userAPI: UserAPIProtocol
    public let instantAPI: InstantAPIProtocol
    public let store: InstantStore
    public let identities: DeviceIdentityProviding
    public let makeCamera: @MainActor () -> CameraControlling

    /// Set when a push arrives naming an instant, so the UI can jump to it.
    public var pendingInstantId: String?
    public var showsInbox = false

    public init(
        config: AppConfig,
        session: SessionStore,
        userAPI: UserAPIProtocol,
        instantAPI: InstantAPIProtocol,
        identities: DeviceIdentityProviding,
        store: InstantStore,
        makeCamera: @escaping @MainActor () -> CameraControlling
    ) {
        self.config = config
        self.session = session
        self.userAPI = userAPI
        self.instantAPI = instantAPI
        self.identities = identities
        self.store = store
        self.makeCamera = makeCamera
    }

    public static func live(config: AppConfig = .production) -> AppEnvironment {
        let session = SessionStore()
        let client = APIClient(config: config, tokens: session) { [weak session] in
            session?.signOut()
        }
        let instantAPI = InstantAPI(client: client)
        let identities = DeviceIdentityStore()
        let store = InstantStore(
            api: instantAPI,
            identities: identities,
            makeSocket: { api in InboxSocket(api: api, config: config) }
        )
        return AppEnvironment(
            config: config,
            session: session,
            userAPI: UserAPI(client: client),
            instantAPI: instantAPI,
            identities: identities,
            store: store,
            makeCamera: { CameraController() }
        )
    }

    public func signOut() async {
        await userAPI.signOut()
        store.reset()
        session.signOut()
    }

    public func handleSignIn(token: String) async {
        session.setToken(token)
        guard let userId = session.currentUserId else { return }
        await store.start(userId: userId)
    }
}
