# The iOS client

`ios/` — a native SwiftUI client for Instant, and only Instant. It signs in
against the same backend as the web app and speaks the same protocol, byte for
byte. It does not do the blog or the chat.

This is the endpoint the design was aimed at: a signed binary that does not
re-download its logic on every visit, with the private key in the Secure
Enclave. See [product.md](product.md).

iPhone only (`TARGETED_DEVICE_FAMILY = 1`) — the camera and the pager are
phone-shaped, and a portrait-only app declaring iPad support fails App Store
validation. iPads still run it in compatibility mode. Deployment target iOS
18.0, Swift 6. Sole SPM dependency is libwebp.

Points at `https://api.lounge.eduardcazacu.com` by default; switch
`AppEnvironment.live()` to `.localWorker` to run against `npm run dev:worker`.

## Shape

- **`App/`** — `InstantApp` (`@main`), `AppEnvironment` (the composition root),
  `RootView` and `MainPager`, `PushRegistrar`, and the UI-test seams
  (`LaunchOptions`, `StubBackend`).
- **`Core/Crypto`** — the ECIES port, the Secure Enclave identity, safety
  numbers. See [instant-protocol.md](instant-protocol.md).
- **`Core/Networking`** — `APIClient` plus one facade per router (`InstantAPI`,
  `UserAPI`, `ModerationAPI`), all behind `Sendable` protocols.
- **`Core/Realtime`** — `InboxSocket`, the WebSocket inbox.
- **`Core/Media`** — libwebp encoding, the compression ladder, the caption
  compositor, the filters, the sensitivity check.
- **`Core/Camera`** — capture behind a protocol, so the Simulator's
  photo-library fallback and the UI tests' fixed frame are the same seam.
- **`Core/Store`** — `InstantStore` (the live inbox), the Keychain, the session,
  peer fingerprints, the widget snapshot.
- **`Features/`** — one folder per screen, each an `@Observable` model plus a
  view.

**View models hold no view types** and take their dependencies as protocols, so
every one of them is tested without a screen. `AppEnvironment` itself is
concrete on purpose — the seams that get stubbed are one level down
(`APIClientProtocol`, `CameraControlling`, `DeviceIdentityProviding`).

**The Simulator has no camera.** The capture screen falls back to the photo
library when `AVCaptureDevice` finds nothing, which is the same path a device
takes when camera permission is refused.

## The camera

Pinch-to-zoom drives `AVCaptureDevice.videoZoomFactor`, which belongs to the
device rather than the preview — so the captured photo comes out magnified
without the capture path knowing anything about it. It caps at 8x, because past
that digital zoom is interpolation, and resets on a flip since the front and
back cameras have different limits. The gesture only exists when there is a real
capture session, so it is covered by unit tests against the camera protocol
rather than by a UI test.

A flip holds the last frame. Swapping the session's input leaves the outgoing
camera's frame in the preview layer, where the new connection redraws it with
the new camera's mirroring — the picture you were just looking at, flipped — and
the frames that follow arrive dark while auto-exposure ramps. So the view
snapshots itself for the length of the swap and cross-fades back once the new
camera has settled, and the controller does not report the flip finished until
then.

Double-tapping the frame flips the camera, and the flash and flip buttons run
down the right-hand side in the same rail the compose screen puts its tools in —
the two screens are one surface with different tools on it. The gesture is on
the frame rather than on the preview, so it still answers on a device with no
camera attached.

### The shutter

Taking a photo covers the frame in black, from the press until the photo is on
screen. Not a blink: a blink ends on a timer, and whatever is left between the
end of it and the picture appearing is the live camera still moving under a
frame captured a moment ago — which reads as the shutter having missed. The
cover is drawn above both screens so that it outlasts the handover from one to
the other, and the compose screen appearing is what lifts it.

That window is visible in full, so nothing is allowed to sit in it.
`ComposeModel.init` does no image work at all — it shows the photo exactly as it
arrived. The display-sized copy is built on the first tap that needs one, and
the strip's seven renders happen when the strip is first opened rather than on
every capture.

## Filters

`PhotoFilter` is seven looks — original, vivid, warm, cool, fade, mono, noir —
each a fixed Core Image chain. They are chosen on the compose screen, **after**
the shot, and that is a property of the preview rather than a preference:
`AVCaptureVideoPreviewLayer` draws buffers the capture system hands it directly,
with nowhere to hang a `CIFilter`, so a filtered viewfinder would mean replacing
the preview with a video-data-output and a Metal path.

The look is baked into the pixels before the caption and before the seal, for
the same reason the caption is: the server holds nothing but ciphertext, so
there is no later moment at which either could be applied, and no filter name
rides along on the wire.

The strip previews at display size — a library photo can be 4000px on its long
edge, and re-filtering that on every tap is a hitch per tap for pixels no screen
shows. The full-resolution render happens once, on send. Nothing in the chains
measures the photo, so the thumbnail in the strip and the frame that goes on the
wire are one transform at two resolutions.

