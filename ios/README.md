# Instant for iOS

A native SwiftUI client for Instant — Eddie's Lounge's expiring, end-to-end
encrypted 1:1 photos. It signs in against the same backend as the web app and
speaks the same protocol, byte for byte.

**Design notes live in [`../wiki/`](../wiki/README.md)** — this file is how to
run and test it.

| Question | Page |
|---|---|
| App shape, camera, compose, inbox, widget, extension | [ios-client.md](../wiki/ios-client.md) |
| The encryption contract and what it does not defend | [instant-protocol.md](../wiki/instant-protocol.md) |
| Delivery, the one-shot media read, streaks, push | [instant-runtime.md](../wiki/instant-runtime.md) |
| Terms, reporting, blocking, deletion | [safety.md](../wiki/safety.md) |
| **Things that fail silently** | [gotchas.md](../wiki/gotchas.md) |
| Why the native app rather than the web client | [product.md](../wiki/product.md) |

Submission checklist, review notes and privacy answers: [`APP_STORE.md`](APP_STORE.md).

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

## Tests

```bash
xcodebuild test -project ios/Instant.xcodeproj -scheme Instant \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -enableCodeCoverage YES
```

`InstantTests` covers everything that is not a view; `InstantUITests` drives the
screens against a stubbed backend and a fixed camera frame.

### Crypto interop — the load-bearing part

Everything else can look healthy while the app produces envelopes the web client
cannot open. Two committed fixture sets pin both directions, and the whole loop
runs in about a second on the host with no Simulator:

```bash
cd backend && npx tsx ../ios/tools/gen-interop-fixtures.ts   # JS seals
ios/tools/run-interop.sh                                     # Swift opens, and seals
cd backend && npx tsx ../ios/tools/verify-swift-fixtures.ts  # JS opens
```

Run all three after touching either side. Why the generators import the real web
implementation rather than restating the algorithm:
[instant-protocol.md](../wiki/instant-protocol.md).

### Push

```bash
ios/tools/push-test.sh
```

`xcrun simctl push` delivers a real APNs payload with no Apple Developer
account, and the script prints the widget snapshot either side of it — a new
contact appearing proves the Notification Service Extension ran with the app
closed.

It needs one manual step: `simctl push` refuses to deliver to an app that has
not been granted notification permission, and simctl has no
`privacy … notifications` service with which to grant it. The script waits for
you to tap Allow.

What this does not cover is Apple accepting the request the backend sends;
`backend/scripts/verify-apns.ts` checks that against a stubbed Apple instead.

## Build facts

iPhone only (`TARGETED_DEVICE_FAMILY = 1`), portrait only, deployment target
iOS 18.0, Swift 6. Five targets: the app, the widget, the notification service
extension, and two test bundles, all under `com.eduardcazacu.instant*`. App
Group `group.com.eduardcazacu.instant`. Sole SPM dependency is libwebp.

Push is compiled into every build; `aps-environment` is declared in
`Instant/Resources/Instant.entitlements` and needs a paid Apple Developer
membership to sign. Debug builds register their token as `apns-sandbox`, Release
builds as `apns`.

Info.plist is mostly generated from `INFOPLIST_KEY_*` build settings.
`Instant-Info.plist` exists only to declare the `instant://` URL scheme, which
is an array of dictionaries and has no build-setting form.

```bash
xcrun swift ios/tools/make-app-icon.swift    # regenerate AppIcon.png
```
