# Submitting Instant to the App Store

What App Review needs from this app, where each requirement lives in the code,
and the text to paste into App Store Connect. **No credentials belong in this
file** — the review accounts' passwords go only into App Store Connect.

## Checklist

Before each submission:

1. **Backend first.** `cd backend && DATABASE_URL=<production> npm run prisma:deploy`,
   then `npm run deploy`. The app calls `/moderation/*`, `/user/me/accept-terms` and
   `/user/me/delete`; an app build that reaches an old backend gets 404s.
2. **Web.** Deploy the frontend so `/privacy`, `/terms` and `/support` are live on
   `https://lounge.eduardcazacu.com`. Review opens them.
3. **Email.** `hello@eduardcazacu.com` must receive mail — it is the published
   support address — and `ADMIN_EMAILS` plus `RESEND_API_KEY` must be set on the
   Worker, or nobody hears about a report within the 24 hours the terms promise.
4. **Review accounts** exist in the `testing` group (`backend/README.md`, Groups)
   and can sign in. Sign each in on a device once so it has a device key: nobody
   can send an instant to an account that has never opened the app.
5. **Archive** in Xcode (Product → Archive) with the Release configuration and
   upload. The Sensitive Content Analysis and Push capabilities must be enabled on
   the App ID; automatic signing adds them.
6. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` for every upload.

## App information

| Field | Value |
|---|---|
| Privacy Policy URL | https://lounge.eduardcazacu.com/privacy |
| Support URL | https://lounge.eduardcazacu.com/support |
| Terms (EULA) | Standard Apple EULA is fine; the Community Guidelines are at https://lounge.eduardcazacu.com/terms and are agreed to in the app |
| Category | Social Networking (secondary: Photo & Video) |
| Devices | iPhone only (`TARGETED_DEVICE_FAMILY = 1`). It still runs on iPad in compatibility mode, which review may use. |
| Screenshots | `ios/screenshots/`, 1320×2868 for the 6.9" slot |
| Age rating | Answer the questionnaire honestly: user-generated content and messaging are both **yes**, unrestricted web access **no**. Expect 13+ or higher; the terms require 16. |

## Review notes (paste into "Notes" under App Review Information)

> Instant is the iPhone app for Eddie's Lounge, a small invite-based community.
> New accounts are created at https://lounge.eduardcazacu.com/signup and
> approved by an administrator, so please use the two demo accounts provided.
> They are in an isolated test group: you will only see each other.
>
> **To send and receive an instant on one device:**
> 1. Sign in as App Review 2 and agree to the Community Guidelines. Sign out
>    (profile button top-left → Sign out). This registers its device key.
> 2. Sign in as App Review 1. Take a photo (or pick one — the shutter falls back
>    to the photo library without a camera), tap Send To, choose App Review 2.
> 3. Sign out, sign back in as App Review 2. Swipe right or tap the chat button
>    for conversations and open the instant.
>
> **User-generated content (Guideline 1.2):**
> - Everyone must agree to the Community Guidelines (zero tolerance for
>   objectionable content and abusive users) before using the app.
> - Report a photo: while viewing it, tap ••• (top right). The reporter can
>   choose to attach the photo for the moderators; photos are otherwise end-to-end
>   encrypted and cannot be seen by us.
> - Report or block a person: press and hold them in the conversation list.
> - Blocked people are listed, and can be unblocked, under profile → Blocked people.
> - Filtering: received photos are checked on-device with Apple's
>   SensitiveContentAnalysis framework and hidden behind a warning when the user
>   has Sensitive Content Warnings or Communication Safety turned on.
> - Every report emails the administrators, is reviewed within 24 hours, and
>   offending accounts are suspended. Contact: hello@eduardcazacu.com.
>
> **Account deletion (Guideline 5.1.1(v)):** profile → Delete account. It asks
> for the password and deletes the account and all its data immediately.
>
> **Encryption:** photos are end-to-end encrypted with CryptoKit and the Secure
> Enclave; the server stores only ciphertext.

## App Privacy ("nutrition label")

Tracking: **No.** For each type below: *linked to the user*, *not used for
tracking*, purpose **App Functionality** only. This mirrors
`Instant/Resources/PrivacyInfo.xcprivacy` — change both together.

| Data type | Why |
|---|---|
| Contact Info → Email Address | Account sign-in |
| Contact Info → Name | Display name shown to the group |
| Identifiers → User ID | Account id |
| Identifiers → Device ID | Each device's Instant key id |
| User Content → Photos or Videos | Profile pictures, and a photo a reporter chooses to attach to a report |
| User Content → Other User Content | Bio; report details |

Not collected: instant photo contents (end-to-end encrypted — Apple's
definition excludes data the developer cannot read), location, contacts,
health, financial info, browsing history, search history, usage data,
diagnostics.

## Export compliance

`ITSAppUsesNonExemptEncryption = NO` is set in `Instant-Info.plist`, so App Store
Connect does not ask on every build. The basis: every cryptographic operation
goes through Apple's operating system — CryptoKit (P-256 ECDH, HKDF-SHA256,
AES-GCM), Secure Enclave keys, and URLSession's TLS — and the app implements no
cryptography of its own. Apple treats encryption limited to what the OS provides
as exempt.

This is a legal declaration and it is yours to make. If you are not comfortable
that end-to-end encrypted messaging built on OS APIs qualifies, set the key to
`YES`, answer the questionnaire in App Store Connect, and file the annual
self-classification report with the US Bureau of Industry and Security. The
French declaration applies only if you distribute in France with non-exempt
encryption.

## Where each requirement lives

| Requirement | Code |
|---|---|
| Agree to terms before use | `Features/Terms/TermsScreen.swift`, gated in `App/RootView.swift` by `AppEnvironment.needsTermsAcceptance`; `POST /user/me/accept-terms` |
| Report content | `Features/Moderation/ReportScreen.swift` from `Features/Viewer/ViewerScreen.swift` (•••) and the inbox context menu; `POST /moderation/reports` |
| Block users | Inbox context menu, `Features/Moderation/BlockedPeopleScreen.swift`; `/moderation/blocks` |
| Filter objectionable content | `Core/Media/SensitivityCheck.swift` (SensitiveContentAnalysis), concealment in `ViewerModel` |
| Act on reports in 24h | Admin email on every report; `/admin` Reports queue with Suspend/Dismiss |
| Published contact info | Settings → Safety & support; `/support` |
| Account deletion | Settings → Delete account (`Features/Settings/DeleteAccountScreen.swift`); `POST /user/me/delete` |
| Privacy manifest | `Instant/Resources/PrivacyInfo.xcprivacy` |
| App icon | `Instant/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`, from `tools/make-app-icon.swift` |

## If review pushes back

- **Guideline 3.2 / "limited audience".** Apps built for a closed group are
  sometimes steered to Unlisted App Distribution. The notes above point at the
  public signup page. If Apple still asks, request unlisted distribution in App
  Store Connect; it goes through the same review and needs no code change.
- **"We could not sign up."** Signup requires admin approval by design; the demo
  accounts are the answer, and saying so in the notes usually prevents this.
- **Push.** The app asks for notification permission after sign-in. Push needs
  the `APNS_*` Worker secrets (`backend/README.md`); without them the app still
  works and delivers over its WebSocket while open.
