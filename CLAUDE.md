# CLAUDE.md

Native SwiftUI iOS client for Aidrobe (衣然). Backend: [U2SG/aidrobe-BE](https://github.com/U2SG/aidrobe-BE). The React Native client [U2SG/aidrobe-FE](https://github.com/U2SG/aidrobe-FE) (branch `redesign/mvp-v0.8-ui`) remains the Android app and the behavioural reference for parity.

Plan and decisions: `docs/plans/2026-11-13-swiftui-rewrite-plan.md`.

## Commands

- Generate the Xcode project after changing `project.yml`: `xcodegen generate` (the generated `Aidrobe.xcodeproj` is committed so CI needs no generator).
- Unit tests (business logic, no simulator): `cd Packages/AidrobeKit && swift test`
- Build for simulator: `xcodebuild -project Aidrobe.xcodeproj -scheme Aidrobe -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath .build/dd -skipPackagePluginValidation build` (Xcode GUI: trust the OpenAPIGenerator plugin once)
- Dev wardrobe: `scripts/dev-seed-wardrobe.py [--reset]` gives the dev user 16 drawn garments through the real import pipeline (the dev API is rate-limited per minute; the script waits).
- Screenshot walkthrough (local stack only, not in CI): `TEST_RUNNER_WALKTHROUGH_DIR=/tmp/aidrobe-shots xcodebuild test -project Aidrobe.xcodeproj -scheme Walkthrough -destination 'platform=iOS Simulator,name=iPhone Air' -skipPackagePluginValidation`. Look at the screenshots after any UI change, light and dark (`testDarkAppearance`).
- Contract drift check: `./scripts/check-contracts.sh`; after re-copying `contracts/openapi.json` run `scripts/normalize-openapi.py` (rewrites FastAPI `anyOf [X, null]`, which the generator otherwise drops)

Unlike the backend / RN repos, local build, unit tests and simulator runs are expected here; GitHub CI (`.github/workflows/ci.yml`, `macos-26`) is the merge gate. CI's default Xcode is 26.6 while local is 27.x — only use APIs available in the iOS 26 SDK.

## Layout

- `Packages/AidrobeKit` — UI-free logic: `Core` (environment, flags, Keychain, tokens), `API` (envelope-aware client, single-flight refresh, typed `Endpoint`; wire models are generated from `contracts/openapi.json` as `Wire.*` = `Components.Schemas.*`, types only — never hand-write a model the spec already has), `Upload` (presign + host rewrite + compression). Everything here is unit tested.
- `Packages/AidrobeKit/.../Domain` — pure rules with tests (`OutfitBoardLayout`, `SettingsFormat`).
- `App/Sources` — SwiftUI only. `Features/<Area>` per tab/flow (Today, Wardrobe, Import, Profile). `Design/` holds the system: `Theme.swift` (tokens, `Font.display`, `kicker()`, `SectionHeading`), `Components.swift` (`Chip`, `FlowLayout`, `FactRow`, `.toast`), `GarmentImage.swift` (image pipeline + on-device cutout), `Vocabulary.swift` (display copy for categories, colours, statuses; `userMessage(for:)`).
- `App/UITests` — the walkthrough above.
- `App/Resources/Assets.xcassets` — brand colours with light + dark variants (light values mirror RN `src/theme/design.ts`).
- `Config/*.xcconfig` — per-configuration `AIDROBE_*` values surfaced through Info.plist and read by `AppEnvironment`.
- `contracts/` — byte-identical copies of the backend's `docs/openapi.json`, `v3-p0-contract.md`, `v3-analytics-events.json`. Never edit locally; re-copy from the backend.

## Rules that are easy to get wrong

- Two error channels: HTTP 2xx with non-zero envelope `code` (`APIError.business`) and HTTP ≥400 with `data.reason` (`APIError.http`). V3 success bodies are not wrapped. 503 = backend flag off → hide the surface silently.
- Persist `object_key`, never signed `file_url`s (≈30 min TTL).
- Presigned upload hosts `minio` / `localhost` / `127.0.0.1` / `0.0.0.0` are rewritten to the `file_url` host on the client — don't move this to config.
- Today / refresh / first-outfit need the 60 s `Endpoint.slowTimeout`.
- Location is sent as `"lon,lat"` (longitude first, 2 decimals); departure time as `HH:MM:00`.
- Copy must pass the RN denylist (`aidrobe-FE/scripts/check-copy-denylist.ts`), e.g. no 显瘦 / 遮肉 / 减龄 / 数字分身 / AI 虚拟试衣.
- The look is a daily page: warm paper background, Songti headlines via `Font.display` (an on-demand system font; system serif until it arrives, and always on the simulator), section kickers over hairlines, no shadows or gradients. Glass is for floating controls only (bottom bar, toolbar buttons, toasts). Every garment picture goes through `GarmentImage`; all garment/status copy through `Garment.*`.
- Cutouts are made on device with Vision and cached by image path; the server original is never replaced. Vision's subject lift does not run on the simulator, so screens there show photo tiles — design for both.
- A view whose content can be empty must not hang `.task` on a `Group` (it attaches to nothing); use a `ZStack`.
- Dates from the API (`recommendation_date`, `last_worn`) are calendar days: never derive "today" from an ISO8601 format of `Date.now` (that is UTC).
- Prefer system controls (TabView/Tab, NavigationStack, sheets with detents, Menu, PhotosPicker, ShareLink, SignInWithAppleButton, Swift Charts) tinted with brand tokens.
