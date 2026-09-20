# Things that fail silently

Every entry here produced no error, no warning and no failing test — just wrong
behaviour, found later. They are written down so that nobody has to find them
twice.

Read this alongside [instant-protocol.md](instant-protocol.md) before touching
any crypto.

## Crypto and the wire

**`deviceId` case.** `crypto.randomUUID()` is lowercase; Swift's
`UUID().uuidString` is uppercase. The id is inside the HKDF `info` string, so the
wrong case derives a different key and produces envelopes **nobody can ever
open** — with no error until decryption fails, on someone else's device, later.
Both sides use lowercase.

**HKDF salt is the raw 65 bytes** of the ephemeral public key, not its base64url
text. Both are 'a string of bytes' to the API; only one is right.

**AES-GCM layout.** WebCrypto emits `ciphertext || tag16` and carries the nonce
separately, so CryptoKit's `SealedBox.combined` — which prepends the nonce — is
the wrong shape. Use the three-argument initialiser.

**base64url must be unpadded.** The server answers 400 for padding, which at
least is loud; the quiet version is a decoder that accepts both and a comparison
that does not.

**Safety numbers sort by UTF-8 bytes** in Swift, to match JavaScript's UTF-16
code-unit ordering. The two agree for ASCII, which is a coincidence and not a
guarantee.

## Auth

**Auth failures are 403, not 401.** Refresh keys off 403, or the 15-minute
access token quietly ends the session with no visible error.

**Refresh renews a session; it must never start one.**
`POST /api/v1/user/refresh` authenticates from the `refresh_token` cookie alone,
so a signed-out client that answers its first 403 by refreshing will silently
adopt whichever account that ambient cookie belongs to. Both clients refuse to
refresh while holding no token.

This is not theoretical. It was caught on a Simulator, where cookie and Keychain
storage are not sandboxed per app the way they are on a device, and the app came
up signed in as the machine's owner.

**A wrong password on account deletion is 400, deliberately.** If it were 403,
clients would treat a typo as an expired session and answer it with a refresh.
Do not "fix" it.

**Keychain items outlive the app.** Deleting an iOS app does not clear its
Keychain, so a stale session survives a reinstall. `SessionStore` discards a
stored value it cannot read an id out of, rather than reporting a session it
cannot use.

## Endpoints

**`GET /api/v1/instant/:id/media` is destructive.** The server claims the row
before reading R2, so it can succeed exactly once ever — across every device the
recipient owns. A retry is not a retry; it is a lost photo. Guard it with a flag
that can only flip once.

**`PUT /api/v1/user/me` wipes `bio` if you omit it.** Always send the current
text.

**A block answers 404, not 403.** That is the point — a block must be
indistinguishable from a user who does not exist, or it can be probed for. Do
not make it more informative.

## The backend's two runtimes

**`backend/src/index.ts` must stay Node-safe.** `backend/src/instant-inbox.ts`
imports `cloudflare:workers`, which does not resolve under Node. Re-exporting
the Durable Object from `index.ts` breaks `npm run dev` for the **whole app**,
not just for Instant. That is why `src/worker.ts` exists separately.

**`npm run dev` is not the real backend.** No Durable Object, no R2. `/ws`
returns 501 and the media endpoints cannot work. Use `npm run dev:worker` for
anything touching Instant's transport or storage.

**Cron fires under neither dev server.** Use
`POST /api/v1/admin/instant/sweep`, which runs the same function.

**Delete the R2 object before clearing `media_key`.** The row is the only thing
that knows which object belongs to it; clearing the key first strands the
ciphertext where no sweep can ever find it. Same reason account deletion removes
objects before the cascade.

**Only `sendPushToUsers` reaches APNs.** The five older senders hard-code Web
Push and pre-filter with `isDeliverableWebPush`, so an APNs row is invisible to
them. A new notification type added to the wrong one reaches every browser and
no iPhone. See [instant-runtime.md](instant-runtime.md).

## Realtime

**The keepalive is a literal text frame `"ping"`**, answered by the Durable
Object's auto-response with the bare string `"pong"`. It is *not*
`URLSessionWebSocketTask.sendPing` or a protocol-level ping — those never reach
the auto-responder, and the connection dies quietly.

