# What must change in more than one place

Several contracts in this repository are implemented two, three or four times,
in two languages. That is deliberate in every case — the alternatives were worse
— but it means **editing one side is usually a bug**.

Check this page before changing anything listed here.

## The Instant crypto contract — three places, plus fixtures

| Where | Role |
|---|---|
| `frontend/src/lib/instantCrypto.ts` | **Authoritative.** The header comment is the contract |
| `ios/Instant/Core/Crypto/InstantCrypto.swift` | The Swift port, restating the contract and its three silent-failure modes |
| `ios/InstantTests/Fixtures/*.json` | Committed fixtures pinning both directions |

Why not share it: WebCrypto and CryptoKit have no common implementation, and the
whole point of the iOS app is a Secure Enclave key that could not exist in
JavaScript.

**What pins it** is the fixture loop, and the trick is that the generators
*import the real web implementation* rather than restating the algorithm:

```bash
cd backend && npx tsx ../ios/tools/gen-interop-fixtures.ts
ios/tools/run-interop.sh
cd backend && npx tsx ../ios/tools/verify-swift-fixtures.ts
```

A generator that reimplemented the crypto would agree with a Swift port carrying
the same misunderstanding. Run all three after touching either side. Details in
[instant-protocol.md](instant-protocol.md).

## The eight themes — four places

| Where | What it holds |
|---|---|
| `common/src/index.ts` | `themeKeys`, the Zod enum and `ThemeKey` type |
| `frontend/src/themes.ts` | `THEME_PALETTES` — six colours per key |
| `ios/Shared/Theme.swift` | The same palettes, accent and border |
| `users.theme_key` in Postgres | Which one each person picked |

Adding a theme means all four, in that order — the enum first, because the
backend validates against it, and the database last if a migration changes the
default. Nothing checks that the hex values match; they are matched by hand, and
a mismatch shows up as the same person looking like two different people on two
clients.

## The photo overlay — two clients, and a preview inside each

`ios/Instant/Core/Media/OverlayCompositor.swift` and
`frontend/src/components/instant/overlay.ts` are the same file in two languages:
the caption placement and its clamp, the two styles and their metrics, the
scale range, the rotation snap, the stroke width and the curve through the
midpoints. Both clients have the whole model now — bar and plate, several
captions, pinch, turn, drawing — so there is no longer a smaller web version to
allow for.

A caption and a line are burned into the pixels before the photo is sealed, so
their positions are stored as **image fractions** and never travel on the wire.
Two clients that place them differently produce visibly different photos from
the same input, with nothing to compare against afterwards.

**Inside each client there is a second pair**: the preview and the burn-in. Both
read the same metrics and, crucially, the same *wrapping* —
`OverlayCompositor.textSize` on iOS, `wrapLines` on the web, where the preview
renders the lines that function returns rather than letting the browser wrap the
text itself. A preview that measured its own text would drift from the file, and
nothing would say so. The drawing is the same story: preview and compositor
stroke one path at one width.

The numbers that can be checked without a font are checked:

```bash
cd backend && npx tsx ../frontend/scripts/verify-instant-parity.ts
```

## The seven looks — two clients, and they need not match exactly

`ios/Instant/Core/Media/PhotoFilter.swift` and
`frontend/src/components/instant/filters.ts`. Same seven ids, same names, same
order, same intent — vibrance before saturation for vivid, a fixed per-channel
gain for warm and cool.

The arithmetic deliberately does **not** match: `CIPhotoEffectMono` and friends
are proprietary curves with no published definition, and the web side is a
per-pixel approximation. That is fine, and it is worth knowing why — the look is
burned in before the photo is sealed, so what travels is an image, not a filter
name, and nothing downstream can tell. What must not drift is the list itself,
which the verifier above pins.

## The wire types — `common/` and hand-written Swift

`common/src/index.ts` holds the Zod input schemas and wire types that the
backend and the web client share. **iOS does not consume it** — 
`ios/Instant/Core/Networking/DTOs.swift` mirrors the same shapes by hand, with
property names matching the JSON exactly so that no `CodingKeys` are needed.

This is why `common/src/index.ts` carries the instruction to keep the shapes
explicit and the field names stable: renaming a field there silently breaks a
Swift decode that nothing in the TypeScript build can see. Adding an *optional*
field is safe; renaming or removing one is not.

## The duration modes — three places

`instantDurationModes` in `common/src/index.ts` (with the photo and video
families, and the rule pairing them with `mediaType`), `InstantDurationMode` in
`ios/Instant/Core/Networking/DTOs.swift`, and in the web client
`DURATION_MS` in `InstantViewer.tsx` and `durationText` in `InboxScreen.tsx`.
A mode added to `common/` alone is accepted by the server and shown by iOS as
five seconds — the Swift decoder maps anything it does not know there, on
purpose, because a strict one fails the whole inbox (see
[gotchas.md](gotchas.md)). The web composer lists its own modes and offers
photo ones only.

## Auth behaviour — two clients, same rules

`frontend/src/lib/auth.ts` and `ios/Instant/Core/Networking/APIClient.swift`
implement the same three rules independently:

- Refresh on **403**, not 401.
- Exactly one refresh and one retry per request (`__authRetried` in axios, the
  `RefreshCoordinator` in Swift).
- **Never refresh while holding no token** — see [accounts.md](accounts.md) for
  what happens otherwise.

A third client would have to reimplement all three. They are in
[gotchas.md](gotchas.md) because each one fails silently.

## Also worth knowing

- **`PrivacyInfo.xcprivacy` and the App Privacy table in `ios/APP_STORE.md`**
  describe the same disclosures and must change together.
- **The receipt and the relative-time phrasing** exist as
  `ios/Instant/Core/RelativeTime.swift` plus `InstantSendReceipt.status`, and
  `frontend/src/components/instant/relativeTime.ts` plus `sendReceipt.ts`. Two
  clients telling the same person two different things about the same photo is
  the kind of difference nobody can explain afterwards. Pinned by the verifier
  above.
- **The image compression ladder** exists as `frontend/src/lib/image.ts` and
  `ios/Instant/Core/Media/ImagePipeline.swift`. They need not agree exactly —
  each targets its own budget — but both must stay under the 3 MiB ciphertext
  ceiling the send endpoint enforces. So must the video bitrate ladder in
  `ios/Instant/Core/Media/VideoPipeline.swift`, whose `byteBudget` is that
  ceiling restated, less a margin.
- **The `instant://` deep link** is built by the widget extension and parsed by
  the app, which is exactly why it lives once in `ios/Shared/DeepLink.swift`
  rather than being spelled out twice. Keep it that way.
