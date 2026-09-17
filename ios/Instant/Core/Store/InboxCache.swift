import Foundation

/// The inbox as it was last seen, kept so a cold start draws it at once.
///
/// A cold start otherwise has nothing to draw until the device is registered,
/// the socket is up and the inbox is drained — and a notification tap lands on
/// that inbox, so the first thing the person saw was "No conversations yet".
///
/// It is a cache and nothing more: whatever the server says next replaces it.
/// The envelopes it holds are sealed to this device's Secure Enclave key, and
/// the photos themselves never touch the disk, so it holds nothing the widget
/// snapshot and the Keychain do not already imply.
public struct InboxCacheContents: Codable, Equatable, Sendable {
    public let userId: Int
    public let instants: [InstantDelivery]
    public let history: [InstantConversationSummary]

    public init(userId: Int, instants: [InstantDelivery], history: [InstantConversationSummary]) {
        self.userId = userId
        self.instants = instants
        self.history = history
    }
}

public protocol InboxCaching: Sendable {
    func load() -> InboxCacheContents?
    func save(_ contents: InboxCacheContents)
    func clear()
}

public struct InboxCache: InboxCaching {
    private let url: URL?
    /// Writes happen on every inbox change, off the main actor, and must land
    /// in the order they were made or an older inbox could overwrite a newer one.
    private let queue = DispatchQueue(label: "com.eduardcazacu.instant.inbox-cache")

    public init(fileManager: FileManager = .default) {
        url = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("inbox-cache.json")
    }

    public init(url: URL) {
        self.url = url
    }

    /// Synchronous on purpose: it runs before the first frame, and a frame drawn
    /// before it would be the empty inbox this exists to avoid.
    public func load() -> InboxCacheContents? {
        guard let url else { return nil }
        return queue.sync {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(InboxCacheContents.self, from: data)
        }
    }

    public func save(_ contents: InboxCacheContents) {
        guard let url else { return }
        queue.async {
            guard let data = try? JSONEncoder().encode(contents) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    public func clear() {
        guard let url else { return }
        queue.async { try? FileManager.default.removeItem(at: url) }
    }
}

/// For tests and the UI-test stubs, which must not inherit a previous run's inbox.
public final class InMemoryInboxCache: InboxCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: InboxCacheContents?

    public init(_ contents: InboxCacheContents? = nil) {
        stored = contents
    }

    public var contents: InboxCacheContents? { lock.withLock { stored } }

    public func load() -> InboxCacheContents? { lock.withLock { stored } }
    public func save(_ contents: InboxCacheContents) { lock.withLock { stored = contents } }
    public func clear() { lock.withLock { stored = nil } }
}
