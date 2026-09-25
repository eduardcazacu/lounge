#if canImport(UIKit)
import Foundation
import Observation
import UIKit
import UserNotifications

/// Everything the compose screen decided, before any of it is applied.
///
/// Handed over whole so the compose screen can close the moment Send is
/// tapped: the filter, the drawing, the captions and the encryption all happen
/// afterwards, off the main actor.
public struct InstantDraft: Sendable {
    public enum Media: Sendable {
        case photo(UIImage)
        /// Owned by the outbox from the moment the draft is handed over: the
        /// file is deleted once it has been encoded, or when the send is
        /// abandoned before it was.
        case video(RecordedClip)
    }

    public let media: Media
    public let filter: PhotoFilter
    public let strokes: [OverlayCompositor.Stroke]
    public let captions: [OverlayCompositor.Caption]
    public let duration: InstantDurationMode
    /// A clip's sound. Ignored for a photo.
    public let includesSound: Bool
    /// Where the film grain comes from, which is not the same for a
    /// recording as for a wiggle. See `VideoPipeline.GrainSeeding`.
    public let grain: VideoPipeline.GrainSeeding

    public init(
        media: Media,
        filter: PhotoFilter,
        strokes: [OverlayCompositor.Stroke] = [],
        captions: [OverlayCompositor.Caption],
        duration: InstantDurationMode,
        includesSound: Bool = true,
        grain: VideoPipeline.GrainSeeding = .perFrame
    ) {
        self.media = media
        self.filter = filter
        self.strokes = strokes
        self.captions = captions
        self.duration = duration
        self.includesSound = includesSound
        self.grain = grain
    }

    public init(
        image: UIImage,
        filter: PhotoFilter,
        strokes: [OverlayCompositor.Stroke] = [],
        captions: [OverlayCompositor.Caption],
        duration: InstantDurationMode
    ) {
        self.init(media: .photo(image), filter: filter, strokes: strokes, captions: captions, duration: duration)
    }

    var clip: RecordedClip? {
        if case .video(let clip) = media { clip } else { nil }
    }

    /// The photo with every choice made about it already in its pixels: the
    /// look, then the drawing, then the captions. What the recipient sees,
    /// and — saved to the library — what the sender keeps.
    var composedPhoto: UIImage? {
        guard case .photo(let image) = media else { return nil }
        return OverlayCompositor.composite(
            image: filter.apply(to: image),
            strokes: strokes,
            captions: captions
        )
    }

    /// The clip, encoded with the same three applied per frame. It leaves the
    /// recording where it is: the outbox owns that file and deletes it when
    /// the send is done with it, and a save must not take it out from under
    /// a send that has not happened yet.
    func composedVideo() async throws -> Data {
        guard let clip else { throw ImagePipeline.PipelineError.noDimensions }
        return try await VideoPipeline.encode(
            clip,
            filter: filter,
            strokes: strokes,
            captions: captions,
            includesSound: includesSound,
            grain: grain
        )
    }
}

/// A draft once it is pixels: the encoded bytes and what they are.
public struct RenderedMedia: Sendable {
    public let data: Data
    public let mediaType: String
}

/// An instant that has been sealed and not yet accepted by the server — the
/// only form in which a send is ever written to disk.
///
/// Sealed rather than the photo itself: the app never keeps a photo, and a
/// sealed one can only be opened by the recipient's devices. The cost is that a
/// send killed before sealing finishes is not recoverable — the WebP encode,
/// about 0.2 s in an optimized build and several seconds in a Debug one.
public struct PendingSend: Codable, Equatable, Sendable {
    public struct Envelope: Codable, Equatable, Sendable {
        public let deviceKeyId: Int
        public let wrappedKey: String
        public let wrapIv: String
    }

