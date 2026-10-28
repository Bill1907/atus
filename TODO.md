# TODO

Open work for atus, most important first. Move items to "Done" with the version that shipped them.

## 1. Homebrew distribution

Goal: `brew install --cask atus`. Until then, offer a personal tap.

### 1a. Personal tap (now)

Homebrew/cask won't take the app yet. Its [Package Acceptance Policy](https://docs.brew.sh/Package-Acceptance-Policy) requires the repository to be at least 30 days old and, for a self-submission by the repository owner, 90 forks, 90 watchers or 225 stars. The repo was created on 2026-10-28.

- [ ] Create the public repo `Bill1907/homebrew-tap`, with `Casks/atus.rb`:
  ```ruby
  cask "atus" do
    version "0.4.0"
    sha256 "<sha256 of Atus.dmg for this version>"

    url "https://github.com/Bill1907/atus/releases/download/v#{version}/Atus.dmg"
    name "atus"
    desc "Menu bar meter for Claude, Codex, Grok, Cursor and Copilot usage limits"
    homepage "https://github.com/Bill1907/atus"

    livecheck do
      url :url
      strategy :github_latest
    end

    depends_on macos: :sonoma

    app "Atus.app"

    uninstall quit: "com.boseongkim.atus"

    zap trash: [
      "~/.config/atus",
      "~/Library/Preferences/com.boseongkim.atus.plist",
    ]
  end
  ```
- [ ] Check it locally: `brew style --fix Casks/atus.rb`, `brew audit --cask --online bill1907/tap/atus`, then install, launch, and uninstall/zap on a clean account.
- [ ] Extend `scripts/release.sh`: after the GitHub release, compute `shasum -a 256 dist/Atus.dmg`, update `version` and `sha256` in the tap, commit and push it. Skip with a warning if the tap checkout isn't present. Never point the cask at `releases/latest`, since the sha256 must match a fixed file.
- [ ] README Install: add the Homebrew route. Since Homebrew 6, third-party taps must be trusted; installing by full name trusts only this cask.
  ```sh
  brew install --cask bill1907/tap/atus
  ```
  Upgrades go through `brew upgrade --cask atus`. Note that a Homebrew install and a manual DMG install of the same app shouldn't be mixed.

### 1b. Official homebrew/cask (later)

- [ ] When the repo is 30+ days old and meets notability (225 stars / 90 forks / 90 watchers as owner, or 75 / 30 / 30 if someone else submits), open a PR to `Homebrew/homebrew-cask`. Run `brew audit --cask --new --online atus` first. Releases are already Developer ID signed and notarized, which official casks require.
- [ ] After acceptance, drop the tap from the README (or keep it only for pre-releases) and stop updating it in `release.sh`.

## 2. Notifications when a limit is close

Goal: a macOS notification when any tracked window crosses a threshold, so you notice before you're cut off.

Behavior:
- [ ] Default thresholds **80%** and **95%**, configurable in the panel (e.g. a "Notify at" control with off / 80 / 90 / 95 and a second level). Persist in UserDefaults.
- [ ] Notify once per crossing. Track `(provider id, window key, resetsAt)` → highest threshold already notified, persisted so relaunches don't re-alert. When `resetsAt` changes (the window reset) or usage drops below the threshold, the window can alert again.
- [ ] Don't alert for values that were already over the threshold on the first fetch after launch if that same crossing was already recorded. Do alert on the first fetch if it was never recorded (e.g. a fresh install already at 96%).
- [ ] Content, localized through `L()`:
  - title: "Claude 5-hour session at 82%"
  - body: "Resets in 1h 24m (7:10 PM)"
  - Clicking the notification opens the panel.
- [ ] Plugins take part too, since their windows have labels.
- [ ] Optional: a separate alert when a provider starts failing (e.g. token expired) and stays failed for more than an hour.

Implementation notes:
- [ ] Give `UsageWindow` a stable `key` (e.g. `five_hour`, `seven_day`, `primary`, plugin label) that doesn't change with the UI language. Today `label` is localized, so it can't be the dedup key.
- [ ] New `NotificationCenter`-style service in the app target (e.g. `LimitNotifier`), fed by `UsageStore` after each successful fetch; the threshold-crossing logic lives in a pure function in `AtusCore` so it can be unit-tested (crossing up, staying above, reset, drop below, multiple thresholds in one jump → one notification for the highest).
- [ ] Use `UNUserNotificationCenter`. Request authorization the first time notifications are enabled, not at launch. If authorization is denied, show that in the panel with a button to open System Settings → Notifications.
- [ ] Notifications need the bundled app (bundle identifier); `swift run` can't post them. Verify with the installed app. A test hook that fakes a crossing (or a debug menu item) is fine during development, but remove it before release.
- [ ] README: document the setting and how to turn notifications off.

## 3. Smaller follow-ups

- [ ] English screenshot for the README (current `docs/screenshot.png` shows the Korean UI); consider one screenshot per language.
- [ ] Unit tests for `UsageStore` selection logic (first launch detection, 0.1.x upgrade keeps Claude + Grok, new plugins auto-enable once, last provider can't be disabled). It lives in the executable target; move the pure parts to `AtusCore` or add a test target that can import the app.
- [ ] Grok fallback: the `grok agent stdio` path has not yet been observed refreshing an expired token end to end; confirm once the Grok token expires naturally.
- [ ] Cursor: support the `cursor-safe-storage:v1:` encrypted token (Cursor ≥ 3.27) via the `Cursor Safe Storage` keychain item; today it reports an error.
- [ ] Plugins: when a plugin's shell is killed on timeout, child processes it started (e.g. a hung `curl`) can keep the pipe open; start the command in its own process group and kill the group.
- [ ] Gemini: decide on a ToS-safe source (official API key usage, or the Gemini app usage page via the user's own browser session) and ship it as an example plugin if it's safe.
- [ ] Automatic updates (e.g. Sparkle), or at least an "update available" line in the panel based on the latest GitHub release.

## Done

- 0.4.0: English and Korean UI, following the system language
- 0.3.0: command plugins (`~/.config/atus/providers.json`)
- 0.2.0: Codex, Cursor, GitHub Copilot; per-service picker
- 0.1.x: Claude and Grok, logos, notch-friendly label, notarized DMG releases
