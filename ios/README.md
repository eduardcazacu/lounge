# Instant for iOS

A native SwiftUI client for Instant — Eddie's Lounge's expiring, end-to-end
encrypted 1:1 photos. It signs in against the same backend as the web app and
speaks the same protocol, byte for byte.

The React client at `/instant` was always a test harness. This is the endpoint
the design was actually aimed at: a signed binary that does not re-download its
logic on every visit, with the private key in the Secure Enclave. P-256 was
chosen over X25519 for exactly one reason — it is the only curve the Enclave
supports.

## Running it

```bash
open ios/Instant.xcodeproj      # or:
xcodebuild build -project ios/Instant.xcodeproj -scheme Instant \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Points at `https://api.lounge.eduardcazacu.com` by default; switch
`AppEnvironment.live()` to `.localWorker` to run against `npm run dev:worker`.

**The Simulator has no camera.** The capture screen falls back to the photo
library when `AVCaptureDevice` finds nothing, which is the same path a device
takes when camera permission is refused.

## Shape

- `Core/Crypto` — the ECIES port, the Secure Enclave identity, safety numbers.
- `Core/Networking` — `APIClient` plus one facade per router.
- `Core/Realtime` — the WebSocket inbox.
- `Core/Media` — libwebp encoding, the compression ladder, the caption compositor.
- `Core/Camera` — capture behind a protocol, so the Simulator's photo-library
  fallback and the UI tests' fixed frame are the same seam.
- `Features` — one folder per screen, each an `@Observable` model plus a view.

View models hold no view types and take their dependencies as protocols, so all
of them are tested without a screen.

Pinch-to-zoom drives `AVCaptureDevice.videoZoomFactor`, which belongs to the
device rather than the preview — so the captured photo comes out magnified
without the capture path knowing anything about it. It caps at 8x, because past
that digital zoom is interpolation, and resets on a flip since the front and
back cameras have different limits. The gesture only exists when there is a real
capture session, so it is covered by unit tests against the camera protocol
rather than by a UI test: the Simulator has no camera to pinch.

## Where the inbox comes from

`GET /api/v1/instant/conversations` is the spine: everyone you have talked to,
whether or not a streak is running. `/streaks` is a strict subset of it and is
no longer fetched — a conversation used to vanish from the app the moment its
streak lapsed, and a one-way send never appeared at all.

What is openable is still decided locally. The server's `unopenedCount` counts
every device the recipient owns, including instants this one holds no envelope
for, so the local inbox list is what decides whether a row can be tapped.

Rows order by what is time-sensitive: anything waiting, then a streak about to
lapse, then simply whoever you spoke to most recently.

## The protocol, and what is easy to get wrong

Full contract in `backend/README.md`. The parts that fail *silently* if a port
gets them wrong:

- **`deviceId` case.** `crypto.randomUUID()` is lowercase; `UUID().uuidString`
  is uppercase. The id is inside the HKDF `info` string, so the wrong case
  derives a different key and produces envelopes nobody can ever open — with no
  error until decryption fails.
- **HKDF salt is the raw 65 bytes** of the ephemeral public key, not its
  base64url text.
- **AES-GCM layout.** WebCrypto emits `ciphertext || tag16` and carries the
  nonce separately, so `SealedBox.combined` (which prepends the nonce) is the
  wrong shape. Use the three-argument initialiser.
- **`GET /:id/media` is destructive.** The server claims the row before reading
  R2, so it can succeed exactly once ever — across every device the recipient
  owns. `ViewerModel` guards it with a flag that can only flip once.
- **The keepalive is a literal text frame `"ping"`**, answered by the Durable
  Object's auto-response with the bare string `"pong"`. It is *not*
  `URLSessionWebSocketTask.sendPing`, which sends a protocol-level ping the
  auto-response never sees.
- **Auth failures are 403, not 401.** Refresh keys off 403, or the 15-minute
  access token quietly ends the session.
