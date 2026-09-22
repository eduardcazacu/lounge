import Foundation
import Synchronization
import Testing
import UIKit
@testable import Instant

/// Waits for a condition that a fire-and-forget `Task` will satisfy.
///
/// A single `Task.yield()` is not enough: the work is scheduled, not run
/// inline, and on a loaded machine it can take several hops.
func eventually(
    timeout: Duration = .seconds(3),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await MainActor.run(body: condition) { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await MainActor.run(body: condition)
}

/// Anchors `Bundle(for:)` on the test bundle so the interop fixtures can be found.
final class FixtureLocator {}

enum Fixtures {
    static let bundle = Bundle(for: FixtureLocator.self)

    static func json(_ name: String) throws -> [String: Any] {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw FixtureError.missing(name)
        }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError.malformed(name)
        }
        return object
    }

    enum FixtureError: Error { case missing(String), malformed(String) }

    static func b64(_ value: String) throws -> Data {
        guard let data = Base64URL.decode(value) else { throw FixtureError.malformed(value) }
        return data
    }

    static func device(_ raw: [String: Any]) throws -> DeviceIdentity {
        try DeviceIdentity(
            deviceId: raw["deviceId"] as! String,
            privateKeyRaw: try b64(raw["privateKeyRaw"] as! String)
        )
    }

    static func openable(
        _ fixture: [String: Any],
        envelope: [String: Any]
    ) -> InstantCrypto.OpenableInstant {
        InstantCrypto.OpenableInstant(
            mediaIv: fixture["mediaIv"] as! String,
            ephemeralPubKey: fixture["ephemeralPubKey"] as! String,
            senderId: fixture["senderUserId"] as! Int,
            envelopeWrappedKey: envelope["wrappedKey"] as! String,
            envelopeWrapIv: envelope["wrapIv"] as! String
        )
    }
}

// MARK: - HTTP stubbing

/// Captures outbound requests and replays canned responses, so endpoint shape
/// can be asserted without a network.
///
/// Each `Stub` owns its own id, injected as a header on the session it vends, so
/// suites running in parallel cannot see or overwrite each other's traffic —
/// `URLProtocol` subclasses are registered process-wide, which makes a single
/// shared handler a race between suites rather than a convenience.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Exchange: @unchecked Sendable {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
    }

    static let idHeader = "X-Instant-Stub-Id"

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var handlers: [String: @Sendable (URLRequest) -> Exchange] = [:]
        private var recorded: [String: [URLRequest]] = [:]

        func register(_ id: String, handler: @escaping @Sendable (URLRequest) -> Exchange) {
            lock.lock(); defer { lock.unlock() }
            handlers[id] = handler
            recorded[id] = []
        }

        func unregister(_ id: String) {
            lock.lock(); defer { lock.unlock() }
            handlers[id] = nil
            recorded[id] = nil
        }

        func handle(_ request: URLRequest, id: String?) -> Exchange {
            lock.lock()
            let handler = id.flatMap { handlers[$0] }
            if let id { recorded[id, default: []].append(request) }
            lock.unlock()
            return handler?(request) ?? Exchange(status: 200, body: Data("{}".utf8))
        }

        func requests(_ id: String) -> [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return recorded[id] ?? []
        }
    }

    private static let registry = Registry()

    static func register(id: String, handler: @escaping @Sendable (URLRequest) -> Exchange) {
        registry.register(id, handler: handler)
    }

    static func unregister(id: String) { registry.unregister(id) }
    static func requests(id: String) -> [URLRequest] { registry.requests(id) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol moves httpBody into a stream; re-attach it so tests can
        // read what was actually sent.
        var recordable = request
        if recordable.httpBody == nil, let stream = request.httpBodyStream {
            recordable.httpBody = Self.drain(stream)
        }

        let exchange = Self.registry.handle(
            recordable,
            id: request.value(forHTTPHeaderField: Self.idHeader)
        )
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: exchange.status,
            httpVersion: "HTTP/1.1",
            headerFields: exchange.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: exchange.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// One isolated stubbed backend. Create one per test.
final class Stub: @unchecked Sendable {
    let id = UUID().uuidString

    init(handler: @escaping @Sendable (URLRequest) -> StubURLProtocol.Exchange = { _ in
        StubURLProtocol.Exchange(status: 200, body: Data("{}".utf8))
    }) {
        StubURLProtocol.register(id: id, handler: handler)
    }

    deinit { StubURLProtocol.unregister(id: id) }

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [StubURLProtocol.idHeader: id]
        return URLSession(configuration: configuration)
    }

    var requests: [URLRequest] { StubURLProtocol.requests(id: id) }

    static func json(_ text: String, status: Int = 200) -> @Sendable (URLRequest) -> StubURLProtocol.Exchange {
        { _ in StubURLProtocol.Exchange(status: status, body: Data(text.utf8)) }
    }
}

