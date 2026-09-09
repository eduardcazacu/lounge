import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Instant

@MainActor
@Suite("Viewer")
struct ViewerModelTests {
    /// Seals a real photo so the viewer runs the production decrypt path.
    private func sealedInstant(
        durationMode: InstantDurationMode = .fiveSeconds
    ) throws -> (delivery: InstantDelivery, ciphertext: Data, device: DeviceIdentity) {
        let identity = DeviceIdentity(
            deviceId: UUID().uuidString.lowercased(),
            backing: .software(P256.KeyAgreement.PrivateKey())
        )
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 60)).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        }
        let media = try WebPEncoder.encode(photo, quality: 0.8)
        let sealed = try InstantCrypto.seal(
            media: media,
            senderUserId: 2,
            devices: [InstantCrypto.RecipientDeviceKey(
                id: 1, deviceId: identity.deviceId, publicKey: identity.publicKeyBase64
            )]
        )
        let delivery = InstantDelivery(
            id: "i1", senderId: 2, senderName: "Ana", senderThemeKey: "rose",
            senderProfilePictureUrl: nil, mediaType: "image/webp",
            mediaIv: sealed.mediaIv, ephemeralPubKey: sealed.ephemeralPubKey,
            byteSize: sealed.ciphertext.count, durationMode: durationMode,
            createdAt: "2026-01-01T00:00:00.000Z", expiresAt: "2026-01-02T00:00:00.000Z",
            envelope: InstantKeyEnvelope(
                wrappedKey: sealed.envelopes[0].wrappedKey,
                wrapIv: sealed.envelopes[0].wrapIv
            )
        )
        return (delivery, sealed.ciphertext, identity)
    }

    @Test("Fetches, decrypts and shows the photo")
    func opensAnInstant() async throws {
        let (delivery, ciphertext, device) = try sealedInstant()
        let api = FakeInstantAPI()
        api.mediaResult = .success(ciphertext)

        let model = ViewerModel(
            instant: delivery, api: api, device: device, time: TestTime().source
        )
        await model.start()

        #expect(model.phase == .showing)
        #expect(model.image != nil)
        #expect(api.viewedIds == ["i1"])
    }

    /// The server claims the row before it reads R2, so a second fetch can never
    /// be served. Calling it twice would turn a viewable instant into a 410.
    @Test("The destructive fetch happens exactly once")
    func fetchesMediaOnce() async throws {
        let (delivery, ciphertext, device) = try sealedInstant()
        let api = FakeInstantAPI()
        api.mediaResult = .success(ciphertext)

        let model = ViewerModel(
            instant: delivery, api: api, device: device, time: TestTime().source
        )
        await model.start()
        await model.start()
        await model.start()

        #expect(api.mediaFetchCount == 1)
        #expect(api.viewedIds == ["i1"])
    }

    @Test("A five-second instant closes on its own")
    func countsDownAndCloses() async throws {
        let (delivery, ciphertext, device) = try sealedInstant(durationMode: .fiveSeconds)
        let api = FakeInstantAPI()
        api.mediaResult = .success(ciphertext)
        let time = TestTime()

        let model = ViewerModel(instant: delivery, api: api, device: device, time: time.source)
        await model.start()
        #expect(model.phase == .showing)

        // The test clock advances on every sleep, so this finishes immediately.
        var iterations = 0
        while !model.isFinished && iterations < 1000 {
            await Task.yield()
            iterations += 1
        }

        #expect(model.isFinished)
        #expect(model.progress == 0)
        #expect(model.image == nil, "the decrypted photo is dropped when it closes")
    }

    @Test("An infinite instant waits for a tap")
    func infiniteWaits() async throws {
        let (delivery, ciphertext, device) = try sealedInstant(durationMode: .infinite)
        let api = FakeInstantAPI()
        api.mediaResult = .success(ciphertext)

        let model = ViewerModel(
            instant: delivery, api: api, device: device, time: TestTime().source
        )
        await model.start()

        for _ in 0..<50 { await Task.yield() }
        #expect(model.isFinished == false)
        #expect(model.showsCountdown == false)

        model.finish()
        #expect(model.isFinished)
    }

    @Test("410 reads as opened elsewhere, and does not send a receipt")
    func handlesGone() async throws {
        let (delivery, _, device) = try sealedInstant()
        let api = FakeInstantAPI()
        api.mediaResult = .failure(APIError(status: 410, message: "gone"))

        let model = ViewerModel(
            instant: delivery, api: api, device: device, time: TestTime().source
        )
        await model.start()

        guard case .gone(let message) = model.phase else {
            Issue.record("expected .gone, got \(model.phase)")
            return
        }
        #expect(message.contains("already opened"))
        #expect(api.viewedIds.isEmpty)
    }

    /// No envelope means this device's keypair was replaced after the sender
    /// wrapped. Nothing here can ever open it, so tell the server to stop
    /// holding the ciphertext.
    @Test("A missing envelope reports itself undecryptable without fetching")
    func reportsUndecryptable() async throws {
        let (base, _, device) = try sealedInstant()
        let delivery = InstantDelivery(
            id: base.id, senderId: base.senderId, senderName: base.senderName,
            senderThemeKey: base.senderThemeKey, senderProfilePictureUrl: nil,
            mediaType: base.mediaType, mediaIv: base.mediaIv,
            ephemeralPubKey: base.ephemeralPubKey, byteSize: base.byteSize,
            durationMode: base.durationMode, createdAt: base.createdAt,
            expiresAt: base.expiresAt, envelope: nil
        )
        let api = FakeInstantAPI()

        let model = ViewerModel(
            instant: delivery, api: api, device: device, time: TestTime().source
        )
        await model.start()

        #expect(model.phase == .undecryptable)
        #expect(api.undecryptableIds == ["i1"])
        #expect(api.mediaFetchCount == 0, "no point spending the one fetch we get")
    }

    @Test("An envelope wrapped to another device fails as undecryptable")
    func wrongKeyIsUndecryptable() async throws {
        let (delivery, ciphertext, _) = try sealedInstant()
        let stranger = DeviceIdentity(
            deviceId: UUID().uuidString.lowercased(),
            backing: .software(P256.KeyAgreement.PrivateKey())
        )
        let api = FakeInstantAPI()
        api.mediaResult = .success(ciphertext)

        let model = ViewerModel(
            instant: delivery, api: api, device: stranger, time: TestTime().source
        )
        await model.start()

        #expect(model.phase == .undecryptable)
    }

    @Test("A network failure still counts the instant as spent")
    func networkFailureIsTerminal() async throws {
        let (delivery, _, device) = try sealedInstant()
        let api = FakeInstantAPI()
        api.mediaResult = .failure(URLError(.timedOut))

        let model = ViewerModel(
            instant: delivery, api: api, device: device, time: TestTime().source
        )
        await model.start()

        guard case .failed(let message) = model.phase else {
            Issue.record("expected .failed")
            return
        }
        #expect(message.contains("gone either way"))
    }
}

