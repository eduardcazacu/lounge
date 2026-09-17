import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Someone a photo is already aimed at.
///
/// The name travels with the id because the two places that show it — the
/// camera's chip and the compose screen's send button — have no conversation
/// list to look it up in, and an instant aimed at "user 3" tells the sender
/// nothing about whether it is going to the right person.
public struct InstantRecipient: Identifiable, Equatable, Sendable {
    public let userId: Int
    public let name: String

    public var id: Int { userId }

    public init(userId: Int, name: String) {
        self.userId = userId
        self.name = name
    }
}

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
    public let moderationAPI: ModerationAPIProtocol
    public let store: InstantStore
    public let identities: DeviceIdentityProviding
    public let makeCamera: @MainActor () -> CameraControlling

    /// Set when a push arrives naming an instant, so the UI can jump to it.
    public var pendingInstantId: String?
    public var showsInbox = false

    /// True while a capture is being composed.
    ///
    /// The account button is drawn above the pager so that it survives the
    /// swipe, which also puts it above the compose screen — on top of the cross
    /// that discards the photo, in the same corner. Composing is the one time
    /// it has to get out of the way.
    public var isComposing = false

    /// Who the next photo is already going to, set by tapping someone in the
    /// inbox. The camera draws it, so an aim is never a surprise waiting on the
    /// send button — and it outlives a discarded capture, because it came from
    /// the inbox rather than from the photo.
    public private(set) var aimedAt: InstantRecipient?

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

    /// Tapping someone in the inbox: the camera, already aimed at them.
    ///
    /// The camera rather than a recipient picker, because the thing being sent
    /// does not exist yet — Snapchat's order, where you take the photo and then
    /// say who it is for, with the "who" already answered here.
    public func aim(at recipient: InstantRecipient) {
        aimedAt = recipient
        showsInbox = false
    }

    /// Dropped once something has been sent, or when the sender taps the chip's
    /// cross. Not dropped by discarding a capture: the aim survives a retake.
    public func clearAim() {
        aimedAt = nil
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

    /// Signed in, account loaded, and the Community Guidelines not yet agreed
    /// to. Guideline 1.2: nobody gets past this until they have said yes.
    ///
    /// Keyed off a loaded account rather than a missing one, so a network
    /// failure fetching `/me` does not lock someone out behind a sheet that
    /// cannot submit either.
    public var needsTermsAcceptance: Bool {
        guard session.isSignedIn, let account else { return false }
        return account.termsAcceptedAt == nil
    }

    public func acceptTerms() async throws {
        _ = try await userAPI.acceptTerms()
        await loadAccount()
    }

    public init(
        config: AppConfig,
        session: SessionStore,
        userAPI: UserAPIProtocol,
        instantAPI: InstantAPIProtocol,
        moderationAPI: ModerationAPIProtocol,
        identities: DeviceIdentityProviding,
        store: InstantStore,
        makeCamera: @escaping @MainActor () -> CameraControlling
    ) {
        self.config = config
        self.session = session
        self.userAPI = userAPI
        self.instantAPI = instantAPI
        self.moderationAPI = moderationAPI
        self.identities = identities
        self.store = store
        self.makeCamera = makeCamera
        // Before the first frame, so a cold start — most often a tapped
        // notification or widget, landing on the inbox — never draws it empty.
        if let userId = session.currentUserId {
            store.restore(userId: userId)
        }
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
            cache: InboxCache(),
            makeSocket: { api in InboxSocket(api: api, config: config) }
        )
        return AppEnvironment(
            config: config,
            session: session,
            userAPI: UserAPI(client: client),
            instantAPI: instantAPI,
            moderationAPI: ModerationAPI(client: client),
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
        aimedAt = nil
    }

    /// Someone was just blocked, from wherever: their conversation and anything
    /// waiting from them leave this device now, and an aim at them is dropped.
    public func didBlock(userId: Int) {
        store.forget(userId: userId)
        if aimedAt?.userId == userId { aimedAt = nil }
    }

    /// The account is already gone on the server. This device's key for it goes
    /// too — Keychain items outlive the app, and a key for an account that no
    /// longer exists is nothing but a thing to leak — and then it signs out.
    public func didDeleteAccount() async {
        if let userId = session.currentUserId {
            identities.reset(forUserId: userId)
        }
        await signOut()
    }

    public func handleSignIn(token: String) async {
        session.setToken(token)
        guard let userId = session.currentUserId else { return }
        await store.start(userId: userId)
        await loadAccount()
    }
}
