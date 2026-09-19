# The web client

`frontend/` — React 18, Vite 5, TypeScript, Tailwind 3, react-router 6, axios.
It is the whole Lounge: blog, chat, admin, legal pages, and Instant. Deployed to
Vercel as a static SPA with the rewrite in `vercel.json`.

One configuration knob, `frontend/src/config.ts`: `BACKEND_URL` (or
`VITE_BACKEND_URL`). The WebSocket origin is **derived** from it by replacing
`http` with `ws` rather than configured separately, so there is only ever one
URL to get wrong.

## Pages

`frontend/src/pages/`, wired flat in `frontend/src/App.tsx`. `RootRedirect` tries
`refreshAccessToken()` and sends you to `/blogs` or `/signin`.

| Page | What it is |
|---|---|
| `Blogs.tsx` | The feed. Author filter via `UsersStrip`, paged, and the page background is tinted from the selected author's palette |
| `Blog.tsx` | One post, by id |
| `Publish.tsx` | Compose a post. Markdown plus one image, WebP-encoded client-side; the draft is kept in `localStorage` under `publishPostDraft` |
| `Account.tsx` | Display name, bio, profile picture, theme picker, notification toggle, logout |
| `Instant.tsx` | The Instant client — see below |
| `Admin.tsx` | Approvals, push broadcast, markdown email broadcast with preview, stats, and the report queue |
| `Signin.tsx` / `Signup.tsx` | The `Auth` form beside `Quotes` |
| `VerifyEmail.tsx`, `ForgotPassword.tsx`, `ResetPassword.tsx` | The token flows from [accounts.md](accounts.md) |
| `Legal.tsx` | Exports **three** pages: `Privacy`, `Terms`, `Support` |

`Legal.tsx` matters more than it looks. Those URLs are what App Store Connect
points at, and `/terms` doubles as the Community Guidelines the iOS app links
to. They must be reachable signed out. See [safety.md](safety.md).

## Auth is module-level, not a context

There is no `AuthProvider` and no context. `frontend/src/lib/auth.ts` exports
functions over `localStorage`, and `initializeAxiosAuth()` installs two global
axios interceptors: one attaching the bearer token, one catching 401/403 and
doing exactly **one** refresh and **one** retry, guarded by a `__authRetried`
marker on the request.

Three details that look like mistakes and are not:

- `normalizeToken` defends against a token stored as `"[object Object]"` or
  JSON-wrapped. Old builds did that and the bad values outlive them.
- `getCurrentUserId` decodes the JWT payload **without verifying it**. It only
  wants the `id` claim for client-side bookkeeping; the server verifies.
- `refreshAccessToken` deliberately **does not clear the token on failure**,
  because iOS PWAs routinely fail to send the refresh cookie and clearing would
  sign people out for a transient reason.

## Instant on the web

`frontend/src/pages/Instant.tsx` plus `frontend/src/components/instant/`. It
works, and it is a harness rather than the product — see
[product.md](product.md) for why, and
[instant-protocol.md](instant-protocol.md) for the threat model that makes the
distinction real.

- **`InstantCapture.tsx`** — `getUserMedia` viewfinder, front/back toggle, file
  picker fallback for non-secure contexts. It deliberately stores **no** aspect
  ratio, because iOS reports stale landscape `videoWidth`/`videoHeight`.
- **`InstantComposer.tsx`** — caption overlay positioned in image *fractions*,
  duration mode, recipient picker, WebP encode, then `sealForDevices` and
  upload. The caption geometry here is the iOS plate caption at scale 1; see
  [parallel-implementations.md](parallel-implementations.md).
- **`InstantViewer.tsx`** — full screen, countdown, and a guard against
  double-fetch because fetching the media destroys it server-side.
- **`InstantKeySetup.tsx`** — the honest disclosure panel: encryption is local,
  the key is non-extractable, there is no recovery, and the web client is itself
  the weak link because it is re-downloaded on every visit.
- **`SafetyNumberPanel.tsx`** — the 12×5-digit number, and a warning when a
  remembered peer fingerprint has changed.

### `useInstant.ts`

`frontend/src/hooks/useInstant.ts` is the realtime machinery, and three of its
oddities are load-bearing:

- **`useSignedInUserId` polls every 5 seconds**, plus `storage` and
  `visibilitychange`. One shared `localStorage.token` means a second account
  signing in *in any tab* re-points every open tab, and the crypto identity is
  per-account.
- **Enrollment re-checks the signed-in user mid-keygen**, for the same reason.
- **Dedup bookkeeping happens outside the `setInstants` updater.** React
  StrictMode double-invokes an impure updater, and an impure one here drops the
  instant. See [gotchas.md](gotchas.md).

Reconnect backs off 1s→30s. A 501 from the ticket endpoint means no Durable
Object binding and is surfaced as `connection: "unsupported"` rather than
retried forever.

## Themes are a user column, not a CSS theme

`frontend/tailwind.config.js` has an empty `theme.extend` on purpose. Palettes
live in `frontend/src/themes.ts` as `THEME_PALETTES` — `accent`, `border`,
`softBg`, `postBg`, `profileBg`, `text` for each of eight keys — and are applied
as **inline styles** on top of Tailwind utility classes.

They have to be inline: the palette in play is whichever *user* you are looking
at, changing per card in a feed, so it cannot be a class on an ancestor. The
current user's key is cached in `localStorage.themeKey`; everybody else's rides
along on API payloads as `themeKey`.

The same eight palettes exist in three other places. See
[parallel-implementations.md](parallel-implementations.md).

## Shared machinery

`frontend/src/lib/`:

| File | What it holds |
|---|---|
| `auth.ts` | Tokens, refresh, axios interceptors (above) |
| `instantCrypto.ts` | **The authoritative interop contract.** [instant-protocol.md](instant-protocol.md) |
| `instantKeystore.ts` | IndexedDB identity, non-extractable key, peer fingerprints |
| `image.ts` | The WebP compression ladder, shared by Publish, Account and the composer |
| `content.ts` | Markdown helpers, YouTube embed extraction, `/cdn-cgi/image/...` URL building |
| `push.ts` | VAPID subscription and prompt suppression |
| `datetime.ts` | `formatPostedTime` |

`frontend/src/hooks/index.ts` holds `useBlog`, `useBlogs`, `useUsers` and
`useChat` (polled, visibility-aware, deduped by max id).

Images are optimised client-side before upload and served through Cloudflare
transformations (`/cdn-cgi/image/width=...`), which keeps R2 egress inside the
free tier. Encrypted bytes cannot be transformed, which is why the Instant
composer owns its whole bandwidth budget and encodes to roughly 250 KB.

## PWA

`frontend/public/manifest.webmanifest` and a hand-written service worker,
`frontend/public/sw.js`, handling `push` and notification clicks. Registered in
`frontend/src/main.tsx`, which also mounts Vercel analytics.
