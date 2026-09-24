# Decisions

What was chosen, what lost, and what would reopen it. Entries are corrected in
place, not appended to — see [README.md](README.md).

---

## P-256 rather than X25519

**Chosen** ECDH P-256 for Instant device keys.

**Rejected** X25519, which is the better curve on the merits.

**Because** P-256 is the only curve the iOS Secure Enclave supports, and a
private key that cannot leave the Enclave is the reason the native app exists at
all. Every other consideration was downstream of that.

**Would reopen if** Apple supported X25519 in the Enclave — and even then only
with a versioned `info` string and both curves supported for a long overlap,
because anything sealed to a P-256 key stays sealed.

---

## The native app carries the guarantee; the web client does not

**Chosen** iOS as the endpoint the crypto is designed around.

**Rejected** treating the React `/instant` page as somewhere the guarantee could
be as strong.

**Because** browser end-to-end encryption is only ever as strong as the channel
delivering the JavaScript, and that channel is a Vercel deployment that can
serve different code tomorrow. A non-extractable `CryptoKey` stops a script
copying the key out, not from using it in place. A signed binary is where the
guarantee is actually strong.

The web client says this to the user rather than hiding it
(`frontend/src/components/instant/InstantKeySetup.tsx`).

This is about the threat model and nothing else. The interface is a separate
question, answered separately below.

---

## The web client runs the iOS app's screens

**Chosen** the same product on both: camera-first, black, full-bleed, the
conversations one swipe to the left, the same tools on the photo and the same
words on every row. `frontend/src/components/instant/` is a port of `ios/Instant/`
screen for screen.

**Rejected** the scrolling panel of sections it used to be — a streaks strip, a
"waiting for you" list and a "send one" form on the Lounge's own grey page.

**Because** the two clients are used by the same dozen people, often on the same
day, and the old page made that feel like two different products that happened
to share a login. Everything the phone had learned — that the camera is the
home screen, that a row means "open this" or "aim at them", that a receipt is
the quiet line under a name — had to be learned again in a different shape.

**Cost paid** roughly the whole of `frontend/src/components/instant/`, four
things that only a phone can do (see [web-client.md](web-client.md)), and a
second implementation of the caption geometry, the filters and the send queue.
The first of those is a real risk and is listed in
[parallel-implementations.md](parallel-implementations.md).

**Would reopen if** the web client were ever retired in favour of the app, which
would delete the port rather than reshape it.

---

## Postgres rather than D1

**Chosen** Postgres via Prisma 7 and the `@prisma/adapter-pg` driver adapter.

**Rejected** Cloudflare D1, despite the backend running on Workers. The D1 and
KV blocks are still in `wrangler.toml`, commented out.

**Because** the schema and its relational integrity predate the move to Workers,
and Prisma's Postgres support was the known quantity.

**Cost paid** a per-request client on Workers
(`backend/src/prisma.ts` branches on `navigator.userAgent`) and a connection
string as a secret rather than a binding.

---

## No key recovery

**Chosen** a new device means a new identity; anything sealed to the old key
stays sealed forever.

**Rejected** any recovery mechanism.

**Because** recovery means an escrowed key, and an escrowed key means the server
can read photos. That is the whole guarantee.

**Cost paid** Safari evicting IndexedDB after ~7 idle days silently mints a new
identity, and so does reinstalling the app. Clients report unopenable instants
to `POST /api/v1/instant/:id/undecryptable` so the server stops holding them.

---

## Reading an instant destroys it, server-side

**Chosen** `GET /:id/media` claims the row with an `updateMany` **before**
reading R2.

**Rejected** deleting after a successful delivery, and trusting the client.

**Because** claiming first is the only ordering in which a second request can
never be served — including from another device the same recipient owns, which
gets a 410. The countdown's promise is enforced rather than requested.

**Cost paid** a download that fails mid-flight loses the photo. That is the same
trade Snapchat makes.

---

## Conversations read the streak table

**Chosen** `GET /api/v1/instant/conversations` derives from `InstantStreak`.