    public let id: UUID
    public let senderUserId: Int
    public let recipientId: Int
    public let recipientName: String
    public let duration: InstantDurationMode
    /// What the sealed bytes are. Optional on disk: a send sealed by a build
    /// from before video carries no such key, and it was a photo.
    public let mediaType: String
    public let mediaIv: String
    public let ephemeralPubKey: String
    public let envelopes: [Envelope]
    /// Not encoded with the rest; the store keeps it in a file of its own.
    public var ciphertext: Data

    public static let photoMediaType = "image/webp"

    enum CodingKeys: String, CodingKey {
        case id, senderUserId, recipientId, recipientName, duration, mediaType
        case mediaIv, ephemeralPubKey, envelopes
    }

    public init(
        id: UUID,
        senderUserId: Int,
        recipient: InstantRecipient,
        duration: InstantDurationMode,
        mediaType: String = PendingSend.photoMediaType,
        sealed: InstantCrypto.SealedInstant
    ) {
        self.id = id
        self.senderUserId = senderUserId
        recipientId = recipient.userId
        recipientName = recipient.name
        self.duration = duration
        self.mediaType = mediaType
        mediaIv = sealed.mediaIv
        ephemeralPubKey = sealed.ephemeralPubKey
        envelopes = sealed.envelopes.map {
            Envelope(deviceKeyId: $0.deviceKeyId, wrappedKey: $0.wrappedKey, wrapIv: $0.wrapIv)
        }
        ciphertext = sealed.ciphertext
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        senderUserId = try container.decode(Int.self, forKey: .senderUserId)
        recipientId = try container.decode(Int.self, forKey: .recipientId)
        recipientName = try container.decode(String.self, forKey: .recipientName)
        duration = try container.decode(InstantDurationMode.self, forKey: .duration)
        mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType) ?? Self.photoMediaType
        mediaIv = try container.decode(String.self, forKey: .mediaIv)
        ephemeralPubKey = try container.decode(String.self, forKey: .ephemeralPubKey)
        envelopes = try container.decode([Envelope].self, forKey: .envelopes)
        ciphertext = Data()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(senderUserId, forKey: .senderUserId)
        try container.encode(recipientId, forKey: .recipientId)
        try container.encode(recipientName, forKey: .recipientName)
        try container.encode(duration, forKey: .duration)
        try container.encode(mediaType, forKey: .mediaType)
        try container.encode(mediaIv, forKey: .mediaIv)
        try container.encode(ephemeralPubKey, forKey: .ephemeralPubKey)
        try container.encode(envelopes, forKey: .envelopes)
    }

    var sealedEnvelopes: [InstantCrypto.SealedEnvelope] {
        envelopes.map {
            InstantCrypto.SealedEnvelope(deviceKeyId: $0.deviceKeyId, wrappedKey: $0.wrappedKey, wrapIv: $0.wrapIv)
        }
    }
}

// MARK: - Persistence

public protocol PendingSendStoring: Sendable {
    func save(_ send: PendingSend)
    func remove(id: UUID)
    func load() -> [PendingSend]
    func clear()
}

/// One JSON file and one ciphertext file per send, in Application Support.
///
/// Writes are synchronous: a send is only safe from a force quit once its file
/// is on disk, so the upload does not start until the write has returned.
/// Readable after first unlock, because a send finishing in the background may
/// be running on a locked phone.
public struct PendingSendStore: PendingSendStoring {
    private let directory: URL?

    public init(fileManager: FileManager = .default) {
        directory = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("outbox", isDirectory: true)
    }

    public init(directory: URL) {
        self.directory = directory
    }

    private func files(for id: UUID) -> (meta: URL, body: URL)? {
        guard let directory else { return nil }
        return (
            directory.appendingPathComponent("\(id.uuidString).json"),
            directory.appendingPathComponent("\(id.uuidString).bin")
        )
    }

    public func save(_ send: PendingSend) {
        guard let directory, let files = files(for: send.id),
              let meta = try? JSONEncoder().encode(send)
        else { return }
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The body first: metadata with no body is a send that can never load,
        // and a body with no metadata is only an orphan the next clear removes.
        guard (try? send.ciphertext.write(to: files.body, options: options)) != nil else { return }
        try? meta.write(to: files.meta, options: options)
    }

