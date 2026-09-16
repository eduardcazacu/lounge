# Accounts, tokens and groups

## Getting in is two gates, not one

1. **Verify the email.** Signup sends a link through Resend. Until it is
   followed, sign-in refuses.
2. **Be approved by a human.** New accounts land `pending`. An administrator
   flips them to `approved` (`PUT /api/v1/admin/approve/:id`), which sends a
   welcome mail. Sign-in refuses anything not `approved`.

Addresses listed in `ADMIN_EMAILS` skip the second gate — an admin signup is
auto-approved, otherwise the first administrator could never get in.

This is the whole membership funnel, and it is meant to be narrow. See
[product.md](product.md).

## Tokens

**Access token** — HS256 JWT signed with `JWT_SECRET`, payload `{ id, exp }`,
**15 minutes** (`ACCESS_TOKEN_TTL_SECONDS` in `backend/src/route/user.ts`). Sent
as `Authorization: Bearer`.

**Refresh token** — an opaque random string, stored **only** as a SHA-256 hex
digest in `sessions.token_hash`, 30 days, delivered as an httpOnly `refresh_token`
cookie (`SameSite=Lax`; `secure` only when the request URL is https, so local
http development works).

`POST /api/v1/user/refresh` **rotates**: inside one `prisma.$transaction` it
revokes the old session and creates a new one, and re-checks that the account is
still verified and still approved. Suspending someone therefore stops their next
refresh, though their current access token keeps working for up to 15 minutes.

**Passwords** — bcryptjs at 12 rounds (`backend/src/password.ts`). A legacy
plaintext row is accepted once and silently upgraded on successful sign-in.

### Auth failures are 403, not 401

Every client keys its refresh logic off **403**. A port that watches for 401
will let the 15-minute token quietly end the session with no visible error.

There is one deliberate exception: a wrong password on
`POST /api/v1/user/me/delete` answers **400**, precisely so clients do not read
it as an expired session and answer it with a refresh. See [safety.md](safety.md).

### Refresh renews a session; it must never start one

`POST /api/v1/user/refresh` authenticates from the `refresh_token` cookie alone.
A signed-out client that answers its first 403 by refreshing will therefore
silently adopt whichever account that ambient cookie belongs to.

Both clients refuse to refresh while holding no token —
`ios/Instant/Core/Networking/APIClient.swift` and the axios interceptors in
`frontend/src/lib/auth.ts`. This is not theoretical; it was caught on a
Simulator, where cookie and Keychain storage are not sandboxed per app the way
they are on a device, and the app came up signed in as the machine's owner.

### Token confusion is defended explicitly

Instant's WebSocket ticket is a JWT signed with the same `JWT_SECRET` but
carrying `aud: "instant-ws"` and a `deviceId`, valid 60 seconds. To stop one
being used as the other:

- `instantRouter` and `moderationRouter` reject any token that carries an `aud`
  claim at all.
- `GET /api/v1/instant/ws` rejects any token that does not.

This is why each router installs its own JWT middleware rather than sharing one.

## Email tokens

Verification and password reset use the same pattern: 32 random bytes as
base64url, stored as a SHA-256 hex digest with an expiry, compared by hash.
Verification lasts 24 hours; password reset lasts 1 hour
(`PASSWORD_RESET_TOKEN_TTL_MS`). `POST /api/v1/user/resend-verification` has a
60-second cooldown. Mail goes out through Resend; the machinery is in
`backend/src/email.ts` and `backend/src/verification.ts`.

## Admin is an allowlist

There is no admin column, no role, no join table. `ADMIN_EMAILS` is a
comma-separated secret, resolved by `backend/src/admin-config.ts`, and the
`adminRouter` middleware looks the caller's email up per request.

Two consequences: promoting somebody is a secret change and a redeploy, not a
database write; and the check costs a user lookup on every admin request, which
is fine at this scale and would not be at another.

The same middleware stashes the admin's `groupId`, so broadcasts stay inside
their own group.

## Groups

Every user belongs to exactly one group, and a group is a **sealed-off copy of
the community**. People see only the users, posts, comments, likes, chat
messages and Instant key directories of their own group, and can only mention,
like, comment on or send instants to their own group. Anything outside answers
**404**, as though it did not exist.

Two groups are seeded by `20260914090000_groups`:

- **`main`** — the real community. Every pre-existing account was put here, and
  every signup lands here.
- **`testing`** — App Store review accounts, so reviewers get a working app
  containing nobody's real content.

**The caller's group is looked up per request** (`backend/src/groups.ts`) rather
than carried in the JWT, so moving somebody between groups takes effect
immediately instead of at their next sign-in.

Admin broadcasts, email and push alike, reach only the admin's own group. Admin
approval and `GET /api/v1/admin/stats` deliberately span every group.

### Creating an account in a group

Signup cannot choose a group, so review accounts are made with a script that
creates the account already verified and already approved:

```bash
cd backend
npx tsx scripts/create-account.ts --email review@example.com --name "App Review" --group testing
```

It writes to whatever `DATABASE_URL` resolves to. The password comes from
`ACCOUNT_PASSWORD` if set, otherwise it is generated and printed once. Either
way it reaches the database only as a bcrypt hash. **Never commit it** — it
belongs in App Store Connect's review notes and a password manager.
