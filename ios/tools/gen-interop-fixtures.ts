// Generates the crypto interop fixtures the Swift tests assert against.
//
// This imports the REAL web implementation — frontend/src/lib/instantCrypto.ts,
// unmodified — rather than restating its algorithm here. A fixture generator
// that reimplemented the crypto would happily agree with a Swift port that had
// the same bug in it, which is exactly what these fixtures exist to catch.
//
//   cd backend && npx tsx ../ios/tools/gen-interop-fixtures.ts
//
// Node 20 provides crypto.subtle, Blob, btoa/atob and TextEncoder, and
// instantKeystore.ts touches IndexedDB only inside functions we never call, so
// the module imports cleanly outside a browser.

import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
    sealForDevices,
    safetyNumber,
    fingerprintKeys,
    INSTANT_CRYPTO_VERSION,
    type RecipientDeviceKey,
} from "../../frontend/src/lib/instantCrypto";
import { toBase64Url, fromBase64Url } from "../../frontend/src/lib/instantKeystore";

const OUT_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "InstantTests", "Fixtures");

type FixtureDevice = {
    id: number;
    deviceId: string;
    publicKey: string;
    // Raw 32-byte P-256 scalar, base64url. CryptoKit reads this as
    // P256.KeyAgreement.PrivateKey(rawRepresentation:).
    privateKeyRaw: string;
};

// An extractable keypair, so the fixture can hand the private scalar to Swift.
// The app itself always generates non-extractable keys; this is a test-only
// concession and never leaves this file.
async function makeDevice(id: number): Promise<{ fixture: FixtureDevice; key: CryptoKey }> {
    const pair = await crypto.subtle.generateKey(
        { name: "ECDH", namedCurve: "P-256" },
        true,
        ["deriveBits", "deriveKey"]
    );
    const jwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
    const raw = await crypto.subtle.exportKey("raw", pair.publicKey);
    return {
        key: pair.privateKey,
        fixture: {
            id,
            deviceId: crypto.randomUUID(),
            publicKey: toBase64Url(raw),
            privateKeyRaw: jwk.d as string,
        },
    };
}

function toDeviceKey(device: FixtureDevice): RecipientDeviceKey {
    return { id: device.id, deviceId: device.deviceId, publicKey: device.publicKey };
}

// Deterministic bytes, so a diff on the fixture is readable.
function plaintext(length: number): Uint8Array {
    const bytes = new Uint8Array(length);
    for (let i = 0; i < length; i += 1) {
        bytes[i] = (i * 37 + 11) % 256;
    }
    return bytes;
}

async function sealed(devices: FixtureDevice[], senderUserId: number, size: number) {
    const media = plaintext(size);
    const result = await sealForDevices(
        new Blob([media]),
        senderUserId,
        devices.map(toDeviceKey)
    );
    return {
        senderUserId,
        plaintext: toBase64Url(media),
        devices,
        ciphertext: toBase64Url(result.ciphertext),
        mediaIv: result.mediaIv,
        ephemeralPubKey: result.ephemeralPubKey,
        envelopes: result.envelopes,
    };
}

// The HKDF step in isolation, using the same parameters deriveWrappingKey uses.
// deriveWrappingKey itself produces a non-extractable key, so this re-runs the
// derivation with deriveBits to get something assertable. A mismatch here says
// "salt or info is wrong"; a mismatch only in the sealed fixtures says the error
// is elsewhere.
async function hkdfVectors() {
    const { fixture: device, key: devicePrivate } = await makeDevice(1);
    const ephemeral = await crypto.subtle.generateKey(
        { name: "ECDH", namedCurve: "P-256" },
        true,
        ["deriveBits"]
    );
    const ephemeralPublicRaw = new Uint8Array(
        await crypto.subtle.exportKey("raw", ephemeral.publicKey)
    );
    const ephemeralJwk = await crypto.subtle.exportKey("jwk", ephemeral.privateKey);

    const senderUserId = 4242;
    const devicePublic = await crypto.subtle.importKey(
        "raw",
        fromBase64Url(device.publicKey),
        { name: "ECDH", namedCurve: "P-256" },
        true,
        []
    );

    const sharedBits = await crypto.subtle.deriveBits(
        { name: "ECDH", public: devicePublic },
        ephemeral.privateKey,
        256
    );
    const hkdfSource = await crypto.subtle.importKey("raw", sharedBits, "HKDF", false, [
        "deriveBits",
    ]);
    const info = new TextEncoder().encode(
        `${INSTANT_CRYPTO_VERSION}|${senderUserId}|${device.deviceId}`
    );
    const wrappingKey = await crypto.subtle.deriveBits(
        { name: "HKDF", hash: "SHA-256", salt: ephemeralPublicRaw, info },
        hkdfSource,
        256
    );

    return {
        senderUserId,
        device,
        ephemeralPubKey: toBase64Url(ephemeralPublicRaw),
        ephemeralPrivateKeyRaw: ephemeralJwk.d as string,
        sharedSecret: toBase64Url(sharedBits),
        hkdfInfoUtf8: toBase64Url(info),
        expectedWrappingKey: toBase64Url(wrappingKey),
    };
}

// The sort order inside safetyNumber is JS UTF-16 code-unit order, which Swift's
// default String sort does not reproduce. These keys are chosen to straddle the
// characters where the two orderings disagree: '-' (0x2D), digits, uppercase,
// '_' (0x5F) and lowercase.
async function safetyVectors() {
    const sets = [
        { mine: ["-aaa", "Zbbb", "_ccc", "aaaa", "0ddd"], theirs: ["zzz", "AAA", "-_-"] },
        { mine: ["AQIDBA"], theirs: ["BQYHCA"] },
        { mine: ["a", "B", "-", "_", "9"], theirs: ["a", "B", "-", "_", "9"] },
    ];
    const vectors = [];
    for (const set of sets) {
        vectors.push({
            ...set,
            safetyNumber: await safetyNumber(
                set.mine.map((publicKey) => ({ publicKey })),
                set.theirs.map((publicKey) => ({ publicKey }))
            ),
            mineFingerprint: await fingerprintKeys(set.mine.map((publicKey) => ({ publicKey }))),
            theirsFingerprint: await fingerprintKeys(set.theirs.map((publicKey) => ({ publicKey }))),
        });
    }
    return vectors;
}

async function main() {
    const single = await makeDevice(101);
    const trio = [await makeDevice(201), await makeDevice(202), await makeDevice(203)];

    const files: Record<string, unknown> = {
        "interop-single.json": {
            note: "Sealed by frontend/src/lib/instantCrypto.ts. Swift must open it and recover `plaintext` exactly.",
            ...(await sealed([single.fixture], 7, 4096)),
        },
        "interop-multi.json": {
            note: "One seal, three devices. Each opens its own envelope; any other device's envelope must fail against it.",
            ...(await sealed(trio.map((entry) => entry.fixture), 31337, 1024)),
        },
        "interop-hkdf.json": {
            note: "The key-agreement step in isolation, to localize a salt/info mistake.",
            version: INSTANT_CRYPTO_VERSION,
            ...(await hkdfVectors()),
        },
        "interop-safety.json": {
            note: "Safety numbers and fingerprints. These are what catch the JS-vs-Swift sort-order difference.",
            vectors: await safetyVectors(),
        },
    };

    for (const [name, body] of Object.entries(files)) {
        writeFileSync(join(OUT_DIR, name), `${JSON.stringify(body, null, 2)}\n`);
        console.log(`wrote ${name}`);
    }
}

void main();