**Rejected** a `conversations` table.

**Because** the streak table already is a permanent conversation index:
`recordSend` upserts a row on the very first send, and lapsing only sets
`count = 0` — the row and its two `last*_sent_at` marks stay for good. Meanwhile
`instants` rows are swept after 30 days, so they cannot answer "who have I ever
talked to". A conversation survives with no instants left in the table at all.

---

## A read receipt is the claim on the media, not the viewer's confirmation

**Chosen** `instants.opened_at`, the claim `GET /api/v1/instant/:id/media`
makes before it reads R2, as the receipt — both the mark reported on the
conversation and the moment the sender's Durable Object is told.

**Rejected** `viewed_at`, which `POST /:id/viewed` writes once the photo has
actually reached a screen.

**Because** exactly one request ever gets past the claim, and from that moment
the photo is destroyed whatever happens next. `viewed_at` needs the recipient's
client to come back and say so: a viewer that crashes after the download, or a
client that never implements the call, leaves a photo that is provably gone
showing on the sender's row as still waiting. The two are normally under a
second apart, and where they differ the claim is the one that is true.

`viewed_at` is still recorded — it is the only thing that knows a photo was
looked at rather than merely fetched — and iOS still uses its own local answer
to that question to decide whether to offer a reply (`ViewerModel.wasSeen`).

**Would reopen if** a receipt ever needed to distinguish "downloaded" from
"seen" on the server, which would mean reporting both marks rather than swapping
one for the other.

---

## The receipt rides on the conversation, not a sent-items endpoint

**Chosen** `lastSentReceipt` on each `GET /api/v1/instant/conversations` entry:
the newest photo the caller sent that person, within 48 hours.

**Rejected** an endpoint listing the instants you have sent, with their states.

**Because** a row has space for one line, and the question it answers is "did
the last one land" rather than "what have I sent". The inbox already refreshes
conversations on every socket event, every foreground and every pull — a sent
list would be a second endpoint, a second cache, and a second thing to reconcile
with the first, for strictly less than one line of text per row. The rows are
swept after 30 days anyway, so it could never be a real history.

**Cost paid** a third query in `backend/src/instant-conversations.ts`, and the
fact that a photo sent to several people reports only the newest one per person.

**Would reopen if** the app ever grew a screen about your own sending — a
per-photo list of who opened what — which a conversation row cannot carry.

---

## Streaks count sends, not opens

**Chosen** a streak advances on sending, whether or not the photo was ever
opened.

**Rejected** counting opens.

**Because** streak state must not depend on key material the server cannot
reason about. An instant that expired unopened, or that could not be decrypted,
still counts.

**Cost paid** the day boundary is UTC, so someone in a distant timezone sees it
roll over at an odd local hour. Storing a per-user timezone was not worth it.

---

## Admin is an email allowlist, not a column

**Chosen** `ADMIN_EMAILS`, resolved per request by
`backend/src/admin-config.ts`.

**Rejected** a role column or a roles table.

**Because** there are very few administrators and they change roughly never.

**Cost paid** promoting somebody is a secret change and a redeploy, and every
admin request costs a user lookup. Both are fine at this scale and would not be
at another.

---

## A group is looked up per request, not carried in the JWT

**Chosen** `backend/src/groups.ts` resolves the caller's group on every request.

**Rejected** putting `groupId` in the access token.

**Because** moving somebody between groups then takes effect immediately rather
than at their next sign-in — which matters when the reason for moving them is
usually a review deadline or a mistake.

---

## The APNs environment rides in `provider`

**Chosen** `provider` holds `"apns"` or `"apns-sandbox"` on the shared
`user_push_subscriptions` table.

**Rejected** a separate environment column.

**Because** the same device token is invalid across environments and they must
be told apart; encoding it in the existing column avoided a migration.

**Cost paid** a deliberately overloaded column, which is why it is written down
here and in [data-model.md](data-model.md).

---

## Three backend entrypoints

