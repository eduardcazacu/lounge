import Foundation
import Testing
@testable import Instant

/// 1.0 wrote nothing that says "this device has seen the notes", so whether
/// they appear rests entirely on being signed in already. Every case here is a
/// sheet that either appears for someone who has nothing to compare with, or
/// never appears for the people the notes were written for.
@MainActor
@Suite("What's new after an update")
struct WhatsNewTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: UUID().uuidString)!
    }

    private func signedInSession() -> SessionStore {
        SessionStore(keychain: InMemoryKeychain(
            seed: ["session:access-token": Data(StubBackend.token.utf8)]
        ))
    }

    @Test("Someone already signed in when the update lands sees the notes, once")
    func showsOnceAfterUpgrade() {
        let environment = makeTestEnvironment(session: signedInSession())

        environment.presentWhatsNewIfDue()
        #expect(environment.showsWhatsNew)

        environment.showsWhatsNew = false
        environment.presentWhatsNewIfDue()
        #expect(environment.showsWhatsNew == false)
    }

    @Test("Signing in counts as having seen them")
    func signInMarksSeen() async {
        let tracker = WhatsNewTracker(defaults: freshDefaults())
        let environment = makeTestEnvironment(whatsNew: tracker)

        await environment.handleSignIn(token: StubBackend.token)

        #expect(tracker.isDue == false)
    }

    @Test("Nobody signed in sees nothing, and the notes stay due")
    func signedOut() {
        let tracker = WhatsNewTracker(defaults: freshDefaults())
        let environment = makeTestEnvironment(whatsNew: tracker)

        environment.presentWhatsNewIfDue()

        #expect(environment.showsWhatsNew == false)
        #expect(tracker.isDue)
    }

    @Test("A tapped notification opens the photo, and the notes wait")
    func deferredByNotification() {
        let tracker = WhatsNewTracker(defaults: freshDefaults())
        let environment = makeTestEnvironment(session: signedInSession(), whatsNew: tracker)
        environment.openInbox(instantId: "11111111-2222-3333-4444-555555555555")

        environment.presentWhatsNewIfDue()

        #expect(environment.showsWhatsNew == false)
        #expect(tracker.isDue)
    }

    @Test("Not over the guidelines gate")
    func deferredByTerms() async {
        let tracker = WhatsNewTracker(defaults: freshDefaults())
        let environment = makeTestEnvironment(session: signedInSession(), whatsNew: tracker)
        await environment.loadAccount()
        #expect(environment.needsTermsAcceptance)

        environment.presentWhatsNewIfDue()

        #expect(environment.showsWhatsNew == false)
        #expect(tracker.isDue)
    }

    @Test("Newer notes are due again on a device that saw the last ones")
    func newerNotesAreDue() {
        let defaults = freshDefaults()
        WhatsNewTracker(defaults: defaults).markSeen()
        let next = WhatsNew(version: "99.0", features: [], fixes: [])

        #expect(WhatsNewTracker(defaults: defaults).isDue == false)
        #expect(WhatsNewTracker(defaults: defaults, notes: next).isDue)
    }

    /// The notes name a version, and the sheet's title says it. A release
    /// that bumps `MARKETING_VERSION` without new notes is fine — nothing
    /// shows — but notes naming a version the app is not must not ship.
    @Test("The notes are not for a version newer than the app")
    func notesMatchBundle() throws {
        let bundleVersion = try #require(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
        #expect(
            WhatsNew.current.version.compare(bundleVersion, options: .numeric) != .orderedDescending
        )
    }
}
