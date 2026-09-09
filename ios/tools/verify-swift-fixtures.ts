// The other half of the interop check: opens the Swift-sealed fixture with the
// REAL web implementation.
//
//   cd backend && npx tsx ../ios/tools/verify-swift-fixtures.ts
//
// Regenerate the fixture first with ios/tools/run-interop.sh. Checking only the
// JS -> Swift direction would miss a Swift *sender* that produces envelopes the
// web client cannot open, which is the failure that would strand real photos.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { openInstant } from "../../frontend/src/lib/instantCrypto";
import { fromBase64Url, type InstantDevice } from "../../frontend/src/lib/instantKeystore";

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "..", "InstantTests", "Fixtures");

type FixtureDevice = { id: number; deviceId: string; publicKey: string; privateKeyRaw: string };

function b64(bytes: Uint8Array): string {
    return Buffer.from(bytes).toString("base64url");
}

// The fixture carries the raw 32-byte scalar plus the uncompressed public point;
// WebCrypto wants those as JWK coordinates.
async function importDevice(device: FixtureDevice): Promise<InstantDevice> {
    const point = fromBase64Url(device.publicKey);
    if (point.length !== 65 || point[0] !== 0x04) {
        throw new Error(`Expected a 65-byte uncompressed P-256 point, got ${point.length}`);
    }
    const jwk: JsonWebKey = {
        kty: "EC",
        crv: "P-256",
        d: device.privateKeyRaw,
        x: b64(point.subarray(1, 33)),
        y: b64(point.subarray(33, 65)),
        ext: true,
    };
    const privateKey = await crypto.subtle.importKey(
        "jwk",
        jwk,
        { name: "ECDH", namedCurve: "P-256" },
        false,
        ["deriveBits", "deriveKey"]
    );
    const publicKey = await crypto.subtle.importKey(
        "raw",
        point as BufferSource,
        { name: "ECDH", namedCurve: "P-256" },
        true,
        []
    );
    return { deviceId: device.deviceId, publicKeyB64: device.publicKey, privateKey, publicKey };
}

let failures = 0;
function check(label: string, ok: boolean) {
    console.log(`  ${ok ? "ok  " : "FAIL"} ${label}`);
    if (!ok) failures += 1;
}

async function main() {
    const fixture = JSON.parse(
        readFileSync(join(FIXTURES, "swift-sealed.json"), "utf8")
    ) as {
        senderUserId: number;
        plaintext: string;
        devices: FixtureDevice[];
        ciphertext: string;
        mediaIv: string;
        ephemeralPubKey: string;
        envelopes: { deviceKeyId: number; wrappedKey: string; wrapIv: string }[];
    };

    const expected = Buffer.from(fromBase64Url(fixture.plaintext));
    const ciphertext = fromBase64Url(fixture.ciphertext);

    console.log("\nswift-sealed.json — Swift seals, the web client opens");

    for (const device of fixture.devices) {
        const envelope = fixture.envelopes.find((entry) => entry.deviceKeyId === device.id)!;
        const imported = await importDevice(device);
        const blob = await openInstant(
            ciphertext.buffer.slice(
                ciphertext.byteOffset,
                ciphertext.byteOffset + ciphertext.byteLength
            ) as ArrayBuffer,
            {
                mediaIv: fixture.mediaIv,
                ephemeralPubKey: fixture.ephemeralPubKey,
                senderId: fixture.senderUserId,
                mediaType: "image/webp",
                envelope: { wrappedKey: envelope.wrappedKey, wrapIv: envelope.wrapIv },
            },
            imported
        );
        const actual = Buffer.from(await blob.arrayBuffer());
        check(`device ${device.id} opens its envelope`, actual.equals(expected));
    }

    // Cross-device rejection, in this direction too.
    const [first, second] = fixture.devices;
    const foreign = fixture.envelopes.find((entry) => entry.deviceKeyId === second.id)!;
    let rejected = false;
    try {
        await openInstant(
            ciphertext.buffer.slice(
                ciphertext.byteOffset,
                ciphertext.byteOffset + ciphertext.byteLength
            ) as ArrayBuffer,
            {
                mediaIv: fixture.mediaIv,
                ephemeralPubKey: fixture.ephemeralPubKey,
                senderId: fixture.senderUserId,
                mediaType: "image/webp",
                envelope: { wrappedKey: foreign.wrappedKey, wrapIv: foreign.wrapIv },
            },
            await importDevice(first)
        );
    } catch {
        rejected = true;
    }
    check(`device ${first.id} cannot open device ${second.id}'s envelope`, rejected);

    console.log(failures === 0 ? "\nall checks passed" : `\n${failures} check(s) failed`);
    if (failures > 0) process.exit(1);
}

void main();
