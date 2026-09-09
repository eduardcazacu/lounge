import CryptoKit
import Foundation

/// Out-of-band fingerprints, matching `safetyNumber`/`fingerprintKeys` in
/// `frontend/src/lib/instantCrypto.ts`.
///
/// The server publishes everyone's public keys and could publish its own
/// instead, to sit in the middle. Comparing these two numbers out of band is the
/// only thing that detects that, which is why the app shows them.
public enum SafetyNumber {
    /// JS `Array.prototype.sort()` orders by UTF-16 code unit. Swift's default
    /// `String` ordering happens to agree for pure-ASCII input like base64url,
    /// but only as a consequence of how Unicode ordering falls out for ASCII —
    /// it is not the same rule. Comparing UTF-8 bytes states the rule the wire
    /// format actually requires instead of relying on that coincidence, and the
    /// committed fixtures in `interop-safety.json` pin it against the real JS.
    static func jsSorted(_ values: [String]) -> [String] {
        values.sorted { lhs, rhs in
            Array(lhs.utf8).lexicographicallyPrecedes(Array(rhs.utf8))
        }
    }

    static func digest(of publicKeys: [String]) -> Data {
        let material = jsSorted(publicKeys).joined(separator: "|")
        return Data(SHA256.hash(data: Data(material.utf8)))
    }

    /// Twelve groups of five digits, each from a big-endian 16-bit slice of the
    /// digest. Both sides compute the same string from the union of their keys.
    public static func safetyNumber(mine: [String], theirs: [String]) -> String {
        let bytes = [UInt8](digest(of: mine + theirs))
        var groups: [String] = []
        groups.reserveCapacity(12)
        for index in 0..<12 {
            let chunk = (Int(bytes[index * 2]) << 8 | Int(bytes[index * 2 + 1])) % 100_000
            groups.append(String(format: "%05d", chunk))
        }
        return groups.joined(separator: " ")
    }

    /// A compact fingerprint of one side's keys, used to notice when a peer's
    /// keys change between conversations.
    public static func fingerprint(of publicKeys: [String]) -> String {
        Base64URL.encode(digest(of: publicKeys))
    }
}
