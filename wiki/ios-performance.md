# iOS performance: where a tap's time goes

Why the iOS app can feel slow, especially between tapping a notification and
seeing the photo, and what could make that wait shorter. The numbers come from
`JourneyLog` (see Measuring, below), and the explanations from reading the
code. Where they disagree, the numbers win, and this page gets corrected.

**When an opportunity ships, delete its entry.** This page describes the app as
it is now. A fixed entry left in place is a false claim about the code.

## What was measured

Build 1.4 (7) from TestFlight, on one iPhone 15 Pro (`iPhone16,1`), with the
backend on Hyperdrive: 48 journeys in one sitting. The previous build, 1.4 (6),
is the comparison, and its numbers are given in brackets. It had none of these:
Hyperdrive, the early token refresh, the viewer opening on the tap, the receipt
sent without waiting for it, or the shutter holding its frame. The samples are
small (5 cold notification taps, 4 warm), which is enough to see which way
things moved but not enough for tail latencies.

| Journey | 1.4 (7) | [1.4 (6)] |
|---|---|---|
| Notification → photo, cold | 1.15–2.0 s | [1.7–2.2 s] |
| Notification → photo, warm | 1.5 s, once 3.0 s | [1.9–2.3 s] |
| Notification → viewer on screen, warm | 0–7 ms | [1.2–1.3 s, behind the inbox fetch] |
| Notification → viewer on screen, cold | 0.6–0.7 s | [1.0–1.4 s] |
| Back from the background → inbox refreshed | 0.25–0.7 s | [1.0–1.5 s] |
| Send → accepted, photo | 0.9–1.2 s | [1.9–2.0 s] |
| Send → accepted, clip | 1.1–1.8 s | [1.9–4.1 s] |
| Shutter → frame held still | 9–16 ms | [0.43 s of black] |
| Shutter → compose | 0.42 s | [0.43 s] |

**Hyperdrive about halved every request.** `GET /keys/:userId` went from
0.8–1.0 s to 0.36–0.55 s. Uploading about 200 KB went from 0.9–1.2 s to
0.5–0.6 s. Downloading a photo, 20–240 KB, took 0.24–0.65 s. Even so, a request
still costs roughly 100 ms per query it makes: `/keys/:userId` runs four in a
row, and `POST /user/refresh` (a transaction) takes 0.87 s. See opportunity 2.

**In build 1.4 (7), the viewer on the tap worked only when the main actor was
free.** On a warm start it was on screen within a frame. On a cold start it
waited 0.6–0.7 s behind the camera setup, which now runs on its own queue. See
opportunity 1.

**What is not slow:** the first frame (80–150 ms), decryption and the
sensitivity check (under 40 ms together), a clip's end to compose (0.14 s), and
a hold to recording (0.06 s). A received clip still has not been opened in a
timed session.

## Opportunities, most valuable first

### 1. Don't start the camera during a launch headed to the inbox

`CameraController` builds and starts its session on its own serial queue
(`sessionQueue`), so the camera no longer holds the main actor at launch. In
build 1.4 (7) it held it for about 650 ms and delayed everything behind it:
the two cold notification taps where the store happened to start before the
camera opened the photo in 1.15–1.19 s, and the three where the camera went
first took 1.86–2.0 s. The camera still starts on every launch, though, because
a page-style `TabView` builds both pages. On a launch headed to the inbox it
competes with the fetch the tap is waiting for, and it keeps the camera and
microphone indicators on while someone looks at a photo. Delaying the **first**
start until the camera page is shown would fix both, and it does not conflict
with the rule in `CameraScreen` against stopping on swipe. Check the next
timings first: `storeStarting` should now arrive close behind
`rootTaskStarted`.

### 2. Find where the 100 ms per query goes

With Hyperdrive, a request no longer opens a connection. Even so, the
requests that make several queries in a row are the slow ones:
`/keys/:userId` runs four and takes 0.36–0.55 s, and `POST /user/refresh`, a
transaction, takes 0.87 s. That is roughly 100 ms per query. It is not
distance: the database is in central Europe and the phones are in the
Netherlands, about 10 ms apart, so Smart Placement would gain little. The
candidates are the work each query does rather than the path it takes: a new
`PrismaClient` and `pg` pool built for every request (`backend/src/prisma.ts`),
the auth middleware's own lookups (the caller's group is looked up on every
request — `wiki/accounts.md`), and the database host itself. A
`Server-Timing` header on `/keys/:userId`, reporting the time before the first
query and the time for each query, would show which one it is before anything
is changed.

### 3. Don't fetch the inbox three times at launch

A cold start with a cache runs `refreshAll` from `InstantStore.start`. The
socket then emits `.shouldDrainInbox` before its ticket, and that runs
`refreshInbox` and `refreshHistory` again. `RootView`'s `.active` handler can
run `refreshAll` a third time. When every request costs what the measurements
above show, that is a lot of extra time spent next to the fetch that the tap is
waiting for. Coalescing calls that are already in flight, the way
`RefreshCoordinator` does for token refreshes, keeps what is actually needed:
a fetch before the socket connects.

