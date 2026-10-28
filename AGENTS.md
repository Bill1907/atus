# AGENTS.md

Guide for coding agents working on atus, a macOS menu bar app that shows AI subscription usage limits (Claude, Codex, Grok, Cursor, GitHub Copilot, plus user plugins). User-facing docs are in `README.md`; open work is in `TODO.md`.

## Commands

```sh
swift build                                     # debug build
swift test                                      # unit tests (Swift Testing)
swift run Atus                                  # run without a bundle (English only, no login item)
./scripts/bundle.sh --install                   # build build/Atus.app, copy to /Applications, launch
ATUS_UNIVERSAL=1 ./scripts/bundle.sh            # universal (arm64 + x86_64), as CI and releases do
./scripts/release.sh <version>                  # maintainer only, see "Releasing"
swift scripts/make-icon.swift                   # regenerate Resources/AppIcon.icns
```

Toolchain: Swift 6 language mode, macOS 14 deployment target. CI (`.github/workflows/ci.yml`) runs `swift test` and a universal bundle on `macos-latest` (Xcode 26.6 / Swift 6.3 at the time of writing); local development has used Xcode 27.

## Layout

| Path | Contents |
|---|---|
| `Sources/AtusCore/` | Everything that is not UI: the `UsageProvider` protocol and models (`Models.swift`), one file per built-in provider, `CommandProvider.swift` (plugins + `providers.json` loader), `StdioJSONRPC.swift` (talks to vendor CLIs; also `CLILocator`), `ISODate.swift`, `Localization.swift` (`L()`, `appLocale`) |
| `Sources/Atus/` | The app: `main.swift` (plain AppKit lifecycle), `StatusItemController.swift` (NSStatusItem, label image, popover), `UsagePanel.swift` (SwiftUI panel), `UsageStore.swift` (refresh loop, provider selection), `ProviderLogo.swift` (embedded SVG logos) |
| `Tests/AtusCoreTests/` | Response-mapping tests per provider, plugin tests |
| `Resources/` | `Info.plist`, `AppIcon.icns`, `<lang>.lproj/Localizable.strings` |
| `scripts/` | `bundle.sh`, `make-dmg.sh`, `release.sh`, `make-icon.swift` |
| `examples/plugins/` | Plugin scripts referenced from the README |

There is no Xcode project: `scripts/bundle.sh` assembles the `.app` from the SwiftPM binary plus `Resources/`.

## Rules that are easy to break

- **Never write vendor credentials.** Providers only read tokens (keychain via `/usr/bin/security`, `~/.grok/auth.json`, Cursor's `state.vscdb` opened read-only, `gh auth token`). Refresh tokens rotate, so refreshing one ourselves can log the user out of the vendor's CLI. When a token is stale, either report it (`UsageError.tokenExpired`) or go through the vendor's own CLI (`codex app-server`, `grok agent stdio`), which refreshes its own login.
- **Respect vendor terms.** Google forbids third-party reuse of Gemini CLI / Antigravity OAuth, so Gemini is not built in (see README). Don't add a built-in provider that depends on a ban-risk path; that belongs in a user plugin.
- **No network or prompts in `isDetected`.** It only checks for local files. It decides the first-launch defaults.
- **Keep response mapping pure and tested.** Each provider has a `static func snapshot(from:…)` that turns raw JSON into a `UsageSnapshot`. Add a test with a sanitized real response for every new provider or field.
- **All user-facing text goes through `L("English")`** (`L("Format %@", arg)` for formats; `%@` strings, `%ld` integers). The English string is the key. Add the Korean entry to `Resources/ko.lproj/Localizable.strings`; every `L(...)` key must exist there. Tests run without the app bundle, so they assert English. Dates use `appLocale`.
- **Swift 6.3 crash (CI).** Passing a method reference as a SwiftUI `Binding` setter (`set: setEnabled`) crashes the compiler in IRGen. Use a closure (`set: { setEnabled($0) }`). Local Xcode 27 does not reproduce it, so watch CI.
- **Menu bar item.** It is an `NSStatusItem` with `autosaveName = "atus"`, so the user's position persists. Don't go back to `MenuBarExtra`, which doesn't persist position and lands behind the notch. Keep the label compact (two rows per column).
- **Undocumented endpoints.** Most providers call internal APIs. On failure, keep the last good snapshot and surface the error; never crash on unknown or missing fields.

## Adding a built-in provider

1. Add a `ProviderID` constant in `Models.swift`.
2. Create `Sources/AtusCore/<Name>Provider.swift` conforming to `UsageProvider`, with `info` (display name, `L()` requirement caption, `.bundled` icon), `isDetected`, `fetch()`, and a static `snapshot(from:…)`.
3. Register it in `Providers.builtIn`.
4. Add a monochrome SVG to `ProviderLogo.swift` and credit it in `THIRD_PARTY_NOTICES.md` (Simple Icons is CC0; LobeHub Icons is MIT and needs its notice).
5. Add the mapping test, the Korean strings, and README rows (What it shows, How it works, Troubleshooting).

## Verifying changes

Unit tests aren't enough for anything user-visible:

- Run `swift test`, then `./scripts/bundle.sh --install` and check the real app. The menu bar title is readable without screen-recording permission:
  `osascript -e 'tell application "System Events" to tell process "Atus" to get description of menu bar item 1 of menu bar 1'`
- Live provider checks need the user's logins. Write a throwaway test that calls `fetch()` on each provider and prints the snapshot, and delete it afterwards. Never print tokens.
- To check another language: `open -a /Applications/Atus.app --args -AppleLanguages '(en)'`.
- Tests and smoke runs must not leave state behind. Restore `~/.config/atus/providers.json` and the `enabledProviders` / `seenProviders` defaults in `com.boseongkim.atus` if you touch them.

## Releasing

`./scripts/release.sh X.Y.Z` from a clean `main`. It reads signing material from the untracked `release.env` (see `release.env.example`): a Developer ID `.p12` imported into a throwaway keychain, and an App Store Connect API key for `notarytool`. It runs the tests, builds a universal app, signs it with the hardened runtime, notarizes and staples both app and DMG, tags `vX.Y.Z`, and uploads `Atus.dmg` to a GitHub release. The README links to `releases/latest/download/Atus.dmg`, so the asset name must stay `Atus.dmg`. Versioning: minor for features, patch for fixes. Never commit `release.env` or signing files.

## Commits and docs

- Imperative, specific commit subjects (e.g. "Track Codex, Cursor and GitHub Copilot too, with a per-service picker").
- When behavior changes, update `README.md` in the same change. When you finish or discover work, update `TODO.md`.
