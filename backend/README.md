## Backend (Local)

1. Copy `.env.example` to `.env`.
2. Set:
   - `DATABASE_URL=postgres://postgres:postgres@localhost:5432/blogging_app`
   - `JWT_SECRET=your-local-secret`
   - `ADMIN_EMAILS=admin@example.com` (comma-separated for multiple admins)
 - `RESEND_API_KEY=re_xxx`
  - `EMAIL_FROM=Eddie's Lounge <onboarding@resend.dev>`
  - `FRONTEND_URL=http://localhost:5173`
  - `VAPID_PUBLIC_KEY=<your-web-push-public-key>`
  - `VAPID_PRIVATE_KEY=<your-web-push-private-key>`
  - `VAPID_SUBJECT=mailto:you@example.com`
3. Install and run:

```bash
npm install
npm run prisma:generate
npm run dev
```

If you use Prisma 7, ensure these runtime deps are installed:

```bash
npm install @prisma/adapter-pg pg
```

Server default: `http://localhost:8787`

## Prisma Setup

Paste your real Prisma connection string(s) into `backend/.env` (this file is git-ignored):

- `DATABASE_URL=...`

Then run:

```bash
npm run prisma:generate
npm run prisma:deploy
```

## Email Verification

- Signup sends a verification email via Resend.
- User must verify email before signing in.
- Non-admin accounts still require admin approval after email verification.

## Instant

Expiring, end-to-end encrypted 1:1 photos, served at `/api/v1/instant` and
`/instant` in the web client. The React front-end is a test harness; the API,
the wire format and the crypto contract are designed for the native iOS app.

### Running it

Instant needs the `INSTANT_INBOX` Durable Object and the `BLOG_IMAGES` R2
bucket, neither of which exists under `tsx src/server.ts`:

```bash
npm run dev:worker
```

Under plain `npm run dev` the REST endpoints still work (the inbox is polled
instead of pushed) and `GET /api/v1/instant/ws` returns 501 saying so.

The Workers entrypoint is `src/worker.ts`, not `src/index.ts`. The two are kept
separate on purpose: `src/instant-inbox.ts` imports `cloudflare:workers`, which
does not resolve under Node, so re-exporting it from `index.ts` would break the
Node dev server for the whole app.

### Transport

One `InstantInbox` Durable Object per user, addressed `user:<id>`, using the
WebSocket Hibernation API (`ctx.acceptWebSocket`) so an idle inbox accrues no
billable duration while its clients stay connected. The object holds no durable
state and never touches Postgres — it is purely a relay. The Worker owns the
database and R2 and calls `deliver()` over RPC; if that reaches no connected
device, it sends a Web Push instead.

Browsers cannot set an `Authorization` header on a WebSocket, so `/ws`
authenticates with a 60-second ticket from `POST /ws-ticket`, signed with the
same `JWT_SECRET` but carrying `aud: "instant-ws"`. Tickets are refused on the
REST routes and access tokens are refused at `/ws`.

### What the encryption does and does not defend against

**Defended.** The server never holds key material it can use. R2 holds
ciphertext; Postgres holds per-device *wrapped* content keys, and unwrapping one
requires a private key that never leaves the recipient's device. A full
compromise of Cloudflare and Postgres together still yields no plaintext images.

**Not defended:**

1. **Key-directory substitution.** The server publishes everyone's public keys
   and could publish its own instead, to sit in the middle. The only real
   mitigation is out-of-band comparison, which is why the client shows a safety
   number and warns when a peer's keys change.
2. **Browser code delivery.** The React client is downloaded from Vercel on
   every visit, so whoever controls that deployment can serve JavaScript that
   reads photos after decryption. Storing the private key as a non-extractable
   `CryptoKey` stops a script from copying the key out, but not from using it in
   place. Browser E2E is only ever as strong as the code-delivery channel; a
   signed native app is the endpoint where this guarantee is actually strong.
3. **Metadata.** Who sent to whom, when, byte size and duration mode are all
   plaintext. Encryption does not touch any of it.

### Crypto parameters (the iOS interop contract)

Device keypair is **ECDH P-256** — chosen over X25519 because P-256 is the only
curve the iOS Secure Enclave supports. Media is AES-256-GCM with a random
12-byte IV and the 128-bit tag appended. Per message there is one ephemeral
P-256 keypair; per recipient device, `ECDH(ephemeral_priv, device_pub)` gives
256 raw bits, HKDF-SHA256 turns those into a wrapping key, and that wraps the
content key under its own 12-byte IV. HKDF salt is the raw uncompressed
ephemeral public key; HKDF info is
`"eddies-lounge/instant/v1|<senderUserId>|<recipientDeviceId>"`, which binds an
envelope to one device. Everything travels as unpadded base64url.

The authoritative copy of this lives in a header comment in
`frontend/src/lib/instantCrypto.ts`.

**There is no key recovery.** Clearing site data, switching browsers, or Safari
evicting IndexedDB after ~7 idle days all mint a new identity, and anything
already wrapped to the old key becomes permanently unopenable. The client
reports those to `POST /:id/undecryptable` so the server stops holding them.