- **Refresh renews a session; it must never start one.** `POST /user/refresh`
  authenticates from the `refresh_token` cookie alone, so a signed-out client
  that answers its first 403 by refreshing will silently adopt whichever account
  that ambient cookie belongs to. `APIClient` therefore refuses to refresh when
  it holds no token. This is not theoretical — it was caught on a Simulator,
  where cookie and Keychain storage are not sandboxed per app the way they are
  on a device, and the app came up signed in as the machine's owner.
- **Keychain items outlive the app.** Deleting an iOS app does not clear its
  Keychain, so a stale session survives a reinstall. `SessionStore` discards a
  stored value it cannot read an id out of, rather than reporting a session it
  cannot use.
- **`PUT /user/me` wipes `bio` if you omit it**, so always send the current text.

There is no endpoint that changes a user's display name, so settings shows it
read-only.

## Tests

```bash
xcodebuild test -project ios/Instant.xcodeproj -scheme Instant \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -enableCodeCoverage YES
```

### Crypto interop — the load-bearing part

Everything else can look healthy while the app produces envelopes the web client
cannot open. Two committed fixture sets pin both directions:

```bash
cd backend && npx tsx ../ios/tools/gen-interop-fixtures.ts   # JS seals
ios/tools/run-interop.sh                                     # Swift opens, and seals
cd backend && npx tsx ../ios/tools/verify-swift-fixtures.ts  # JS opens
```

The generators import `frontend/src/lib/instantCrypto.ts` itself rather than
restating the algorithm — a generator that reimplemented the crypto would agree
with a Swift port carrying the same misunderstanding, which is the exact failure
these exist to catch. `run-interop.sh` compiles the real app sources on the host
and finishes in about a second, which is why it is worth having alongside the
Xcode suite.

`InstantTests` covers everything that is not a view; `InstantUITests` drives the
screens against a stubbed backend and a fixed camera frame, injected by launch
arguments. The stub exists because the real endpoints cannot support a
repeatable UI test — `GET /:id/media` is destructive, so a second run of "open an
instant" would always fail. Only the API and camera seams are replaced: the
stub seals a real photo to the app's own device key, so the viewer under test
runs the production decrypt path.

### Push

```bash
ios/tools/push-test.sh
```

`xcrun simctl push` delivers a real APNs payload to the Simulator with no Apple
Developer account, which covers the whole device side: presentation, the tap,
and the deep link into the instant the payload names. What it cannot cover is
Apple accepting the request the backend sends — `backend/scripts/verify-apns.ts`
checks the ES256 signing and request shape against a stubbed Apple instead.

## Push is off by default

The Push Notifications capability requires the `aps-environment` entitlement, and
**a free personal team cannot sign an app that declares it** — Xcode refuses the
build outright, so the app cannot reach a device at all. `INSTANT_PUSH_ENABLED`
is therefore `NO`, which drops both the entitlement and the registration code.

Turn it on with one setting once there is a paid membership:

```bash
xcodebuild build -project ios/Instant.xcodeproj -scheme Instant INSTANT_PUSH_ENABLED=YES
```

or set `INSTANT_PUSH_ENABLED` to `YES` in the target's build settings to make it
permanent. That restores `Instant/Resources/Instant.entitlements` and defines the
`INSTANT_PUSH` compilation condition, which is the only thing gating
`PushRegistrar.requestAuthorizationAndRegister()`.

While it is off the app never asks for notification permission — iOS gives one
chance to ask, and spending it when no token can be issued wastes it. Handling a
*tapped* notification is compiled either way, so nothing else changes when it is
switched on. The backend half is already live and inert: it records APNs tokens
and reports the provider as unconfigured until the `APNS_*` secrets exist.

## What this deliberately does not do

Sign-up and password reset link out to the web app: both need an email
verification link and then admin approval, so an in-app form could only ever end
on a waiting screen. There is no key recovery — reinstalling mints a new
identity, and anything already sent to the old one stays sealed. That is the
design, not a gap.