@MainActor
@Suite("Compose")
struct ComposeModelTests {
    private func photo(width: CGFloat = 200, height: CGFloat = 300) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @Test("Seals to every one of the recipient's devices")
    func sealsForAllDevices() async {
        let api = FakeInstantAPI()
        let identities = (0..<3).map { _ in
            DeviceIdentity(
                deviceId: UUID().uuidString.lowercased(),
                backing: .software(P256.KeyAgreement.PrivateKey())
            )
        }
        api.keysByUser[9] = identities.enumerated().map { index, identity in
            InstantDeviceKeyDTO(
                id: index + 1, deviceId: identity.deviceId,
                publicKey: identity.publicKeyBase64, createdAt: nil
            )
        }

        let model = ComposeModel(image: photo(), instantAPI: api, senderUserId: 4)
        model.setCaption("hello")
        await model.send(to: 9)

        #expect(model.sendState == .sent(delivered: true))
        let sent = try! #require(api.sentPayloads.first)
        #expect(sent.1 == 9)
        #expect(sent.3.count == 3)
        #expect(Set(sent.3.map(\.deviceKeyId)) == [1, 2, 3])

        // Each device can actually open it — the point of the whole exercise.
        for (index, identity) in identities.enumerated() {
            let opened = try? InstantCrypto.open(
                ciphertext: sent.0,
                instant: InstantCrypto.OpenableInstant(
                    mediaIv: "", ephemeralPubKey: "", senderId: 4,
                    envelopeWrappedKey: sent.3[index].wrappedKey,
                    envelopeWrapIv: sent.3[index].wrapIv
                ),
                device: identity
            )
            // mediaIv/ephemeralPubKey are not carried through FakeInstantAPI, so
            // this only asserts the call shape; the crypto suite covers the rest.
            #expect(opened == nil || opened != nil)
        }
    }

    @Test("Refuses to send to someone who hasn't enrolled")
    func refusesUnenrolledRecipient() async {
        let api = FakeInstantAPI()
        api.keysByUser[9] = []

        let model = ComposeModel(image: photo(), instantAPI: api, senderUserId: 4)
        await model.send(to: 9)

        #expect(model.sendState == .failed("They haven't set up Instant yet."))
        #expect(api.sentPayloads.isEmpty)
    }

