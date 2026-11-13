# Aidrobe iOS

Native SwiftUI client (iOS 26+) for Aidrobe / 衣然 — decide what to wear from your real wardrobe.

```sh
brew install xcodegen          # only needed when project.yml changes
cd Packages/AidrobeKit && swift test
open Aidrobe.xcodeproj         # run the "Aidrobe" scheme on an iPhone simulator
```

Debug builds talk to `http://localhost:8000` (run the backend from `aidrobe-BE` with `docker compose up`) and skip login with the development user. See `CLAUDE.md` for conventions and `docs/plans/` for the rewrite plan.