**Chosen** `src/index.ts` (the app, Node-safe), `src/worker.ts` (Workers),
`src/server.ts` (Node dev).

**Rejected** one entrypoint.

**Because** `src/instant-inbox.ts` imports `cloudflare:workers`, which does not
resolve under Node — so re-exporting the Durable Object from `index.ts` would
break the Node dev server for the entire app.

**Cost paid** `npm run dev` is not the real backend, and the difference has to
be remembered. See [gotchas.md](gotchas.md).

---

## Filters, drawing and captions are baked into the pixels

**Chosen** all three are applied before the photo is sealed.

**Rejected** sending a filter name, strokes or caption text alongside the
ciphertext.

**Because** the server holds nothing but ciphertext, so there is no later moment
at which any of them could be applied — and nothing about the photo's content rides
on the wire in the clear.

**Cost paid** the caption's geometry has to match between two clients; see
[parallel-implementations.md](parallel-implementations.md).

---

## The iOS composer does more than the web's

**Chosen** several captions per photo on iOS, each either a full-width bar (the
default) or a plate that drags anywhere, turns, and pinches between 0.5× and 3×
(`OverlayCompositor.scaleRange`), and drawing with a finger. The web composer
keeps its single plate and does not draw.

**Rejected** holding iOS to what the web can do, and porting the styles or the
pen to the web in the same change.

**Because** captions and drawings arrive as pixels, so nothing that receives a photo depends
on which client composed it. The web composer is a harness for the protocol
rather than the product's camera ([web-client.md](web-client.md)).

**Cost paid** the two composers no longer offer the same things. Only the plate
at scale 1 is held in parity.

**Reopen if** the web composer becomes a camera people use day to day.

---

## Filters are chosen after the shot, not in the viewfinder

**Chosen** `PhotoFilter` on the compose screen.

**Rejected** a filtered viewfinder.

**Because** `AVCaptureVideoPreviewLayer` draws buffers the capture system hands
it directly, with nowhere to hang a `CIFilter`. A filtered viewfinder means
replacing the preview with a video-data-output and a Metal path — a large amount
of machinery for a preference.

---

## The widget is the picture

**Chosen** the sender's profile picture fills the whole widget, with the name,
the count and the streak over a scrim along the bottom.

**Rejected** the picture as a circle above the name.

**Because** a widget is looked at from across a room, at a size where a
68-point circle is a smudge and the only thing carrying who it is from is the
name. The photograph is the one part of the widget legible at a glance, so it
gets the whole of it. It is also what Instant is about: the app is photographs
of people, and a home screen that shows a face reads as one of them.

**Consequence** everything else has to survive being drawn over an arbitrary
photograph — hence the scrim gradient and the shadow on the type in
`ios/Shared/InstantWidgetView.swift`, and the cached pictures being kept at the
widget's size rather than an avatar's in `WidgetSnapshotPublisher.downsized`.

**Would reopen it** a tinted or accented widget family, where a photograph is
desaturated to a single colour by the system and stops being a face at all.

---

## The app publishes the widget's data; the widget only reads

**Chosen** `InstantStore` writes a snapshot into the
`group.com.eduardcazacu.instant` App Group, and the widget renders what is on
disk.

**Rejected** the widget calling the API.

**Because** an extension can reach neither the access token nor the refresh
cookie, and a token lives fifteen minutes — a widget refreshing on WidgetKit's
schedule would find an expired one nearly every time. No credential ever enters
the extension.

**Consequence** the Notification Service Extension keeps the snapshot fresh
while the app is closed, which is why the push payload carries the sender's
name and theme.

It also means **the widget never refreshes on a schedule** unless it is cycling
through several people: the snapshot changes only when something writes it,
and every writer asks for a reload. `WidgetTimeline.nextRefresh` in
`ios/Shared/WidgetTimeline.swift` returns `nil` for a timeline that does not
cycle. A 15-minute refresh was rejected because it spent WidgetKit's daily
reload budget re-reading an unchanged file, and a spent budget is what
silenced the extension's reload when an instant arrived.

