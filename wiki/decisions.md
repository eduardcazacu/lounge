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

## Filters and captions are baked into the pixels

**Chosen** both are applied before the photo is sealed.

**Rejected** sending a filter name or caption text alongside the ciphertext.

**Because** the server holds nothing but ciphertext, so there is no later moment
at which either could be applied — and nothing about the photo's content rides
on the wire in the clear.

**Cost paid** the caption's geometry has to match between two clients; see
[parallel-implementations.md](parallel-implementations.md).

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
