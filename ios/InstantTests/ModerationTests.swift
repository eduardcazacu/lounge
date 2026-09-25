import Foundation
import Testing
import UIKit
@testable import Instant

@MainActor
@Suite("Reporting")
struct ReportModelTests {
    private let photo = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 30)).image { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
    }

    @Test("Nothing is sent until a reason is chosen")
    func requiresReason() async {
        let api = FakeModerationAPI()
        let model = ReportModel(reportedUserId: 2, reportedName: "Ana", api: api)

        #expect(!model.canSubmit)
        #expect(await model.submit() == false)
        #expect(api.reports.isEmpty)

        model.reason = .harassment
        #expect(model.canSubmit)
    }

    /// Attaching the photo takes it out of end-to-end encryption, so having one
    /// to attach must never be the same thing as attaching it.
    @Test("The photo is not attached unless asked for")
    func photoIsOptIn() async throws {
        let api = FakeModerationAPI()
        let model = ReportModel(
            reportedUserId: 2, reportedName: "Ana", instantId: "i1", photo: photo, api: api,
            encodeEvidence: { _ in Issue.record("encoded without being asked"); return Data() }
        )
        model.reason = .nudity
        model.details = "  not ok  "

        #expect(model.canAttachPhoto)
        #expect(!model.includesPhoto)
        #expect(await model.submit())

        let sent = try #require(api.reports.first)
        #expect(sent.evidence == nil)
        #expect(sent.reportedUserId == 2)
        #expect(sent.instantId == "i1")
        #expect(sent.reason == .nudity)
        #expect(sent.alsoBlock, "reporting blocks by default")
    }

    @Test("An attached photo is encoded and sent")
    func attachesPhoto() async {
        let api = FakeModerationAPI()
        let evidence = Data([1, 2, 3])
        let model = ReportModel(
            reportedUserId: 2, reportedName: "Ana", photo: photo, api: api,
            encodeEvidence: { _ in evidence }
        )
        model.reason = .nudity
        model.includesPhoto = true
        model.alsoBlock = false

        #expect(await model.submit())
        #expect(api.reports.first?.evidence == evidence)
        #expect(api.reports.first?.alsoBlock == false)
    }

    @Test("A conversation row has no photo to offer")
    func noPhotoFromRow() {
        let model = ReportModel(reportedUserId: 3, reportedName: "Bo", api: FakeModerationAPI())
        #expect(!model.canAttachPhoto)
    }

    @Test("A photo that will not encode stops the report and says why")
    func encodeFailure() async {
        struct Broken: Error {}
        let api = FakeModerationAPI()
        let model = ReportModel(
            reportedUserId: 2, reportedName: "Ana", photo: photo, api: api,
            encodeEvidence: { _ in throw Broken() }
        )
        model.reason = .violence
        model.includesPhoto = true

        #expect(await model.submit() == false)
        #expect(api.reports.isEmpty)
        #expect(model.errorMessage?.contains("Include this photo") == true)
    }

    @Test("A server error keeps the sheet up with its message")
    func serverError() async {
        let api = FakeModerationAPI()
        api.reportError = APIError(status: 404, message: "User not found")
        let model = ReportModel(reportedUserId: 9, reportedName: "Nobody", api: api)
        model.reason = .spam

        #expect(await model.submit() == false)
        #expect(model.errorMessage == "User not found")
        #expect(model.reason == .spam, "nothing chosen is lost")
    }

    @Test("The real encoder produces an image under the server's limit")
    func encodesForModerators() throws {
        let large = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 3000)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2000, height: 3000))
        }
        let data = try ReportModel.encodeForModerators(large)
        #expect(data.count > 0)
        #expect(data.count < 3 * 1024 * 1024)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
    }
}

@MainActor
@Suite("Blocked people")
struct BlockedPeopleModelTests {
    private func user(_ id: Int, _ name: String) -> BlockedUser {
        BlockedUser(
            userId: id, name: name, themeKey: "rose", profilePictureUrl: nil,
            blockedAt: "2026-09-14T10:00:00.000Z"
        )
    }

    @Test("Loads who is blocked, and unblocking removes them")
    func unblocks() async {
        let api = FakeModerationAPI()
        api.blocked = [user(2, "Ana"), user(3, "Bo")]
        let model = BlockedPeopleModel(api: api)

        await model.load()
        #expect(model.hasLoaded)
        #expect(model.blocked.map(\.userId) == [2, 3])

        await model.unblock(model.blocked[0])
        #expect(model.blocked.map(\.userId) == [3])
        #expect(api.unblockedIds == [2])
    }

