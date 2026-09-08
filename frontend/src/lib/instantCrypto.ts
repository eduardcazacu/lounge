// Instant's ECIES envelope.
//
// ===========================================================================
// INTEROP CONTRACT — the native iOS client must match this byte for byte.
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
//                    Binding the device id stops an envelope being replayed
//                    against a different device.
//   Encoding         Raw uncompressed P-256 points and all blobs as unpadded
//                    base64url.
//
// CryptoKit equivalent:
//   P256.KeyAgreement.PrivateKey
//     .sharedSecretFromKeyAgreement(with:)
//     .hkdfDerivedSymmetricKey(using: SHA256.self, salt:, sharedInfo:,
//                              outputByteCount: 32)
//   then AES.GCM.seal / AES.GCM.open
// ===========================================================================

import { fromBase64Url, toBase64Url, type InstantDevice } from "./instantKeystore";

export const INSTANT_CRYPTO_VERSION = "eddies-lounge/instant/v1";

const IV_BYTES = 12;
const CONTENT_KEY_BYTES = 32;

export type RecipientDeviceKey = {
  id: number;
  deviceId: string;
  publicKey: string;
};

export type SealedEnvelope = {
  deviceKeyId: number;
  wrappedKey: string;
  wrapIv: string;
};

export type SealedInstant = {
  ciphertext: ArrayBuffer;
  mediaIv: string;
  ephemeralPubKey: string;
  envelopes: SealedEnvelope[];
};

function hkdfInfo(senderUserId: number, recipientDeviceId: string): Uint8Array {
  return new TextEncoder().encode(
    `${INSTANT_CRYPTO_VERSION}|${senderUserId}|${recipientDeviceId}`
  );
}

function randomIv(): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(IV_BYTES));
}

async function importDevicePublicKey(publicKeyB64: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    fromBase64Url(publicKeyB64) as BufferSource,
    { name: "ECDH", namedCurve: "P-256" },
    true,
    []
  );
}

// ECDH + HKDF. Both sides run this and land on the same 256-bit AES key.
async function deriveWrappingKey(
  privateKey: CryptoKey,
  peerPublicKey: CryptoKey,
  ephemeralPublicKeyRaw: Uint8Array,
  senderUserId: number,
  recipientDeviceId: string
): Promise<CryptoKey> {
  const sharedBits = await crypto.subtle.deriveBits(
    { name: "ECDH", public: peerPublicKey },
    privateKey,
    256
  );
  const hkdfSource = await crypto.subtle.importKey("raw", sharedBits, "HKDF", false, [
    "deriveKey",
  ]);
  return crypto.subtle.deriveKey(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: ephemeralPublicKeyRaw as BufferSource,
      info: hkdfInfo(senderUserId, recipientDeviceId) as BufferSource,
    },
    hkdfSource,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"]
  );
}

// Encrypts once, then wraps the content key separately for each of the
// recipient's devices. The server sees only ciphertext and wrapped keys.
export async function sealForDevices(
  media: Blob,
  senderUserId: number,
  devices: RecipientDeviceKey[]
): Promise<SealedInstant> {
  if (devices.length === 0) {
    throw new Error("This person has not set up Instant on any device yet.");
  }

  const contentKeyBytes = crypto.getRandomValues(new Uint8Array(CONTENT_KEY_BYTES));
  const contentKey = await crypto.subtle.importKey(
    "raw",
    contentKeyBytes as BufferSource,
    { name: "AES-GCM" },
    false,
    ["encrypt"]
  );

  const mediaIv = randomIv();
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: mediaIv as BufferSource },
    contentKey,
    await media.arrayBuffer()
  );

  const ephemeral = await crypto.subtle.generateKey(
    { name: "ECDH", namedCurve: "P-256" },
    true,
    ["deriveBits", "deriveKey"]
  );
  const ephemeralPublicRaw = new Uint8Array(
    await crypto.subtle.exportKey("raw", ephemeral.publicKey)
  );

  const envelopes: SealedEnvelope[] = [];
  for (const device of devices) {
    const devicePublicKey = await importDevicePublicKey(device.publicKey);
    const wrappingKey = await deriveWrappingKey(
      ephemeral.privateKey,
      devicePublicKey,
      ephemeralPublicRaw,
      senderUserId,
      device.deviceId
    );
    const wrapIv = randomIv();
    const wrappedKey = await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: wrapIv as BufferSource },
      wrappingKey,
      contentKeyBytes as BufferSource
    );
    envelopes.push({
      deviceKeyId: device.id,
      wrappedKey: toBase64Url(wrappedKey),
      wrapIv: toBase64Url(wrapIv),
    });
  }

  // The plaintext content key never leaves this function.
  contentKeyBytes.fill(0);

  return {
    ciphertext,
    mediaIv: toBase64Url(mediaIv),
    ephemeralPubKey: toBase64Url(ephemeralPublicRaw),
    envelopes,
  };
}

export type OpenableInstant = {
  mediaIv: string;
  ephemeralPubKey: string;
  senderId: number;
  mediaType: string;
  envelope: { wrappedKey: string; wrapIv: string };
};

export async function openInstant(
  ciphertext: ArrayBuffer,
  instant: OpenableInstant,
  device: InstantDevice
): Promise<Blob> {
  const ephemeralPublicRaw = fromBase64Url(instant.ephemeralPubKey);
  const ephemeralPublicKey = await crypto.subtle.importKey(
    "raw",
    ephemeralPublicRaw as BufferSource,
    { name: "ECDH", namedCurve: "P-256" },
    true,
    []
  );

  const wrappingKey = await deriveWrappingKey(
    device.privateKey,
    ephemeralPublicKey,
    ephemeralPublicRaw,
    instant.senderId,
    device.deviceId
  );

  const contentKeyBytes = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: fromBase64Url(instant.envelope.wrapIv) as BufferSource },
    wrappingKey,
    fromBase64Url(instant.envelope.wrappedKey) as BufferSource
  );

  const contentKey = await crypto.subtle.importKey(
    "raw",
    contentKeyBytes,
    { name: "AES-GCM" },
    false,
    ["decrypt"]
  );

  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: fromBase64Url(instant.mediaIv) as BufferSource },
    contentKey,
    ciphertext
  );

  return new Blob([plaintext], { type: instant.mediaType || "image/webp" });
}

// A safety number both people can read aloud to check the server did not
// substitute a key. Order-independent so both sides see the same digits.
export async function safetyNumber(
  myKeys: { publicKey: string }[],
  theirKeys: { publicKey: string }[]
): Promise<string> {
  const material = [...myKeys, ...theirKeys]
    .map((key) => key.publicKey)
    .sort()
    .join("|");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(material));
  const bytes = new Uint8Array(digest);

  const groups: string[] = [];
  for (let i = 0; i < 12; i += 1) {
    // Five digits per group, from a 16-bit slice of the digest.
    const chunk = ((bytes[i * 2] << 8) | bytes[i * 2 + 1]) % 100000;
    groups.push(chunk.toString().padStart(5, "0"));
  }
  return groups.join(" ");
}

// The fingerprint of just one side, for detecting when someone's keys change.
export async function fingerprintKeys(keys: { publicKey: string }[]): Promise<string> {
  const material = keys
    .map((key) => key.publicKey)
    .sort()
    .join("|");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(material));
  return toBase64Url(digest);
}