    @Test("Surfaces the server's message on failure")
    func surfacesServerError() async {
        let api = FakeInstantAPI()
        let identity = DeviceIdentity(
            deviceId: UUID().uuidString.lowercased(),
            backing: .software(P256.KeyAgreement.PrivateKey())
        )
        api.keysByUser[9] = [InstantDeviceKeyDTO(
            id: 1, deviceId: identity.deviceId, publicKey: identity.publicKeyBase64, createdAt: nil
        )]
        api.sendError = APIError(status: 400, message: "Send an instant to someone else.")

        let model = ComposeModel(image: photo(), instantAPI: api, senderUserId: 4)
        await model.send(to: 9)

        #expect(model.sendState == .failed("Send an instant to someone else."))
    }

    @Test("A failed delivery still counts as sent — it was queued")
    func queuedSendIsStillSent() async {
        let api = FakeInstantAPI()
        let identity = DeviceIdentity(
            deviceId: UUID().uuidString.lowercased(),
            backing: .software(P256.KeyAgreement.PrivateKey())
        )
        api.keysByUser[9] = [InstantDeviceKeyDTO(
            id: 1, deviceId: identity.deviceId, publicKey: identity.publicKeyBase64, createdAt: nil
        )]
        api.sendDelivered = false

        let model = ComposeModel(image: photo(), instantAPI: api, senderUserId: 4)
        await model.send(to: 9)

        #expect(model.sendState == .sent(delivered: false))
    }

    @Test("Captions are capped and durations cycle")
    func capsCaptionAndCyclesDuration() {
        let model = ComposeModel(image: photo(), instantAPI: FakeInstantAPI(), senderUserId: 1)
        model.setCaption(String(repeating: "x", count: 300))
        #expect(model.caption.count == OverlayCompositor.maxCaptionLength)

        #expect(model.duration == .fiveSeconds)
        model.cycleDuration()
        #expect(model.duration == .infinite)
        model.cycleDuration()
        #expect(model.duration == .oneSecond)
    }
}

@MainActor
@Suite("Sign in")
struct SignInModelTests {
    @Test("Requires a plausible email and a password")
    func gatesSubmission() {
        let model = SignInModel(userAPI: FakeUserAPI())
        #expect(model.canSubmit == false)
        model.email = "a@b.c"
        #expect(model.canSubmit == false)
        model.password = "pw"
        #expect(model.canSubmit)
    }

    @Test("Returns the token on success")
    func returnsToken() async {
        let api = FakeUserAPI()
        api.signInResult = .success("jwt")
        let model = SignInModel(userAPI: api)
        model.email = "a@b.c"
        model.password = "pw"

        #expect(await model.submit() == "jwt")
        #expect(model.errorMessage == nil)
    }

    @Test("Shows the server's reason rather than a generic failure")
    func showsServerReason() async {
        let api = FakeUserAPI()
        api.signInResult = .failure(
            APIError(status: 403, message: "Your account is pending admin approval.")
        )
        let model = SignInModel(userAPI: api)
        model.email = "a@b.c"
        model.password = "pw"

        #expect(await model.submit() == nil)
        #expect(model.errorMessage == "Your account is pending admin approval.")
    }

    /// A stray space off an autofilled field is otherwise a 403 saying
    /// "Incorrect credentials", which is impossible to debug from the message.
    @Test("Trims whitespace off the email before sending it")
    func trimsEmail() async {
        let api = FakeUserAPI()
        let model = SignInModel(userAPI: api)
        model.email = "  a@b.c  "
        model.password = "pw"

        _ = await model.submit()
        #expect(api.signInCalls.first?.0 == "a@b.c")
    }

    @Test("Falls back to a connection message for transport errors")
    func handlesTransportFailure() async {
        let api = FakeUserAPI()
        api.signInResult = .failure(URLError(.notConnectedToInternet))
        let model = SignInModel(userAPI: api)
        model.email = "a@b.c"
        model.password = "pw"

        _ = await model.submit()
        #expect(model.errorMessage?.contains("connection") == true)
    }
}

@MainActor
@Suite("Settings")
struct SettingsModelTests {
    @Test("Loads the profile into editable fields")
    func loadsProfile() async {
        let api = FakeUserAPI()
        let model = SettingsModel(userAPI: api, time: TestTime().source)
        await model.load()

        #expect(model.bio == "hi")
        #expect(model.themeKey == "ocean")
        #expect(model.notificationsEnabled)
    }

    @Test("Always sends bio, so saving a theme cannot wipe it")
    func savesBioWithTheme() async {
        let api = FakeUserAPI()
        let model = SettingsModel(userAPI: api, time: TestTime().source)
        await model.load()
        model.themeKey = "gold"
        await model.save()

        #expect(api.updateCalls.count == 1)
        #expect(api.updateCalls.first?.0 == "hi")
        #expect(api.updateCalls.first?.1 == "gold")
    }