extension URLRequest {
    var path: String { url?.path ?? "" }
    var queryItems: [String: String] {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
    }
    var bodyText: String { String(data: httpBody ?? Data(), encoding: .utf8) ?? "" }
    var bodyJSON: [String: Any] {
        guard let httpBody,
              let object = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any]
        else { return [:] }
        return object
    }
}

// MARK: - Doubles

/// Records calls and replays scripted results.
///
/// State lives behind one lock because `SendToModel` resolves enrollment with a
/// task group, so `keys(forUserId:)` genuinely runs concurrently.
final class FakeInstantAPI: InstantAPIProtocol, @unchecked Sendable {
    struct Storage {
        var registeredDevices: [(String, String)] = []
        var keysByUser: [Int: [InstantDeviceKeyDTO]] = [:]
        var myKeys: [InstantDeviceKeyDTO] = []
        var inboxPages: [[InstantDelivery]] = []
        var streaksResult: [InstantStreakSummary] = []
        var conversationsResult: [InstantConversationSummary] = []
        var conversationsCallCount = 0
        /// Awaited before `conversations()` answers, so a test can hold a fetch
        /// open while something else happens.
        var conversationsGate: (@Sendable () async -> Void)?
        var ticket = "ticket"
        var mediaResult: Result<Data, Error> = .success(Data())
        var mediaFetchCount = 0
        var viewedIds: [String] = []
        var undecryptableIds: [String] = []
        var sentPayloads: [(Data, Int, InstantDurationMode, [InstantCrypto.SealedEnvelope])] = []
        /// The two fields `sentPayloads` leaves out, which opening one needs.
        var sentHeaders: [(mediaIv: String, ephemeralPubKey: String)] = []
        var sentMediaTypes: [String] = []
        /// Awaited before `send` answers, so a test can hold an upload open.
        var sendGate: (@Sendable () async -> Void)?
        var sendDelivered = true
        var sendError: Error?
        var inboxError: Error?
        var inboxCallCount = 0
        var streaksCallCount = 0
    }

    let storage = Mutex(Storage())

