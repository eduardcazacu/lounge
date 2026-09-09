import Foundation
import Observation

public protocol TokenStoring: Sendable {
    var token: String? { get }
    func setToken(_ token: String?)
}

/// The access token and whatever can be read out of it.
///
/// The `id` claim is read *without verifying the signature*, exactly as the web
/// client does in `frontend/src/lib/auth.ts`. That is safe here because the
/// claim is only used to key local state and to build the HKDF info string —
/// a forged id yields envelopes the real recipient cannot open, which is a
/// self-inflicted failure, not an escalation. Every actual authorization
/// decision happens server-side against the signature.
@Observable
public final class SessionStore: TokenStoring, @unchecked Sendable {
    private let keychain: KeychainStoring
    private let account = "session:access-token"
    private let lock = NSLock()
    private var cachedToken: String?

    public private(set) var currentUserId: Int?
    public private(set) var isSignedIn: Bool

    public init(keychain: KeychainStoring = Keychain(service: "com.eduardcazacu.instant.session")) {
        self.keychain = keychain
        // A stored blob only counts as a session if an id can actually be read
        // out of it. Treating any non-nil value as signed-in would strand the
        // app on a camera screen it can never load anything into, with no way
        // back to sign-in short of deleting it.
        let stored = keychain.read(account: account)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { Self.userId(fromJWT: $0) == nil ? nil : $0 }
        cachedToken = stored
        currentUserId = stored.flatMap(Self.userId(fromJWT:))
        isSignedIn = stored != nil
        if stored == nil { keychain.delete(account: account) }
    }

    public var token: String? {
        lock.lock(); defer { lock.unlock() }
        return cachedToken
    }

    public func setToken(_ token: String?) {
        lock.lock()
        cachedToken = token
        lock.unlock()

        if let token, let data = token.data(using: .utf8) {
            try? keychain.write(data, account: account)
        } else {
            keychain.delete(account: account)
        }

        let userId = token.flatMap(Self.userId(fromJWT:))
        Task { @MainActor in
            self.currentUserId = userId
            self.isSignedIn = userId != nil
        }
    }

    public func signOut() {
        setToken(nil)
    }

    /// Payload is `{ id, exp }` and nothing else.
    public static func userId(fromJWT token: String) -> Int? {
        let parts = token.split(separator: ".")
        guard parts.count == 3,
              let payload = Base64URL.decode(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        if let id = json["id"] as? Int { return id }
        if let id = json["id"] as? Double { return Int(id) }
        if let id = json["id"] as? String { return Int(id) }
        return nil
    }

    public static func expiry(ofJWT token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3,
              let payload = Base64URL.decode(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let exp = json["exp"] as? Double
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

/// Test double.
public final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    public init(token: String? = nil) { stored = token }

    public var token: String? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    public func setToken(_ token: String?) {
        lock.lock(); defer { lock.unlock() }
        stored = token
    }
}
