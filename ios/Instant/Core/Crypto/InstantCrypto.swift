import CryptoKit
import Foundation

// Instant's ECIES envelope.
//
// ===========================================================================
// INTEROP CONTRACT — this must match frontend/src/lib/instantCrypto.ts byte for
// byte. That file holds the authoritative copy of the comment below.
//
//   Device keypair   ECDH P-256. Chosen over X25519 because P-256 is the only
//                    curve the iOS Secure Enclave supports.
//   Content key      AES-256-GCM, random 12-byte IV, 128-bit tag appended to
//                    the ciphertext (WebCrypto's default layout).
//   Key wrapping     One ephemeral P-256 keypair per message. Per recipient
//                    device: ECDH(ephemeral_priv, device_pub) -> 256 raw bits
//                    -> HKDF-SHA256 -> 256-bit wrapping key -> AES-256-GCM
//                    over the raw 32-byte content key, with its own 12-byte IV.
//   HKDF salt        The raw uncompressed ephemeral public key (65 bytes).
//   HKDF info        UTF-8 "eddies-lounge/instant/v1|<senderUserId>|<recipientDeviceId>"
//   Encoding         Raw uncompressed P-256 points (x963Representation) and all
//                    blobs as unpadded base64url.
//
// Three details are easy to get wrong and fail silently:
//
//   * The HKDF salt is the raw 65 key bytes, NOT the base64url text of them.
//   * WebCrypto emits `ciphertext || tag16` and carries the nonce separately,
//     so `AES.GCM.SealedBox.combined` (which prepends the nonce) is the wrong
//     shape. Split and rejoin explicitly.
//   * `recipientDeviceId` is a lowercase UUID. `UUID().uuidString` is uppercase
//     and would change the info string, producing envelopes nobody can open.
// ===========================================================================

public enum InstantCrypto {
    public static let version = "eddies-lounge/instant/v1"

    static let ivBytes = 12
    static let contentKeyBytes = 32
    static let tagBytes = 16

    // MARK: - Wire types

    /// One recipient device from `GET /api/v1/instant/keys/:userId`.
    public struct RecipientDeviceKey: Sendable, Equatable {
        public let id: Int
        public let deviceId: String
        public let publicKey: String

        public init(id: Int, deviceId: String, publicKey: String) {
            self.id = id
            self.deviceId = deviceId
            self.publicKey = publicKey
        }
    }

    /// One wrapped copy of the content key, addressed to a single device.
    public struct SealedEnvelope: Sendable, Equatable {
        public let deviceKeyId: Int
        public let wrappedKey: String
        public let wrapIv: String

        public init(deviceKeyId: Int, wrappedKey: String, wrapIv: String) {
            self.deviceKeyId = deviceKeyId
            self.wrappedKey = wrappedKey
            self.wrapIv = wrapIv
        }
    }

    public struct SealedInstant: Sendable, Equatable {
        public let ciphertext: Data
        public let mediaIv: String
        public let ephemeralPubKey: String
        public let envelopes: [SealedEnvelope]
    }

    /// Everything `open` needs that is not the ciphertext itself.
    public struct OpenableInstant: Sendable, Equatable {
        public let mediaIv: String
        public let ephemeralPubKey: String
        public let senderId: Int
        public let envelopeWrappedKey: String
        public let envelopeWrapIv: String

        public init(
            mediaIv: String,
            ephemeralPubKey: String,
            senderId: Int,
            envelopeWrappedKey: String,
            envelopeWrapIv: String
        ) {
            self.mediaIv = mediaIv
            self.ephemeralPubKey = ephemeralPubKey
            self.senderId = senderId
            self.envelopeWrappedKey = envelopeWrappedKey
            self.envelopeWrapIv = envelopeWrapIv
        }
    }

    public enum CryptoError: Error, Equatable {
        case noRecipientDevices
        case malformedBase64(String)
        case malformedPublicKey
        case malformedCiphertext
        case decryptionFailed
    }

    // MARK: - Key agreement

    /// The exact bytes WebCrypto passes as HKDF `info`.
    static func hkdfInfo(senderUserId: Int, recipientDeviceId: String) -> Data {
        Data("\(version)|\(senderUserId)|\(recipientDeviceId)".utf8)
    }