    var registeredDevices: [(String, String)] { get { storage.withLock { $0.registeredDevices } } set { storage.withLock { $0.registeredDevices = newValue } } }
    var keysByUser: [Int: [InstantDeviceKeyDTO]] { get { storage.withLock { $0.keysByUser } } set { storage.withLock { $0.keysByUser = newValue } } }
    var myKeys: [InstantDeviceKeyDTO] { get { storage.withLock { $0.myKeys } } set { storage.withLock { $0.myKeys = newValue } } }
    var inboxPages: [[InstantDelivery]] { get { storage.withLock { $0.inboxPages } } set { storage.withLock { $0.inboxPages = newValue } } }
    var streaksResult: [InstantStreakSummary] { get { storage.withLock { $0.streaksResult } } set { storage.withLock { $0.streaksResult = newValue } } }
    var ticket: String { get { storage.withLock { $0.ticket } } set { storage.withLock { $0.ticket = newValue } } }
    var mediaResult: Result<Data, Error> { get { storage.withLock { $0.mediaResult } } set { storage.withLock { $0.mediaResult = newValue } } }
    var mediaFetchCount: Int { storage.withLock { $0.mediaFetchCount } }
    var viewedIds: [String] { storage.withLock { $0.viewedIds } }
    var undecryptableIds: [String] { storage.withLock { $0.undecryptableIds } }
    var sentPayloads: [(Data, Int, InstantDurationMode, [InstantCrypto.SealedEnvelope])] { storage.withLock { $0.sentPayloads } }
    var sentHeaders: [(mediaIv: String, ephemeralPubKey: String)] { storage.withLock { $0.sentHeaders } }
    var sentMediaTypes: [String] { storage.withLock { $0.sentMediaTypes } }
    var sendGate: (@Sendable () async -> Void)? { get { storage.withLock { $0.sendGate } } set { storage.withLock { $0.sendGate = newValue } } }
    var sendDelivered: Bool { get { storage.withLock { $0.sendDelivered } } set { storage.withLock { $0.sendDelivered = newValue } } }
    var sendError: Error? { get { storage.withLock { $0.sendError } } set { storage.withLock { $0.sendError = newValue } } }
    var inboxError: Error? { get { storage.withLock { $0.inboxError } } set { storage.withLock { $0.inboxError = newValue } } }
    var inboxCallCount: Int { storage.withLock { $0.inboxCallCount } }
    var streaksCallCount: Int { storage.withLock { $0.streaksCallCount } }
    var conversationsResult: [InstantConversationSummary] { get { storage.withLock { $0.conversationsResult } } set { storage.withLock { $0.conversationsResult = newValue } } }
    var conversationsCallCount: Int { storage.withLock { $0.conversationsCallCount } }
    var conversationsGate: (@Sendable () async -> Void)? { get { storage.withLock { $0.conversationsGate } } set { storage.withLock { $0.conversationsGate = newValue } } }

    func registerDevice(deviceId: String, publicKey: String) async throws -> InstantDeviceKeyDTO {
        storage.withLock { $0.registeredDevices.append((deviceId, publicKey)) }
        return InstantDeviceKeyDTO(id: 1, deviceId: deviceId, publicKey: publicKey, createdAt: nil)
    }

    func keys(
        forUserId userId: Int
    ) async throws -> (theirs: [InstantDeviceKeyDTO], mine: [InstantDeviceKeyDTO]) {
        storage.withLock { ($0.keysByUser[userId] ?? [], $0.myKeys) }
    }

    func socketTicket(deviceId: String) async throws -> String { ticket }

    func inbox(deviceId: String) async throws -> [InstantDelivery] {
        try storage.withLock { state in
            state.inboxCallCount += 1
            if let inboxError = state.inboxError { throw inboxError }
            return state.inboxPages.isEmpty ? [] : state.inboxPages.removeFirst()
        }
    }

    func streaks() async throws -> [InstantStreakSummary] {
        storage.withLock { state in
            state.streaksCallCount += 1
            return state.streaksResult
        }
    }

    func conversations() async throws -> [InstantConversationSummary] {
        if let gate = conversationsGate { await gate() }
        return storage.withLock { state in
            state.conversationsCallCount += 1
            return state.conversationsResult
        }
    }

    func send(
        ciphertext: Data,
        recipientId: Int,
        durationMode: InstantDurationMode,
        mediaType: String,
        mediaIv: String,
        ephemeralPubKey: String,
        envelopes: [InstantCrypto.SealedEnvelope]
    ) async throws -> Bool {
        if let gate = sendGate { await gate() }
        return try storage.withLock { state in
            if let sendError = state.sendError { throw sendError }
            state.sentPayloads.append((ciphertext, recipientId, durationMode, envelopes))
            state.sentHeaders.append((mediaIv, ephemeralPubKey))
            state.sentMediaTypes.append(mediaType)
            return state.sendDelivered
        }
    }

    func media(instantId: String) async throws -> Data {
        try storage.withLock { state in
            state.mediaFetchCount += 1
            return try state.mediaResult.get()
        }
    }