### Media lifecycle

Ciphertext lands in R2 under `instant/<uuid>`. `GET /:id/media` claims the row
before reading the object, hands the bytes over once, then deletes the object
and every wrapped key. Claiming first means a second request can never be
served — including from another of the recipient's devices, which gets a 410 —
and it also means a download that fails mid-flight loses the image. That is the
same trade Snapchat makes.

Three independent backstops: delete-on-fetch, the hourly cron sweep in
`src/scheduled.ts` (which also expires anything unopened after 24h), and an R2
lifecycle rule.

The sweep deletes the R2 object *before* clearing `media_key`, and skips the row
entirely if the `BLOG_IMAGES` binding is missing (reported as
`skippedWithoutBucket`). Clearing the key first would strand the ciphertext:
the row is the only thing that knows which object belongs to it.

**Known limitation.** Deleting a user cascades their `instants` rows away in
Postgres but leaves any un-opened ciphertext in R2 with nothing pointing at it,
so the cron sweep can never find it. This is reachable in practice — admin
*reject* deletes the user. The exposure is bounded and the bytes are useless
without the recipient's private key, but it is the specific case the R2
lifecycle rule exists to mop up, which is another reason not to skip it. **The lifecycle rule is not expressible in `wrangler.toml` and
must be added by hand** in the Cloudflare dashboard: on the
`eddies-lounge-images` bucket, expire objects under the `instant/` prefix after
1 day.

### Streaks

One row per ordered pair. A streak advances once per **UTC** day, and only when
both people have sent to the other within the last 24 hours; it lapses when
either side's most recent send ages past that window. Note the UTC boundary — a
user in a distant timezone sees the day roll over at an odd local hour.

Streaks count *sends*, not opens, so an instant that expired unopened or could
not be decrypted still counts. That is deliberate: streak state must not depend
on key material the server cannot reason about.

Streaks of 7 days or more get a push to **both** people when they are within 4
hours of lapsing, at most once per day.

### Push, and APNs

Web Push and APNs share `user_push_subscriptions`. For Web Push, `endpoint` is
the push service URL and `p256dh`/`auth` carry the encryption material; for APNs,
`endpoint` holds the hex device token and both key columns are null.

The APNs **environment rides in `provider`** — `"apns"` for production builds and
`"apns-sandbox"` for development ones. The same device token is not valid in both
environments, so they have to be told apart; encoding it here rather than adding
a column means no migration. `POST /api/v1/user/me/push/subscribe` accepts
`provider` and makes `keys` optional, required only when `provider` is
`"webpush"`, so existing web callers are unaffected.

Sending lives in `src/apns.ts`. Apple wants a short-lived ES256 JWT signed with a
`.p8` key, which maps cleanly onto WebCrypto: ECDSA P-256 with SHA-256 produces
the raw `r‖s` pair that JWS ES256 expects, with no DER unwrapping (unlike Node's
`crypto`). The token is cached and re-signed roughly every 50 minutes, because
Apple rejects tokens older than an hour and rate-limits minting them. A `410
Unregistered` or a `400 BadDeviceToken` deletes the subscription, mirroring the
404/410 cleanup the Web Push path already does — otherwise the hourly streak
sweep would retry dead tokens forever.

Four secrets turn it on. Until all four are present the APNs branch reports
itself unconfigured rather than throwing, so the iOS app can register tokens and
ship before the Apple Developer account exists; adding the secrets starts
delivery with no code change.

```bash
npx wrangler secret put APNS_KEY_ID       # 10-char Key ID from the .p8
npx wrangler secret put APNS_TEAM_ID      # 10-char Team ID
npx wrangler secret put APNS_PRIVATE_KEY  # the whole AuthKey_XXXXXXXXXX.p8
npx wrangler secret put APNS_BUNDLE_ID    # com.eduardcazacu.instant
```

Note that the iOS app ships with push **disabled** (`INSTANT_PUSH_ENABLED = NO`)
because a free personal Apple team cannot sign an app declaring
`aps-environment`. Nothing here depends on that: the backend records whatever
tokens it is given and simply has none to send to until the app is built with
push enabled. See `ios/README.md`.

Verify the sender without an Apple account:

```bash
npx tsx scripts/verify-apns.ts
```

It generates a throwaway P-256 key, checks the JWT against its own public key,
and drives every response Apple can give through a stubbed `fetch`.

**Only `sendPushToUsers` reaches APNs.** The five older senders
(`notifyFollowersOfNewPost`, `sendTestNotificationToUser`,
`sendBroadcastNotification`, `notifyPostAuthorOfReply`, `notifyMentionedUsers`)
hard-code Web Push and pre-filter with `isDeliverableWebPush`, so an APNs row is
invisible to them. Instant's own notifications and the streak warnings both go
through the generic dispatcher and do reach iOS.

### Testing the cron

Cron triggers fire under neither `tsx src/server.ts` nor `wrangler dev`, so the
sweep is also reachable as `POST /api/v1/admin/instant/sweep` (admin only). It
runs exactly the same function the schedule does.