## Where the inbox comes from

`GET /api/v1/instant/conversations` is the spine: everyone you have talked to,
whether or not a streak is running. `/streaks` is a strict subset of it and is
no longer fetched — a conversation used to vanish from the app the moment its
streak lapsed, and a one-way send never appeared at all.

What is openable is still decided **locally**. The server's `unopenedCount`
counts every device the recipient owns, including instants this one holds no
envelope for, so the local inbox list is what decides whether a row can be
tapped.

Rows order by what is time-sensitive: anything waiting, then a streak waiting on
a send from *you*, then simply whoever you interacted with most recently.

Recency means either direction. A photo you have just sent is the most recent
thing between you, so the person you send to goes to the top of that tier —
`lastInteractionAt` is the newer of the two marks, and `InstantStore` stamps a
send locally the moment it lands (`noteSent`) rather than waiting for the round
trip. `withSend` takes the *later* of the local and server marks, so a refresh
that has not caught up cannot walk a send backwards.

Which side a streak waits on comes from the same pair of marks. The deadline is
set by whoever went quiet first, so a streak about to lapse because *they* have
not sent in a day is not something this reader can fix: it neither says "Send
one today to keep your streak" nor outranks somebody they have just sent to.
Never having sent counts as your move, because there is nobody else it could be
waiting on.

The Send To picker's "Recent" section reads the same history, so recency
survives a reinstall and is identical on every device you sign in from. It used
to come from a device-local store, which was neither.

## Tapping someone

A row means one of two things, depending on whether they have something waiting:

- **Something waiting** — it opens. That is the unread marker's promise, and the
  same thing a tapped notification does.
- **Nothing waiting** — the camera, already aimed at them. There is nothing to
  read, so the tap means the other direction, and the photo does not exist yet:
  tapping a person has answered who it is for before there is anything to send.

The aim lives on `AppEnvironment` as `aimedAt`, not on the camera or the
capture, because it outlives both: it is set before there is a photo and
survives a retake. The camera draws it as a chip with a cross, so an aim set
several taps ago is never a surprise discovered on the send button — and
`ComposeScreen` reads it when it builds its model, which is what turns "Send To"
into "Send to Ana" and makes sending one tap instead of a trip through the
picker. The picker is still one button away, because the alternative way out of
a wrong recipient would be discarding the photo. Sending spends the aim,
whichever path sent it.

Closing an instant lands back on the inbox with the sender's row offering **Tap
to reply** — the same tap, now meaning the camera. The prompt is
`InstantStore.replyHints`, set from `ViewerModel.wasSeen` rather than from the
close itself: an instant already opened elsewhere, or one this device holds no
envelope for, was seen by nobody and there is nothing to reply to. It is
session-scoped on purpose; one that survived a relaunch would be a chore list
rather than a nudge. Anything newly waiting from the same person outranks it,
since a row says one thing and "open this" beats "answer that".

## The widget

`InstantWidget` is a WidgetKit extension showing who has sent you an instant:
the app mark when nothing is waiting, otherwise the sender's picture (or their
initials on their own theme colour), their name, how many are waiting, and the
streak if there is one. Several people cycle every 30 seconds.

**The app publishes; the widget only reads.** An extension can reach neither the
access token nor the refresh cookie, and a token lives fifteen minutes — a
widget refreshing on WidgetKit's schedule would find an expired one nearly every
time. So `InstantStore` writes a snapshot into the
`group.com.eduardcazacu.instant` App Group whenever the waiting list changes,
and the widget renders whatever is on disk. No credential ever enters the
extension.

Two consequences:

- **Profile pictures are cached by the app, not fetched by the widget.** Widgets
  render synchronously off local state; an image loaded at draw time simply
  never appears. The app downsizes and writes them next to the snapshot, and
  prunes the ones nobody is waiting on.
- **A Notification Service Extension keeps it fresh while the app is closed.**
  `InstantNotificationService` runs on delivery of every Instant push, folds the
  new arrival into the snapshot and reloads the widget. It has no access token
  and cannot call the API, so the push payload carries the sender's id, name and
  theme — metadata the notification's own title already reveals. It reads no
  media and decrypts nothing.

  What a push cannot carry is the streak or the cached picture, so the merge
  keeps whatever the app last recorded and shows initials for someone new. The
  banner is passed through untouched whether or not the snapshot could be
  written: a widget that failed to update must never cost someone their
  notification.

The cycling rule lives in `ios/Shared/WidgetTimeline.swift` and the view in
`ios/Shared/InstantWidgetView.swift` rather than in the extension, because an
extension's code cannot be reached from the app's test bundle.
`WidgetRenderTests` rasterises every state to PNGs — the only way to see a
widget, since XCUITest cannot drive one and the Simulator has no way to add one
from the command line.

## Where a tap from outside lands

