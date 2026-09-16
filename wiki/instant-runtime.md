# Instant at runtime

How a photo gets delivered, read once, and forgotten. The encryption contract is
in [instant-protocol.md](instant-protocol.md).

## Transport: one Durable Object per person

`backend/src/instant-inbox.ts` defines `InstantInbox`, addressed `user:<id>` via
`idFromName`. It is **a pure relay**: no durable storage, no Prisma, no R2. The
Worker owns the database and the bucket and calls the object over RPC.

It uses the **WebSocket Hibernation API** (`ctx.acceptWebSocket`), so an idle
inbox accrues no billable duration while its clients stay connected. Each socket
carries `{ userId, deviceId }` in `serializeAttachment`, which is how
`deliver(meta, envelopesByDeviceId)` sends each connected device only **its own**
envelope rather than broadcasting all of them.

`deliver()` returns whether it reached anybody. If it did not, the Worker sends a
push instead.

### The WebSocket ticket

Browsers cannot set an `Authorization` header on a WebSocket. So
`POST /api/v1/instant/ws-ticket` mints a 60-second JWT carrying
`aud: "instant-ws"` and the `deviceId`, and `GET /api/v1/instant/ws` verifies it,
re-confirms the device row still exists, and forwards the raw request to the
object. Access tokens are refused at `/ws` and tickets are refused on the REST
routes; see [accounts.md](accounts.md).

### The keepalive is a literal string

Clients send the text frame `"ping"` every 25 seconds and the object's
`setWebSocketAutoResponse` answers with the bare string `"pong"`, which does not
wake it from hibernation. It is **not** a protocol-level WebSocket ping — those
never reach the auto-responder. See [gotchas.md](gotchas.md).

### Without the binding

Under `npm run dev` there is no Durable Object, so `/ws` answers **501** with an
explanation and clients fall back to polling. The web hook surfaces that as
`connection: "unsupported"` and stops retrying rather than reconnecting forever.
`npm run dev:worker` is the one with a real object.

Both clients **drain `GET /api/v1/instant/inbox` before every connect**, not
after, so nothing that arrived while the socket was down is missed.

## Sending

`POST /api/v1/instant` is multipart: the ciphertext as `media` (3 MiB ceiling)
plus a JSON `payload` validated by `createInstantInput` from `common/`.

The checks, in order: recipient is in the same group, approved and verified;
no block exists in either direction; and **every envelope targets a distinct
device actually owned by the recipient**. A block answers 404 — identical to the
response for a user who does not exist — so a block cannot be probed for.

Then the object goes to R2 at `instant/<uuid>` with `cacheControl: no-store`,
the row and its envelopes are written (and the R2 object deleted again if that
fails, so nothing is orphaned), `recordSend` advances the streak, and delivery
is attempted over the Durable Object, falling back to push.

## Reading destroys

`GET /api/v1/instant/:id/media` **claims the row with an `updateMany` before it
reads R2**. The ordering is the whole mechanism:

- A second request can never be served — including from another device the same
  recipient owns, which gets a **410**.
- A download that fails mid-flight loses the photo. That is a real cost, and it
  is the same trade Snapchat makes.

Having claimed it, `destroyInstantMedia` nulls `mediaKey`, `mediaIv` and
`ephemeralPubKey`, deletes every envelope, and deletes the R2 object.

Clients must guard this with a flag that can only flip once —
`ios/Instant/Features/Viewer/ViewerModel.swift` does, and so does
`frontend/src/components/instant/InstantViewer.tsx`. A retry is not a retry
here; it is a lost photo.

### Three independent backstops

1. **Delete on fetch**, above.
2. **The hourly cron** — `runInstantSweep` in `backend/src/scheduled.ts` expires
   anything unopened after 24 hours, drops rows older than 30 days, lapses
   streaks and warns the at-risk ones, in batches of 200.
3. **An R2 lifecycle rule** on the `instant/` prefix, which is **not expressible
   in `wrangler.toml`** and must be added by hand. See
   [operations.md](operations.md).

