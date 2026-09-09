// Runs the Swift crypto against the JS-generated fixtures on the host, without
// needing a simulator, and seals a fixture in the other direction for
// verify-swift-fixtures.ts to open with the real WebCrypto code.
//
//   ios/tools/run-interop.sh
//
// The Xcode test target covers the same ground; this exists because it gives
// sub-second feedback on the one part of the port that fails silently.

import CryptoKit
import Foundation

// ios/tools/interop/main.swift -> ios
let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // interop
    .deletingLastPathComponent()  // tools
    .deletingLastPathComponent()  // ios
let fixtures = root.appendingPathComponent("InstantTests/Fixtures")

var failures: [String] = []
var checks = 0

func check(_ label: String, _ condition: Bool) {
    checks += 1
    if condition {
        print("  ok   \(label)")
    } else {
        print("  FAIL \(label)")
        failures.append(label)
    }
}

func load(_ name: String) -> [String: Any] {
    let data = try! Data(contentsOf: fixtures.appendingPathComponent(name))
    return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
}

func b64(_ value: String) -> Data { Base64URL.decode(value)! }

func device(_ raw: [String: Any]) throws -> (identity: DeviceIdentity, id: Int, publicKey: String) {
    let identity = try DeviceIdentity(
        deviceId: raw["deviceId"] as! String,
        privateKeyRaw: b64(raw["privateKeyRaw"] as! String)
    )
    return (identity, raw["id"] as! Int, raw["publicKey"] as! String)
}

func openable(_ fixture: [String: Any], envelope: [String: Any]) -> InstantCrypto.OpenableInstant {
    InstantCrypto.OpenableInstant(
        mediaIv: fixture["mediaIv"] as! String,
        ephemeralPubKey: fixture["ephemeralPubKey"] as! String,
        senderId: fixture["senderUserId"] as! Int,
        envelopeWrappedKey: envelope["wrappedKey"] as! String,
        envelopeWrapIv: envelope["wrapIv"] as! String
    )
}

// MARK: - JS sealed it, Swift must open it

print("\ninterop-single.json — JS seals, Swift opens")
do {
    let fixture = load("interop-single.json")
    let devices = fixture["devices"] as! [[String: Any]]
    let envelopes = fixture["envelopes"] as! [[String: Any]]
    let (identity, id, publicKey) = try device(devices[0])

    check("public key round-trips", identity.publicKeyBase64 == publicKey)
    check("envelope targets this device", envelopes[0]["deviceKeyId"] as! Int == id)

    let plaintext = try InstantCrypto.open(
        ciphertext: b64(fixture["ciphertext"] as! String),
        instant: openable(fixture, envelope: envelopes[0]),
        device: identity
    )
    check("plaintext matches exactly", plaintext == b64(fixture["plaintext"] as! String))
    check("plaintext is the expected length", plaintext.count == 4096)
}

print("\ninterop-multi.json — one seal, three devices")
do {
    let fixture = load("interop-multi.json")
    let devices = try (fixture["devices"] as! [[String: Any]]).map { try device($0) }
    let envelopes = fixture["envelopes"] as! [[String: Any]]
    let ciphertext = b64(fixture["ciphertext"] as! String)
    let expected = b64(fixture["plaintext"] as! String)

    for (index, entry) in devices.enumerated() {
        let envelope = envelopes.first { $0["deviceKeyId"] as! Int == entry.id }!
        let plaintext = try InstantCrypto.open(
            ciphertext: ciphertext,
            instant: openable(fixture, envelope: envelope),
            device: entry.identity
        )
        check("device \(index) opens its own envelope", plaintext == expected)
    }

    // The whole point of binding deviceId into the HKDF info: an envelope must
    // not open against a device it was not addressed to.
    let foreign = envelopes.first { $0["deviceKeyId"] as! Int == devices[1].id }!
    var rejected = false
    do {
        _ = try InstantCrypto.open(
            ciphertext: ciphertext,
            instant: openable(fixture, envelope: foreign),
            device: devices[0].identity
        )
    } catch {
        rejected = true
    }
    check("device 0 cannot open device 1's envelope", rejected)
}

