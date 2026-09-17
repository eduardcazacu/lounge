# Operations

## Deploy order

It matters, and getting it wrong is the most common way to break a release.
**Migrations, then the Worker, then the clients.** An app build that reaches an
old backend gets 404s for endpoints it depends on.

```bash
cd backend
DATABASE_URL="postgres://..." npm run prisma:deploy   # 1. migrations
npm run deploy                                        # 2. wrangler deploy --minify
```

Then the frontend (Vercel, on push), then the iOS archive.

Vercel builds from the **repository root**, not `frontend/`, because the
frontend depends on `../common`:

- Install: `cd frontend && npm ci`
- Build: `cd frontend && npm run build`
- Output: `frontend/dist`

## Secrets and variables

Worker secrets, by name only — set with `npx wrangler secret put <NAME>`:

| Secret | For |
|---|---|
| `DATABASE_URL` | Postgres |
| `JWT_SECRET` | Access tokens and WebSocket tickets both |
| `ADMIN_EMAILS` | The admin allowlist, comma-separated |
| `RESEND_API_KEY`, `EMAIL_FROM` | Verification, resets, report notifications |
| `FRONTEND_URL` | Links inside those emails |
| `R2_PUBLIC_BASE_URL` | Public image URLs (also set as a plain var in `wrangler.toml`) |
| `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT` | Web Push |
| `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`, `APNS_BUNDLE_ID` | APNs |

Until **all four** `APNS_*` secrets exist, the APNs branch reports itself
unconfigured rather than throwing. The backend records whatever tokens it is
given and simply has none to send to; adding the secrets starts delivery with no
code change.

Bindings in `backend/wrangler.toml`: `BLOG_IMAGES` (R2) and `INSTANT_INBOX`
(Durable Object). Cron `0 * * * *`. Node-only: `PORT`, `NODE_ENV`. Script-only:
`ACCOUNT_PASSWORD`. Vercel: `VITE_BACKEND_URL`, `VITE_IMAGE_TRANSFORM_BASE_URL`.

Local template: `backend/.env.example`.

## Configuration that exists only in a dashboard

Two things are not in this repository and cannot be, and both fail quietly.

1. **The R2 lifecycle rule.** On the `eddies-lounge-images` bucket, objects
   under the `instant/` prefix expire after **1 day**. It is not expressible in
   `wrangler.toml`. It is the third backstop against stranded ciphertext, after
   delete-on-fetch and the hourly sweep — and the only one that catches a user
   row deleted by hand. See [instant-runtime.md](instant-runtime.md).
2. **The bucket's public domain**, `images.lounge.eduardcazacu.com` (or a
   Public Development URL), which `R2_PUBLIC_BASE_URL` must match.

A rebuilt bucket needs both re-applied. Neither will be missed until much later.

## Verification scripts

Each proves one thing that is otherwise awkward or impossible to test.

```bash
cd backend
npx tsx scripts/verify-conversations.ts   # the conversations query, against an in-memory fake
npx tsx scripts/verify-apns.ts            # ES256 signing and request shape, against a stubbed Apple
npx tsx scripts/verify-push-routing.ts    # who still gets Web Push when the app was reached
```

`verify-apns.ts` generates a throwaway P-256 key, checks the JWT against its own
public key, and drives every response Apple can give through a stubbed `fetch` —
so the sender is covered with no Apple Developer account.

To ask Apple about a real key before blaming anything else:

```bash
cd backend
npx tsx scripts/check-apns-key.ts ~/Downloads/AuthKey_XXXXXXXXXX.p8 \
  --key-id XXXXXXXXXX --team-id <team> --bundle com.eduardcazacu.instant
```

It signs a token locally — the `.p8` never leaves the machine — and pushes to a
deliberately invalid device token on both hosts. **`BadDeviceToken` back from a
host is the result you want**: it means the key and topic were accepted there.
`BadEnvironmentKeyInToken` means the key is not enabled for that environment; an
APNs key can be created restricted to one, and a development build's token can
only ever be delivered through sandbox.

The crypto interop loop is in [instant-protocol.md](instant-protocol.md) and
matters more than any of these.

## Running the cron by hand

Cron triggers fire under neither `npm run dev` nor `wrangler dev`, so the sweep
is also reachable as `POST /api/v1/admin/instant/sweep` (admin only). It runs
exactly the same function the schedule does.

## Local development

```bash
cd common && npm install
cd ../backend && npm install && npm run prisma:generate && npm run dev
cd ../frontend && npm install && npm run dev
```

API on `http://localhost:8787`, frontend on `http://localhost:5173`.

**`npm run dev` is not the real backend.** It has no Durable Object and no R2
binding: `GET /api/v1/instant/ws` answers 501 and clients poll. Use
`npm run dev:worker` (`wrangler dev`) for anything touching Instant's transport
or media. See [architecture.md](architecture.md).

Observability is on in `wrangler.toml` with `head_sampling_rate = 1`, so
`npx wrangler tail` shows everything. When Apple rejects a push, the delivery log
names the reason rather than only a count.

## Releasing the iOS app

The full checklist is `ios/APP_STORE.md`. The parts people forget: deploy the
backend **first**; make sure the `testing`-group review accounts can sign in and
have each signed in on a device once, so they have a device key (nobody can be
sent an instant before enrolling one); and bump `MARKETING_VERSION` /
`CURRENT_PROJECT_VERSION` on every upload.
