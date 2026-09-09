import CryptoKit
import Foundation
import Testing
@testable import Instant

/// The load-bearing suite.
///
/// The fixtures are produced by `ios/tools/gen-interop-fixtures.ts`, which
/// imports `frontend/src/lib/instantCrypto.ts` itself rather than restating the
/// algorithm. A fixture generator that reimplemented the crypto would agree with
/// a Swift port carrying the same misunderstanding — which is precisely the
/// failure these tests exist to catch.
@Suite("Crypto interop with the web client")
struct CryptoInteropTests {
    @Test("JS seals, Swift opens")
    func opensSingleDeviceFixture() throws {
        let fixture = try Fixtures.json("interop-single")
        let devices = fixture["devices"] as! [[String: Any]]
        let envelopes = fixture["envelopes"] as! [[String: Any]]
        let identity = try Fixtures.device(devices[0])

        #expect(identity.publicKeyBase64 == devices[0]["publicKey"] as! String)

        let plaintext = try InstantCrypto.open(
            ciphertext: try Fixtures.b64(fixture["ciphertext"] as! String),
            instant: Fixtures.openable(fixture, envelope: envelopes[0]),
            device: identity
        )
        #expect(plaintext == (try Fixtures.b64(fixture["plaintext"] as! String)))
        #expect(plaintext.count == 4096)
    }

