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
18.0, Swift 6. Sole SPM dependency is libwebp; the one bundled model is Depth
Anything V2 Small, for 3D.

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
  and drawing compositor, the filters, the sensitivity check, and the video
  pipeline, player and capture scratch directory.
- **`Core/Camera`** — capture behind a protocol, so the Simulator's
  photo-library fallback and the UI tests' fixed frame are the same seam.
- **`Core/Store`** — `InstantStore` (the live inbox), the inbox cache,
  `Outbox` (sends in flight), the Keychain, the session, peer fingerprints, the
  widget snapshot.
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

A clip uses no cover: the frame keeps moving until the finger lifts, and
compose's player takes over from it.

That window is visible in full, so nothing is allowed to sit in it.
`ComposeModel.init` does no image work at all — it shows the photo exactly as it
arrived. The display-sized copy is built on the first tap that needs one, and
the strip's seven renders happen when the strip is first opened rather than on
every capture.

### Holding the shutter

A tap is a photo and a hold is a clip, up to five seconds, with a red ring
filling round the shutter for the time left. **One `DragGesture` decides
both** (`CameraScreen.shutter`): touch-down starts a 0.3 s timer, a lift before
it fires is a photo, and the timer firing is the hold. A long press competing
with a tap would be outranked-but-waited-on, and the recording would start on
the lift (see [gotchas.md](gotchas.md)). The limit is enforced twice: by
`CameraModel`'s own clock, which stops at `VideoPipeline.maximumDuration`, and
by `maxRecordedDuration` a quarter-second later as a backstop.

**Nothing about the session changes when a clip starts.** The microphone is
asked for with the camera and is on the session for as long as the camera is;
the movie connection is set up (portrait, mirrored, unstabilised) when the
session is built and again after a flip. Changing an input or a connection's
processing on a running session rebuilds its pipeline, and the camera restarts
exposure and white balance for a frame or two — which, done on the hold, was a
flicker at the start of every clip (see [gotchas.md](gotchas.md)). The cost is
the microphone indicator whenever the camera is open. A refused microphone
records silent clips.

**Unstabilised on purpose.** Stabilisation crops the recorded frame, so a
stabilised clip is a tighter picture than the viewport showed.

**The audio session is the camera's.** `CameraController` sets
`.playAndRecord` with `.mixWithOthers` itself rather than letting the capture
session take it over, which would stop the person's music the moment the
camera opened. Nothing else sets a category: the camera keeps running under the
inbox, and a category without recording would cut its microphone off.

**The movie output must not slow the photo.** `CameraController` keeps it on
the session only if the photo output still offers zero shutter lag beside it,
and otherwise adds it for each recording — the one case left where a clip's
start changes the session, and so can flicker. Nothing reports the loss of
zero shutter lag; the photo would just go back to being of the moment after
the press.

A portrait recording is stored landscape with a transform, and a selfie
mirrored like the photo is. The clip is a file (`RecordedClip`), because
AVFoundation records to nothing else — the one form of an instant that sits on
the sender's disk. `CaptureScratch` owns the directory: a clip is deleted when
discarded or once encoded, and the directory is emptied at launch and sign-out.

## Filters

`PhotoFilter` is seven looks — original, vivid, warm, cool, fade, mono, noir —
each a fixed Core Image chain. They are chosen on the compose screen, **after**
the shot, and that is a property of the preview rather than a preference:
`AVCaptureVideoPreviewLayer` draws buffers the capture system hands it directly,
with nowhere to hang a `CIFilter`, so a filtered viewfinder would mean replacing
the preview with a video-data-output and a Metal path.

The look is baked into the pixels before the drawing, the captions and the
seal, for the same reason those are: the server holds nothing but ciphertext, so
there is no later moment at which either could be applied, and no filter name
rides along on the wire.

The strip previews at display size — a library photo can be 4000px on its long
edge, and re-filtering that on every tap is a hitch per tap for pixels no screen
shows. The full-resolution render happens once, in the outbox, after the
compose screen has closed. Nothing in the chains
measures the photo, so the thumbnail in the strip and the frame that goes on the
wire are one transform at two resolutions.

## Captions

Tapping the photo anywhere that is not already a caption starts a new one, so
a photo can carry several. Tapping a caption edits it. The text button in the
rail switches the style of the caption being typed, and changes glyph while it
does, because adding text and restyling it are two different buttons. When
nothing is being typed, it starts a caption in the middle of the photo, for
someone who has not found out that the photo takes a tap.