---

## iOS does not consume `common/`

**Chosen** `ios/Instant/Core/Networking/DTOs.swift` mirrors the wire types by
hand.

**Rejected** generating Swift types from the Zod schemas.

**Because** a code generator is a build dependency and a toolchain to maintain,
for a surface that is small and changes slowly.

**Cost paid** renaming a field in `common/src/index.ts` silently breaks a Swift
decode that nothing in the TypeScript build can see. Field names are kept
explicit and stable for this reason.

---

## Themes are inline styles, not Tailwind config

**Chosen** `THEME_PALETTES` in `frontend/src/themes.ts`, applied inline.

**Rejected** Tailwind theme extension or CSS custom properties on an ancestor.

**Because** the palette in play belongs to whichever *user* you are looking at
and changes per card within a single feed. It is data, not a design token.

---

## Blocks answer 404

**Chosen** a send to somebody who has blocked you is indistinguishable from a
send to somebody who does not exist.

**Rejected** a 403 explaining the block.

**Because** anything more informative lets a block be probed for.

**Known limit** blocks cover Instant and the user list. Blog posts and chat are
not filtered by them.

---

## A wrong password on account deletion is 400

**Chosen** 400, breaking the 403-means-auth-failure rule on purpose.

**Rejected** 403.

**Because** clients answer 403 with a token refresh, so a typo would sign the
person out instead of showing an error.

---

## The interop fixture generators import the real implementation

**Chosen** `ios/tools/gen-interop-fixtures.ts` imports
`frontend/src/lib/instantCrypto.ts` itself.

**Rejected** a standalone reference implementation in the test tooling.

**Because** a generator that restated the algorithm would happily agree with a
Swift port carrying exactly the same misunderstanding — which is the failure the
fixtures exist to catch.

---

## iPhone only

**Chosen** `TARGETED_DEVICE_FAMILY = 1`.

**Rejected** declaring iPad support.

**Because** the camera and the pager are phone-shaped, and a portrait-only app
that declares iPad support fails App Store validation. iPads run it in
compatibility mode.

---

## Sign-up and password reset link out to the web

**Chosen** the iOS app sends people to the browser.

**Rejected** in-app forms.

**Because** both need an email verification link and then admin approval, so an
in-app form could only ever end on a waiting screen.

---

## iOS tests run filtered and optimized by default

**Chosen** an everyday `xcodebuild test` that runs only the suites covering the
change (`-only-testing`), compiles with `-O`, skips failure diagnostics
(`-collect-test-diagnostics never`) and has per-test time limits. The command is
in [ios-client.md](ios-client.md).

**Rejected** running the full suite with default settings on every change.

**Because** on the Simulator the default run is slow, and a failing one is
much slower: by default xcodebuild spends about ten minutes collecting crash logs
and diagnostics before it reports the failure, which the `✘` lines already
explain. `ENABLE_TESTABILITY=YES` goes with `-O` so `@testable import` still
builds.

**Cost paid** an optimized build can hide a bug that only shows up in an
unoptimized Debug build, and a filter can skip the suite that would have caught
a regression somewhere else. The full suite, with default settings and
coverage, still runs when a change crosses areas and before merging to
`main`.

**Would reopen if** a failure turns up that only a Debug build reproduces, or
if the full suite becomes fast enough that filtering saves nothing.

---

## Instant pushes go to the app, and to the browser only as a fallback

**Chosen** `appFirst` in `sendPushToUsers`: APNs is sent first, and a person's
Web Push subscriptions are used only if Apple accepted nothing for them.

**Rejected** sending to every subscription, which gave someone with both the
app and a subscribed browser two banners for one photo. Also rejected: a
per-user "prefer the app" setting, and dropping Web Push for anyone with an APNs
row without trying it. The setting would have been a choice nobody wants to
make. Dropping without trying would have silenced everyone whose token had
gone dead, since a dead token is only found out by sending to it.

