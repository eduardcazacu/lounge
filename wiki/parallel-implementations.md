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

## The caption geometry — two places, and two inside iOS

The iOS **plate** caption at scale 1 matches the web's only caption:
`ios/Instant/Core/Media/OverlayCompositor.swift` against
`frontend/src/components/instant/InstantComposer.tsx`, font 6% of the image
width, positions clamped to 0.05–0.95. The bar style, the pinch scale, the
rotation, several captions per photo and drawing are iOS-only and have no web
side to keep in step.

A caption is burned into the pixels before the photo is sealed, so its position
is stored as **image fractions** and never travels on the wire. Two clients
that place it differently produce visibly different photos from the same input,
with nothing to compare against afterwards.

Inside the app, the compose preview (`ComposeScreen.swift`) and the compositor
are the other pair. Both size a caption from `OverlayCompositor.metrics` and
wrap it with `OverlayCompositor.textSize`, which is how the preview's line
breaks match the pixels. A preview that measured its own text would drift. A
drawn line is the same: both stroke `OverlayCompositor.path` at the width
`OverlayCompositor.strokeWidth` gives for the photo's width.

## The wire types — `common/` and hand-written Swift

`common/src/index.ts` holds the Zod input schemas and wire types that the
backend and the web client share. **iOS does not consume it** — 
`ios/Instant/Core/Networking/DTOs.swift` mirrors the same shapes by hand, with
property names matching the JSON exactly so that no `CodingKeys` are needed.

This is why `common/src/index.ts` carries the instruction to keep the shapes
explicit and the field names stable: renaming a field there silently breaks a
Swift decode that nothing in the TypeScript build can see. Adding an *optional*
field is safe; renaming or removing one is not.

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
- **The image compression ladder** exists as `frontend/src/lib/image.ts` and
  `ios/Instant/Core/Media/ImagePipeline.swift`. They need not agree exactly —
  each targets its own budget — but both must stay under the 3 MiB ciphertext
  ceiling the send endpoint enforces.
- **The `instant://` deep link** is built by the widget extension and parsed by
  the app, which is exactly why it lives once in `ios/Shared/DeepLink.swift`
  rather than being spelled out twice. Keep it that way.