    func markViewed(instantId: String) async throws {
        storage.withLock { $0.viewedIds.append(instantId) }
    }

    func markUndecryptable(instantId: String) async throws {
        storage.withLock { $0.undecryptableIds.append(instantId) }
    }
}

final class FakeUserAPI: UserAPIProtocol, @unchecked Sendable {
    var signInResult: Result<String, Error> = .success("token")
    var signInCalls: [(String, String)] = []
    var profile = AccountProfile(
        id: 1, email: "a@b.c", name: "Ana", bio: "hi", themeKey: "ocean",
        notificationsEnabled: true, profilePictureKey: nil, isAdmin: false,
        profilePictureUrl: nil
    )
    var usersResult: [UserSummary] = []
    var updateCalls: [(String, String)] = []
    var notificationCalls: [Bool] = []
    var notificationsError: Error?
    var apnsRegistrations: [(String, Bool)] = []
    var signOutCount = 0
    var acceptTermsCount = 0
    var deleteAccountResult: Result<Void, Error> = .success(())
    var deleteAccountPasswords: [String] = []

    func signIn(email: String, password: String) async throws -> String {
        signInCalls.append((email, password))
        return try signInResult.get()
    }
    func signOut() async { signOutCount += 1 }
    func me() async throws -> AccountProfile { profile }

    func updateProfile(bio: String, themeKey: String) async throws -> UpdatedProfile {
        updateCalls.append((bio, themeKey))
        return UpdatedProfile(
            id: 1, name: profile.name, bio: bio, themeKey: themeKey,
            profilePictureKey: nil, profilePictureUrl: nil
        )
    }

    func uploadProfilePicture(
        _ data: Data, filename: String, contentType: String
    ) async throws -> String? { "https://example.test/avatar.webp" }

    func deleteProfilePicture() async throws {}

    func setNotificationsEnabled(_ enabled: Bool) async throws -> Bool {
        if let notificationsError { throw notificationsError }
        notificationCalls.append(enabled)
        return enabled
    }

    func registerAPNsToken(_ token: String, sandbox: Bool) async throws {
        apnsRegistrations.append((token, sandbox))
    }

    func users() async throws -> [UserSummary] { usersResult }

    func acceptTerms() async throws -> String? {
        acceptTermsCount += 1
        profile.termsAcceptedAt = "2026-09-14T10:00:00.000Z"
        return profile.termsAcceptedAt
    }

    func deleteAccount(password: String) async throws {
        deleteAccountPasswords.append(password)
        try deleteAccountResult.get()
    }
}

final class FakeModerationAPI: ModerationAPIProtocol, @unchecked Sendable {
    private let storage = Mutex(State())

    struct State {
        var blocked: [BlockedUser] = []
        var blockedIds: [Int] = []
        var unblockedIds: [Int] = []
        var reports: [ReportDraft] = []
        var reportError: Error?
        var unblockError: Error?
    }

    var blocked: [BlockedUser] {
        get { storage.withLock { $0.blocked } }
        set { storage.withLock { $0.blocked = newValue } }
    }
    var reportError: Error? {
        get { storage.withLock { $0.reportError } }
        set { storage.withLock { $0.reportError = newValue } }
    }
    var unblockError: Error? {
        get { storage.withLock { $0.unblockError } }
        set { storage.withLock { $0.unblockError = newValue } }
    }
    var blockedIds: [Int] { storage.withLock { $0.blockedIds } }
    var unblockedIds: [Int] { storage.withLock { $0.unblockedIds } }
    var reports: [ReportDraft] { storage.withLock { $0.reports } }

    func blockedUsers() async throws -> [BlockedUser] { blocked }

    func block(userId: Int) async throws {
        storage.withLock { $0.blockedIds.append(userId) }
    }

    func unblock(userId: Int) async throws {
        try storage.withLock { state in
            if let error = state.unblockError { throw error }
            state.unblockedIds.append(userId)
        }
    }

    func report(_ draft: ReportDraft) async throws {
        try storage.withLock { state in
            if let error = state.reportError { throw error }
            state.reports.append(draft)
        }
    }
}

