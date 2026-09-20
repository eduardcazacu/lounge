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

## The native app is the product; the web client is a harness

**Chosen** iOS as the real endpoint for Instant.

**Rejected** treating the React `/instant` page as the primary client.

**Because** browser end-to-end encryption is only ever as strong as the channel
delivering the JavaScript, and that channel is a Vercel deployment that can
serve different code tomorrow. A non-extractable `CryptoKey` stops a script
copying the key out, not from using it in place. A signed binary is where the
guarantee is actually strong.

The web client says this to the user rather than hiding it
(`frontend/src/components/instant/InstantKeySetup.tsx`).

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
device's Secure Enclave key, the photos are never on disk, and names and
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
sealed one opens only on the recipient's devices. A background `URLSession`
upload was rejected too. It would need its own path around `APIClient`'s
token refresh, and background time covers the ordinary case of switching
apps.

**Cost paid** a send killed before it is sealed is lost without a trace. That
is the length of the WebP encode: about 0.2 s in a Release build, several
seconds in a Debug one. A send killed between the server storing it
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
