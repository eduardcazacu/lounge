# The idea

Eddie's Lounge is a private online hangout for a small group of people who
already know each other. It exists out of frustration with what social media
became, and out of nostalgia for what it was before that — a place where you
posted something because a handful of people would enjoy it, not because a
ranking system might.

Instant is the second half of it: expiring, end-to-end encrypted photos sent to
one person at a time, with a native iPhone app.

## Who it is for

People who were invited. Signing up is public at
`https://lounge.eduardcazacu.com/signup`, but an account is not usable until an
administrator approves it by hand. There is no growth mechanism, no discovery,
no invite tree, no referral. The member list fits on one screen and is meant to.

That single fact decides a surprising amount of the architecture. A directory
of every user can be fetched whole (`GET /api/v1/user/list`). The feed has no
ranking, because there is nothing to rank away. The chat is one room. A photo is
sent to one named person, chosen from a strip of faces, rather than to a
selected audience.

## What is in it

- **Posts** — markdown, one image each, comments, likes, @-mentions.
- **Chat** — a single room with a retention window, default 24 hours.
- **Instant** — a photo, optionally captioned, sealed to the recipient's
  devices, viewable once and then gone. Streaks count consecutive days two
  people send to each other.
- **Themes** — each person picks a palette that follows them around the app, so
  you can tell whose post you are looking at before reading the name.
- **Groups** — every account belongs to exactly one, and a group is a sealed-off
  copy of the community. `main` is the real one. `testing` exists so App Store
  reviewers get a working app containing nobody's real content.

## What it refuses to be

These are choices, re-made deliberately, not gaps waiting to be filled.

- **No ranking, no algorithm.** Posts are reverse-chronological. The only filter
  is "show me this person's posts", and you pick the person.
- **No growth.** There is no public content, no SEO surface, no share-to-signup.
  Admin approval is the whole funnel and it is meant to be narrow.
- **No key recovery for Instant.** A new device means a new identity, and
  anything already sealed to the old one stays sealed forever. Recovery would
  mean an escrowed key, which would mean the server could read photos. See
  [instant-protocol.md](instant-protocol.md).
- **No read-the-photo-twice.** Fetching an instant's media destroys it, across
  every device the recipient owns. That is the promise the countdown makes, and
  it is enforced on the server rather than by asking the client nicely.
- **No iPad app.** The camera and the pager are phone-shaped. iPads run the
  iPhone build in compatibility mode.
- **No in-app signup on iOS.** Signup needs an email verification link and then
  a human approval, so an in-app form could only ever end on a waiting screen.
  It links to the web instead.

## The web Instant client is not the product

`/instant` in the React app came first and still works, but it was always a test
harness. The design target is the signed iOS binary: an app that does not
re-download its own cryptography on every visit, with the private key in the
Secure Enclave.

This is not modesty about the web client — it is the threat model. Browser
end-to-end encryption is only ever as strong as the channel that delivers the
JavaScript, and that channel is a Vercel deployment. The web client says so, to
the user's face, in `frontend/src/components/instant/InstantKeySetup.tsx`.

P-256 was chosen over X25519 for exactly one reason: it is the only curve the
Secure Enclave supports. The whole crypto contract bends around an app that did
not exist yet when it was written.

## Lineage

The blog half started from syedahmedullah14's Medium-style example app and has
been rewritten well past it. The package name `@blogging-app/common` is the last
visible trace, kept because renaming it would churn every import for nothing.