    public func remove(id: UUID) {
        guard let files = files(for: id) else { return }
        try? FileManager.default.removeItem(at: files.meta)
        try? FileManager.default.removeItem(at: files.body)
    }

    public func load() -> [PendingSend] {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            let meta = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: meta),
                  var send = try? JSONDecoder().decode(PendingSend.self, from: data),
                  let body = files(for: send.id)?.body,
                  let ciphertext = try? Data(contentsOf: body)
            else { return nil }
            send.ciphertext = ciphertext
            return send
        }
    }

    public func clear() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

public final class InMemoryPendingSendStore: PendingSendStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var sends: [UUID: PendingSend] = [:]

    public init(_ sends: [PendingSend] = []) {
        for send in sends { self.sends[send.id] = send }
    }

    public var stored: [PendingSend] { lock.withLock { Array(sends.values) } }

    public func save(_ send: PendingSend) { lock.withLock { sends[send.id] = send } }
    public func remove(id: UUID) { _ = lock.withLock { sends.removeValue(forKey: id) } }
    public func load() -> [PendingSend] { lock.withLock { Array(sends.values) } }
    public func clear() { lock.withLock { sends = [:] } }
}

// MARK: - Leaving the app

/// What the outbox needs from the system when the app goes to the background
/// with a send still in flight.
@MainActor
public protocol OutboxSystem: AnyObject {
    /// Asks for time to finish. The handler runs if that time runs out.
    func beginBackgroundTime(expiration: @escaping @MainActor () -> Void)
    func endBackgroundTime()
    /// A notification for later, saying these sends did not go. Scheduled on the
    /// way out and cancelled if they finish, because a force quit runs no code
    /// at all: the only way to say anything afterwards is to have said it
    /// already.
    func scheduleUnsentReminder(recipientNames: [String], after delay: TimeInterval)
    func cancelUnsentReminder()
}

@MainActor
public final class SystemOutboxSystem: OutboxSystem {
    static let reminderId = "instant.unsent"
    private var task: UIBackgroundTaskIdentifier = .invalid

    public init() {}

    public func beginBackgroundTime(expiration: @escaping @MainActor () -> Void) {
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "Sending an instant") {
            MainActor.assumeIsolated { expiration() }
        }
    }

    public func endBackgroundTime() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }

    public func scheduleUnsentReminder(recipientNames: [String], after delay: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = recipientNames.count == 1
            ? "Your instant to \(recipientNames[0]) wasn't sent"
            : "\(recipientNames.count) instants weren't sent"
        content.body = "Open Instant to send it."
        content.sound = .default
        content.userInfo = [OutboxReminder.kindKey: OutboxReminder.kind]
        let request = UNNotificationRequest(
            identifier: Self.reminderId,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    public func cancelUnsentReminder() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.reminderId])
        center.removeDeliveredNotifications(withIdentifiers: [Self.reminderId])
    }
}

/// Lets the notification delegate tell the reminder apart from a push.
public enum OutboxReminder {
    static let kindKey = "kind"
    static let kind = "unsent-instant"

    public static func isReminder(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo[kindKey] as? String == kind
    }
}

/// Touches nothing in the system, and remembers what was asked; for tests and
/// the UI-test stubs.
@MainActor
public final class RecordingOutboxSystem: OutboxSystem {
    public private(set) var backgroundTimeActive = false
    public private(set) var reminderNames: [String]?
    public private(set) var expiration: (@MainActor () -> Void)?

    public init() {}

    public func beginBackgroundTime(expiration: @escaping @MainActor () -> Void) {
        backgroundTimeActive = true
        self.expiration = expiration
    }

    public func endBackgroundTime() { backgroundTimeActive = false }

    public func scheduleUnsentReminder(recipientNames: [String], after delay: TimeInterval) {
        reminderNames = recipientNames
    }

    public func cancelUnsentReminder() { reminderNames = nil }
}

// MARK: - The outbox

