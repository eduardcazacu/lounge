# Architecture

Four codebases in one repository.

| Package | What it is | Where it runs |
|---|---|---|
| `backend/` | Hono API, Prisma over Postgres, R2, one Durable Object | Cloudflare Workers (`api.lounge.eduardcazacu.com`) |
| `frontend/` | React 18 + Vite + Tailwind, the whole web app | Vercel (`lounge.eduardcazacu.com`) |
| `common/` | Zod input schemas and wire types | Imported by both of the above |
| `ios/` | SwiftUI app for Instant only, plus a widget and a notification extension | iPhone |

## The three backend entrypoints

This is the first thing that confuses a reader, so it comes first.

- **`backend/src/index.ts`** builds the Hono app — CORS, routers, nothing else.
  It **must stay Node-safe**: no `cloudflare:workers` import may ever reach it,
  directly or transitively.
- **`backend/src/worker.ts`** is the Cloudflare entrypoint named by
  `wrangler.toml`. It exports `{ fetch, scheduled }` and re-exports the
  `InstantInbox` Durable Object class.
- **`backend/src/server.ts`** is the Node dev server (`@hono/node-server`, port
  8787), run by `npm run dev`.

They are separate because `backend/src/instant-inbox.ts` imports
`cloudflare:workers`, which does not resolve under Node. Re-exporting the
Durable Object from `index.ts` would break the Node dev server for the entire
app, not just for Instant. This has been done by accident before; see
[gotchas.md](gotchas.md).

The practical consequence: **`npm run dev` is not the real backend.** It has no
Durable Object and no R2 binding, so `GET /api/v1/instant/ws` answers 501 and
the web client falls back to polling. `npm run dev:worker` (`wrangler dev`) is
the one that behaves like production.

## Request path

A signed-in request carries a 15-minute bearer token. Each router installs its
own JWT middleware — there is no shared auth module, deliberately, because the
Instant and moderation routers additionally reject any token carrying an `aud`
claim. See [accounts.md](accounts.md).

Routers, all mounted under `/api/v1`:

| File | Mount | Handles |
|---|---|---|
| `backend/src/route/user.ts` | `/user` | Signup, signin, refresh, verification, password reset, profile, push subscriptions, account deletion, the user directory |
| `backend/src/route/blog.ts` | `/blog` | Posts, comments, likes, mentions, image upload |
| `backend/src/route/chat.ts` | `/chat` | The single chatroom and its retention setting |
| `backend/src/route/instant.ts` | `/instant` | Device keys, WebSocket ticket and upgrade, send, inbox, the one-shot media read, conversations, streaks |
| `backend/src/route/moderation.ts` | `/moderation` | Blocks and reports |
| `backend/src/route/admin.ts` | `/admin` | Approvals, broadcasts, stats, the report queue, the on-demand sweep |

## Data and storage

**Postgres, not D1.** Prisma 7 with the `@prisma/adapter-pg` driver adapter.
`backend/src/prisma.ts` detects `navigator.userAgent === "Cloudflare-Workers"`
and builds a fresh client per request there, while caching per-URL clients on
`globalThis` under Node. The D1 and KV blocks in `wrangler.toml` are commented
out and there is no D1 database.

**One R2 bucket**, bound as `BLOG_IMAGES`, holding three unrelated things under
three prefixes: post and profile images (public, read through Cloudflare image
transformations), `instant/<uuid>` ciphertext (private, deleted on read), and
`reports/` evidence (private, streamed only to admins).

**One Durable Object class**, `InstantInbox`, one instance per user. It holds no
durable state and never touches Postgres — it is purely a socket relay. See
[instant-runtime.md](instant-runtime.md).

**No queues and no workflows.** Background work is either
`scheduleBackgroundWork` in `backend/src/background.ts` (`waitUntil` on Workers,
a detached promise under Node) or the hourly cron in
`backend/src/scheduled.ts`.

## The shared package

`common/` is one file, `common/src/index.ts`, holding Zod input schemas and the
Instant wire types. It has no build step: `main` and `types` point straight at
the TypeScript source, and the `common/dist/` directory on disk is stale and
unused.

Both `backend/package.json` and `frontend/package.json` depend on it as
`"@blogging-app/common": "file:../common"` — a local path, never published. This
is why **Vercel builds from the repository root** rather than from `frontend/`:
the frontend needs `../common` to exist.

**iOS deliberately does not consume it.** `ios/Instant/Core/Networking/DTOs.swift`
mirrors the same shapes by hand, with property names matching the JSON exactly so
that no `CodingKeys` are needed. That duplication is accepted on purpose and is
the reason field names in `common/` are stable and explicit rather than
generated. See [parallel-implementations.md](parallel-implementations.md).

## Deployment topology

```
iPhone ──┐
         ├──► api.lounge.eduardcazacu.com   (Cloudflare Worker)
Browser ─┤         ├──► Postgres            (Prisma, driver adapter)
         │         ├──► R2 BLOG_IMAGES
         │         └──► INSTANT_INBOX       (Durable Object, one per user)
         │
         └──► lounge.eduardcazacu.com       (Vercel, static SPA)
                   └──► images.lounge.eduardcazacu.com  (R2 public domain)
```

Hourly cron (`0 * * * *`) drives `backend/src/scheduled.ts`. Deploy order,
secrets and the pieces of configuration that exist only in the Cloudflare
dashboard are in [operations.md](operations.md).