**Because** the native app is the real Instant client (see
[product.md](product.md)), and Apple's answer is the only live signal of
whether the app is still installed. Waiting for it costs one round trip,
inside a background job.

**Cost paid** Apple accepts a notification even when iOS will not show it, so
someone who switched Instant's notifications off in iOS Settings gets no
browser banner either. Only instant and streak pushes are app-first; blog and
chat pushes go to the browser regardless, because the app has no blog or chat.

**Would reopen if** the web client stopped being a harness, or the app
reported its notification permission to the server.

---

## The iOS inbox is cached on disk

**Chosen** `InboxCache` writes the waiting instants and the conversation
history to Application Support on every change, and a cold start draws them
before anything is fetched.

**Rejected** starting empty and waiting for the network, which put "No
conversations yet" under every notification tapped from a cold start. Also
rejected: caching the history but not the instants. That shows the rows but
not what is waiting in them, and what is waiting is what the tap was for.

**Because** the cache holds nothing new. The envelopes are sealed to this
device's Secure Enclave key, no received photo or clip is ever on disk, and names and
pictures are already in the widget snapshot. It is written with
`completeFileProtectionUntilFirstUserAuthentication`, cleared on sign-out, and
ignored if it belongs to a different account.

**Cost paid** for about one round trip, the inbox can show an instant that was
opened on another device, which answers 410 if tapped in that window. The
viewer already handles an instant that is gone.

**Would reopen if** the inbox ever carried something the device could not
already see, such as decrypted content or a preview.

---

## Sends happen in the background, and only the sealed form is kept

**Chosen** the compose screen closes on the tap, and `Outbox` does the key
lookup, rendering, sealing and upload afterwards. A send is written to disk
once it is sealed, and survives a force quit until the server accepts it.

**Rejected** keeping the compose screen up until the upload finishes, which
took seconds. Also rejected: writing the rendered photo to disk so that even the
sealing window survives a kill, because the app never keeps a photo and a
sealed one opens only on the recipient's devices. A recorded clip is the one
exception, and only because AVFoundation records to nothing but a file: it sits
in `CaptureScratch` until it has been encoded, and is not kept past that. A background `URLSession`
upload was rejected too. It would need its own path around `APIClient`'s
token refresh, and background time covers the ordinary case of switching
apps.

**Cost paid** a send killed before it is sealed is lost without a trace. That
is the length of the encode: about 0.2 s for a photo in a Release build,
several seconds in a Debug one, and a second or two for a clip. A send killed between the server storing it
and the app hearing so goes twice (see [gotchas.md](gotchas.md)). A sealed send
restored after the recipient's devices changed can be rejected, and only a
retry with the photo still in memory can seal it again.

**Would reopen if** a lost or doubled send turns up in practice. The fix for
doubling is a client-generated id that the server deduplicates on, which is a
change to `createInstantInput` and so to `DTOs.swift`.

---

## Update notes go to people who were already signed in

**Chosen** the "what's new" sheet appears when the notes' version differs from
the one recorded in `UserDefaults` and the person was already signed in. A
sign-in records the notes as seen.

**Rejected** comparing against a recorded bundle version. 1.0 recorded nothing,
so every 1.0 install would have looked like a fresh one and the first notes
would have reached nobody. Also rejected: telling a fresh install apart by
what is in the Keychain, because Keychain items outlive deleting the app.

**Cost paid** someone who reinstalls and still has a session in the Keychain
sees notes for a version they never used. Someone who was signed out when the
update landed never sees them.

**Would reopen if** the notes start saying something a person must read, such
as a changed behaviour they would otherwise be surprised by. Then signing in
should not count as reading them.

---

## Compose and viewer choices are remembered per device

**Chosen** duration, loop, both speakers and the pen colour are kept in
`UserDefaults` on the phone (`ios/Instant/Core/Store/Preferences.swift`).

**Rejected** storing them on the account. That is a table or a column, a route,
a schema in `common/src/index.ts` and its mirror in `DTOs.swift`, for choices
that cost one tap to redo when wrong. They also describe how someone uses this
phone rather than anything about them: the web client, which is a harness, has
no reason to inherit a pen colour.