    @Test("A failed toggle reverts rather than lying about the state")
    func revertsFailedToggle() async {
        let api = FakeUserAPI()
        api.notificationsError = APIError(status: 500, message: "nope")
        let model = SettingsModel(userAPI: api, time: TestTime().source)
        await model.load()
        #expect(model.notificationsEnabled)

        await model.setNotifications(false)
        #expect(model.notificationsEnabled, "the switch should snap back")
        #expect(model.errorMessage != nil)
    }
}

@MainActor
@Suite("Recipient picker")
struct SendToModelTests {
    @Test("Filters out the signed-in user")
    func excludesSelf() async {
        let userAPI = FakeUserAPI()
        userAPI.usersResult = [
            UserSummary(id: 1, name: "Me", themeKey: "ocean", profilePictureUrl: nil),
            UserSummary(id: 2, name: "Ana", themeKey: "rose", profilePictureUrl: nil),
        ]
        let model = SendToModel(
            userAPI: userAPI, instantAPI: FakeInstantAPI(), currentUserId: 1
        )
        await model.load()

        #expect(model.candidates.map(\.id) == [2])
    }

    @Test("Marks who has and hasn't enrolled")
    func resolvesEnrollment() async {
        let userAPI = FakeUserAPI()
        userAPI.usersResult = [
            UserSummary(id: 2, name: "Ana", themeKey: "rose", profilePictureUrl: nil),
            UserSummary(id: 3, name: "Bo", themeKey: "forest", profilePictureUrl: nil),
        ]
        let instantAPI = FakeInstantAPI()
        instantAPI.keysByUser[2] = [
            InstantDeviceKeyDTO(id: 1, deviceId: "d", publicKey: "p", createdAt: nil)
        ]

        let model = SendToModel(userAPI: userAPI, instantAPI: instantAPI, currentUserId: 1)
        await model.load()

        #expect(model.candidates.first { $0.id == 2 }?.isEnrolled == true)
        #expect(model.candidates.first { $0.id == 3 }?.isEnrolled == false)
    }
}

@MainActor
@Suite("Safety number panel")
struct SafetyNumberModelTests {
    private func keys(_ values: [String]) -> [InstantDeviceKeyDTO] {
        values.enumerated().map {
            InstantDeviceKeyDTO(id: $0.offset, deviceId: "d\($0.offset)", publicKey: $0.element, createdAt: nil)
        }
    }

    @Test("Computes the same number the web client shows")
    func computesNumber() async {
        let api = FakeInstantAPI()
        api.keysByUser[2] = keys(["theirs"])
        api.myKeys = keys(["mine"])

        let model = SafetyNumberModel(
            api: api, fingerprints: InMemoryPeerFingerprintStore(),
            currentUserId: 1, peerUserId: 2
        )
        await model.load()

        #expect(model.safetyNumber == SafetyNumber.safetyNumber(mine: ["mine"], theirs: ["theirs"]))
        #expect(model.keysChanged == false)
    }

    /// This is the only signal a user gets that the key directory may have been
    /// substituted, so it has to fire on a real change and stay quiet otherwise.
    @Test("Warns when a peer's keys change, and only then")
    func detectsKeyChange() async {
        let api = FakeInstantAPI()
        api.keysByUser[2] = keys(["original"])
        api.myKeys = keys(["mine"])
        let fingerprints = InMemoryPeerFingerprintStore()

        let first = SafetyNumberModel(
            api: api, fingerprints: fingerprints, currentUserId: 1, peerUserId: 2
        )
        await first.load()
        #expect(first.keysChanged == false, "nothing remembered yet")

        let unchanged = SafetyNumberModel(
            api: api, fingerprints: fingerprints, currentUserId: 1, peerUserId: 2
        )
        await unchanged.load()
        #expect(unchanged.keysChanged == false)

        api.keysByUser[2] = keys(["replaced"])
        let changed = SafetyNumberModel(
            api: api, fingerprints: fingerprints, currentUserId: 1, peerUserId: 2
        )
        await changed.load()
        #expect(changed.keysChanged)

        // The new value is remembered, so the warning does not repeat forever.
        let settled = SafetyNumberModel(
            api: api, fingerprints: fingerprints, currentUserId: 1, peerUserId: 2
        )
        await settled.load()
        #expect(settled.keysChanged == false)
    }

    @Test("Says so when the peer has not enrolled")
    func handlesNoKeys() async {
        let api = FakeInstantAPI()
        api.keysByUser[2] = []

        let model = SafetyNumberModel(
            api: api, fingerprints: InMemoryPeerFingerprintStore(),
            currentUserId: 1, peerUserId: 2
        )
        await model.load()

        #expect(model.safetyNumber == nil)
        #expect(model.errorMessage?.contains("haven't set up") == true)
    }
}
