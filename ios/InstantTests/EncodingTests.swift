import CryptoKit
import Foundation
import Testing
@testable import Instant

@Suite("base64url")
struct Base64URLTests {
    @Test("Round-trips arbitrary bytes")
    func roundTrips() {
        for length in 0...64 {
            let data = Data((0..<length).map { UInt8(($0 * 31 + 7) % 256) })
            #expect(Base64URL.decode(Base64URL.encode(data)) == data)
        }
    }

    @Test("Never emits padding or the standard alphabet")
    func usesUrlAlphabetWithoutPadding() {
        // The server validates every blob against /^[A-Za-z0-9_-]+$/, so a '='
        // or a '+' is a 400 rather than a subtle bug.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        for length in 1...200 {
            let encoded = Base64URL.encode(Data((0..<length).map { UInt8($0 % 256) }))
            #expect(encoded.unicodeScalars.allSatisfy { allowed.contains($0) }, "bad output: \(encoded)")
        }
    }

    @Test("Accepts input with or without padding")
    func decodesPadded() {
        #expect(Base64URL.decode("AQID") == Data([1, 2, 3]))
        #expect(Base64URL.decode("AQI") == Data([1, 2]))
        #expect(Base64URL.decode("AQ") == Data([1]))
    }

    @Test("Rejects nonsense")
    func rejectsInvalid() {
        #expect(Base64URL.decode("!!!!") == nil)
    }
}

@Suite("Safety numbers")
struct SafetyNumberTests {
    @Test("Matches the web client's vectors")
    func matchesFixtures() throws {
        let fixture = try Fixtures.json("interop-safety")
        for vector in fixture["vectors"] as! [[String: Any]] {
            let mine = vector["mine"] as! [String]
            let theirs = vector["theirs"] as! [String]
            #expect(
                SafetyNumber.safetyNumber(mine: mine, theirs: theirs)
                    == vector["safetyNumber"] as! String
            )
            #expect(SafetyNumber.fingerprint(of: mine) == vector["mineFingerprint"] as! String)
            #expect(SafetyNumber.fingerprint(of: theirs) == vector["theirsFingerprint"] as! String)
        }
    }

    /// Orders by byte value across the whole base64url alphabet:
    /// `-` (0x2D) < digits < uppercase < `_` (0x5F) < lowercase. Getting this
    /// wrong yields a safety number that is stable, plausible, and never matches
    /// the other side — which is why it is pinned here as well as against the
    /// JS fixtures.
    @Test("Sorts by UTF-8 byte value across the whole alphabet")
    func sortsByByteValue() {
        #expect(
            SafetyNumber.jsSorted(["_z", "-a", "Zb", "0c", "ay"])
                == ["-a", "0c", "Zb", "_z", "ay"]
        )
        #expect(SafetyNumber.jsSorted(["b", "a", "B", "A"]) == ["A", "B", "a", "b"])
        #expect(SafetyNumber.jsSorted([]) == [])
    }

    @Test("Both sides compute the same number from the same key sets")
    func isSymmetricAcrossSides() {
        let alice = ["aaa", "bbb"]
        let bob = ["ccc"]
        // Keys are concatenated then sorted, so who is "mine" does not matter.
        #expect(
            SafetyNumber.safetyNumber(mine: alice, theirs: bob)
                == SafetyNumber.safetyNumber(mine: bob, theirs: alice)
        )
    }

    @Test("Shape is twelve five-digit groups")
    func hasExpectedShape() {
        let number = SafetyNumber.safetyNumber(mine: ["a"], theirs: ["b"])
        let groups = number.split(separator: " ")
        #expect(groups.count == 12)
        #expect(groups.allSatisfy { $0.count == 5 && $0.allSatisfy(\.isNumber) })
    }

    @Test("A changed key changes the fingerprint")
    func fingerprintTracksKeys() {
        let before = SafetyNumber.fingerprint(of: ["key-one"])
        let after = SafetyNumber.fingerprint(of: ["key-two"])
        #expect(before != after)
        #expect(SafetyNumber.fingerprint(of: ["a", "b"]) == SafetyNumber.fingerprint(of: ["b", "a"]))
    }
}

@Suite("Device identity")
struct DeviceIdentityTests {
    @Test("Generates once and reloads the same key")
    func persistsAcrossCalls() throws {
        let store = DeviceIdentityStore(
            keychain: InMemoryKeychain(),
            secureEnclaveAvailable: { false }
        )
        let first = try store.identity(forUserId: 7)
        let second = try store.identity(forUserId: 7)
        #expect(first.deviceId == second.deviceId)
        #expect(first.publicKeyBase64 == second.publicKeyBase64)
    }

    /// Two accounts on one device must never share a keypair: sharing one would
    /// let either of them decrypt instants addressed to the other.
    @Test("Accounts on the same device get separate identities")
    func isKeyedPerAccount() throws {
        let store = DeviceIdentityStore(
            keychain: InMemoryKeychain(),
            secureEnclaveAvailable: { false }
        )
        let alice = try store.identity(forUserId: 1)
        let bob = try store.identity(forUserId: 2)
        #expect(alice.deviceId != bob.deviceId)
        #expect(alice.publicKeyBase64 != bob.publicKeyBase64)
    }

    @Test("deviceId is a lowercase UUID")
    func deviceIdIsLowercaseUUID() throws {
        let store = DeviceIdentityStore(
            keychain: InMemoryKeychain(),
            secureEnclaveAvailable: { false }
        )
        let identity = try store.identity(forUserId: 3)
        #expect(UUID(uuidString: identity.deviceId) != nil)
        #expect(identity.deviceId == identity.deviceId.lowercased())
    }

    @Test("Resetting mints a new identity, which is what makes key loss terminal")
    func resetGeneratesNewKey() throws {
        let store = DeviceIdentityStore(
            keychain: InMemoryKeychain(),
            secureEnclaveAvailable: { false }
        )
        let before = try store.identity(forUserId: 4)
        store.reset(forUserId: 4)
        let after = try store.identity(forUserId: 4)
        #expect(before.deviceId != after.deviceId)
    }

    @Test("Falls back to a software key where the Enclave is unavailable")
    func fallsBackWithoutSecureEnclave() throws {
        let store = DeviceIdentityStore(
            keychain: InMemoryKeychain(),
            secureEnclaveAvailable: { false }
        )
        #expect(try store.identity(forUserId: 5).isSecureEnclaveBacked == false)
    }

    @Test("A corrupted keychain record is replaced rather than fatal")
    func recoversFromCorruptRecord() throws {
        let keychain = InMemoryKeychain()
        try keychain.write(Data("not json".utf8), account: "device:9")
        let store = DeviceIdentityStore(keychain: keychain, secureEnclaveAvailable: { false })
        #expect(try store.identity(forUserId: 9).deviceId.isEmpty == false)
    }

    @Test("The public key is a 65-byte uncompressed point")
    func publicKeyEncoding() throws {
        let store = DeviceIdentityStore(
            keychain: InMemoryKeychain(),
            secureEnclaveAvailable: { false }
        )
        let identity = try store.identity(forUserId: 6)
        let raw = Base64URL.decode(identity.publicKeyBase64)
        #expect(raw?.count == 65)
        #expect(raw?.first == 0x04)
        // The server bounds this field at 80...120 characters.
        #expect((80...120).contains(identity.publicKeyBase64.count))
    }
}
