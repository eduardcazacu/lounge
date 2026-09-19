import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Instant

/// Polls rather than yields: sealing runs on a detached task doing real image
/// and crypto work, which a handful of yields does not reliably outlast.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(10),
    _ condition: @MainActor () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition(), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
@Suite("Outbox", .serialized)
struct OutboxTests {
    private let ana = InstantRecipient(userId: 9, name: "Ana")
    private let bo = InstantRecipient(userId: 3, name: "Bo")

    private func draft(caption: String = "") -> InstantDraft {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        }
        return InstantDraft(
            image: image, filter: .none,
            captions: caption.isEmpty ? [] : [OverlayCompositor.Caption(text: caption)],
            duration: .fiveSeconds
        )
    }

    private func device() -> DeviceIdentity {
        DeviceIdentity(
            deviceId: UUID().uuidString.lowercased(),
            backing: .software(P256.KeyAgreement.PrivateKey())
        )
    }

    private func enroll(_ identities: [DeviceIdentity], as userId: Int, in api: FakeInstantAPI) {
        api.keysByUser[userId] = identities.enumerated().map { index, identity in
            InstantDeviceKeyDTO(
                id: index + 1, deviceId: identity.deviceId,
                publicKey: identity.publicKeyBase64, createdAt: nil
            )
        }
    }

    /// A sleep that never ends, so a confirmation can be looked at before it
    /// is taken down.
    private static let frozen = TimeSource(
        now: { Date() },
        sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
    )

    private final class SentLog {
        var recipients: [Int] = []
    }

    private func makeOutbox(
        api: FakeInstantAPI,
        store: PendingSendStoring = InMemoryPendingSendStore(),
        system: OutboxSystem = RecordingOutboxSystem(),
        time: TimeSource = OutboxTests.frozen,
        log: SentLog = SentLog()
    ) -> Outbox {
        Outbox(api: api, store: store, system: system, time: time) { recipientId in
            log.recipients.append(recipientId)
        }
    }

    private func sealedSend(for recipient: InstantRecipient, senderUserId: Int) throws -> PendingSend {
        let recipientDevice = device()
        let sealed = try InstantCrypto.seal(
            media: Data("photo".utf8),
            senderUserId: senderUserId,
            devices: [InstantCrypto.RecipientDeviceKey(
                id: 1, deviceId: recipientDevice.deviceId, publicKey: recipientDevice.publicKeyBase64
            )]
        )
        return PendingSend(
            id: UUID(), senderUserId: senderUserId, recipient: recipient,
            duration: .infinite, sealed: sealed
        )
    }

    // MARK: Sending

    @Test("Every one of the recipient's devices can open what was sent")
    func sealsForEveryDevice() async throws {
        let api = FakeInstantAPI()
        let devices = [device(), device(), device()]
        enroll(devices, as: 9, in: api)
        let outbox = makeOutbox(api: api)

        outbox.send(draft(caption: "hello"), to: [ana], from: 4)
        await waitUntil { outbox.items.first?.phase == .sent }

        let sent = try #require(api.sentPayloads.first)
        let header = try #require(api.sentHeaders.first)
        #expect(sent.1 == 9)
        #expect(Set(sent.3.map(\.deviceKeyId)) == [1, 2, 3])
        for (index, identity) in devices.enumerated() {
            let envelope = try #require(sent.3.first { $0.deviceKeyId == index + 1 })
            let opened = try InstantCrypto.open(
                ciphertext: sent.0,
                instant: InstantCrypto.OpenableInstant(
                    mediaIv: header.mediaIv, ephemeralPubKey: header.ephemeralPubKey,
                    senderId: 4,
                    envelopeWrappedKey: envelope.wrappedKey,
                    envelopeWrapIv: envelope.wrapIv
                ),
                device: identity
            )
            #expect(!opened.isEmpty)
        }
    }

    /// Several recipients is several instants. Each is sealed to one person's
    /// devices, so what one person can open, nobody else can — and each read
    /// destroys only that person's copy.
    @Test("A photo to several people is one instant each, openable only by its own recipient")
    func sealsSeparatelyForEachRecipient() async throws {
        let api = FakeInstantAPI()
        let anaDevice = device()
        let boDevice = device()
        enroll([anaDevice], as: 9, in: api)
        enroll([boDevice], as: 3, in: api)
        let log = SentLog()
        let outbox = makeOutbox(api: api, log: log)

        outbox.send(draft(), to: [ana, bo], from: 4)
        #expect(outbox.items.map(\.recipient) == [ana, bo])
        await waitUntil { outbox.items.allSatisfy { $0.phase == .sent } }

        #expect(Set(api.sentPayloads.map(\.1)) == [9, 3])
        #expect(Set(log.recipients) == [9, 3], "recency and streaks move for each of them")
        #expect(
            Set(api.sentHeaders.map(\.ephemeralPubKey)).count == 2,
            "a fresh ephemeral key, and so a fresh content key, per recipient"
        )

        func open(_ recipientId: Int, with identity: DeviceIdentity) throws -> Data {
            let index = try #require(api.sentPayloads.firstIndex { $0.1 == recipientId })
            let sent = api.sentPayloads[index]
            let header = api.sentHeaders[index]
            let envelope = try #require(sent.3.first)
            return try InstantCrypto.open(
                ciphertext: sent.0,
                instant: InstantCrypto.OpenableInstant(
                    mediaIv: header.mediaIv, ephemeralPubKey: header.ephemeralPubKey,
                    senderId: 4,
                    envelopeWrappedKey: envelope.wrappedKey,
                    envelopeWrapIv: envelope.wrapIv
                ),
                device: identity
            )
        }
        let toAna = try open(9, with: anaDevice)
        let toBo = try open(3, with: boDevice)
        #expect(toAna == toBo, "the same photo, encoded once")
        #expect(throws: (any Error).self) { try open(9, with: boDevice) }
    }

    /// Each send stands alone, so one person who cannot be reached does not
    /// hold back everybody else.
    @Test("One recipient failing leaves the others sent")
    func failsPerRecipient() async {
        let api = FakeInstantAPI()
        enroll([device()], as: 9, in: api)
        api.keysByUser[3] = []
        let log = SentLog()
        let outbox = makeOutbox(api: api, log: log)

        outbox.send(draft(), to: [ana, bo], from: 4)
        await waitUntil { !outbox.items.contains { $0.phase == .sending } }

        #expect(outbox.items.first { $0.recipient == ana }?.phase == .sent)
        #expect(outbox.items.first { $0.recipient == bo }?.phase == .failed("They haven't set up Instant yet."))
        #expect(log.recipients == [9])
    }

    @Test("Sending to nobody queues nothing")
    func ignoresEmptyRecipients() {
        let outbox = makeOutbox(api: FakeInstantAPI())
        outbox.send(draft(), to: [], from: 4)
        #expect(outbox.items.isEmpty)
    }

    /// The whole point: the compose screen closes on the tap, so the send has
    /// to be visibly under way before any of the work is done.
    @Test("A send is in flight the moment it is handed over, then confirmed")
    func reportsProgressThenConfirmation() async {
        let api = FakeInstantAPI()
        enroll([device()], as: 9, in: api)
        let log = SentLog()
        let outbox = makeOutbox(api: api, log: log)

        outbox.send(draft(), to: [ana], from: 4)
        #expect(outbox.items.map(\.phase) == [.sending])
        #expect(outbox.headline?.recipient == ana)

        await waitUntil { outbox.items.first?.phase == .sent }
        #expect(outbox.items.first?.phase == .sent)
        #expect(log.recipients == [9], "recency moves only once the server has it")
    }

    @Test("The confirmation goes away by itself")
    func confirmationClears() async {
        let api = FakeInstantAPI()
        enroll([device()], as: 9, in: api)
        let outbox = makeOutbox(api: api, time: TimeSource(now: { Date() }, sleep: { _ in }))

        outbox.send(draft(), to: [ana], from: 4)
        await waitUntil { api.sentPayloads.count == 1 && outbox.items.isEmpty }
        #expect(outbox.items.isEmpty)
    }

    @Test("Someone who hasn't enrolled is a failure, and nothing is kept")
    func refusesUnenrolledRecipient() async {
        let api = FakeInstantAPI()
        api.keysByUser[9] = []
        let store = InMemoryPendingSendStore()
        let log = SentLog()
        let outbox = makeOutbox(api: api, store: store, log: log)

        outbox.send(draft(), to: [ana], from: 4)
        await waitUntil { outbox.items.first?.phase != .sending }

        #expect(outbox.items.first?.phase == .failed("They haven't set up Instant yet."))
        #expect(api.sentPayloads.isEmpty)
        #expect(store.stored.isEmpty)
        #expect(log.recipients.isEmpty, "a send that failed must not answer a streak")
    }

    @Test("The server's message is what the failure says")
    func surfacesServerError() async {
        let api = FakeInstantAPI()
        enroll([device()], as: 9, in: api)
        api.sendError = APIError(status: 400, message: "Send an instant to someone else.")
        let outbox = makeOutbox(api: api)

        outbox.send(draft(), to: [ana], from: 4)
        await waitUntil { outbox.items.first?.phase != .sending }

        #expect(outbox.items.first?.phase == .failed("Send an instant to someone else."))
    }

    /// The recipient's devices may be what changed, so a retry looks them up
    /// again and seals afresh while the photo is still in memory.
    @Test("Retrying a failed send seals it again and sends it")
    func retrySealsAgain() async throws {
        let api = FakeInstantAPI()
        enroll([device()], as: 9, in: api)
        api.sendError = APIError(status: 503, message: "Busy")
        let outbox = makeOutbox(api: api)
        outbox.send(draft(), to: [ana], from: 4)
        await waitUntil { outbox.items.first?.phase != .sending }
        let id = try #require(outbox.items.first?.id)

        api.sendError = nil
        enroll([device(), device()], as: 9, in: api)
        outbox.retry(id)
        #expect(outbox.items.first?.phase == .sending)
        await waitUntil { outbox.items.first?.phase == .sent }

        #expect(api.sentPayloads.first?.3.count == 2, "sealed to the devices that exist now")
    }

    @Test("Dismissing a failure forgets it, including its sealed copy")
    func dismissForgets() async {
        let api = FakeInstantAPI()
        enroll([device()], as: 9, in: api)
        api.sendError = APIError(status: 503, message: "Busy")
        let store = InMemoryPendingSendStore()
        let outbox = makeOutbox(api: api, store: store)
        outbox.send(draft(), to: [ana], from: 4)
        await waitUntil { outbox.items.first?.phase != .sending }
        #expect(store.stored.count == 1, "kept for the next launch until dismissed")

        outbox.dismiss(outbox.items[0].id)

        #expect(outbox.items.isEmpty)
        #expect(store.stored.isEmpty)
    }

    /// A force quit runs no code, so the sealed copy has to be on disk before
    /// the upload starts, and gone the moment the server has it.
    @Test("The sealed copy is written before uploading and removed after")
    func persistsAroundTheUpload() async {
        let api = FakeInstantAPI()
        enroll([device()], as: 9, in: api)
        let (released, release) = AsyncStream<Void>.makeStream()
        api.sendGate = { for await _ in released { break } }
        let store = InMemoryPendingSendStore()
        let outbox = makeOutbox(api: api, store: store)

        outbox.send(draft(), to: [ana], from: 4)
        await waitUntil { store.stored.count == 1 }
        #expect(store.stored.first?.recipientId == 9)
        #expect(store.stored.first?.senderUserId == 4)
        #expect(outbox.items.first?.phase == .sending)

        release.yield()
        await waitUntil { outbox.items.first?.phase == .sent }
        #expect(store.stored.isEmpty)
    }

    // MARK: Launch

    @Test("A send left behind by a force quit goes on the next launch")
    func resumesAfterRelaunch() async throws {
        let pending = try sealedSend(for: ana, senderUserId: 4)
        let store = InMemoryPendingSendStore([pending])
        let api = FakeInstantAPI()
        let log = SentLog()
        let outbox = makeOutbox(api: api, store: store, log: log)

        outbox.restore(userId: 4)
        #expect(outbox.items.map(\.phase) == [.sending])
        #expect(api.sentPayloads.isEmpty, "nothing goes before there is a session")

        outbox.resume()
        await waitUntil { outbox.items.first?.phase == .sent }

        #expect(api.sentPayloads.first?.0 == pending.ciphertext, "the same sealed bytes")
        #expect(api.sentPayloads.first?.2 == .infinite)
        #expect(store.stored.isEmpty)
        #expect(log.recipients == [9])
    }

    @Test("Another account's unsent instant is dropped, never sent")
    func dropsAnotherAccountsSend() throws {
        let store = InMemoryPendingSendStore([try sealedSend(for: ana, senderUserId: 7)])
        let outbox = makeOutbox(api: FakeInstantAPI(), store: store)

        outbox.restore(userId: 4)

        #expect(outbox.items.isEmpty)
        #expect(store.stored.isEmpty)
    }

    @Test("Signing out forgets every send")
    func resetClears() async throws {
        let store = InMemoryPendingSendStore([try sealedSend(for: ana, senderUserId: 4)])
        let outbox = makeOutbox(api: FakeInstantAPI(), store: store)
        outbox.restore(userId: 4)

        outbox.reset()
        outbox.resume()

        #expect(outbox.items.isEmpty)
        #expect(store.stored.isEmpty)
    }

    @Test("Sealed sends survive on disk, ciphertext included")
    func diskRoundTrip() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("outbox-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PendingSendStore(directory: directory)
        let first = try sealedSend(for: ana, senderUserId: 4)
        let second = try sealedSend(for: InstantRecipient(userId: 3, name: "Bo"), senderUserId: 4)

        store.save(first)
        store.save(second)
        #expect(Set(store.load().map(\.id)) == [first.id, second.id])
        #expect(store.load().first { $0.id == first.id } == first)

        store.remove(id: first.id)
        #expect(store.load().map(\.id) == [second.id])

        store.clear()
        #expect(store.load().isEmpty)
    }

    // MARK: Leaving the app

    @Test("Leaving mid-send asks for time and schedules a reminder, withdrawn once it goes")
    func remindsOnlyIfUnsent() async {
        let api = FakeInstantAPI()
        enroll([device()], as: 9, in: api)
        let (released, release) = AsyncStream<Void>.makeStream()
        api.sendGate = { for await _ in released { break } }
        let system = RecordingOutboxSystem()
        let outbox = makeOutbox(api: api, system: system)
        outbox.send(draft(), to: [ana], from: 4)

        outbox.didEnterBackground()
        #expect(system.backgroundTimeActive)
        #expect(system.reminderNames == ["Ana"])

        release.yield()
        await waitUntil { outbox.items.first?.phase == .sent }
        #expect(system.reminderNames == nil, "it went, so there is nothing to remind about")
        #expect(!system.backgroundTimeActive)
    }

    @Test("A send that fails in the background leaves the reminder to fire")
    func failureKeepsReminder() async {
        let api = FakeInstantAPI()
        enroll([device()], as: 9, in: api)
        api.sendError = APIError(status: 503, message: "Busy")
        let (released, release) = AsyncStream<Void>.makeStream()
        api.sendGate = { for await _ in released { break } }
        let system = RecordingOutboxSystem()
        let outbox = makeOutbox(api: api, system: system)
        outbox.send(draft(), to: [ana], from: 4)

        outbox.didEnterBackground()
        release.yield()
        await waitUntil { outbox.items.first?.phase != .sending }

        #expect(system.reminderNames == ["Ana"])
        #expect(!system.backgroundTimeActive)
    }

    @Test("Nothing in flight, nothing scheduled; coming back withdraws it")
    func quietWhenIdle() {
        let system = RecordingOutboxSystem()
        let outbox = makeOutbox(api: FakeInstantAPI(), system: system)

        outbox.didEnterBackground()
        #expect(system.reminderNames == nil)
        #expect(!system.backgroundTimeActive)

        system.scheduleUnsentReminder(recipientNames: ["Ana"], after: 30)
        outbox.didBecomeActive()
        #expect(system.reminderNames == nil)
    }

    @Test("The reminder is told apart from an instant push")
    func recognisesReminder() {
        #expect(OutboxReminder.isReminder(["kind": "unsent-instant"]))
        #expect(!OutboxReminder.isReminder(["data": ["instantId": "x"]]))
    }

    // MARK: The environment

    /// Sending spends the aim at once, whichever way the send then goes.
    @Test("Handing a draft over spends the aim and queues the send")
    func environmentSendSpendsAim() async {
        let session = SessionStore(keychain: InMemoryKeychain())
        session.setToken(StubBackend.token)
        await waitUntil { session.currentUserId != nil }
        let environment = makeTestEnvironment(session: session)
        environment.aim(at: ana)

        environment.send(draft(), to: [ana])

        #expect(environment.aimedAt == nil)
        #expect(environment.outbox.items.map(\.recipient) == [ana])
    }
}
