# Safety and moderation

What App Store Guideline 1.2 asks of an app where people send each other
content: agree to terms, report, block, and somebody who acts on reports within
24 hours. Plus Guideline 5.1.1(v), account deletion.

All of it is server-side where it can be, so agreeing or blocking once covers
every device. The submission checklist and the text to paste into App Store
Connect are in `ios/APP_STORE.md`.

## Terms

`users.terms_accepted_at` is null until `POST /api/v1/user/me/accept-terms`.
`GET /api/v1/user/me` returns it, and the iOS app will not let anyone in until
it is set.

`ios/Instant/Features/Terms/TermsScreen.swift` replaces the app after sign-in
until `AppEnvironment.needsTermsAcceptance` is false. Two details are
deliberate:

- It keys off a **loaded** account whose `termsAcceptedAt` is null, not a
  missing one, so a failed `/me` never traps somebody behind a screen that could
  not submit either.
- It sits **in place of** `MainPager` rather than over it, so nothing behind
  it — a notification opening the viewer — is reachable first.

The guidelines themselves are the `/terms` page of the web app
(`frontend/src/pages/Legal.tsx`), which must stay reachable signed out.

## Blocks

`/api/v1/moderation/blocks` — `GET`, `POST {userId}`, `DELETE /:userId`. Stored
one-way, read both ways; see [data-model.md](data-model.md).

**A block cuts both directions, whoever made it.** Neither person appears in the
other's `/user/list`, conversations or streaks; the key directory returns no
devices; and a send answers **404 exactly as it would for somebody who does not
exist**, so a block cannot be probed for. Un-opened instants between the two are
deleted when the block lands. Unblocking removes only the caller's own block.

Blocks cover Instant and the user list. Blog posts and chat on the web are **not**
filtered by them — a known limit, acceptable because the whole group is people
who know each other, and worth knowing before assuming otherwise.

On iOS, `AppEnvironment.didBlock` drops the person's conversation, anything
waiting from them and any aim at them straight away, without waiting for the
server. Blocking is on the conversation context menu, which replaced a bare long
press for the safety number: one gesture now offers all three. Settings →
Blocked people lists and unblocks.

## Reports

`POST /api/v1/moderation/reports`, multipart: a `payload` JSON part
(`reportedUserId`, `reason`, optional `instantId` and `details`, `alsoBlock`
defaulting to true) and an optional `evidence` image.

**Evidence is the one way the plaintext of an instant ever reaches the server.**
The recipient, who already sees it decrypted, chooses to attach it. It is off by
default in `ReportScreen` and the screen says why. It is stored privately under
`reports/` in R2, streamed only through
`GET /api/v1/admin/reports/:id/evidence`, and deleted when the report is
resolved.

Opening the report sheet pauses the viewer's countdown (`ViewerModel.pause`), so
the photo being reported is still there to attach; sending closes the viewer
rather than resuming it. Reporting also blocks, unless the toggle is turned off.

Every address in `ADMIN_EMAILS` is emailed on arrival. Without `RESEND_API_KEY`
the report is still stored and a warning is logged — a missing mail
configuration must never lose a report.

## Resolving

`GET /api/v1/admin/reports`, `PUT /api/v1/admin/reports/:id/resolve {action}`,
surfaced in `frontend/src/components/AdminReports.tsx`.

- `dismiss` closes it.
- `suspend` sets the reported account to `rejected`, which sign-in and refresh
  already refuse, and revokes its sessions. **Its current access token still
  works until it expires, at most 15 minutes.** That is the cost of stateless
  access tokens and it is accepted.

Reports survive either account being deleted, with that side set to null.

## On-device filtering

`ios/Instant/Core/Media/SensitivityCheck.swift` runs Apple's
SensitiveContentAnalysis on each decrypted photo. **The server cannot inspect
ciphertext, so on-device is the only place filtering can happen** — this is a
direct consequence of end-to-end encryption, not a preference.

A flagged photo is shown blurred with *View anyway* and *Report*, and counts as
**unseen** — no read receipt, no countdown — until revealed. The classifier only
runs when the person has Sensitive Content Warnings or Communication Safety
turned on; otherwise the policy is `.disabled` and photos are shown as sent.
Needs the `com.apple.developer.sensitivecontentanalysis.client` entitlement.

## Deleting an account

`POST /api/v1/user/me/delete {password}`.

The password is asked again, and a wrong one answers **400, not 403**. Clients
treat 403 as an expired session and answer it with a refresh, so a typo would
otherwise sign the person out. This is the one deliberate exception to the
403-means-auth-failure rule in [accounts.md](accounts.md).

Order matters: the profile picture, post images and un-opened instant ciphertext
are deleted from R2 **first**, then the user row, whose cascade takes everything
else. Deleting the user first would leave ciphertext with nothing pointing at
it — see [instant-runtime.md](instant-runtime.md).

It is the whole Lounge account, blog posts included, not just Instant. On iOS
the device's key for that account is deleted from the Keychain before signing
out, because Keychain items outlive the app.

## Where each requirement lives

| Requirement | Code |
|---|---|
| Agree to terms before use | `ios/Instant/Features/Terms/TermsScreen.swift`, gated in `App/RootView.swift`; `POST /user/me/accept-terms` |
| Report content | `ios/Instant/Features/Moderation/ReportScreen.swift`; `POST /moderation/reports` |
| Block users | Inbox context menu, `Features/Moderation/BlockedPeopleScreen.swift`; `/moderation/blocks` |
| Filter objectionable content | `ios/Instant/Core/Media/SensitivityCheck.swift`, concealment in `ViewerModel` |
| Act on reports in 24h | Admin email on every report; the `/admin` reports queue |
| Published contact info | Settings → Safety & support; the web `/support` page |
| Account deletion | `Features/Settings/DeleteAccountScreen.swift`; `POST /user/me/delete` |
| Privacy manifest | `ios/Instant/Resources/PrivacyInfo.xcprivacy` |

`PrivacyInfo.xcprivacy` and the App Privacy answers in `ios/APP_STORE.md`
describe the same thing and **must be changed together**.