**Cost paid** a reinstall or a second phone starts from the defaults.

**Would reopen if** people use Instant on more than one device routinely and
notice.

---

## A photo to several people is several instants

**Chosen** the iOS client fans out: one `POST /api/v1/instant` per recipient,
each sealed to that person's devices with its own ephemeral key. The photo is
encoded once and shared across them (`Outbox.send`).

**Rejected** one upload carrying envelopes for every recipient's devices. That
changes `createInstantInput`, `DTOs.swift` and the row's single recipient, and
it breaks read-once: `GET /:id/media` destroys the object for everyone, so the
first person to open it would take it from the rest. Streaks and blocks would
each need a per-recipient answer too.

**Cost paid** the same bytes are uploaded, and written to the outbox on disk,
once per person. At the size of the member list that is a few megabytes. The
web client still sends to one person at a time; it is a harness.

**Would reopen if** the Lounge grew enough that sending to everyone meant
uploads the phone could not finish in its background time.

---

## Video is HEVC

**Chosen** HEVC in an MP4, 1080×1920 at about 3 Mbps, with the codec string in
`mediaType` (`VideoPipeline.mediaType`).

**Rejected** H.264, which every browser plays.

**Because** HEVC is about 40% smaller at the same quality, and the send
endpoint's 3 MiB ceiling is a ceiling. Five seconds of HEVC at a bitrate that
looks like video is about 2 MB; H.264 at the same quality would crowd the limit
and need a lower bitrate to fit. The phone is the real client, and Safari and
most Chrome builds decode HEVC.

**Cost paid** Firefox, and some Linux and Android browsers, cannot play a clip.
The web viewer finds out with `canPlayType` *before* the one-shot fetch and
leaves the clip waiting for the phone, since asking after would be asking about
something already destroyed.

**Would reopen if** the people using the web client are mostly on browsers
without HEVC — then H.264, or both, with the sender choosing by who is
receiving.

---

## Video has sound, and the microphone is on while the camera is

**Chosen** clips record with sound, and the microphone input is part of the
capture session from the moment the camera starts. Permission is asked for with
the camera's, and a refusal records silent clips.

**Rejected** adding the microphone when a hold begins and removing it after,
which keeps the indicator off while framing. Adding an input rebuilds the
running session's pipeline, and the camera re-meters: the first frame or two
of every clip flickered. Also rejected: a separate audio-only session feeding
an `AVAssetWriter` beside a video data output, which keeps the indicator off
without touching the camera's session, at the price of rewriting recording and
syncing the two by timestamp. Also rejected: silent video, which feels less like
a message than a moving photo.

**Cost paid** the microphone indicator is lit whenever the camera screen is
open, which is the home screen. Every camera app that records sound does the
same.

**Would reopen if** the indicator draws complaints — then the separate audio
session, not a return to attaching on the hold.

---

## A received clip plays from memory

**Chosen** `AVVideoPlayback` hands the player a made-up URL scheme and serves
it from the decrypted bytes through an `AVAssetResourceLoaderDelegate`
(`InMemoryAssetLoader`).

**Rejected** writing the plaintext to a temporary file, which is all
`AVPlayer` asks for.

**Because** no received photo is ever on disk, and the disk cache of the inbox
is justified on exactly that ground. A temporary file of a decrypted clip
would survive a crash mid-view, where nothing would ever delete it.

---

## Builds from before video were left to break

**Chosen** shipping the `once` and `loop` duration modes without gating them
on what the recipient's app understands.

**Rejected** a capability flag on device registration, which senders would
check before offering video.

**Because** the builds before video decode `InstantDurationMode` strictly, so a
single clip fails the decode of their entire inbox — but the people on them are
a dozen, on builds the maintainer ships. A flag would have been a field on
`registerInstantDeviceInput` and `DTOs.swift` and a rule in the send path, kept
for good, to cover a gap that closes the day everybody updates. The Swift
decoder maps an unknown mode to `5s`, so a mode added after this one cannot do
it again.