**Drain the inbox before connecting, not after.** Anything that arrived while
the socket was down is otherwise missed.

**An open browser tab swallows the push.** The Worker pushes only when
`deliver()` reached no socket (`backend/src/route/instant.ts`). While the web
client is open anywhere, that tab receives the instant, so the phone gets no
notification and its widget does not update until the app next opens. This is
known and has been left as it is.

## The web client

**React StrictMode double-invokes an impure state updater.** Dedup bookkeeping
inside a `setInstants` updater drops the instant. It is kept outside the updater
in `frontend/src/hooks/useInstant.ts` for exactly this reason.

**One `localStorage.token` is shared by every tab.** A second account signing in
anywhere re-points all of them, and the Instant identity is per-account — hence
the 5-second poll in `useSignedInUserId` and the re-check mid-keygen.

**`refreshAccessToken` does not clear the token on failure**, because iOS PWAs
routinely fail to send the refresh cookie. Clearing would sign people out for a
transient reason.

**iOS reports stale landscape `videoWidth`/`videoHeight`.** They arrive in the
camera's native orientation and are updated after the fact, so any aspect ratio
read from them is both wrong to begin with and stale after a rotation.
`CameraScreen.tsx` stores none and tells the element nothing: the video is
`max-h-full max-w-full` inside the viewport and lays itself out, so it corrects
itself when the numbers do.

**Constraining both axes of `getUserMedia` states an aspect ratio.** Asking for
`width: 1080, height: 1920` looks like asking for a sharp portrait frame, and a
browser that has no such mode natively satisfies it by cropping the sensor
instead — on a phone that is a threefold crop of the middle of the picture, and
nothing reports it: the preview looks like a camera, just a suspiciously narrow
one. Constrain one axis and leave the shape to the camera.

**A caption preview that wraps its own text drifts from the file.** Canvas has
no text wrapping, so the burn-in has to wrap the caption itself — and if the
preview then lets CSS wrap the same string, the two agree until they do not.
The break lands in a different place in the photo that was sent from the one on
screen, and nobody finds out, because the sender never sees the file.
`frontend/src/components/instant/overlay.ts` exports `wrapLines`, the preview
renders the lines it returns, and the compositor draws the same ones.

**A control that acts on what is being typed has two ways to never run.** The
caption editor dims the photo with a full-frame layer, and the text button that
restyles the caption being typed sits in the rail above it. Give that layer a
`z-index` and it paints over the rail and eats the click; close the editor on
`blur` and the click arrives after the caption has already been committed, so
the button acts on nothing. Neither errors, and the button looks live either
way. The editor in `ComposeScreen.tsx` carries no `z-index` — `ViewportOverlay`
is a later sibling and paints above it — closes only on the dim layer, Return or
Escape, and the button both `preventDefault`s its mousedown and hands the caret
back afterwards.

**`loadImageElement` revokes the object URL it loaded from.** The element keeps
its decoded bitmap, so the image still draws — but `element.src` is a dead
`blob:` URL by the time anybody reads it, and putting it back into an `<img>`
renders nothing at all, silently. Anything that needs a URL for the same bytes
makes its own.

## iOS

**Install the `UNUserNotificationCenter` delegate at launch**, not after
sign-in. iOS hands a notification tapped from a cold start to whatever delegate
exists when launching finishes, once — set it later and the tap is dropped
silently, and the app comes up on the camera.

**A notification's instant is usually not in the inbox yet** on a cold start, so
the id stays pending until it lands rather than being dropped on the first miss.

**Dropping a cached instant must also drop it from the seen-set.** The seen-set
exists so a drain cannot bring back an instant that was already dealt with. A
cached instant missing from the first drain is removed from both
(`InstantStore.dropUnconfirmed`). The inbox is paged, so a missing instant may
only be on a later page. If it stays in the seen-set, it never comes back.

**A new field on a cached type must be optional.** `InboxCache` decodes
`InstantConversationSummary` off the disk with `try?`, so a required property
the last build never wrote turns the whole cold-start inbox into nil — no error,
no log, just "No conversations yet" for the three round trips the cache exists
to cover, which reads as a slow launch rather than a decode failure.
`lastSentReceipt` is declared optional for exactly this reason.

