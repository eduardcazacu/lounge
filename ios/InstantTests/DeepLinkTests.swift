import Foundation
import Testing
import UIKit
@testable import Instant

/// The contract between the widget, which writes these URLs, and the app, which
/// reads them. They are built and parsed in different binaries, so a change to
/// one that does not match the other fails silently: the tap opens the app on
/// the camera, exactly as if there were no deep link at all.
@Suite("Deep links")
struct DeepLinkTests {
    @Test("An inbox link survives the round trip")
    func roundTripsInbox() {
        let url = DeepLink.inbox(instantId: nil).url
        #expect(DeepLink(url: url) == .inbox(instantId: nil))
    }

    @Test("An inbox link carries the instant a notification named")
    func roundTripsInstantId() {
        let id = "11111111-2222-3333-4444-555555555555"
        let url = DeepLink.inbox(instantId: id).url
        #expect(DeepLink(url: url) == .inbox(instantId: id))
    }

    /// The widget builds the URL against a scheme the app declares in its
    /// Info.plist. If either half moves, nothing routes.
    @Test("Uses the scheme the app registers")
    func usesRegisteredScheme() {
        #expect(DeepLink.scheme == "instant")
        #expect(DeepLink.inbox(instantId: nil).url.scheme == "instant")
    }

    @Test("An empty id is the same as no id")
    func treatsEmptyIdAsAbsent() {
        #expect(DeepLink(url: URL(string: "instant://inbox?instant=")!) == .inbox(instantId: nil))
        #expect(DeepLink.inbox(instantId: "").url.query == nil)
    }

    /// Guessing that an unknown URL meant the inbox would let anything that can
    /// open a URL move the app around.
    @Test("Ignores anything that is not ours")
    func ignoresForeignURLs() {
        #expect(DeepLink(url: URL(string: "https://lounge.eduardcazacu.com/instant")!) == nil)
        #expect(DeepLink(url: URL(string: "instant://camera")!) == nil)
        #expect(DeepLink(url: URL(string: "other://inbox")!) == nil)
    }
}

/// The other half: what the app does with one.
@MainActor
@Suite("Opening from outside the app")
struct DeepLinkRoutingTests {
    private func makeEnvironment() -> AppEnvironment {
        let identities = DeviceIdentityStore(
            keychain: InMemoryKeychain(),
            secureEnclaveAvailable: { false }
        )
        let api = FakeInstantAPI()
        return AppEnvironment(
            config: .localWorker,
            session: SessionStore(keychain: InMemoryKeychain()),
            userAPI: FakeUserAPI(),
            instantAPI: api,
            identities: identities,
            store: InstantStore(api: api, identities: identities, makeSocket: { _ in StubSocket() }),
            makeCamera: { StubCameraController(frame: UIImage()) }
        )
    }

    /// The app opens on the camera. A widget saying someone is waiting has to
    /// override that, or the tap lands somewhere that says nothing about why it
    /// was tapped.
    @Test("A tapped widget lands on the inbox")
    func widgetOpensInbox() {
        let environment = makeEnvironment()
        #expect(!environment.showsInbox)
        #expect(environment.handle(DeepLink.inbox(instantId: nil).url))
        #expect(environment.showsInbox)
    }

    @Test("A tapped notification lands on the inbox, and on its instant")
    func notificationOpensInstant() {
        let environment = makeEnvironment()
        environment.openInbox(instantId: "abc-123")
        #expect(environment.showsInbox)
        #expect(environment.pendingInstantId == "abc-123")
    }

    @Test("A URL that is not ours moves nothing")
    func ignoresForeignURL() {
        let environment = makeEnvironment()
        #expect(!environment.handle(URL(string: "https://example.com")!))
        #expect(!environment.showsInbox)
        #expect(environment.pendingInstantId == nil)
    }
}