**Would reopen if** Instant ever had users who do not update promptly.

---

## A copy can be kept from compose, never from the viewer

**Chosen** a save button on the compose screen, which writes the composed
photo or clip to the sender's own photo library with add-only permission.

**Rejected** the same button in the viewer, on a received instant.

**Because** what compose holds is the person's own capture, which they are
about to send and may want to keep; nothing about it is anyone else's. A
received instant is the other way round: it expires, and it was sent on that
understanding. A screenshot is always possible, and the sender is told about
one; a save button would be the app helping, quietly.

**Cost paid** a photo saved from compose is not quite the file the recipient
gets — full size in the library rather than the wire's quarter-megabyte WebP.
The pixels are the same; the compression is not.

---

## A 3D photo's outline comes from Vision, and each layer is warped on its own

**Chosen** `VisionSubjectMasker` asks Vision for a mask per subject, falling
back to the person mask, and the renderer cuts the picture into layers at
those outlines: each is warped on its own, with its own alpha, and they are
composited back to front. A face found inside a mask becomes that layer's key
plane.

**Rejected** the person request as the first choice, though people are what
Instant sends: on the sample photos it finds the same person as the subject
request with a wispier outline, and on a photo with no people in it, it
answers with confident nonsense. Also rejected: using the masks only to
correct the depth map, and keeping the single pass. It puts the edge in the right place but every pixel still belongs
wholly to one side of it, so fine hair stays ragged — an outline can only be a
cut. Also rejected: leaving it to the depth map, which is what shipped first.

**Because** an estimated depth map has no outline to speak of. Its edges are
ramps a few pixels wide that sit a little off the subject, and it reads a body
leaning towards the camera as an edge — so a slanted person came out terraced
and glitching along the outline. A matte answers both: where the subject ends,
and what share of a rim pixel is it.

**Cost paid** Vision runs on every first 3D tap, beside the depth model. A
photo it finds no subject in renders as before, by the depth map alone, which
is two paths through the renderer to keep working.

**Would reopen if** the depth model gets good enough at edges that the masks
add nothing, or Vision gains a matte that carries depth with it.

---

## 3D is rendered on the sender, as a clip, from estimated depth

**Chosen** the 3D button estimates the photo's depth on the phone with Depth
Anything V2 Small (Apple's Core ML conversion, 8-bit palettized, 24 MB,
Apache-2.0), renders four viewpoints from it, and writes them out as a silent
clip, 1-2-3-4-3-2 eight times over (`DepthEstimator`, `ParallaxRenderer`).
From there on it is a clip: the same encode, seal, wire format and viewer.

**Rejected** the depth the camera measures (TrueDepth, dual cameras). It was
built twice and taken out both times. On every photo, a device delivering
depth restricts its own zoom, so the back camera's pinch stalled and jumped
and the front camera's did nothing (see [gotchas.md](gotchas.md)). As a camera
mode chosen before the shot, zoom worked outside it, but 3D could never be
decided after the photo, and the mode took the camera's zoom and its movie
output away while on. Also rejected: Apple's own photo-to-3D generator,
`ImagePresentationComponent.Spatial3DImage`, which is visionOS only; and
sending the photo with its depth to be wiggled on the recipient's screen — a
new media type and a contract on three sides and the web, for something the
sender has to see before sending anyway.

**Because** estimating after the shot leaves the camera exactly as it was —
zoom, zero shutter lag, shutter speed — and gives every photo 3D, including
zoomed ones, library ones and those from a phone with one lens. A clip needs
nothing new anywhere past the compose screen.

**Cost paid** 24 MB of app, and the first 3D tap loading the model. The
parallax is a guess twice over: at the depth, and at what was behind the
subject, which is copied from the background beside it.

**Would reopen if** iOS gets a public depth-estimation or spatial-scene API,
or camera depth stops restricting zoom.
