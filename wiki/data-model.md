# Data model

Postgres, via Prisma 7 with the `@prisma/adapter-pg` driver adapter. The schema
is `backend/prisma/schema.prisma` and it is the authority for columns and types;
this page is for the things the schema cannot say.

Table names are snake_case via `@map`; Prisma model names are not.

## The tables, briefly

**Identity** — `User`, `Group`, `Session`, `UserPushSubscription`.

**Blog** — `Post`, `Comment`, `PostLike`, `CommentLike`.

**Chat** — `ChatMessage`, and `ChatSetting`, a singleton row with `id = 1`
holding `retentionHours` (default 24).

**Instant** — `InstantDeviceKey`, `Instant`, `InstantKeyEnvelope`,
`InstantStreak`.

**Safety** — `UserBlock`, `ContentReport`.

## Invariants the schema cannot state

### A streak row is a conversation record, permanently

`InstantStreak` is keyed `@@unique([userLowId, userHighId])`, where low and high
are the smaller and larger of the two user ids. A pair therefore has exactly one
row no matter who sends first, and any query must normalise the pair before
looking it up. `backend/src/instant-streaks.ts` owns that ordering; do not
re-derive it elsewhere.

The row is created by `recordSend` on the **very first send** and is never
deleted. Lapsing sets `count = 0` and leaves everything else in place.

That is why `GET /api/v1/instant/conversations` is built from this table rather
than from `instants`: `instants` rows are swept after 30 days, so they cannot
answer "who have I ever talked to". A conversation survives with no instants
left in the database at all. Adding a `conversations` table was considered and
rejected for exactly this reason — the index already existed.

### An `Instant` row outlives its media, and says so by going null

`mediaKey`, `mediaIv` and `ephemeralPubKey` are nullable not because they are
optional but because they are **erased** when the photo is opened or expires.
A row with a null `mediaKey` is a delivered-and-gone instant, and it is the only
thing that ever knew which R2 object belonged to it.

This drives an ordering rule that matters: anything deleting an instant must
delete the R2 object **before** clearing `mediaKey`. Clearing the key first
strands the ciphertext with nothing pointing at it, and no sweep can ever find
it again. See [instant-runtime.md](instant-runtime.md).

`InstantKeyEnvelope` holds one wrapped content key per recipient device,
`@@unique([instantId, deviceKeyId])`. All of an instant's envelopes are deleted
together with its media.

### Reports survive the people in them

`ContentReport.reporterId` and `reportedUserId` are `onDelete: SetNull`, alone
in a schema that otherwise cascades from `User`. A report must remain readable
after either party deletes their account, because the moderation record is the
point. `instantId` is a plain string column rather than a relation, for the same
reason: the instant it names is usually already gone.

### Blocks are stored one-way and read two-way

`UserBlock` is `@@unique([blockerId, blockedId])` — one row, one direction. But
every check in `backend/src/blocks.ts` asks whether a block exists in *either*
direction, so the effect is symmetric while the record of who did it is not.
Unblocking removes only the caller's own row.

### `theme_key` is a user column, not a CSS theme

`users.theme_key` holds one of eight keys. The palettes those keys map to are
defined in three other places, in two other languages, and must stay in sync:
see [parallel-implementations.md](parallel-implementations.md).

### Admin is not in the database

There is no admin column and no role table. Administrators are an allowlist of
email addresses in the `ADMIN_EMAILS` secret, resolved per request by
`backend/src/admin-config.ts`. See [accounts.md](accounts.md).

### Refresh tokens are never stored

`Session.tokenHash` is a SHA-256 hex digest. The token itself exists only in the
httpOnly cookie on the client. A database dump yields no usable session.

### The APNs environment hides in `provider`

`UserPushSubscription` serves both Web Push and APNs. For Web Push, `endpoint`
is the push service URL and `p256dh`/`auth` carry key material. For APNs,
`endpoint` holds the hex device token, both key columns are null, and `provider`
is `"apns"` or `"apns-sandbox"`.

The environment rides in `provider` rather than in a column of its own because
the same device token is invalid across environments and they must be told
apart — encoding it here avoided a migration. It is a deliberate overload, and
it is the reason the column is not just `"apns"`.

## Migrations

`backend/prisma/migrations/`, applied with `npm run prisma:deploy`. Two worth
knowing about because they rewrote existing rows rather than only adding
structure:

- `20260224174000_theme_defaults_and_purple` flipped the default theme from
  `sunset` to `boring-grey` and backfilled every existing `sunset` row.
- `20260914090000_groups` seeded `main` and `testing` and put every account that
  existed before groups did into `main`.
