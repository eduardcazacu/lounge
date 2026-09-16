# Eddie's Lounge

A private, invite-only hangout: a blog, a chatroom, and **Instant** — expiring,
end-to-end encrypted 1:1 photos with a native iPhone app.

It exists out of frustration with what social media became, and out of nostalgia
for the early days of social platforms. There is no ranking, no discovery and no
growth mechanism; signing up is public but an account is not usable until an
administrator approves it by hand.

The blog half started from syedahmedullah14's Medium-style example and has been
rewritten well past it.

## Start here

**[`wiki/`](wiki/README.md)** is the single source of truth for why this project
is shaped the way it is — the product, the architecture, the decisions and what
they cost, and the list of things that fail silently. The READMEs in each
package are setup and commands only.

## Layout

| Package | What it is | Runs on |
|---|---|---|
| [`backend/`](backend/README.md) | Hono API, Prisma over Postgres, R2, one Durable Object | Cloudflare Workers |
| [`frontend/`](frontend/README.md) | React + Vite + Tailwind — the whole web app | Vercel |
| [`common/`](common/) | Shared Zod input schemas and wire types | imported by both |
| [`ios/`](ios/README.md) | SwiftUI client for Instant, plus a widget and a notification extension | iPhone |

## Local development

Node 20+ and a Postgres database.

```bash
cd common   && npm install
cd ../backend  && npm install && npm run prisma:generate && npm run dev
cd ../frontend && npm install && npm run dev
```

API on `http://localhost:8787`, frontend on `http://localhost:5173`. Backend
configuration goes in `backend/.env` — see
[`backend/README.md`](backend/README.md).

**`npm run dev` is not the real backend.** It runs under Node with no Durable
Object and no R2, so Instant's WebSocket returns 501 and its media endpoints
cannot work. Use `npm run dev:worker` for anything touching Instant.

## Deploying

Migrations first, then the Worker, then the clients:

```bash
cd backend
DATABASE_URL="postgres://..." npm run prisma:deploy
npm run deploy
```

The frontend builds on Vercel from the **repository root**, not from
`frontend/`, because the frontend depends on `../common`:

- Install `cd frontend && npm ci`
- Build `cd frontend && npm run build`
- Output `frontend/dist`

SPA routing fallback is in `vercel.json`.

Every secret by name, and the configuration that exists only in the Cloudflare
dashboard, are in [`wiki/operations.md`](wiki/operations.md). Releasing the iOS
app is [`ios/APP_STORE.md`](ios/APP_STORE.md).
