# The Instant protocol

An expiring photo, sealed so that only the recipient's own devices can open it.
This page is the contract and the threat model. Delivery, expiry and streaks are
in [instant-runtime.md](instant-runtime.md).

**Read [gotchas.md](gotchas.md) alongside this one before touching any of it.**
Every mistake available here fails *silently*: the envelope is produced, the
upload succeeds, nothing errors, and the photo is simply unopenable forever.

## Where the contract actually lives

The authoritative statement is the header comment of
**`frontend/src/lib/instantCrypto.ts`**. It is restated in
`ios/Instant/Core/Crypto/InstantCrypto.swift`, and it is *pinned* by committed
fixtures. Do not treat this page as the source — if this page and that comment
disagree, the comment wins and this page is a bug.

Summarised, so you know whether you need to open it:

- Device keypair is **ECDH P-256**.
- Content key is **AES-256-GCM**, random 12-byte IV, 128-bit tag appended to the
  ciphertext (WebCrypto's layout).
- One ephemeral P-256 keypair per message. Per recipient device,
  `ECDH(ephemeral_priv, device_pub)` → HKDF-SHA256 → a 256-bit wrapping key,
  which wraps the raw 32-byte content key under its own 12-byte IV.
- **HKDF salt** is the raw uncompressed ephemeral public key — 65 bytes, not its
  base64url text.
- **HKDF info** is `eddies-lounge/instant/v1|<senderUserId>|<recipientDeviceId>`,
  which binds an envelope to one device and stops it being replayed against
  another.
- Everything on the wire is **unpadded base64url**. The server rejects padding
  with a 400.

## Why P-256

X25519 is the better curve and it lost anyway. **P-256 is the only curve the iOS
Secure Enclave supports**, and a private key that cannot leave the Enclave is
the entire point of shipping a native app. Every other consideration was
downstream of that.

This is the single most load-bearing decision in the repo, and it was made for
an app that did not exist yet.

## What enforces it

Three commands, and they are the reason ports do not silently diverge:

```bash
cd backend && npx tsx ../ios/tools/gen-interop-fixtures.ts   # JS seals
ios/tools/run-interop.sh                                     # Swift opens, and seals
cd backend && npx tsx ../ios/tools/verify-swift-fixtures.ts  # JS opens
```

The generators **import `frontend/src/lib/instantCrypto.ts` itself** rather than
restating the algorithm. This is deliberate and it is the whole trick: a
generator that reimplemented the crypto would happily agree with a Swift port
carrying exactly the same misunderstanding, which is the failure these exist to
catch.

`run-interop.sh` compiles the real app sources on the host with `swiftc` and
finishes in about a second — no Simulator, no Xcode — which is why it is worth
running alongside the full test suite rather than instead of it. The fixtures
themselves are committed under `ios/InstantTests/Fixtures/`.

## Identity and devices

A device generates its own keypair and registers the public half. At most **10
devices per user**, evicted least-recently-seen by `lastSeenAt`.

- **Browser** — `frontend/src/lib/instantKeystore.ts`. P-256 generated
  **non-extractable**, stored as a live `CryptoKey` in IndexedDB, keyed per
  account (`device:<userId>`) so two people signing in on one browser never
  share an identity. `isPrivateKeyNonExtractable` is surfaced in the UI so the
  guarantee is checkable rather than merely claimed.
- **iOS** — `ios/Instant/Core/Crypto/DeviceIdentity.swift`. Secure Enclave when
  available, software P-256 otherwise, and which one is shown in Settings. The
  key lives in the Keychain as `ThisDeviceOnly` so it never rides an iCloud
  backup.

The `deviceId` is a **lowercase** UUID on both sides, because it is inside the
HKDF info string and `UUID().uuidString` is uppercase. See
[gotchas.md](gotchas.md).

### There is no key recovery

Clearing site data, switching browsers, Safari evicting IndexedDB after roughly
seven idle days, or reinstalling the app — each mints a new identity, and
anything already wrapped to the old key becomes permanently unopenable. Clients
report those to `POST /api/v1/instant/:id/undecryptable` so the server stops
holding ciphertext nobody can read.

This is the design, not a gap. Recovery means an escrowed key, and an escrowed
key means the server can read photos.

## Safety numbers

The server publishes everybody's public keys, so the server could publish its
own instead. The only real mitigation is out-of-band comparison, which is what
the safety number is for: a SHA-256 over the two sides' sorted, joined public
keys, rendered as 12 groups of 5 digits.

Both clients also remember a peer's fingerprint and warn when it changes —
`frontend/src/lib/instantKeystore.ts` and
`ios/Instant/Core/Store/PeerFingerprintStore.swift`.

`ios/Instant/Core/Crypto/SafetyNumber.swift` sorts by UTF-8 bytes to match
JavaScript's UTF-16 code-unit ordering, rather than relying on the coincidence
that both agree for ASCII.

## What the encryption does and does not defend

**Defended.** The server never holds key material it can use. R2 holds
ciphertext; Postgres holds per-device *wrapped* content keys, and unwrapping one
needs a private key that never leaves the recipient's device. A full compromise
of Cloudflare and Postgres together still yields no plaintext photos.

**Not defended, and worth being honest about:**

1. **Key-directory substitution.** The server publishes the key directory and
   could substitute its own keys to sit in the middle. Mitigated only by the
   safety number and the changed-key warning.
2. **Browser code delivery.** The React client downloads its own cryptography
   from Vercel on every visit, so whoever controls that deployment can serve
   JavaScript that reads photos after decryption. A non-extractable `CryptoKey`
   stops a script copying the key out — not from using it in place. Browser
   end-to-end encryption is only ever as strong as the code-delivery channel,
   which is exactly why the signed native app is the real endpoint. The web
   client states this to the user in
   `frontend/src/components/instant/InstantKeySetup.tsx`.
3. **Metadata.** Who sent to whom, when, byte size and duration mode are all
   plaintext. Encryption does not touch any of it, and
   `GET /api/v1/instant/conversations` is built entirely out of it.

There is one deliberate hole in the plaintext guarantee, and it is opt-in: a
recipient reporting a photo may choose to attach it. See [safety.md](safety.md).