Holding a caption hides the chrome and puts a trash button at the top of the
frame. A caption let go over it is deleted. The drag is measured in global
space, not the caption's own: the caption moves under the finger, so its local
space moves too, and a drag read there shudders back and forth.

There are two styles, in `OverlayCompositor.Caption.Style`:

- **The bar** is the default: a translucent black band across the whole photo.
  It lands at the height of the tap that made it and only drags up and down,
  because it has no horizontal position to move.
- **The plate** hugs its text, drags anywhere, pinches between the limits in
  `OverlayCompositor.scaleRange`, and turns with two fingers. It wraps within
  90% of the photo at any scale, so a larger caption breaks into more lines
  instead of running off the edge. A turn that ends within 5° of level or of a
  quarter turn is set exactly there (`OverlayCompositor.normalizedRotation`),
  because two fingers cannot let go at exactly zero. The pinch and the turn are
  on the photo rather than on each caption, because two fingers rarely both land
  on a line of text. They go to the plate the gesture started on, with 44pt of
  slack around it. A bar keeps its scale and angle but is drawn level at its
  usual size, so switching back to a plate restores both.

The editor is the caption itself, drawn in place over a dimmed photo, with the
same font, wrap width and backing. The same view is used for both styles, so
switching style mid-sentence keeps the keyboard up. Return means done, because
a caption is one paragraph that wraps. A caption closed while blank is
removed.

## Drawing

The pencil in the rail turns the photo into a page to draw on. While it is on,
every other tool is hidden — the cross, the text button, filters, duration and
Send — and the pencil moves to the top of the rail with the colours in a column
under it and undo beside it. The pencil is the only way out.

One flag decides what a finger on the photo does. While drawing, the drawing
gesture is the only one enabled (`isEnabled:` in `ComposeScreen.swift`), and
captions stop taking touches, so a tap is a dot rather than a new caption and a
finger on a caption draws over it. The other gestures are switched off, not
outranked: an outranked tap is still waited on (see [gotchas.md](gotchas.md)).

The line is drawn by `DrawingLayer`, a view of its own that reads the strokes in
its `body`, so each new point redraws that layer and not the whole screen.

Points are stored as fractions of the photo, like a caption's placement, but
unclamped: a line may run off the edge. The width is fixed at 1.5% of the
photo's width (`OverlayCompositor.strokeWidth`), so it is the same share of the
picture on screen and at capture resolution. The preview and the compositor
stroke the same `OverlayCompositor.path`, which curves through the midpoints
between samples. Joined straight, a finger sampled 60–120 times a second draws
a corner at every sample.

A new line is detected by the drag's start location changing, not only by
`onEnded`. A cancelled touch never reaches `onEnded`, and the next line would
then be joined on to the last. Undo removes the last whole line.

The drawing lies **under** the captions, on screen and in the pixels, so a
scribble cannot make text unreadable, and it goes on after the filter, so ink
keeps its colour.

## Video

**Compose is the photo's.** A clip loops in the viewport
(`LoopingVideoView`), and the captions, drawing and gestures sit over it
unchanged, because they were already in fractions of the frame. The speaker in
the rail is the clip's sound for the preview and the send alike: off leaves the
audio track out of the encode (`ComposeModel.includesSound`), so the recipient's
device never holds sound the sender took back, and the preview plays exactly
what will arrive. The duration
chip offers Once and Loop instead of 1s, 5s and ∞. The filter strip is the
clip's first frame.

