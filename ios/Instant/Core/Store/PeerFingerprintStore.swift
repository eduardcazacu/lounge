import Foundation

/// Remembers what a peer's keys looked like last time, so a change can be
/// surfaced.
///
/// The server publishes the key directory and could substitute its own key to
/// sit in the middle. Nothing here can prove it did not — but a key that changes
/// without the person saying they got a new device is the signal worth showing,
/// and it costs one string per contact to keep.
public protocol PeerFingerprintStoring: Sendable {
    func fingerprint(userId: Int, peerUserId: Int) -> String?
    func remember(_ fingerprint: String, userId: Int, peerUserId: Int)
}

public struct PeerFingerprintStore: PeerFingerprintStoring {
    // UserDefaults is thread-safe but not marked Sendable.
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Keyed by both sides: the same peer seen from a different account is a
    /// different trust decision.
    static func key(userId: Int, peerUserId: Int) -> String {
        "instant.peerFingerprint.\(userId):\(peerUserId)"
    }

    public func fingerprint(userId: Int, peerUserId: Int) -> String? {
        defaults.string(forKey: Self.key(userId: userId, peerUserId: peerUserId))
    }

    public func remember(_ fingerprint: String, userId: Int, peerUserId: Int) {
        defaults.set(fingerprint, forKey: Self.key(userId: userId, peerUserId: peerUserId))
    }
}

public final class InMemoryPeerFingerprintStore: PeerFingerprintStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init() {}

    public func fingerprint(userId: Int, peerUserId: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[PeerFingerprintStore.key(userId: userId, peerUserId: peerUserId)]
    }

    public func remember(_ fingerprint: String, userId: Int, peerUserId: Int) {
        lock.lock(); defer { lock.unlock() }
        storage[PeerFingerprintStore.key(userId: userId, peerUserId: peerUserId)] = fingerprint
    }
}