print("\ninterop-hkdf.json — key agreement in isolation")
do {
    let fixture = load("interop-hkdf.json")
    let raw = fixture["device"] as! [String: Any]
    let deviceId = raw["deviceId"] as! String
    let senderUserId = fixture["senderUserId"] as! Int

    let ephemeralPrivate = try P256.KeyAgreement.PrivateKey(
        rawRepresentation: b64(fixture["ephemeralPrivateKeyRaw"] as! String)
    )
    let devicePublic = try P256.KeyAgreement.PublicKey(
        x963Representation: b64(raw["publicKey"] as! String)
    )
    let shared = try ephemeralPrivate.sharedSecretFromKeyAgreement(with: devicePublic)
    check(
        "ECDH shared secret matches",
        shared.withUnsafeBytes { Data($0) } == b64(fixture["sharedSecret"] as! String)
    )

    check(
        "HKDF info bytes match",
        InstantCrypto.hkdfInfo(senderUserId: senderUserId, recipientDeviceId: deviceId)
            == b64(fixture["hkdfInfoUtf8"] as! String)
    )

    let ephemeralPublicRaw = b64(fixture["ephemeralPubKey"] as! String)
    let wrappingKey = InstantCrypto.deriveWrappingKey(
        agreement: shared,
        ephemeralPublicKeyRaw: ephemeralPublicRaw,
        senderUserId: senderUserId,
        recipientDeviceId: deviceId
    )
    check(
        "derived wrapping key matches",
        wrappingKey.withUnsafeBytes { Data($0) } == b64(fixture["expectedWrappingKey"] as! String)
    )

    // Salt is the raw 65 bytes, not their base64url text. Prove the difference
    // is detectable rather than assuming it.
    let wrongSalt = InstantCrypto.deriveWrappingKey(
        agreement: shared,
        ephemeralPublicKeyRaw: Data((fixture["ephemeralPubKey"] as! String).utf8),
        senderUserId: senderUserId,
        recipientDeviceId: deviceId
    )
    check(
        "base64 text as salt derives a different key",
        wrongSalt.withUnsafeBytes { Data($0) } != b64(fixture["expectedWrappingKey"] as! String)
    )

    // And that the deviceId case matters, which is the trap Swift walks into.
    let uppercased = InstantCrypto.deriveWrappingKey(
        agreement: shared,
        ephemeralPublicKeyRaw: ephemeralPublicRaw,
        senderUserId: senderUserId,
        recipientDeviceId: deviceId.uppercased()
    )
    check(
        "uppercase deviceId derives a different key",
        uppercased.withUnsafeBytes { Data($0) } != b64(fixture["expectedWrappingKey"] as! String)
    )
}

print("\ninterop-safety.json — fingerprints and sort order")
do {
    let fixture = load("interop-safety.json")
    for (index, raw) in (fixture["vectors"] as! [[String: Any]]).enumerated() {
        let mine = raw["mine"] as! [String]
        let theirs = raw["theirs"] as! [String]
        check(
            "vector \(index) safety number matches",
            SafetyNumber.safetyNumber(mine: mine, theirs: theirs) == raw["safetyNumber"] as! String
        )
        check(
            "vector \(index) my fingerprint matches",
            SafetyNumber.fingerprint(of: mine) == raw["mineFingerprint"] as! String
        )
        check(
            "vector \(index) their fingerprint matches",
            SafetyNumber.fingerprint(of: theirs) == raw["theirsFingerprint"] as! String
        )
    }
}

// MARK: - Swift seals it, JS must open it

print("\nswift-sealed.json — sealing for verify-swift-fixtures.ts")
do {
    // Fixed key material so the committed fixture is reproducible; the IVs and
    // ephemeral key inside the seal are still random, which is the point.
    let recipients = (0..<2).map { index -> (fixture: [String: Any], identity: DeviceIdentity) in
        let key = P256.KeyAgreement.PrivateKey()
        let deviceId = UUID().uuidString.lowercased()
        let identity = DeviceIdentity(deviceId: deviceId, backing: .software(key))
        return (
            [
                "id": 900 + index,
                "deviceId": deviceId,
                "publicKey": identity.publicKeyBase64,
                "privateKeyRaw": Base64URL.encode(key.rawRepresentation),
            ],
            identity
        )
    }

    let senderUserId = 12
    var media = Data(count: 2048)
    for index in 0..<media.count { media[index] = UInt8((index * 53 + 7) % 256) }

    let sealed = try InstantCrypto.seal(
        media: media,
        senderUserId: senderUserId,
        devices: recipients.map {
            InstantCrypto.RecipientDeviceKey(
                id: $0.fixture["id"] as! Int,
                deviceId: $0.fixture["deviceId"] as! String,
                publicKey: $0.fixture["publicKey"] as! String
            )
        }
    )

    // Swift must be able to open what Swift sealed, before we ask JS to.
    for (index, recipient) in recipients.enumerated() {
        let envelope = sealed.envelopes[index]
        let opened = try InstantCrypto.open(
            ciphertext: sealed.ciphertext,
            instant: InstantCrypto.OpenableInstant(
                mediaIv: sealed.mediaIv,
                ephemeralPubKey: sealed.ephemeralPubKey,
                senderId: senderUserId,
                envelopeWrappedKey: envelope.wrappedKey,
                envelopeWrapIv: envelope.wrapIv
            ),
            device: recipient.identity
        )
        check("swift round-trips device \(index)", opened == media)
    }

    let output: [String: Any] = [
        "note": "Sealed by ios/Instant/Core/Crypto/InstantCrypto.swift. verify-swift-fixtures.ts opens it with the real WebCrypto implementation.",
        "senderUserId": senderUserId,
        "plaintext": Base64URL.encode(media),
        "devices": recipients.map { $0.fixture },
        "ciphertext": Base64URL.encode(sealed.ciphertext),
        "mediaIv": sealed.mediaIv,
        "ephemeralPubKey": sealed.ephemeralPubKey,
        "envelopes": sealed.envelopes.map {
            ["deviceKeyId": $0.deviceKeyId, "wrappedKey": $0.wrappedKey, "wrapIv": $0.wrapIv]
        },
    ]
    let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    try (data + Data("\n".utf8)).write(to: fixtures.appendingPathComponent("swift-sealed.json"))
    print("  wrote swift-sealed.json")
}

print("\n\(checks - failures.count)/\(checks) checks passed")
if !failures.isEmpty {
    print("failures:")
    for failure in failures { print("  - \(failure)") }
    exit(1)
}