    @Test("Every device opens its own envelope and no one else's")
    func multiDeviceEnvelopesAreBoundToTheirDevice() throws {
        let fixture = try Fixtures.json("interop-multi")
        let devices = try (fixture["devices"] as! [[String: Any]]).map {
            (identity: try Fixtures.device($0), id: $0["id"] as! Int)
        }
        let envelopes = fixture["envelopes"] as! [[String: Any]]
        let ciphertext = try Fixtures.b64(fixture["ciphertext"] as! String)
        let expected = try Fixtures.b64(fixture["plaintext"] as! String)

        for entry in devices {
            let envelope = envelopes.first { $0["deviceKeyId"] as! Int == entry.id }!
            let plaintext = try InstantCrypto.open(
                ciphertext: ciphertext,
                instant: Fixtures.openable(fixture, envelope: envelope),
                device: entry.identity
            )
            #expect(plaintext == expected)
        }

        // Binding the deviceId into the HKDF info is what makes this fail.
        let foreign = envelopes.first { $0["deviceKeyId"] as! Int == devices[1].id }!
        #expect(throws: (any Error).self) {
            _ = try InstantCrypto.open(
                ciphertext: ciphertext,
                instant: Fixtures.openable(fixture, envelope: foreign),
                device: devices[0].identity
            )
        }
    }

    @Test("Swift seals, the web client opens")
    func opensSwiftSealedFixture() throws {
        // ios/tools/verify-swift-fixtures.ts proves the JS side opens this exact
        // file; this asserts the fixture is still self-consistent, so a change
        // to the Swift crypto cannot pass without regenerating it.
        let fixture = try Fixtures.json("swift-sealed")
        let devices = try (fixture["devices"] as! [[String: Any]]).map {
            (identity: try Fixtures.device($0), id: $0["id"] as! Int)
        }
        let envelopes = fixture["envelopes"] as! [[String: Any]]
        let expected = try Fixtures.b64(fixture["plaintext"] as! String)

        for entry in devices {
            let envelope = envelopes.first { $0["deviceKeyId"] as! Int == entry.id }!
            let plaintext = try InstantCrypto.open(
                ciphertext: try Fixtures.b64(fixture["ciphertext"] as! String),
                instant: Fixtures.openable(fixture, envelope: envelope),
                device: entry.identity
            )
            #expect(plaintext == expected)
        }
    }

    @Test("ECDH and HKDF match WebCrypto step for step")
    func keyAgreementMatches() throws {
        let fixture = try Fixtures.json("interop-hkdf")
        let raw = fixture["device"] as! [String: Any]
        let deviceId = raw["deviceId"] as! String
        let senderUserId = fixture["senderUserId"] as! Int

        let ephemeral = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: try Fixtures.b64(fixture["ephemeralPrivateKeyRaw"] as! String)
        )
        let devicePublic = try P256.KeyAgreement.PublicKey(
            x963Representation: try Fixtures.b64(raw["publicKey"] as! String)
        )
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: devicePublic)

        #expect(
            shared.withUnsafeBytes { Data($0) }
                == (try Fixtures.b64(fixture["sharedSecret"] as! String))
        )
        #expect(
            InstantCrypto.hkdfInfo(senderUserId: senderUserId, recipientDeviceId: deviceId)
                == (try Fixtures.b64(fixture["hkdfInfoUtf8"] as! String))
        )

        let ephemeralPublicRaw = try Fixtures.b64(fixture["ephemeralPubKey"] as! String)
        let derived = InstantCrypto.deriveWrappingKey(
            agreement: shared,
            ephemeralPublicKeyRaw: ephemeralPublicRaw,
            senderUserId: senderUserId,
            recipientDeviceId: deviceId
        )
        #expect(
            derived.withUnsafeBytes { Data($0) }
                == (try Fixtures.b64(fixture["expectedWrappingKey"] as! String))
        )
    }

    /// Both of these produce a plausible-looking key that decrypts nothing, and
    /// neither raises an error at the point of the mistake. Asserting the
    /// difference is detectable is the only way to know the fixture above is
    /// actually pinning something.
    @Test("The salt is the raw key bytes, not their base64url text")
    func saltMustBeRawBytes() throws {
        let fixture = try Fixtures.json("interop-hkdf")
        let raw = fixture["device"] as! [String: Any]
        let ephemeral = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: try Fixtures.b64(fixture["ephemeralPrivateKeyRaw"] as! String)
        )
        let shared = try ephemeral.sharedSecretFromKeyAgreement(
            with: try P256.KeyAgreement.PublicKey(
                x963Representation: try Fixtures.b64(raw["publicKey"] as! String)
            )
        )
        let text = fixture["ephemeralPubKey"] as! String
        let wrong = InstantCrypto.deriveWrappingKey(
            agreement: shared,
            ephemeralPublicKeyRaw: Data(text.utf8),
            senderUserId: fixture["senderUserId"] as! Int,
            recipientDeviceId: raw["deviceId"] as! String
        )
        #expect(
            wrong.withUnsafeBytes { Data($0) }
                != (try Fixtures.b64(fixture["expectedWrappingKey"] as! String))
        )
    }

    @Test("deviceId case is load-bearing")
    func deviceIdCaseMatters() throws {
        let fixture = try Fixtures.json("interop-hkdf")
        let raw = fixture["device"] as! [String: Any]
        let deviceId = raw["deviceId"] as! String
        #expect(deviceId == deviceId.lowercased(), "the web client generates lowercase UUIDs")

        let ephemeral = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: try Fixtures.b64(fixture["ephemeralPrivateKeyRaw"] as! String)
        )
        let shared = try ephemeral.sharedSecretFromKeyAgreement(
            with: try P256.KeyAgreement.PublicKey(
                x963Representation: try Fixtures.b64(raw["publicKey"] as! String)
            )
        )
        let uppercased = InstantCrypto.deriveWrappingKey(
            agreement: shared,
            ephemeralPublicKeyRaw: try Fixtures.b64(fixture["ephemeralPubKey"] as! String),
            senderUserId: fixture["senderUserId"] as! Int,
            recipientDeviceId: deviceId.uppercased()
        )
        #expect(
            uppercased.withUnsafeBytes { Data($0) }
                != (try Fixtures.b64(fixture["expectedWrappingKey"] as! String))
        )
    }

    @Test("Round-trips media of every awkward size")
    func roundTripsAcrossSizes() throws {
        let key = P256.KeyAgreement.PrivateKey()
        let identity = DeviceIdentity(deviceId: UUID().uuidString.lowercased(), backing: .software(key))
        let recipient = InstantCrypto.RecipientDeviceKey(
            id: 1, deviceId: identity.deviceId, publicKey: identity.publicKeyBase64
        )

        for size in [1, 15, 16, 17, 4096, 250_000] {
            let media = Data((0..<size).map { UInt8($0 % 251) })
            let sealed = try InstantCrypto.seal(media: media, senderUserId: 9, devices: [recipient])
            #expect(sealed.ciphertext.count == size + InstantCrypto.tagBytes)

            let opened = try InstantCrypto.open(
                ciphertext: sealed.ciphertext,
                instant: InstantCrypto.OpenableInstant(
                    mediaIv: sealed.mediaIv,
                    ephemeralPubKey: sealed.ephemeralPubKey,
                    senderId: 9,
                    envelopeWrappedKey: sealed.envelopes[0].wrappedKey,
                    envelopeWrapIv: sealed.envelopes[0].wrapIv
                ),
                device: identity
            )
            #expect(opened == media)
        }
    }

    @Test("A wrapped content key is 48 bytes on the wire")
    func wrappedKeyLength() throws {
        let key = P256.KeyAgreement.PrivateKey()
        let identity = DeviceIdentity(deviceId: UUID().uuidString.lowercased(), backing: .software(key))
        let sealed = try InstantCrypto.seal(
            media: Data("hello".utf8),
            senderUserId: 1,
            devices: [InstantCrypto.RecipientDeviceKey(
                id: 1, deviceId: identity.deviceId, publicKey: identity.publicKeyBase64
            )]
        )
        // 32-byte content key + 16-byte tag.
        #expect(Base64URL.decode(sealed.envelopes[0].wrappedKey)?.count == 48)
        #expect(Base64URL.decode(sealed.envelopes[0].wrapIv)?.count == 12)
        #expect(Base64URL.decode(sealed.mediaIv)?.count == 12)
        #expect(Base64URL.decode(sealed.ephemeralPubKey)?.count == 65)
    }

    @Test("Tampered ciphertext is rejected")
    func tamperedCiphertextFails() throws {
        let key = P256.KeyAgreement.PrivateKey()
        let identity = DeviceIdentity(deviceId: UUID().uuidString.lowercased(), backing: .software(key))
        let sealed = try InstantCrypto.seal(
            media: Data(repeating: 7, count: 64),
            senderUserId: 3,
            devices: [InstantCrypto.RecipientDeviceKey(
                id: 1, deviceId: identity.deviceId, publicKey: identity.publicKeyBase64
            )]
        )
        // Index from startIndex, not 0: Data sliced out of a larger buffer keeps
        // the parent's indices, and subscripting it at 0 traps.
        var corrupted = sealed.ciphertext
        corrupted[corrupted.startIndex] ^= 0xFF

        #expect(throws: InstantCrypto.CryptoError.decryptionFailed) {
            _ = try InstantCrypto.open(
                ciphertext: corrupted,
                instant: InstantCrypto.OpenableInstant(
                    mediaIv: sealed.mediaIv,
                    ephemeralPubKey: sealed.ephemeralPubKey,
                    senderId: 3,
                    envelopeWrappedKey: sealed.envelopes[0].wrappedKey,
                    envelopeWrapIv: sealed.envelopes[0].wrapIv
                ),
                device: identity
            )
        }
    }

    @Test("Sealing for nobody is an error, not an empty envelope list")
    func refusesEmptyRecipients() {
        #expect(throws: InstantCrypto.CryptoError.noRecipientDevices) {
            _ = try InstantCrypto.seal(media: Data("x".utf8), senderUserId: 1, devices: [])
        }
    }

    @Test("One seal, many envelopes, one ciphertext")
    func sealsOnceForManyDevices() throws {
        let identities = (0..<3).map { _ in
            DeviceIdentity(
                deviceId: UUID().uuidString.lowercased(),
                backing: .software(P256.KeyAgreement.PrivateKey())
            )
        }
        let media = Data(repeating: 42, count: 512)
        let sealed = try InstantCrypto.seal(
            media: media,
            senderUserId: 5,
            devices: identities.enumerated().map { index, identity in
                InstantCrypto.RecipientDeviceKey(
                    id: index + 1, deviceId: identity.deviceId, publicKey: identity.publicKeyBase64
                )
            }
        )

        #expect(sealed.envelopes.count == 3)
        #expect(Set(sealed.envelopes.map(\.deviceKeyId)) == [1, 2, 3])
        // The photo is encrypted once no matter how many devices receive it.
        #expect(sealed.ciphertext.count == media.count + InstantCrypto.tagBytes)

        for (index, identity) in identities.enumerated() {
            let opened = try InstantCrypto.open(
                ciphertext: sealed.ciphertext,
                instant: InstantCrypto.OpenableInstant(
                    mediaIv: sealed.mediaIv,
                    ephemeralPubKey: sealed.ephemeralPubKey,
                    senderId: 5,
                    envelopeWrappedKey: sealed.envelopes[index].wrappedKey,
                    envelopeWrapIv: sealed.envelopes[index].wrapIv
                ),
                device: identity
            )
            #expect(opened == media)
        }
    }

    @Test("A different sender id cannot open the envelope")
    func senderIdIsBoundIn() throws {
        let identity = DeviceIdentity(
            deviceId: UUID().uuidString.lowercased(),
            backing: .software(P256.KeyAgreement.PrivateKey())
        )
        let sealed = try InstantCrypto.seal(
            media: Data("secret".utf8),
            senderUserId: 11,
            devices: [InstantCrypto.RecipientDeviceKey(
                id: 1, deviceId: identity.deviceId, publicKey: identity.publicKeyBase64
            )]
        )
        #expect(throws: InstantCrypto.CryptoError.decryptionFailed) {
            _ = try InstantCrypto.open(
                ciphertext: sealed.ciphertext,
                instant: InstantCrypto.OpenableInstant(
                    mediaIv: sealed.mediaIv,
                    ephemeralPubKey: sealed.ephemeralPubKey,
                    senderId: 12,
                    envelopeWrappedKey: sealed.envelopes[0].wrappedKey,
                    envelopeWrapIv: sealed.envelopes[0].wrapIv
                ),
                device: identity
            )
        }
    }

    @Test("Malformed base64 is reported, not crashed on")
    func rejectsMalformedInput() throws {
        let identity = DeviceIdentity(
            deviceId: UUID().uuidString.lowercased(),
            backing: .software(P256.KeyAgreement.PrivateKey())
        )
        #expect(throws: InstantCrypto.CryptoError.malformedBase64("ephemeralPubKey")) {
            _ = try InstantCrypto.open(
                ciphertext: Data(),
                instant: InstantCrypto.OpenableInstant(
                    mediaIv: "AA", ephemeralPubKey: "not valid base64!",
                    senderId: 1, envelopeWrappedKey: "AA", envelopeWrapIv: "AA"
                ),
                device: identity
            )
        }
    }
}