/// Sends instants after the compose screen has already closed.
///
/// Sending used to hold the compose screen for as long as the key lookup, the
/// filter, the encode, the seal and the upload took — seconds, on a 3 MiB
/// photo. Now the screen closes on the tap, and this reports progress in a
/// small status pill instead.
@MainActor
@Observable
public final class Outbox {
    public enum Phase: Equatable, Sendable {
        case sending
        case sent
        case failed(String)
    }

    public struct Item: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let recipient: InstantRecipient
        public var phase: Phase
        /// Sealed and on disk, so a force quit no longer loses it.
        public var isSaved = false
    }

    /// Oldest first. A sent item stays for a moment as the confirmation, then
    /// goes; a failed one stays until it is retried or dismissed.
    public private(set) var items: [Item] = []

    public var inFlight: [Item] { items.filter { $0.phase == .sending } }

    /// What the status pill shows: a failure outranks progress, which outranks
    /// a confirmation.
    public var headline: Item? {
        items.first { if case .failed = $0.phase { true } else { false } }
            ?? items.last { $0.phase == .sending }
            ?? items.last { $0.phase == .sent }
    }

    private let api: InstantAPIProtocol
    private let store: PendingSendStoring
    private let system: OutboxSystem
    private let time: TimeSource
    /// Run once the server has accepted a send, so recency and streaks move.
    private let onSent: @MainActor (Int) async -> Void

    private var drafts: [UUID: InstantDraft] = [:]
    /// The encoded photo, shared by every send made from the same draft.
    private var renders: [UUID: Task<RenderedMedia, Error>] = [:]
    private var sealed: [UUID: PendingSend] = [:]
    private var userId: Int?
    private var isInBackground = false
    /// Restored from disk and not yet handed to `run`.
    private var awaitingResume: [UUID] = []

    /// How long "Sent" stays up.
    static let confirmationDuration: Duration = .seconds(2)
    /// Long enough for the background time iOS grants to run out first, so the
    /// reminder only fires when the send really did not finish.
    static let reminderDelay: TimeInterval = 30

    public init(
        api: InstantAPIProtocol,
        store: PendingSendStoring = InMemoryPendingSendStore(),
        system: OutboxSystem = RecordingOutboxSystem(),
        time: TimeSource = .live,
        onSent: @escaping @MainActor (Int) async -> Void
    ) {
        self.api = api
        self.store = store
        self.system = system
        self.time = time
        self.onSent = onSent
    }

    // MARK: Sending

    /// One instant per recipient, each sealed to that person's devices alone.
    ///
    /// The photo is rendered and encoded once for all of them: the pixels are
    /// the same for everybody, and the encode is the slow part of a send. Only
    /// the seal and the upload are per person, so each one fails, retries and
    /// is read once on its own.
    public func send(_ draft: InstantDraft, to recipients: [InstantRecipient], from senderUserId: Int) {
        guard !recipients.isEmpty else { return }
        userId = senderUserId
        let render = Task.detached(priority: .userInitiated) {
            try await Self.render(draft)
        }
        // How the photo was taken and how long it sat on the compose screen,
        // so a send can be read end to end, shutter to server.
        var attributes = JourneyLog.shared.takeLink(to: .capture)
        attributes["media"] = draft.clip == nil ? "photo" : "video"
        attributes["recipients"] = String(recipients.count)
        for recipient in recipients {
            let id = UUID()
            JourneyLog.shared.begin(.send, key: id.uuidString, attributes: attributes)
            drafts[id] = draft
            renders[id] = render
            items.append(Item(id: id, recipient: recipient, phase: .sending))
            Task { await run(id) }
        }
    }

    public func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              case .failed = items[index].phase
        else { return }
        items[index].phase = .sending
        Task { await run(id) }
    }

    /// Gives up on a failed send. Its sealed copy goes too.
    public func dismiss(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.phase != .sending else { return }
        forget(id)
    }

    private func forget(_ id: UUID) {
        items.removeAll { $0.id == id }
        drafts[id] = nil
        renders[id] = nil
        sealed[id] = nil
        store.remove(id: id)
        settleBackground()
    }

    private func run(_ id: UUID) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        do {
            let pending = try await prepared(id, recipient: item.recipient)
            // Whether it reached a live socket does not matter here: a push
            // fallback is still a send.
            _ = try await api.send(
                ciphertext: pending.ciphertext,
                recipientId: pending.recipientId,
                durationMode: pending.duration,
                mediaType: pending.mediaType,
                mediaIv: pending.mediaIv,
                ephemeralPubKey: pending.ephemeralPubKey,
                envelopes: pending.sealedEnvelopes
            )
            JourneyLog.shared.end(.send, key: id.uuidString, outcome: "accepted")
            succeeded(id, recipientId: pending.recipientId)
            await onSent(pending.recipientId)
        } catch {
            // A retry is not timed: it starts from a tap on the pill, not from Send.
            JourneyLog.shared.end(.send, key: id.uuidString, outcome: "failed")
            failed(id, message: Self.message(for: error))
        }
    }

    /// The sealed send, from memory, or built from the draft and written to
    /// disk before anything is uploaded.
    ///
    /// A retry of a send whose draft is still here seals it again rather than
    /// reusing the old ciphertext: the failure may have been the recipient's
    /// device list changing, and a fresh lookup is the only fix for that. The
    /// encoded photo is reused, since nothing about it can have changed. A send
    /// restored after a relaunch has no draft, only its sealed copy.
    private func prepared(_ id: UUID, recipient: InstantRecipient) async throws -> PendingSend {
        guard let draft = drafts[id], let render = renders[id] else {
            guard let pending = sealed[id] else { throw OutboxError.lost }
            return pending
        }
        guard let senderUserId = userId else { throw OutboxError.lost }

        // The lookup runs while the photo is rendered, not before it: until the
        // sealed copy is on disk a force quit loses the send, so every
        // millisecond before that point counts twice.
        async let lookup = api.keys(forUserId: recipient.userId)
        let encoded = try await render.value
        JourneyLog.shared.mark(.send, key: id.uuidString, "encoded")
        JourneyLog.shared.annotate(.send, key: id.uuidString, ["kb": String(encoded.data.count / 1024)])
        let devices = try await lookup.theirs
        JourneyLog.shared.mark(.send, key: id.uuidString, "keysFetched")
        guard !devices.isEmpty else { throw InstantCrypto.CryptoError.noRecipientDevices }
        let sealedInstant = try InstantCrypto.seal(
            media: encoded.data,
            senderUserId: senderUserId,
            devices: devices.map {
                InstantCrypto.RecipientDeviceKey(id: $0.id, deviceId: $0.deviceId, publicKey: $0.publicKey)
            }
        )

        let pending = PendingSend(
            id: id,
            senderUserId: senderUserId,
            recipient: recipient,
            duration: draft.duration,
            mediaType: encoded.mediaType,
            sealed: sealedInstant
        )
        // Still wanted? A sign-out while sealing must not leave it on disk.
        guard items.contains(where: { $0.id == id }), userId == senderUserId else {
            throw OutboxError.lost
        }
        JourneyLog.shared.mark(.send, key: id.uuidString, "sealed")
        store.save(pending)
        JourneyLog.shared.mark(.send, key: id.uuidString, "saved")
        sealed[id] = pending
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].isSaved = true
        }
        return pending
    }

    /// Filters, composites and compresses. Sealing is left to the caller,
    /// because it needs the key lookup this runs alongside, and takes a
    /// millisecond or two.
    ///
    /// The look goes on before the drawing and the captions, so the ink and
    /// the captions' backing keep their own colour instead of being tinted
    /// along with the photo — and all of it is burned into the pixels here
    /// rather than sent as fields. The server only ever holds ciphertext, so it
    /// could not read a caption, or apply the filter, even if the design wanted
    /// it to.
    ///
    /// A clip gets the same three, per frame, and its file is deleted as soon
    /// as it has been read — succeed or fail. Every send made from the draft
    /// shares this one render, so nothing needs the clip afterwards, and a
    /// retry reuses the encoded bytes.
    nonisolated static func render(_ draft: InstantDraft) async throws -> RenderedMedia {
        switch draft.media {
        case .photo:
            guard let flattened = draft.composedPhoto else {
                throw ImagePipeline.PipelineError.noDimensions
            }
            return RenderedMedia(data: try ImagePipeline.encode(flattened), mediaType: PendingSend.photoMediaType)
        case .video(let clip):
            defer { CaptureScratch.remove(clip.url) }
            return RenderedMedia(data: try await draft.composedVideo(), mediaType: VideoPipeline.mediaType)
        }
    }

    private func succeeded(_ id: UUID, recipientId: Int) {
        store.remove(id: id)
        drafts[id] = nil
        renders[id] = nil
        sealed[id] = nil
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].phase = .sent
        }
        settleBackground()
        Task { [time] in
            try? await time.sleep(Self.confirmationDuration)
            self.items.removeAll { $0.id == id && $0.phase == .sent }
        }
    }

    private func failed(_ id: UUID, message: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].phase = .failed(message)
        settleBackground()
    }

    enum OutboxError: Error { case lost }

    static func message(for error: Error) -> String {
        switch error {
        case let error as APIError:
            error.message
        case InstantCrypto.CryptoError.noRecipientDevices:
            "They haven't set up Instant yet."
        case VideoPipeline.PipelineError.tooLarge:
            "That video is too big to send."
        default:
            "That instant could not be sent."
        }
    }

    // MARK: Launch and sign-out

    /// Picks up sends that were sealed but never accepted — the app was force
    /// quit, or iOS ended it in the background. Called before the first frame;
    /// nothing is uploaded until `resume`.
    public func restore(userId: Int) {
        self.userId = userId
        let known = Set(items.map(\.id))
        for pending in store.load() where !known.contains(pending.id) {
            // Another account's send is never made on this one's behalf.
            guard pending.senderUserId == userId else {
                store.remove(id: pending.id)
                continue
            }
            sealed[pending.id] = pending
            awaitingResume.append(pending.id)
            items.append(Item(
                id: pending.id,
                recipient: InstantRecipient(userId: pending.recipientId, name: pending.recipientName),
                phase: .sending,
                isSaved: true
            ))
        }
    }

    /// Sends whatever `restore` found. Separate, because the upload needs a
    /// session and `restore` runs before there is one.
    public func resume() {
        let ids = awaitingResume
        awaitingResume = []
        for id in ids {
            Task { await run(id) }
        }
    }

    public func reset() {
        items = []
        drafts = [:]
        renders = [:]
        sealed = [:]
        awaitingResume = []
        userId = nil
        store.clear()
        system.cancelUnsentReminder()
        system.endBackgroundTime()
    }

    // MARK: Background

    public func didEnterBackground() {
        isInBackground = true
        let waiting = inFlight
        guard !waiting.isEmpty else { return }
        system.beginBackgroundTime { [weak self] in
            // Out of time with the upload unfinished. The reminder is already
            // scheduled and will say so.
            self?.system.endBackgroundTime()
        }
        system.scheduleUnsentReminder(
            recipientNames: waiting.map(\.recipient.name),
            after: Self.reminderDelay
        )
    }

    public func didBecomeActive() {
        isInBackground = false
        system.cancelUnsentReminder()
        system.endBackgroundTime()
    }

    /// Once nothing is in flight, the background time is handed back — and the
    /// reminder is withdrawn only if everything actually went. A failure in the
    /// background leaves it to fire, because that instant was not sent.
    private func settleBackground() {
        guard isInBackground, inFlight.isEmpty else { return }
        let anyFailed = items.contains { if case .failed = $0.phase { true } else { false } }
        if !anyFailed { system.cancelUnsentReminder() }
        system.endBackgroundTime()
    }
}
#endif