The inbox, never the camera. A widget showing that someone is waiting and a
notification saying someone sent you something are both about an instant, so
both open the list of them — the camera is where the app opens when *it* decides
where to start.

- The widget carries `instant://inbox` (`ios/Shared/DeepLink.swift`, built by
  the extension and parsed by the app, which is why it is shared rather than
  spelled out twice). The scheme is declared in `ios/Instant-Info.plist`; the
  rest of that target's Info.plist is still generated from `INFOPLIST_KEY_*`
  settings, since `CFBundleURLTypes` is an array of dictionaries and has no
  build-setting form. The idle widget carries no URL and opens the app wherever
  it normally opens.
- The notification goes through the `UNUserNotificationCenter` delegate, which
  `AppDelegate` installs **at launch** rather than after sign-in. iOS hands a
  notification tapped from a cold start to whatever delegate exists when
  launching finishes, once — set it any later and the tap is dropped silently,
  and the app comes up on the camera.
- A notification names its instant, and that instant is usually not in the inbox
  yet when the tap arrives on a cold start, so the id stays **pending** until it
  lands rather than being dropped on the first miss.

## Networking

`APIClient` mirrors the web's interceptors: cookie-enabled `URLSession` for the
`refresh_token` cookie, one refresh and one retry on **403**, and a refusal to
refresh while holding no token. `APIError` maps 403 to auth failure, 410 to
gone, 501 to realtime-unsupported.

Sign-in sends `authenticated: false` so its own 403s — bad credentials,
unverified, pending approval — are not mistaken for an expired session.

`InboxSocket` opens `wss://.../api/v1/instant/ws?ticket=` with a fresh
60-second ticket per connect, sends the literal text frame `"ping"` every 25
seconds, filters `"pong"` out before JSON decoding, and backs off 1s→30s.
`InstantConnectionState` is deliberately silent while connecting or open — the
connection is only ever mentioned when it is broken.

Push permission is asked for **after** sign-in, never on the sign-in screen,
where iOS's one prompt would be spent before there is any reason to say yes.
Debug builds register as `apns-sandbox`, Release as `apns`.

## Tests

Swift Testing, roughly 265 unit tests in `ios/InstantTests/` plus 33 UI tests in
`ios/InstantUITests/`.

Day to day, run only the suites the change touches, as an optimized build that
reports a failure immediately instead of collecting diagnostics for about ten
minutes first. The trade-off is in [decisions.md](decisions.md).

```bash
xcodebuild test -project ios/Instant.xcodeproj -scheme Instant \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:InstantTests/DeepLinkTests \
  SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule ENABLE_TESTABILITY=YES \
  -collect-test-diagnostics never -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 30 \
  -maximum-test-execution-time-allowance 60
```

`-only-testing` takes a `@Suite` struct's name and can be repeated. Read the
`✔/✘ Test run with N tests` line: the XCTest summary always says 0, and a filter
that matches nothing still passes (see [gotchas.md](gotchas.md)).

Run the full suite when a change crosses areas, and before merging to `main`:

```bash
xcodebuild test -project ios/Instant.xcodeproj -scheme Instant \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -enableCodeCoverage YES
```

The **crypto interop suite is the load-bearing part** — everything else can look
healthy while the app produces envelopes the web client cannot open. The
three-command fixture loop is in [instant-protocol.md](instant-protocol.md) and
is worth running on its own; it finishes in about a second.

`InstantUITests` drives the screens against `StubBackend` and a fixed camera
frame, injected by launch arguments. The stub exists because the real endpoints
cannot support a repeatable UI test — `GET /:id/media` is destructive, so a
second run of "open an instant" would always fail. Only the API and camera seams
are replaced: **the stub seals a real photo to the app's own device key**, so
the viewer under test runs the production decrypt path. Its timestamps are
relative on purpose; a fixed future date inverted the recency ordering.

```bash
ios/tools/push-test.sh
```

`xcrun simctl push` delivers a real APNs payload with no Apple Developer
account, and the script prints the widget snapshot either side of it — a new
contact appearing proves the Notification Service Extension ran with the app
closed. It needs one manual step: `simctl push` refuses to deliver to an app
that has not been granted notification permission, and simctl has no
`privacy … notifications` service with which to grant it, so the script waits
for you to tap Allow.

What none of that covers is Apple accepting the request the backend sends;
`backend/scripts/verify-apns.ts` checks the ES256 signing and request shape
against a stubbed Apple instead. See [operations.md](operations.md).

## What it deliberately does not do

Sign-up and password reset link out to the web app: both need an email
verification link and then admin approval, so an in-app form could only ever end
on a waiting screen.

There is **no key recovery** — reinstalling mints a new identity, and anything
already sent to the old one stays sealed. That is the design, not a gap.

There is no endpoint that changes a display name, so Settings shows it
read-only.

Moderation, terms and account deletion are in [safety.md](safety.md). The
submission checklist is `ios/APP_STORE.md`.