    /// ECDH + HKDF. Both sides run this and land on the same 256-bit AES key.
    ///
    /// The sender agrees `ephemeral_priv` with `device_pub`; the recipient
    /// agrees `device_priv` with `ephemeral_pub`. Either way the salt is the
    /// ephemeral public key and the info names the *receiving* device.
    static func deriveWrappingKey(
        agreement: SharedSecret,
        ephemeralPublicKeyRaw: Data,
        senderUserId: Int,
        recipientDeviceId: String
    ) -> SymmetricKey {
        agreement.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeralPublicKeyRaw,
            sharedInfo: hkdfInfo(senderUserId: senderUserId, recipientDeviceId: recipientDeviceId),
            outputByteCount: 32
        )
    }

    // MARK: - AES-GCM in WebCrypto's layout

    /// Encrypts to `ciphertext || tag`, with the nonce returned separately —
    /// which is what WebCrypto's `crypto.subtle.encrypt` produces.
    static func sealDetached(_ plaintext: Data, key: SymmetricKey, nonce: Data) throws -> Data {
        let box = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: try AES.GCM.Nonce(data: nonce)
        )
        return box.ciphertext + box.tag
    }

    /// Inverse of `sealDetached`: splits the trailing 16-byte tag back off.
    static func openDetached(_ combined: Data, key: SymmetricKey, nonce: Data) throws -> Data {
        guard combined.count > tagBytes else { throw CryptoError.malformedCiphertext }
        let splitAt = combined.count - tagBytes
        let box = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonce),
            ciphertext: combined.prefix(splitAt),
            tag: combined.suffix(tagBytes)
        )
        return try AES.GCM.open(box, using: key)
    }

    static func randomIv() -> Data {
        var bytes = Data(count: ivBytes)
        bytes.withUnsafeMutableBytes { raw in
            _ = SecRandomCopyBytes(kSecRandomDefault, ivBytes, raw.baseAddress!)
        }
        return bytes
    }

    static func decodeRequired(_ value: String, label: String) throws -> Data {
        guard let data = Base64URL.decode(value) else {
            throw CryptoError.malformedBase64(label)
        }
        return data
    }

    // MARK: - Seal

    /// Encrypts the media once, then wraps the content key once per device.
    public static func seal(
        media: Data,
        senderUserId: Int,
        devices: [RecipientDeviceKey]
    ) throws -> SealedInstant {
        guard !devices.isEmpty else { throw CryptoError.noRecipientDevices }

        let contentKey = SymmetricKey(size: .bits256)
        let contentKeyBytes = contentKey.withUnsafeBytes { Data($0) }

        let mediaIv = randomIv()
        let ciphertext = try sealDetached(media, key: contentKey, nonce: mediaIv)

        let ephemeral = P256.KeyAgreement.PrivateKey()
        let ephemeralPublicRaw = ephemeral.publicKey.x963Representation

        var envelopes: [SealedEnvelope] = []
        envelopes.reserveCapacity(devices.count)

        for device in devices {
            let publicKeyData = try decodeRequired(device.publicKey, label: "publicKey")
            guard let devicePublicKey = try? P256.KeyAgreement.PublicKey(
                x963Representation: publicKeyData
            ) else {
                throw CryptoError.malformedPublicKey
            }

            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: devicePublicKey)
            let wrappingKey = deriveWrappingKey(
                agreement: shared,
                ephemeralPublicKeyRaw: ephemeralPublicRaw,
                senderUserId: senderUserId,
                recipientDeviceId: device.deviceId
            )

            let wrapIv = randomIv()
            let wrapped = try sealDetached(contentKeyBytes, key: wrappingKey, nonce: wrapIv)
            envelopes.append(
                SealedEnvelope(
                    deviceKeyId: device.id,
                    wrappedKey: Base64URL.encode(wrapped),
                    wrapIv: Base64URL.encode(wrapIv)
                )
            )
        }

        return SealedInstant(
            ciphertext: ciphertext,
            mediaIv: Base64URL.encode(mediaIv),
            ephemeralPubKey: Base64URL.encode(ephemeralPublicRaw),
            envelopes: envelopes
        )
    }

    // MARK: - Open

    /// Unwraps this device's envelope and decrypts the media.
    public static func open(
        ciphertext: Data,
        instant: OpenableInstant,
        device: DeviceIdentity
    ) throws -> Data {
        let ephemeralPublicRaw = try decodeRequired(instant.ephemeralPubKey, label: "ephemeralPubKey")
        guard let ephemeralPublicKey = try? P256.KeyAgreement.PublicKey(
            x963Representation: ephemeralPublicRaw
        ) else {
            throw CryptoError.malformedPublicKey
        }

        let shared = try device.sharedSecret(with: ephemeralPublicKey)
        let wrappingKey = deriveWrappingKey(
            agreement: shared,
            ephemeralPublicKeyRaw: ephemeralPublicRaw,
            senderUserId: instant.senderId,
            recipientDeviceId: device.deviceId
        )

        let wrapIv = try decodeRequired(instant.envelopeWrapIv, label: "wrapIv")
        let wrappedKey = try decodeRequired(instant.envelopeWrappedKey, label: "wrappedKey")

        let contentKeyBytes: Data
        do {
            contentKeyBytes = try openDetached(wrappedKey, key: wrappingKey, nonce: wrapIv)
        } catch {
            throw CryptoError.decryptionFailed
        }

        let mediaIv = try decodeRequired(instant.mediaIv, label: "mediaIv")
        do {
            return try openDetached(
                ciphertext,
                key: SymmetricKey(data: contentKeyBytes),
                nonce: mediaIv
            )
        } catch {
            throw CryptoError.decryptionFailed
        }
    }
}
