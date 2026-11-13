# CLAUDE.md

Native SwiftUI iOS client for Aidrobe (衣然). Backend: [U2SG/aidrobe-BE](https://github.com/U2SG/aidrobe-BE). The React Native client [U2SG/aidrobe-FE](https://github.com/U2SG/aidrobe-FE) (branch `redesign/mvp-v0.8-ui`) remains the Android app and the behavioural reference for parity.

Plan and decisions: `docs/plans/2026-11-13-swiftui-rewrite-plan.md`.

## Commands

- Generate the Xcode project after changing `project.yml`: `xcodegen generate` (the generated `Aidrobe.xcodeproj` is committed so CI needs no generator).
- Unit tests (business logic, no simulator): `cd Packages/AidrobeKit && swift test`
- Build for simulator: `xcodebuild -project Aidrobe.xcodeproj -scheme Aidrobe -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath .build/dd -skipPackagePluginValidation build` (Xcode GUI: trust the OpenAPIGenerator plugin once)
- Contract drift check: `./scripts/check-contracts.sh`; after re-copying `contracts/openapi.json` run `scripts/normalize-openapi.py` (rewrites FastAPI `anyOf [X, null]`, which the generator otherwise drops)

Unlike the backend / RN repos, local build, unit tests and simulator runs are expected here; GitHub CI (`.github/workflows/ci.yml`, `macos-26`) is the merge gate. CI's default Xcode is 26.6 while local is 27.x — only use APIs available in the iOS 26 SDK.

## Layout

- `Packages/AidrobeKit` — UI-free logic: `Core` (environment, flags, Keychain, tokens), `API` (envelope-aware client, single-flight refresh, typed `Endpoint`; wire models are generated from `contracts/openapi.json` as `Wire.*` = `Components.Schemas.*`, types only — never hand-write a model the spec already has), `Upload` (presign + host rewrite + compression). Everything here is unit tested.
- `App/Sources` — SwiftUI only. `Features/<Area>` per tab/flow, `Design/Theme.swift` for tokens.
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
- Prefer system controls (TabView/Tab, NavigationStack, sheets with detents, Menu, PhotosPicker, ShareLink, SignInWithAppleButton, Swift Charts) tinted with brand tokens.
