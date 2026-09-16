# Frontend

The Eddie's Lounge web app — blog, chatroom, admin console, legal pages, and the
web client for Instant. React 18 + TypeScript + Vite + Tailwind, deployed to
Vercel as a static SPA.

**Design notes live in [`../wiki/web-client.md`](../wiki/web-client.md)** — why
auth is module-level rather than a context, why themes are inline styles, and
why the Instant client here is a test harness rather than the product.

## Running it

```bash
npm install
npm run dev        # http://localhost:5173
```

It expects the API on `http://localhost:8787`. Start it with
`cd ../backend && npm run dev` — or `npm run dev:worker` if you are working on
Instant, since the plain Node server has no Durable Object and `/ws` returns
501.

`npm install` needs `../common` to exist, which is also why Vercel builds from
the repository root rather than from this directory.

## Scripts

```bash
npm run dev
npm run build      # tsc -b && vite build
npm run lint
npm run preview
```

## Configuration

Both optional; `src/config.ts` has the defaults.

- `VITE_BACKEND_URL` — API base URL. The WebSocket origin is derived from it, so
  there is only one URL to set.
- `VITE_IMAGE_TRANSFORM_BASE_URL` — forces Cloudflare image transformations
  through a custom image domain.

## Layout

```
src/
  pages/            one file per route; Legal.tsx exports three
  components/       shared UI
    instant/        capture, composer, viewer, key setup, safety number
  hooks/            useBlog, useBlogs, useUsers, useChat, and useInstant
  lib/              auth, crypto, keystore, images, markdown, push
  themes.ts         the eight palettes, applied as inline styles
  config.ts         the one backend URL
public/             PWA manifest, icons, and a hand-written service worker
```

`src/lib/instantCrypto.ts` is the **authoritative** copy of the Instant
encryption contract that the iOS app must match byte for byte. Do not change it
without reading [`../wiki/instant-protocol.md`](../wiki/instant-protocol.md) and
running the interop fixtures.
