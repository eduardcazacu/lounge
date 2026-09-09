import CryptoKit
import Foundation

/// This device's Instant identity: a P-256 key agreement keypair plus the
/// `deviceId` that names it on the wire.
///
/// The private half is preferably held by the Secure Enclave, which is the whole
/// reason the protocol uses P-256 rather than X25519 — it is the only curve the
/// Enclave supports.
public struct DeviceIdentity: @unchecked Sendable {
    public enum Backing {
        case secureEnclave(SecureEnclave.P256.KeyAgreement.PrivateKey)
        case software(P256.KeyAgreement.PrivateKey)
    }

    /// Lowercase UUID. `crypto.randomUUID()` on the web is lowercase and this
    /// string is inside the HKDF info, so the case is load-bearing: an uppercase
    /// id derives a different wrapping key and every envelope silently fails to
    /// open.
    public let deviceId: String
    public let backing: Backing

    public var publicKey: P256.KeyAgreement.PublicKey {
        switch backing {
        case .secureEnclave(let key): return key.publicKey
        case .software(let key): return key.publicKey
        }
    }

    /// Raw uncompressed point (65 bytes), which is what the server stores and
    /// what senders wrap to.
    public var publicKeyBase64: String {
        Base64URL.encode(publicKey.x963Representation)
    }

    public var isSecureEnclaveBacked: Bool {
        if case .secureEnclave = backing { return true }
        return false
    }

    public init(deviceId: String, backing: Backing) {
        self.deviceId = deviceId
        self.backing = backing
    }

    /// Rebuilds a software-backed identity from a raw 32-byte P-256 scalar.
    /// Only the interop fixtures and tests use this — the app never imports key
    /// material, it generates it.
    public init(deviceId: String, privateKeyRaw: Data) throws {
        self.deviceId = deviceId
        self.backing = .software(try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKeyRaw))
    }

    public func sharedSecret(with peer: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
        switch backing {
        case .secureEnclave(let key): return try key.sharedSecretFromKeyAgreement(with: peer)
        case .software(let key): return try key.sharedSecretFromKeyAgreement(with: peer)
        }
    }
}

/// Loads, creates and persists the per-account device identity.
public protocol DeviceIdentityProviding: Sendable {
    func identity(forUserId userId: Int) throws -> DeviceIdentity
    func reset(forUserId userId: Int)
}

public struct DeviceIdentityStore: DeviceIdentityProviding {
    /// Keyed per *account*, not per install. Two accounts used on one device
    /// must never share a keypair: sharing one would let either of them decrypt
    /// instants addressed to the other. This mirrors `identityKey` in
    /// `frontend/src/lib/instantKeystore.ts`.
    static func account(forUserId userId: Int) -> String { "device:\(userId)" }

    private struct Record: Codable {
        enum Kind: String, Codable { case secureEnclave, software }
        let deviceId: String
        let kind: Kind
        let keyData: Data
    }

    public enum IdentityError: Error, Equatable {
        case keyGenerationFailed
        case storedKeyUnreadable
    }

    let keychain: KeychainStoring
    /// Injectable so tests can exercise both branches on any host.
    let secureEnclaveAvailable: @Sendable () -> Bool

    public init(
        keychain: KeychainStoring = Keychain(),
        secureEnclaveAvailable: @escaping @Sendable () -> Bool = { SecureEnclave.isAvailable }
    ) {
        self.keychain = keychain
        self.secureEnclaveAvailable = secureEnclaveAvailable
    }

    public func identity(forUserId userId: Int) throws -> DeviceIdentity {
        let account = Self.account(forUserId: userId)

        if let data = keychain.read(account: account),
           let record = try? JSONDecoder().decode(Record.self, from: data),
           let identity = restore(record) {
            return identity
        }

        let identity = try generate()
        try keychain.write(try JSONEncoder().encode(record(for: identity)), account: account)
        return identity
    }

    public func reset(forUserId userId: Int) {
        keychain.delete(account: Self.account(forUserId: userId))
    }

    // MARK: - Internals

    private func generate() throws -> DeviceIdentity {
        // Lowercased on purpose — see `DeviceIdentity.deviceId`.
        let deviceId = UUID().uuidString.lowercased()

        if secureEnclaveAvailable(), let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey() {
            return DeviceIdentity(deviceId: deviceId, backing: .secureEnclave(key))
        }
        // Simulators without Enclave emulation, and any device where creation
        // fails, fall back to a software key. It is still non-exportable in
        // practice because it only ever leaves here inside a ThisDeviceOnly
        // keychain item.
        return DeviceIdentity(deviceId: deviceId, backing: .software(P256.KeyAgreement.PrivateKey()))
    }

    private func record(for identity: DeviceIdentity) -> Record {
        switch identity.backing {
        case .secureEnclave(let key):
            return Record(deviceId: identity.deviceId, kind: .secureEnclave, keyData: key.dataRepresentation)
        case .software(let key):
            return Record(deviceId: identity.deviceId, kind: .software, keyData: key.rawRepresentation)
        }
    }

    private func restore(_ record: Record) -> DeviceIdentity? {
        switch record.kind {
        case .secureEnclave:
            guard let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(
                dataRepresentation: record.keyData
            ) else { return nil }
            return DeviceIdentity(deviceId: record.deviceId, backing: .secureEnclave(key))
        case .software:
            guard let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: record.keyData) else {
                return nil
            }
            return DeviceIdentity(deviceId: record.deviceId, backing: .software(key))
        }
    }
}
