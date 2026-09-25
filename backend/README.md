# Backend

Hono API on Cloudflare Workers, Prisma over Postgres, one R2 bucket and one
Durable Object.

**Design notes live in [`../wiki/`](../wiki/README.md)** — this file is setup
and commands only.

| Question | Page |
|---|---|
| How the pieces fit, and why there are three entrypoints | [architecture.md](../wiki/architecture.md) |
| The tables and the invariants the schema cannot state | [data-model.md](../wiki/data-model.md) |
| Tokens, verification, admin approval, groups | [accounts.md](../wiki/accounts.md) |
| Instant's encryption contract and threat model | [instant-protocol.md](../wiki/instant-protocol.md) |
| Delivery, the one-shot media read, streaks, push | [instant-runtime.md](../wiki/instant-runtime.md) |
| Terms, blocks, reports, account deletion | [safety.md](../wiki/safety.md) |
| Deploying, secrets, the dashboard-only config | [operations.md](../wiki/operations.md) |
| Things that fail silently | [gotchas.md](../wiki/gotchas.md) |

## Running it

```bash
npm install
npm run prisma:generate
npm run dev          # http://localhost:8787
```

**`npm run dev` is not the real backend.** It runs under Node with no Durable
Object and no R2, so `GET /api/v1/instant/ws` returns 501 and the media
endpoints cannot work. For anything touching Instant's transport or storage:

```bash
npm run dev:worker   # wrangler dev
```

With the `[[hyperdrive]]` block in `wrangler.toml` enabled, `wrangler dev`
refuses to start without a local database to stand in for it:

```bash
CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_HYPERDRIVE="$DATABASE_URL" npm run dev:worker
```

Cron triggers fire under neither. The hourly sweep is also reachable as
`POST /api/v1/admin/instant/sweep` (admin only), which runs the same function.

## Configuration

Copy `.env.example` to `.env` (git-ignored) and set:

```
DATABASE_URL=postgres://postgres:postgres@localhost:5432/blogging_app
JWT_SECRET=your-local-secret
ADMIN_EMAILS=admin@example.com          # comma-separated
RESEND_API_KEY=re_xxx
EMAIL_FROM=Eddie's Lounge <onboarding@resend.dev>
FRONTEND_URL=http://localhost:5173
VAPID_PUBLIC_KEY=...
VAPID_PRIVATE_KEY=...
VAPID_SUBJECT=mailto:you@example.com
PORT=8787                                # optional
```

The APNs secrets (`APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`,
`APNS_BUNDLE_ID`) are Worker-only. Until all four exist the APNs path reports
itself unconfigured rather than throwing. Full list in
[operations.md](../wiki/operations.md).

## Scripts

```bash
npm run dev            # Node dev server
npm run dev:worker     # wrangler dev
npm run deploy         # prisma generate && wrangler deploy --minify
npm run prisma:generate
npm run prisma:migrate # prisma migrate dev
npm run prisma:deploy  # prisma migrate deploy
npm run prisma:studio
```

Verification scripts, each covering something awkward to test for real:

```bash
npx tsx scripts/verify-conversations.ts   # the conversations query, in-memory fake
npx tsx scripts/verify-apns.ts            # ES256 signing, stubbed Apple
npx tsx scripts/verify-push-routing.ts    # app-first Instant pushes
npx tsx scripts/check-apns-key.ts <p8> --key-id X --team-id Y --bundle Z
```

## Creating an account in a group

Signup always lands in `main` and cannot choose a group, so App Store review
accounts are made with a script. It creates the account already verified and
approved, so it can sign in without an inbox:

```bash
npx tsx scripts/create-account.ts --email review@example.com --name "App Review" --group testing
```

It writes to whatever `DATABASE_URL` resolves to. The password comes from
`ACCOUNT_PASSWORD` if set, otherwise it is generated and printed once. Either
way it reaches the database only as a bcrypt hash — **never commit it**.

## Deploying

Migrations first, then the Worker, then the clients:

```bash
DATABASE_URL="postgres://..." npm run prisma:deploy
npm run deploy
```

Some configuration exists only in the Cloudflare dashboard and will not be
missed until much later — notably the R2 lifecycle rule expiring `instant/`
objects after one day. See [operations.md](../wiki/operations.md).
