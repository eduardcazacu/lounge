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

    /// Where every way in from outside the app lands.
    ///
    /// A notification and a widget both say "someone sent you something", so
    /// both open the inbox — with the named instant on top of it when the
    /// notification named one. The camera is where the app opens by itself, not
    /// where someone who tapped a photo waiting for them wants to be.
    /// Routes a URL the app was opened with — today, only a tapped widget.
    /// Returns whether it was ours, which is what makes the decision testable
    /// without a view.
    @discardableResult
    public func handle(_ url: URL) -> Bool {
        guard case let .inbox(instantId)? = DeepLink(url: url) else { return false }
        openInbox(instantId: instantId)
        return true
    }

    public func openInbox(instantId: String? = nil) {
        // Assigning the same id twice would not fire the observation the inbox
        // watches, and a second push for an instant already pending is not a
        // second thing to open.
        if let instantId, instantId != pendingInstantId {
            pendingInstantId = instantId
        }
        showsInbox = true
    }

    /// The signed-in account, loaded once so the camera's profile button can
    /// show a real avatar rather than waiting for someone to open Settings.
    public private(set) var account: AccountProfile?

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

    public func loadAccount() async {
        account = try? await userAPI.me()
    }

    public func signOut() async {
        await userAPI.signOut()
        store.reset()
        session.signOut()
        account = nil
    }

    public func handleSignIn(token: String) async {
        session.setToken(token)
        guard let userId = session.currentUserId else { return }
        await store.start(userId: userId)
        await loadAccount()
    }
}