**A force quit runs no code.** Swiping the app away in the switcher kills a
suspended process: `applicationWillTerminate` is not called, and neither is
anything else. Anything the app wants to say about an unfinished send has to be
scheduled before it is suspended. That is why the unsent-instant reminder is
scheduled on entering the background, and withdrawn if the send finishes.

**A send can go twice.** The sealed copy is deleted when the server's answer
arrives. If the app dies after the server stored the instant but before that
answer, the next launch sends the same ciphertext again. The server has no
idempotency key, so the recipient gets it twice.

**A widget reload can be ignored.** `WidgetCenter.reloadTimelines` comes out of a
daily budget of roughly 40 to 70, and scheduled refreshes (`.after`, `.atEnd`)
count against it. Once it is spent, the reload the Notification Service
Extension asks for is dropped without an error: the snapshot on disk is new but
the widget keeps showing the old one. It fixes itself the moment the app is
opened, because reloads from the foreground app are free, so it looks as though
tapping the widget is what updates it. Don't schedule refreshes that have no
new data to read, and don't reload for a snapshot the widget already shows:
`WidgetSnapshotPublisher.isAlreadyShowing` compares against the file on disk,
which the extension also writes. To rule the budget out on a device, turn on Settings →
Developer → WidgetKit Developer Mode, which lifts the limit.

**Widgets render synchronously off local state.** An image loaded at draw time
simply never appears, which is why the app caches profile pictures to the App
Group rather than letting the widget fetch them.

**Only `containerBackground` reaches a widget's edges.** A widget's content is
inset by the system's margins, so a picture meant to fill the widget that is
drawn inside the view's own `body` comes out a few points short on every side,
framed in whatever is behind it. Nothing errors — it just looks like a bad
crop. `ios/InstantWidget/InstantWidget.swift` hands the picture to
`containerBackground`, which is also why it is a separate view from
`InstantWidgetView`.

**The extension holds no credential and cannot call the API.** Anything the
Notification Service Extension needs must ride in the push payload.

**A widget that failed to update must never cost someone their notification** —
the banner is passed through untouched either way.

**An extension's code cannot be reached from the app's test bundle**, which is
why the widget's view and timeline live in `ios/Shared/` rather than in
`InstantWidget`.

**A gesture that outranks a tap still waits for it.** A `DragGesture` attached
with `highPriorityGesture`, or with a `GestureMask` meant to switch the others
off, on a view that also has a tap, had every `onChanged` held back and
delivered in one burst when the finger lifted. That is when the tap fails.
Nothing errors, and a UI test that checks only the end state passes. Take the
competing gesture out with `isEnabled:` instead (`ComposeScreen.swift`, the
drawing).

**A `Canvas` closure is not observed.** It runs after `body`, so an
`@Observable` property read only inside it does not redraw the canvas when it
changes. Read the value in `body` and let the closure capture it
(`DrawingLayer`).

**UI-test fixtures need relative timestamps.** A fixed future date in
`StubBackend` inverted the recency ordering and the failure looked like a
sorting bug.

**An `-only-testing` filter that matches nothing passes.** A misspelt suite name
runs zero tests and still prints `** TEST SUCCEEDED **`. The tests are Swift
Testing, so the XCTest `Executed 0 tests` summary appears on every run, whether
the filter matched or not. The real signal is Swift Testing's
`✔ Test run with N tests` line: if it is missing, nothing ran. The identifier is
the `@Suite` struct's name — `InstantTests/DeepLinkTests` — not the display
string passed to `@Suite`.

**New update notes under the old version string never appear.** The seen-key
is `WhatsNew.current.version`, not the text. Rewriting the notes without
changing `version` shows them to nobody who saw the last ones.
`WhatsNewTests` checks only that the notes do not name a version newer than
the app.

**A `.plain` button is hit-tested from what its label draws.** The full-width
capsule buttons painted their background *outside* the label, so the label drew
nothing but its word and only taps on the glyphs registered — the rest of the
capsule looked pressable and was dead. Nothing errors, and the UI tests pass,
because `XCUIElement.tap()` aims at the element's centre, which is exactly where
the text is. Give the label a `.contentShape` matching the visible shape
(`SignInView`, `TermsScreen`, `WhatsNewScreen`), or paint the background inside
the label as the circular buttons do.
