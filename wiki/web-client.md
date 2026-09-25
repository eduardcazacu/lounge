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

Every page except `Signin` and `Signup` is loaded with `React.lazy`, so its
code arrives the first time it is opened. Bundled as one file, the app was over
600 kB, and someone signing in downloaded the admin panel and Instant's camera
and crypto before seeing a form. A page's `export const` stays as it is;
`App.tsx` maps it to the default `lazy` wants. A tab left open across a deploy
still names the old build's chunks, which Vercel no longer serves.
`vite:preloadError` in `frontend/src/main.tsx` reloads the page instead of
failing to open it.

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

`frontend/src/pages/Instant.tsx` is four lines; everything is in
`frontend/src/components/instant/`. It is a **port of the iOS app's screens**,
not a page of the Lounge: black, full-bleed, no app bar, the camera as the home
screen and conversations one swipe to the left. See
[ios-client.md](ios-client.md) for why each screen is shaped the way it is —
that page is the reference for both clients, and this one only records what is
different here.

**One rectangle does the desktop.** `style.ts` centres the same rounded 16:9
viewport the phone uses: as wide as the window until 16:9 would run off the
bottom, then as tall as the window. On a phone it fills the screen; on a laptop
it becomes a phone-shaped card on black with every control still inside the
frame it belongs to. There is one layout, not two, and it is measured in `dvh`
because mobile browser chrome slides in and out.

The catch is anything positioned against the **window** instead. A phone is
taller than 16:9, so the viewport is centred with a black band above it, and a
header measured from the top of the window lands above the controls inside the
frame — the inbox's title sitting a row higher than the account button pinned
over it. `viewportTopLine` in `style.ts` is that band plus the inset, and it is
what the inbox's header is dropped onto.

**The camera frames 16:9 out of whatever it is given.** The phone's app has
`AVCaptureSession` deliver that shape; a browser hands over the camera's own —
4:3 standing up on a phone — and the preview fills the viewport with it, which
costs it a quarter of its width. That is the same trade the phone makes out of
the same 4:3 sensor, and the capture crops to exactly what the preview showed,
because the preview *is* the framing.

The frame has to be the camera's own shape for that to be a quarter rather than
a third of the picture, which is why `openCamera` asks for no size at all: see
[gotchas.md](gotchas.md). A laptop's webcam is 16:9 lying down and there is no
kind answer — it fills the frame from the middle of a picture three times the
wrong shape.

**The system's own strip is made dark too.** Installed to the home screen on
iOS, the area under the Dynamic Island is painted by the system from the
*document's* background, not from whatever is drawn over it — so a black app on
the Lounge's default white canvas came up with a white strip above it.
`useDarkChrome` blackens the document, sets `color-scheme: dark` and points the
`theme-color` meta at black for as long as Instant is mounted, and puts all
three back on the way out, because the rest of the Lounge is a light page that
follows the system.

**Every gesture has a button.** A pointer that cannot swipe still turns the page
(the chat button on the camera, the camera button in the inbox), a pointer that
cannot press-and-hold still opens the row menu (right-click), and Escape closes
the viewer.

| File | What it is |
|---|---|
| `InstantApp.tsx` | The pager, the aim, the account button, the send pill |
| `CameraScreen.tsx` | `getUserMedia`, flip, shutter cover, capture cropped to the frame |
| `ComposeScreen.tsx` | Captions, drawing, filters, duration, Send To |
| `InboxScreen.tsx` | Conversation rows, status line, press-and-hold menu |
| `SendToSheet.tsx` | Recent/everyone, several recipients, All behind a confirmation |
| `InstantViewer.tsx` | Full screen, countdown or playback, report; the one-shot fetch guard |
| `useOutbox.ts` | Render once, seal per recipient, retry; the send pill's state |
| `overlay.ts`, `filters.ts` | The caption and drawing geometry, and the eight looks |
| `InstantKeySetup.tsx` | The honest disclosure panel |
| `SafetyNumberPanel.tsx` | The 12×5-digit number, and a changed-key warning |
| `moderation.ts`, `ReportSheet.tsx` | Blocking and reporting |

### What a browser cannot do

Four things are missing on purpose, because the platform has no honest version
of them:

- **A send does not survive the tab closing.** iOS writes the sealed bytes to
  disk and finishes the upload on the next launch. A page that is gone runs
  nothing, so a reload mid-send loses it.
- **No home-screen widget and no notification service extension.** Web Push
  still delivers the banner; see [instant-runtime.md](instant-runtime.md).
- **No sensitivity check.** The iOS viewer blurs a photo its on-device
  classifier flags. There is no browser equivalent that does not send the pixels
  somewhere.
- **No update notes.** `WhatsNewScreen` announces a version people install. A
  web app has no install to announce.

**Video is played, never made.** The web composer is photos only; iOS records.
A clip is handed to a `<video>` from the decrypted blob, muted until the speaker
is tapped, with no controls — a clip is watched as it plays and then it is gone.
Before anything is fetched the viewer asks `canPlayType` about the instant's
`mediaType`, which carries the codec string: iOS sends HEVC, and Firefox and
some Chromium builds cannot decode it. A browser that says no gets a notice and
**no fetch**, and `onClose` reports the instant untouched so the inbox keeps it
waiting for the phone. Asking after the fetch would be asking after the clip had
been destroyed. See [gotchas.md](gotchas.md).

A report on a clip attaches the frame it was paused on, drawn to a canvas,
because the evidence endpoint takes images.

**Flash and zoom are capability-gated.** Both ride on `MediaStreamTrack`
constraints that most desktops and iOS Safari do not implement, so each control
is drawn only once the track says it has it — rather than offered and then doing
nothing.

### `useInstant.ts`

`frontend/src/hooks/useInstant.ts` is the store as well as the socket: the
conversation rows, the local send marks and the reply prompts are all derived
here, the same merge `InstantStore` does on iOS. Four of its oddities are
load-bearing:

- **`useSignedInUserId` polls every 5 seconds**, plus `storage` and
  `visibilitychange`. One shared `localStorage.token` means a second account
  signing in *in any tab* re-points every open tab, and the crypto identity is
  per-account.
- **Enrollment re-checks the signed-in user mid-keygen**, for the same reason.
- **Dedup bookkeeping happens outside the `setInstants` updater.** React
  StrictMode double-invokes an impure updater, and an impure one here drops the
  instant. See [gotchas.md](gotchas.md).
- **`/conversations` is the spine and `/streaks` is not fetched at all** — it is
  a strict subset, and a conversation used to vanish the moment its streak
  lapsed.

Reconnect backs off 1s→30s. A 501 from the ticket endpoint means no Durable
Object binding and is surfaced as `connection: "unsupported"` rather than
retried forever.

```bash
cd backend && npx tsx ../frontend/scripts/verify-instant-parity.ts
```

Checks the rules that now exist twice and cannot be seen to differ from either
client alone: the receipt states, the relative-time phrasing, the caption
geometry and the names of the eight looks.

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