The sweep deletes the R2 object **before** clearing `media_key`, and skips a row
entirely when the `BLOG_IMAGES` binding is missing — reported as
`skippedWithoutBucket` — because the row is the only thing that knows which
object belongs to it. Clearing the key first strands the ciphertext forever.

For the same reason `POST /api/v1/user/me/delete` removes the R2 objects of
every un-opened instant the person sent or received *before* the cascade takes
the rows naming them.

Cron triggers fire under neither dev server, so the sweep is also reachable as
`POST /api/v1/admin/instant/sweep` (admin only), running exactly the same
function.

## Streaks

`backend/src/instant-streaks.ts`. One row per ordered pair, keyed `(min, max)` —
see [data-model.md](data-model.md).

A streak advances **once per UTC day**, and only when both people have sent to
the other within the last 24 hours. It lapses when either side's most recent
send ages past that window. Note the UTC boundary: someone in a distant timezone
sees the day roll over at an odd local hour. That is a known cost of not storing
a per-user timezone.

**Streaks count sends, not opens.** An instant that expired unopened, or that
could not be decrypted, still counts. This is deliberate — streak state must not
depend on key material the server cannot reason about.

Streaks of 7 days or more push **both** people when they are within 4 hours of
lapsing, at most once a day (`warnedForOn`).

## Conversations

`GET /api/v1/instant/conversations` lists everyone you have exchanged instants
with, newest first, **whether or not a streak is running**. `/streaks` answers a
different question — "what am I about to lose" — and deliberately hides a lapsed
one. An inbox needs "who do I talk to".

No schema was added for it; it reads the streak table, which is already a
permanent conversation index. See [data-model.md](data-model.md).

Each entry carries `lastInteractionAt`, `lastSentAt` and `lastReceivedAt`
oriented to the caller (the same row read from the other side swaps them),
`unopenedCount`, and the streak as `streakCount` (0 when lapsed),
`streakDeadline` and `streakAtRisk`. Partners who are not approved and verified
are filtered out, matching the rest of the API — listing somebody unaddressable
would only offer a send that 404s.

None of this reads media, keys or envelopes. It is metadata the server already
holds in the clear.

```bash
cd backend && npx tsx scripts/verify-conversations.ts
```

Drives the query against an in-memory fake, so states that are awkward to reach
against a real database — a streak that lapsed months ago, a partner who was
never approved, a conversation older than the 30-day sweep — are all covered.

## Push

`backend/src/push.ts` and `backend/src/apns.ts`. Web Push and APNs share one
table, with the APNs environment riding in `provider`; see
[data-model.md](data-model.md).

`backend/src/apns.ts` signs Apple's short-lived ES256 provider token with
WebCrypto — ECDSA P-256 with SHA-256 produces the raw `r‖s` pair JWS expects,
with none of the DER unwrapping Node's `crypto` would need. The token is cached
and re-signed roughly every 50 minutes, because Apple rejects tokens older than
an hour and rate-limits minting them. A `410 Unregistered` or `400 BadDeviceToken`
deletes the subscription, mirroring the 404/410 cleanup the Web Push path
already does — otherwise the hourly sweep would retry dead tokens forever.

**Only `sendPushToUsers` reaches APNs.** The five older senders —
`notifyFollowersOfNewPost`, `sendTestNotificationToUser`,
`sendBroadcastNotification`, `notifyPostAuthorOfReply`, `notifyMentionedUsers` —
hard-code Web Push and pre-filter with `isDeliverableWebPush`, so an APNs row is
invisible to them. Instant's own notifications and the streak warnings go
through the generic dispatcher and do reach iOS. Anyone adding a notification
type should know which of those two they are writing.

The Instant push carries the sender's id, name, theme and picture URL in `data`
alongside `instantId`. That is for the iOS Notification Service Extension, which
updates the home-screen widget on delivery and holds no token with which to call
the API. The payload still carries no media and no key material, and the
notification's title already reveals the sender's name, so it discloses nothing
new. See [ios-client.md](ios-client.md).

Until all four `APNS_*` secrets exist the APNs branch reports itself
unconfigured rather than throwing, so the iOS app can register tokens before the
Apple Developer account does. Adding the secrets starts delivery with no code
change.
