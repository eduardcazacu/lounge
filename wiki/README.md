# The wiki

Why this project is shaped the way it is.

The code says what it does. These pages say why it does it that way, what was
tried instead, and which mistakes have already been made so that nobody makes
them twice. It is written for a language model reading it cold, with no memory
of the last session — which turns out to be the same thing as writing it for a
person who joined this week.

## The pages

| Page | What it answers |
|---|---|
| [product.md](product.md) | What the Lounge is for, who it is for, and what it refuses to become |
| [architecture.md](architecture.md) | The four codebases, what runs where, and why there are three backend entrypoints |
| [data-model.md](data-model.md) | The tables, and the invariants the schema cannot state |
| [accounts.md](accounts.md) | Tokens, verification, admin approval, and groups |
| [instant-protocol.md](instant-protocol.md) | The encryption contract, frozen, and what it does not defend against |
| [instant-runtime.md](instant-runtime.md) | Delivery, the one-shot media read, streaks, conversations, push |
| [web-client.md](web-client.md) | The React app: blog, chat, admin, and Instant as a harness |
| [ios-client.md](ios-client.md) | The SwiftUI app: camera, compose, inbox, widget, extension |
| [safety.md](safety.md) | Terms, blocks, reports, deletion — and what App Review asks for |
| [operations.md](operations.md) | Deploying, every secret by name, and the config that lives only in a dashboard |
| [parallel-implementations.md](parallel-implementations.md) | What must change in more than one place |
| [decisions.md](decisions.md) | The log: what was chosen, what lost, and what would reopen it |
| [gotchas.md](gotchas.md) | The things that fail **silently** |

## Where to start

Reading all of it is usually the wrong move; it is a wiki, not a book.

- **Any non-trivial change** — [product.md](product.md) and
  [architecture.md](architecture.md), then the page for the area you are in.
- **Anything touching Instant's crypto or wire format** —
  [instant-protocol.md](instant-protocol.md) and [gotchas.md](gotchas.md), both,
  before writing a line. A mistake here produces envelopes that nobody can ever
  open, with no error until someone tries.
- **Editing one side of a contract** — check
  [parallel-implementations.md](parallel-implementations.md) first to find out
  how many sides there are.
- **"Why is it like this?"** — [decisions.md](decisions.md), then the area page.
- **Something behaves strangely and the code looks right** —
  [gotchas.md](gotchas.md). It is probably in there.

## How to maintain it

Seven rules. They are what keeps this useful rather than merely large.

**1. Why, not what.** The code is the what, and it is already there and already
correct. A page that describes what a function does has failed twice: it adds
nothing, and it goes stale.

**2. Point, don't copy.** Never restate a schema, a signature or an algorithm.
Name the file — `backend/src/instant-inbox.ts` — and explain why it is shaped
that way. A copied fragment drifts from its original; a path does not.

**3. Record what lost.** X25519 lost to P-256. D1 lost to Postgres. A
`conversations` table lost to reading the streak table. Writing down only the
winner means the losing option gets proposed again every few months, and the
argument gets had again from scratch.

**4. Every claim checkable.** Each assertion names a file, a command or an
endpoint. If a sentence cannot be checked against something in the repo, it is
either wrong or it is atmosphere, and both should go.

**5. Each page stands alone.** No "as described above" pointing across files, no
pronoun whose referent is on another page. A reader arrives at one page in the
middle, by search, having read nothing else.

**6. Small is the point.** Context is the budget. A page too expensive to load
is a page that does not exist. Prefer cutting to appending.

**7. Delete aggressively.** A stale page is worse than a missing one, because it
is believed. When something changes, the wrong lines get removed — not
annotated, not marked deprecated, not kept below a horizontal rule.

### The update contract

- A change that contradicts a page **updates that page in the same commit**. Not
  the next one.
- A new decision, or a reversed one, gets an entry in
  [decisions.md](decisions.md).
- A newly-found way to fail silently gets an entry in [gotchas.md](gotchas.md).
  That page is written in blood and every entry cost somebody an afternoon.
- **This is not a changelog.** Git already is one, and a better one. Entries are
  corrected in place. Nothing here says "as of September 2026" or "previously
  this was". The wiki describes the repo as it stands now.
