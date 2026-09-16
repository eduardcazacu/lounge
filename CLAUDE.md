# Working in this repository

Eddie's Lounge is a private, invite-only hangout — a blog, a chatroom, and
Instant, which is expiring end-to-end encrypted 1:1 photos. Four codebases:
`backend/` (Hono on Cloudflare Workers, Prisma over Postgres), `frontend/`
(React + Vite on Vercel), `common/` (shared Zod schemas), `ios/` (SwiftUI, and
Instant only).

## Read the wiki first

`wiki/` holds why this project is shaped the way it is. It is the single source
of truth for design rationale; the READMEs are setup instructions only.

- **Before planning non-trivial work** — read `wiki/README.md`, then the page
  for the area you are touching.
- **Before answering "why is it like this?"** — `wiki/decisions.md`. What lost
  and why is written down, so it does not have to be re-argued.
- **Before touching Instant's crypto or wire format** — `wiki/instant-protocol.md`
  and `wiki/gotchas.md`, both, without exception. Every mistake available there
  fails *silently*: envelopes get produced that nobody can ever open, with no
  error until someone tries.
- **Before editing one side of a contract** — `wiki/parallel-implementations.md`
  says how many sides there are. The crypto contract has three. The themes have
  four.
- **When something behaves strangely and the code looks right** —
  `wiki/gotchas.md`. It is probably in there.

## Commands

```bash
# Backend
cd backend
npm run dev            # Node. NO Durable Object, NO R2 — /ws returns 501
npm run dev:worker     # wrangler dev. The real thing; use this for Instant
npm run prisma:generate
npm run prisma:deploy  # migrations; needs DATABASE_URL

# Frontend
cd frontend && npm run dev     # :5173, expects the API on :8787
npm run build                  # tsc -b && vite build
npm run lint

# iOS
xcodebuild test -project ios/Instant.xcodeproj -scheme Instant \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

**Crypto interop — the check that matters most.** Run all three after touching
either side of the Instant crypto; it takes about a second and it is the only
thing standing between a port and unopenable photos:

```bash
cd backend && npx tsx ../ios/tools/gen-interop-fixtures.ts   # JS seals
ios/tools/run-interop.sh                                     # Swift opens, and seals
cd backend && npx tsx ../ios/tools/verify-swift-fixtures.ts  # JS opens
```

## Conventions

- **`backend/src/index.ts` must stay Node-safe.** No `cloudflare:workers`
  import may reach it, directly or transitively, or `npm run dev` breaks for the
  whole app. That is why `src/worker.ts` exists.
- **Zod input schemas live in `common/src/index.ts`.** iOS mirrors them by hand
  in `DTOs.swift`, so field names are stable on purpose — renaming one silently
  breaks a Swift decode nothing in the TypeScript build can see.
- **Auth failures are 403, not 401**, everywhere.
- **Explain why, in prose.** The existing READMEs, the wiki and the commit
  messages are the reference for voice: specific, unhedged, and about reasons
  rather than mechanics. Comments that restate the code are not wanted; comments
  that record why a non-obvious thing is non-obvious are.
- Match the surrounding code's idiom rather than importing a new one.

## Maintaining the wiki

The wiki is only worth its tokens if it is true.

- A change that contradicts a wiki page **updates that page in the same
  commit** — not the next one, not a follow-up task.
- A new decision, or a reversed one, gets an entry in `wiki/decisions.md`: what
  was chosen, what was rejected, why, and what would reopen it.
- A newly-discovered way to fail silently gets an entry in `wiki/gotchas.md`.
- **It is not a changelog** — git already is one. Correct entries in place. Never
  write "as of <date>", "previously", or leave a superseded paragraph standing
  below a rule. Wrong lines get deleted.
- **Point, don't copy.** Name a file path rather than restating what is in it.
  Paths survive; copied code drifts.

`wiki/README.md` holds the full contract, including the seven principles the
pages are written to. Read it before adding a page.

**Keep this file short.** It is loaded into every context window, so it holds
only what is needed to route somewhere else. Detail belongs in `wiki/`.
