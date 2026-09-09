import Foundation
import Security

/// Thin wrapper over a generic-password keychain item.
///
/// Everything Instant persists is device-local and unrecoverable by design, so
/// items are written `ThisDeviceOnly` — they must not ride an iCloud backup onto
/// another device, which would quietly break the "one keypair per device"
/// property the crypto depends on.
public protocol KeychainStoring: Sendable {
    func read(account: String) -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String)
}

public struct Keychain: KeychainStoring {
    public enum KeychainError: Error, Equatable {
        case writeFailed(OSStatus)
    }

    let service: String

    public init(service: String = "com.eduardcazacu.instant.identity") {
        self.service = service
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    public func write(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }

        if updated == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError.writeFailed(added) }
            return
        }

        throw KeychainError.writeFailed(updated)
    }

    public func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}

/// In-memory double for tests and UI-test stub launches.
public final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    public init(seed: [String: Data] = [:]) {
        storage = seed
    }

    public func read(account: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[account]
    }

    public func write(_ data: Data, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account] = data
    }

    public func delete(account: String) {
        lock.lock(); defer { lock.unlock() }
        storage[account] = nil
    }
}