**The export is the preview.** `VideoPipeline.videoComposition` is one
per-frame recipe — turned upright, the look (`PhotoFilter.apply(to: CIImage)`,
the photo's own chains), then the drawing and captions as one transparent
image from `OverlayCompositor.overlay` — used by compose's player and by the
encode. The preview goes through it even with no look chosen, so a clip cannot
preview the right way up and send sideways. Whether AVFoundation hands the
handler upright frames is not relied on: `uprighted` compares each frame's
shape with the upright size.

**HEVC, SDR, under 3 MiB.** The encode is a reader-and-writer pass at 3 Mbps
1080×1920 with AAC, forced to BT.709, falling to 2 Mbps and then 720p if a
clip comes out over `byteBudget`. Five seconds is about 2 MB. The codec string
rides in `mediaType` so the web can ask whether it can play it. See
[decisions.md](decisions.md).

**Playback is from memory.** `AVVideoPlayback` answers a made-up URL scheme out
of the decrypted bytes through `InMemoryAssetLoader`, so the plaintext is never
written anywhere, as a photo's never is. A clip opens muted with a speaker
button; the recording audio session ignores the silent switch, so muted is the
default and sound is a tap. The speaker is remembered (see Remembered choices),
so someone who has turned it up once hears the next clip too. Once closes at its end with the ring
tracking playback; Loop stays until tapped. The sensitivity check sees the
first and the middle frame, and a report attaches the frame it was paused on.
The model reaches the player through `VideoPlaying`, so its rules are tested
against `StubVideoPlayback`.

## 3D

Every photo has a **3D** button in the rail. It renders a Nishika-style
wiggle: four viewpoints a little apart, played 1-2-3-4-3-2 at a tenth of a
second each, eight cycles to 4.8 s (`ParallaxRenderer`).

**Depth is estimated, not measured.** `DepthEstimator` runs Depth Anything V2
Small, Apple's Core ML conversion, on the photo after it is taken. The camera
could measure depth, but a capture device delivering it restricts its own
zoom — see [decisions.md](decisions.md). The model's input is a fixed
landscape 518×392, so a portrait photo is letterboxed into it upright rather
than stretched or turned, and only its part of the answer is read back. The
model loads on the first 3D tap, not at launch. It is Apache-2.0, and ships
with its licence and attribution beside it in `Instant/Resources`.

**The subject stands still.** Each view moves a pixel sideways by how far its
disparity is from the subject's, not by its disparity, so the subject lines
up in every frame and the rest swings around it — the background one way,
anything nearer the other. The subject is guessed as the near side of the
middle of the frame (`keyDisparity`), which is where a selfie's face is.

**Edges are steps.** An estimated map's edges are ramps, and a pixel on a
ramp moves by an amount between the subject's and the wall's, so straight
lines in the background bent as they approached the subject. After the map is
upsampled along the photo's own edges (`CIEdgePreserveUpsampleFilter`),
`stepped` snaps every pixel within reach of a real depth edge to its near or
far side, and leaves gentle slopes — a floor, a wall going away — alone. The
cut sits a little towards far, so the outer ring of hair goes with the head.
Each pixel is then sampled at its exact fractional source position, since a
slope's gradual move rounded to whole pixels is a staircase down every
vertical edge.

**The nearer a layer stands, the more it is enlarged.** As Apple's spatial
scenes do, near layers are drawn a little larger in every view
(`growingLayers`, `enlarged`), so a layer already covers most of the band
beside it that the moving viewpoint uncovers, and less has to be invented.
The picture is split into layers at its real depth edges, and each grows by
how far it stands in front of whatever its outline has behind it: a head
against a far wall grows by most of `maxGrowth`, a hand held up to that face
by little, and the background not at all. The band a viewpoint uncovers is
itself as wide as that jump, so the growth is the size of the problem it
solves.

Each layer grows about its own middle, never about one shared centre: grown
about the subject's, a hand off to one side would also be pushed outwards and
uncover a strip along its inner side. Two layers that meet smoothly and both
grow are merged and grow as one, or a face split in two by its own relief
would open a seam down the nose. A surface fading into the distance — a floor
running from under the subject to the back wall — is outlined nowhere, so its
jump is nothing and it keeps its size, as does the background: its lines stay
straight and the right length.

**Gaps are filled from behind.** Moving the viewpoint uncovers slivers beside
every near edge. Each is filled with a copy of the background next to it,
taken from whichever side of the gap is farther away: filling from the
subject would smear it into the wall.

**The wall right beside the subject is not moved at all.** The pixels on an
outline are part subject, part wall, and the estimate can miss the true
outline by a few. Any of them given the wall's depth slid away with the wall
carrying the subject's colour — a faint copy of the outline floating a few
pixels off the subject. So background within `edgeBand` of anything nearer
is dropped from every view (`besideNearer`) and filled like any other gap,
from clean background farther out. The strip a view uncovers at the frame's
own edge is filled the same way. The views are deliberately *not* scaled up to
hide that strip: scaling enlarges the whole picture, background and all.

**Once rendered, it is a clip.** The result is a silent `.mov` in
`CaptureScratch`, and compose treats it as it treats a recording: the player,
filters per frame, captions and drawing, Once and Loop, and the same encode
and seal. Nothing on the wire changes. The duration switches family with the
button and each family is remembered on its own, so a Loop never becomes a
photo's duration. The render is kept, so turning 3D off and on again is free;
a render nobody sent is deleted when compose closes.

**The loop has no seam.** The clip ends on view 2 rather than 1, so looping
back to view 1 is an ordinary step, and the file ends exactly on its last
frame. Sent as Once, it still wiggles eight times before it closes.

## Sending

Tapping Send closes the compose screen at once. `ComposeModel.draft` hands the
original photo and every choice made about it to `Outbox`
(`ios/Instant/Core/Store/Outbox.swift`). The outbox then looks up the
recipient's devices, applies the filter, drawing and captions, encodes and seals off the
main actor, and uploads. That used to hold the compose screen for seconds.

**Several recipients are several instants.** The picker ticks any number of
people, and `Outbox.send` makes one item per person: the photo is rendered and
encoded once for all of them, then each is sealed to that person's devices and
uploaded on its own, so each fails, retries and is read once independently.
The wire format stays single-recipient; see [decisions.md](decisions.md).

**All** sends to everyone the picker found enrolled, and only after an alert
that says how many people that is. It sits beside Send, and a photo meant for
one person going to the whole Lounge is the one mis-tap here that cannot be
undone. It stays disabled until every row's key check has come back, since
before then "everyone" is not yet a known set of people.

`SendStatusPill` sits above the pager, over the camera's bottom bar. It shows a
spinner while a send is going and "Sent to …" for two seconds after it goes,
counting rather than naming when there are several. A
failure stays until it is retried or dismissed. A retry seals again while the
photo is still in memory, because the recipient's device list may be what
changed. The send spends the aim at once, but recency and streaks
(`noteSent`) move only once the server has accepted it. A send that failed must
not answer a streak.

**Surviving a force quit.** The sealed send is written to Application Support
(`PendingSendStore`) before the upload starts, and deleted once the server
accepts it. The next launch restores it before the first frame and sends it
once signed in. Only the sealed form is ever written, never the photo, so a
send killed before sealing finishes is lost. That window is the WebP encode
— for a clip, the video encode, a second or two — the key lookup runs alongside
it, and the seal itself takes a millisecond or two. The pill's accessibility value turns from `preparing` to `saved` when the
window closes, which is what the relaunch UI test waits on.

**Debug builds are slow to send.** libwebp comes in as a Swift package, and a
Debug build compiles its C at `-O0`. Encoding a 1080×1920 frame takes 3–8 s
there and about 0.2 s at `-Os`, which is what Release uses (measured on the
Simulator). A project-level `GCC_OPTIMIZATION_LEVEL` does not reach package
targets. A slow send seen from Xcode says nothing about the shipped app.

A force quit runs no code, so the "wasn't sent" notification is scheduled on the
way out instead: `Outbox.didEnterBackground` asks for background time and
schedules a local notification 30 seconds out, and it is withdrawn if the send
finishes. A send that fails in the background leaves it to fire. Tapping it
opens the app where it normally opens, not the inbox (`OutboxReminder`).

## Remembered choices

`Preferences` (`ios/Instant/Core/Store/Preferences.swift`) keeps the photo
duration, the clip's Once or Loop, compose's speaker, the viewer's speaker and
the pen's colour, so a capture starts where the last one left off. Each is
written the moment it is chosen rather than on send: a discarded capture still
says what the person wants next time.

Photo and clip durations are remembered separately and each refuses the other
family's modes, on the way in and on the way out. A Loop leaking into a photo's
duration would be refused by the server, and a value a later build wrote falls
back to the default rather than becoming something this one cannot send.

Per device, in `UserDefaults`, and not synced to the account; see
[decisions.md](decisions.md). The models default to `Preferences.inMemory()`,
and so do the stubbed UI-test launches, so one test's red pen is never the next
test's starting point. Only `AppEnvironment` hands them the persistent one.

## Where the inbox comes from

`GET /api/v1/instant/conversations` is the spine: everyone you have talked to,
whether or not a streak is running. `/streaks` is a strict subset of it and is
no longer fetched — a conversation used to vanish from the app the moment its
streak lapsed, and a one-way send never appeared at all.

What is openable is still decided **locally**. The server's `unopenedCount`
counts every device the recipient owns, including instants this one holds no
envelope for, so the local inbox list is what decides whether a row can be
tapped.

**A cold start draws the inbox from disk.** `InboxCache`
(`ios/Instant/Core/Store/InboxCache.swift`) holds the last-seen instants and
history, and `AppEnvironment` restores it before the first frame, so a tapped
notification or widget never lands on "No conversations yet". Anything already
expired is left out. When the cache was restored, `InstantStore.start` then
fetches the inbox and history while the device registers, rather than after
registration, a socket ticket and the connect. A launch with no cache waits for
the socket's drain instead. Nothing is sealed to a device until it has
registered, so an early fetch would draw a row saying something is waiting
with nothing to open, and tapping that row opens the camera. The first successful drain drops cached instants the server
no longer returns. Only a launch with nothing cached shows a spinner, and it
stops after the first history fetch, even a failed one. The cache is cleared on
sign-out, and a fetch that finishes after an account switch is discarded.

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

### What a row says about the photo you sent

The line under a name is ordered by what wants a tap: anything waiting, then
the reply prompt, then a streak waiting on your send, and last the receipt for
the newest photo you sent them — "Sent 3m ago", "Opened 3m ago", or
"Expired unopened" when the 24 hours ran out with nobody looking. Last because
it is the only line there that asks for nothing.

It comes from `lastSentReceipt` on `/conversations`, and `openedAt` is the
server's claim of the media rather than the viewer's `viewedAt` confirmation;
see [decisions.md](decisions.md). A send made here fills one in locally the
moment it lands — `withSend` in `ios/Instant/Core/Networking/DTOs.swift` —
because nothing newer than that send can have been opened, and the server's own
receipt replaces it as soon as it catches up. `InstantSendReceipt.status` says
nothing at all about a send older than its window, which is also what stops a
local mark the server has since stopped reporting from sitting on a row for
good.

`InboxScreen` ages what is on screen on a timer of its own, one minute at a
time: a receipt is the only thing here that goes stale while nothing happens,
and a list nobody is touching never redraws. The phrasing is
`ios/Instant/Core/RelativeTime.swift`, which carries a spoken form beside the
written one because VoiceOver reads "3m ago" as a letter.

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
the app mark when nothing is waiting, otherwise the sender's picture filling the
whole widget, with their name, how many are waiting, and the streak if there is
one stacked along the bottom over a scrim. Someone whose picture has not been
cached yet gets their initials, large, on their own theme colour — the same
shape, so the two states do not read as two different widgets. Several people
cycle every 30 seconds, as an hour of pre-built entries; only a cycling timeline
asks WidgetKit to call back, because scheduled refreshes spend the budget that
push-driven reloads need.

The picture is handed to `containerBackground` rather than drawn inside
`InstantWidgetView`, because only the container background reaches the widget's
own edges — see `wiki/gotchas.md`. `InstantWidgetBackground` in
`ios/Shared/InstantWidgetView.swift` is that layer, and it caches what it
decodes: a cycling timeline renders about 120 entries in one pass, and a
picture that fills the widget is an order of magnitude more pixels than an
avatar-sized one — decoding it per entry is how a render pass runs out of the
memory WidgetKit allows it.

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
  prunes the ones nobody is waiting on. `WidgetSnapshotPublisher.downsized`
  keeps 768 pixels, about what a medium widget asks for at 3x — a picture that
  fills the widget is held to the widget's size, not an avatar's.
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
  yet when the tap arrives on a cold start: the cache predates it. So the id
  stays **pending** until the startup fetch brings it in, rather than being
  dropped on the first miss.
- Nothing about the photo itself can be fetched ahead of the tap. Reading
  destroys it (`GET /:id/media`), so the viewer's download is the one wait
  that cannot be moved earlier.

## Update notes

`WhatsNewScreen` is a sheet over the pager, shown once per notes version. The
notes and the key that records them are in
`ios/Instant/Features/WhatsNew/WhatsNew.swift`. A release with something to
say replaces `WhatsNew.current` and sets its `version` to the new
`MARKETING_VERSION`. A release that leaves the notes alone shows nothing.

Only someone who was **already signed in** when the update landed sees them:
`handleSignIn` marks the notes seen, because someone who has just signed in has
nothing to compare with. They are also held back for a launch from a tapped
notification, where the inbox's viewer needs the screen, and behind the
guidelines gate. Stubbed UI tests start with the notes seen unless launched with
`-instantUITestWhatsNew`.

Settings' About section opens the same screen again, pushed rather than
presented, so its Continue button goes back to Settings.

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

Swift Testing, roughly 310 unit tests in `ios/InstantTests/` plus 40 UI tests in
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
relative on purpose; a fixed future date inverted the recency ordering. Video
is the same story: the stand-in camera's hold writes a real clip of its frame
(`StillClipWriter`), and `-instantUITestVideoInstant` has the stub seal a real
HEVC clip instead of a photo. That clip is small because the Simulator encodes
HEVC in software and the device registration waits on it.

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