    @Test("A failed unblock puts them back where they were")
    func failedUnblock() async {
        let api = FakeModerationAPI()
        api.blocked = [user(2, "Ana"), user(3, "Bo")]
        api.unblockError = APIError(status: 500, message: "nope")
        let model = BlockedPeopleModel(api: api)
        await model.load()

        await model.unblock(model.blocked[0])
        #expect(model.blocked.map(\.userId) == [2, 3])
        #expect(model.errorMessage != nil)
    }
}

@MainActor
@Suite("Deleting an account")
struct DeleteAccountModelTests {
    @Test("Needs a password, and passes it through")
    func deletes() async {
        let userAPI = FakeUserAPI()
        let model = DeleteAccountModel(userAPI: userAPI)

        #expect(!model.canDelete)
        #expect(await model.delete() == false)
        #expect(userAPI.deleteAccountPasswords.isEmpty)

        model.password = "hunter2"
        #expect(await model.delete())
        #expect(userAPI.deleteAccountPasswords == ["hunter2"])
    }

    @Test("A wrong password is an error on the sheet, not a sign-out")
    func wrongPassword() async {
        let userAPI = FakeUserAPI()
        userAPI.deleteAccountResult = .failure(APIError(status: 400, message: "That password is not correct."))
        let model = DeleteAccountModel(userAPI: userAPI)
        model.password = "wrong"

        #expect(await model.delete() == false)
        #expect(model.errorMessage == "That password is not correct.")
        #expect(userAPI.signOutCount == 0)
    }
}

@MainActor
@Suite("Terms, blocks and deletion on the environment")
struct ModerationEnvironmentTests {
    /// Seeded through the keychain rather than `setToken`, which publishes the
    /// user id on a later main-actor hop: a test reading it straight after
    /// would see nobody signed in.
    private func signedInSession() -> SessionStore {
        SessionStore(keychain: InMemoryKeychain(
            seed: ["session:access-token": Data(StubBackend.token.utf8)]
        ))
    }

    @Test("Asks for the guidelines only once the account says they are missing")
    func termsGate() async throws {
        let userAPI = FakeUserAPI()
        let environment = makeTestEnvironment(userAPI: userAPI, session: signedInSession())

        // Not loaded yet: no gate, so a failed /me cannot lock anyone out.
        #expect(!environment.needsTermsAcceptance)

        await environment.loadAccount()
        #expect(environment.needsTermsAcceptance)

        try await environment.acceptTerms()
        #expect(userAPI.acceptTermsCount == 1)
        #expect(!environment.needsTermsAcceptance)
    }

    @Test("Signed out, there is nothing to agree to")
    func noGateSignedOut() async {
        let environment = makeTestEnvironment()
        await environment.loadAccount()
        #expect(!environment.needsTermsAcceptance)
    }

    @Test("Blocking someone drops their conversation, what they sent, and any aim at them")
    func didBlockForgets() {
        let environment = makeTestEnvironment()
        environment.store.applyHistory([
            .fixture(userId: 2, name: "Ana", unopenedCount: 1),
            .fixture(userId: 3, name: "Bo"),
        ])
        environment.store.merge([InstantDelivery.fixture(id: "from-ana", senderId: 2)])
        environment.aim(at: InstantRecipient(userId: 2, name: "Ana"))

        environment.didBlock(userId: 2)

        #expect(environment.store.history.map(\.userId) == [3])
        #expect(environment.store.instants.isEmpty)
        #expect(environment.aimedAt == nil)
    }

    @Test("Blocking someone else leaves the aim alone")
    func didBlockKeepsOtherAim() {
        let environment = makeTestEnvironment()
        environment.aim(at: InstantRecipient(userId: 3, name: "Bo"))
        environment.didBlock(userId: 2)
        #expect(environment.aimedAt?.userId == 3)
    }

    /// Keychain items outlive the app, so a deleted account's key would
    /// otherwise stay on the phone for good.
    @Test("After deletion the device key is gone and the session is over")
    func didDeleteAccount() async throws {
        let userAPI = FakeUserAPI()
        let environment = makeTestEnvironment(userAPI: userAPI, session: signedInSession())
        let userId = try #require(environment.session.currentUserId)
        let before = try environment.identities.identity(forUserId: userId)

        await environment.didDeleteAccount()

        #expect(await eventually { !environment.session.isSignedIn })
        #expect(userAPI.signOutCount == 1)
        let after = try environment.identities.identity(forUserId: userId)
        #expect(after.deviceId != before.deviceId, "a fresh identity means the old one was deleted")
    }
}