### 4. Skip frame extraction for a clip when the classifier is off

Not measured, because no clip was opened. For a clip, `showVideo` has
`AVAssetImageGenerator` extract two frames before it sets `.showing`. But
`SystemSensitivityChecker` only checks `analysisPolicy` after it receives an
image, so the frames are extracted even for anyone who has not turned on
Sensitive Content Warnings. Put the policy on `SensitivityChecking` and check
it first.

### 5. Cache avatars

`AvatarView` uses `AsyncImage`, which keeps nothing in memory between
appearances. Every cold start draws initials and then swaps in the picture, and
a row that scrolls back on screen fetches it again. That swap on a list which
is otherwise already drawn from cache (`InboxCache`) makes the list look like it
is still loading. `WidgetSnapshotPublisher` already downsizes and stores
pictures, but only for people with something waiting. A small shared cache in
memory and on disk would fix it for everyone.

### 6. Feel, not speed

- **Show download progress.** A clip can be 3 MiB. On a cellular connection,
  a spinner that never changes feels slower than a ring that fills, even if it
  takes the same time. URLSession can report bytes as they arrive for the media
  request.
- **Present faster.** The default `fullScreenCover` slide is slower than a fade
  onto a black screen, which is how the viewer looks anyway.
- **Haptics.** `.sensoryFeedback` is used for recording and the trash button,
  but not for opening an instant or sending one. A light tap at the moment of
  either confirms the action before any pixels change.

### Small, and only if Instruments says so

- Decryption and the WebP decode run on the main actor (`ViewerModel` is
  `@MainActor`). Decryption was measured at 10–25 ms. `UIImage(data:)` decodes
  lazily at the first draw, which the timings cannot see. Moving both to a
  detached task with `byPreparingForDisplay()` only matters if Hangs shows a
  hitch as the viewer opens.
- `InstantStore.conversations` rebuilds and re-sorts on every read, and
  `InboxScreen.body` reads it twice (as does `makeWidgetSnapshot`). With a few
  dozen people this is too small to see.
- `SystemSensitivityChecker` creates a new `SCSensitivityAnalyzer` on every
  call.
- `Outbox.restore` reads sealed bodies of up to 3 MiB synchronously before the
  first frame. This only happens after a force quit interrupted a send.

## Measuring

`JourneyLog` (`ios/Instant/Core/Diagnostics/JourneyLog.swift`) times six
journeys. Each one starts at something the person did and ends at the thing
they were waiting to see:

| Journey | From | To |
|---|---|---|
| `launch` | the process starting (or `App.init`, when iOS prewarmed the app) | the first inbox fetch; the first frame if signed out |
| `resume` | returning from the background | `refreshAll` finishing |
| `openInstant` | the notification tap, or the tap on an inbox row | a photo's countdown starting, or a clip's frames starting to move |
| `capture` | the shutter release, or a clip's end | the compose screen appearing |
| `recordStart` | a hold being recognised | the recorder running |
| `send` | Send | the server accepting it (one per recipient) |

The marks in between are the steps in the table under "What was measured",
plus `waitingShown` (the viewer up before its instant, on a notification tap),
`frameHeld` and `processed` (a photo on screen held still, and the camera done
processing it), and the launch marks in opportunity 1. When the
access token is refreshed, `tokenRefreshStarted` and `tokenRefreshed` are added
to every journey running at the time, so an expired token shows up in the
results instead of looking like a slow network. A `send` also records
`captureMs` and `sinceMs`, which say how long taking the photo took and how
long it then sat on the compose screen. Together they give the whole time from
the shutter to the server.

**Measure only a build signed for distribution, on a phone.** A Debug build
compiles libwebp at `-O0` (`wiki/ios-client.md`). The Simulator has no Secure
Enclave and no camera. A Release build run from Xcode cannot get notifications
(`wiki/gotchas.md`). So a TestFlight build is the only kind that measures all
six journeys.

Each journey is reported three ways:

- **Settings → Timings** shows the p50 and p90 for each journey. The share
  button exports `journeys.jsonl`, one JSON record per line. Summarise it on a
  Mac, split by cold or warm, photo or clip:

  ```bash
  swift ios/tools/journey-report.swift journeys.jsonl
  ```

- **The unified log** gets one public line per journey (subsystem
  `com.eduardcazacu.instant`, category `journeys`). With the phone plugged in:

  ```bash
  sudo log collect --device --last 2h --output instant.logarchive
  log show instant.logarchive --style compact \
    --predicate 'subsystem == "com.eduardcazacu.instant" AND category == "journeys"'
  ```

- **Instruments** shows each journey as a Points of Interest interval, next to
  the *App Launch*, *Hangs* and *Network* tracks that explain it. It needs a
  build that can be debugged, meaning one run from Xcode, not TestFlight.