/// Says whatever the test needs about a photo.
struct FixedSensitivity: SensitivityChecking {
    let sensitive: Bool
    func isSensitive(_ image: UIImage) async -> Bool { sensitive }
}

// MARK: - Environment

/// A whole `AppEnvironment` on fakes, for the decisions that live on it rather
/// than on a view model — where a tap lands, and who the camera is aimed at.
@MainActor
func makeTestEnvironment(
    userAPI: FakeUserAPI = FakeUserAPI(),
    instantAPI: FakeInstantAPI = FakeInstantAPI(),
    moderationAPI: FakeModerationAPI = FakeModerationAPI(),
    session: SessionStore = SessionStore(keychain: InMemoryKeychain()),
    whatsNew: WhatsNewTracker = WhatsNewTracker(defaults: UserDefaults(suiteName: UUID().uuidString)!)
) -> AppEnvironment {
    let identities = DeviceIdentityStore(
        keychain: InMemoryKeychain(),
        secureEnclaveAvailable: { false }
    )
    return AppEnvironment(
        config: .localWorker,
        session: session,
        userAPI: userAPI,
        instantAPI: instantAPI,
        moderationAPI: moderationAPI,
        identities: identities,
        store: InstantStore(
            api: instantAPI, identities: identities, makeSocket: { _ in StubSocket() }
        ),
        whatsNew: whatsNew,
        makeCamera: { StubCameraController(frame: UIImage()) }
    )
}

// MARK: - Builders

extension InstantConversationSummary {
    static func fixture(
        userId: Int,
        name: String = "Ana",
        lastInteractionAt: String = "2026-01-01T00:00:00.000Z",
        lastSentAt: String? = nil,
        lastReceivedAt: String? = nil,
        unopenedCount: Int = 0,
        lastSentReceipt: InstantSendReceipt? = nil,
        streakCount: Int = 0,
        streakAtRisk: Bool = false
    ) -> InstantConversationSummary {
        InstantConversationSummary(
            userId: userId, name: name, themeKey: "rose", profilePictureUrl: nil,
            lastInteractionAt: lastInteractionAt,
            lastSentAt: lastSentAt, lastReceivedAt: lastReceivedAt ?? lastInteractionAt,
            unopenedCount: unopenedCount,
            lastSentReceipt: lastSentReceipt,
            streakCount: streakCount,
            streakDeadline: streakCount > 0 ? "2026-01-02T00:00:00.000Z" : nil,
            streakAtRisk: streakAtRisk
        )
    }
}

extension InstantDelivery {
    static func fixture(
        id: String = "instant-1",
        senderId: Int = 2,
        durationMode: InstantDurationMode = .fiveSeconds,
        createdAt: String = "2026-01-01T00:00:00.000Z",
        expiresAt: String = "2026-01-02T00:00:00.000Z",
        envelope: InstantKeyEnvelope? = InstantKeyEnvelope(wrappedKey: "AQ", wrapIv: "Ag")
    ) -> InstantDelivery {
        InstantDelivery(
            id: id, senderId: senderId, senderName: "Ana", senderThemeKey: "rose",
            senderProfilePictureUrl: nil, mediaType: "image/webp", mediaIv: "Aw",
            ephemeralPubKey: "BA", byteSize: 10, durationMode: durationMode,
            createdAt: createdAt, expiresAt: expiresAt, envelope: envelope
        )
    }
}

/// A clock that never actually waits: `sleep` advances a virtual now and
/// returns. A five-second countdown finishes in microseconds.
final class TestTime: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_700_000_000)

    var source: TimeSource {
        TimeSource(
            now: { [self] in lock.withLock { current } },
            sleep: { [self] duration in
                let seconds = Double(duration.components.seconds)
                    + Double(duration.components.attoseconds) / 1e18
                lock.withLock { current = current.addingTimeInterval(seconds) }
                await Task.yield()
            }
        )
    }

    var now: Date { lock.withLock { current } }
}
