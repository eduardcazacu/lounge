import Foundation

/// Remembers when you last exchanged an instant with someone, so the recipient
/// picker can lead with the people you actually talk to.
///
/// This has to be tracked locally. `GET /api/v1/user/list` is ordered by who
/// posted to the Lounge most recently, which says nothing about who you send
/// photos to, and no endpoint reports per-person Instant recency — the server
/// deliberately forgets an instant the moment it is opened.
public protocol RecentContactsStoring: Sendable {
    func lastInteraction(with peerUserId: Int, for userId: Int) -> Date?
    func record(peerUserId: Int, for userId: Int, at date: Date)
}

public extension RecentContactsStoring {
    func record(peerUserId: Int, for userId: Int) {
        record(peerUserId: peerUserId, for: userId, at: Date())
    }
}

public struct RecentContactsStore: RecentContactsStoring {
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Keyed by both sides: who you talk to is per account, not per device.
    static func key(peerUserId: Int, userId: Int) -> String {
        "instant.recentContact.\(userId):\(peerUserId)"
    }

    public func lastInteraction(with peerUserId: Int, for userId: Int) -> Date? {
        let stamp = defaults.double(forKey: Self.key(peerUserId: peerUserId, userId: userId))
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    public func record(peerUserId: Int, for userId: Int, at date: Date) {
        let key = Self.key(peerUserId: peerUserId, userId: userId)
        // Draining a backlog can deliver older instants after newer ones, so
        // only ever move the mark forwards.
        let existing = defaults.double(forKey: key)
        guard date.timeIntervalSince1970 > existing else { return }
        defaults.set(date.timeIntervalSince1970, forKey: key)
    }
}

public final class InMemoryRecentContactsStore: RecentContactsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Date] = [:]

    public init() {}

    public func lastInteraction(with peerUserId: Int, for userId: Int) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return storage[RecentContactsStore.key(peerUserId: peerUserId, userId: userId)]
    }

    public func record(peerUserId: Int, for userId: Int, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        let key = RecentContactsStore.key(peerUserId: peerUserId, userId: userId)
        guard date > (storage[key] ?? .distantPast) else { return }
        storage[key] = date
    }
}

/// The wire format is ISO 8601 with fractional seconds; the fallback covers a
/// timestamp serialized without them.
public enum InstantTimestamp {
    // ISO8601DateFormatter is documented as thread-safe for parsing but is not
    // marked Sendable, and these two are never mutated after construction.
    private nonisolated(unsafe) static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let plain = ISO8601DateFormatter()

    public static func parse(_ value: String) -> Date? {
        withFraction.date(from: value) ?? plain.date(from: value)
    }
}
