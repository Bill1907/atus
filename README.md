# atus

A macOS menu bar app that shows how much of your **Claude** and **Grok** subscription limits you have used.

The menu bar shows two stacked rows, each with the provider's logo and a percentage (Claude 46%, Grok 21%). Click it for the details: Claude's 5-hour session and weekly windows, Grok's weekly pool, per-product breakdowns, extra-usage credits, and a countdown to each reset.

> The UI is currently in Korean.

## What it shows

| Provider | Source of truth | Shown |
|---|---|---|
| Claude (Pro / Max) | Claude Code login | 5-hour session %, weekly %, per-model weekly % (if your plan has them), weekly usage by product, extra-usage spend |
| Grok (SuperGrok / X Premium) | Grok CLI login | weekly pool %, usage by product, extra-usage credit balance, plan name (product split and plan name depend on which Grok source answered; see [How it works](#how-it-works)) |

The label is two short stacked rows, so it fits next to the notch on crowded MacBook menu bars. On first launch atus places itself at the right end of the menu bar items. After that it stays wherever you ⌘-drag it, or wherever Ice or Bartender puts it.

The menu bar number is the window closest to its limit, since that is the one that stops you first. A `!` after a number means the last refresh failed and the value shown is the last good one. Open the panel to see why.

## Requirements

- macOS 14 or later (Apple silicon or Intel)
- For Claude: [Claude Code](https://code.claude.com) logged in with a Pro or Max plan (`claude`, then `/login`)
- For Grok: the [Grok CLI](https://x.ai/cli) logged in (`grok login`)

You only need the CLIs for the providers you use. A provider without a login shows a hint in the panel.

## Install

1. Download **[Atus.dmg](https://github.com/Bill1907/atus/releases/latest/download/Atus.dmg)** from the latest release.
2. Open it and drag **Atus** into **Applications**.
3. Open Atus from Applications. It lives in the **menu bar**; there is no Dock icon.
4. Optional: in the panel, turn on **로그인 시 자동 실행** (launch at login).

Releases are signed with a Developer ID and notarized by Apple, so the app opens without Gatekeeper warnings.

### Update

atus does not update itself. Download the latest `Atus.dmg` and replace the app in Applications. Your settings and menu bar position are kept.

### Uninstall

1. In the panel, turn off **로그인 시 자동 실행** if you turned it on, then click **종료** (quit).
2. Delete `/Applications/Atus.app`.
3. Optional: remove its preferences with `defaults delete com.boseongkim.atus`.

atus stores nothing else. It never writes to the Claude Code or Grok CLI login files.

### Build from source

Requires Xcode 26 or later (CI builds with Xcode 26.6).

```sh
git clone https://github.com/Bill1907/atus.git
cd atus
./scripts/bundle.sh --install   # builds, copies to /Applications, launches
```

## How it works

atus refreshes every 5 minutes, after the Mac wakes, when you open the panel (if the data is more than a minute old), and on ⌘R while the panel is open.

- **Claude** reads the OAuth token Claude Code keeps in the login keychain (`Claude Code-credentials`) through `/usr/bin/security`, then calls `GET https://api.anthropic.com/api/oauth/usage`, the endpoint behind Claude Code's `/usage`.
- **Grok** reads the token in `~/.grok/auth.json` and calls `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`, the endpoint behind Grok CLI's `/usage`. This response includes the per-product split but not the plan name. The token lasts about six hours. Once it expires, atus asks `grok agent stdio` for `_x.ai/billing` instead, and the Grok CLI handles its own login. That response includes the plan name but no per-product split.

Privacy and safety:

- atus only reads tokens. It never refreshes, rewrites, or copies them anywhere.
- Requests go straight from your Mac to Anthropic and xAI. There is no atus server and no telemetry.
- Both endpoints are undocumented internal APIs and can change without notice. If one breaks, the app keeps the last value and shows the error.

## Troubleshooting

The panel shows the error under the provider's name; the menu bar adds `!` to that number.

| Panel message | Fix |
|---|---|
| Claude `토큰 만료: Claude Code를 한 번 실행하면 갱신돼요` (token expired) | Run `claude` once; Claude Code refreshes its token. |
| Claude `로그인 정보 없음: Claude Code에 로그인하세요` (no login) | Install Claude Code and log in with `/login`. |
| Grok `로그인 정보 없음: grok login을 실행하세요` (no login) | Run `grok login`. |
| Grok `로그인 정보 없음: grok CLI를 찾을 수 없어요` (CLI not found) | The token has expired and atus can't find the Grok CLI. Install it; atus looks in `~/.grok/bin`, `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`. |
| `HTTP 4xx/5xx` or `응답 해석 실패` (could not parse response) | The vendor endpoint changed or is down. Please [open an issue](https://github.com/Bill1907/atus/issues). |

atus is in the menu bar but you can't see it? On a MacBook with a notch, macOS hides the leftmost items when the menu bar is full. ⌘-drag atus further right, or move it to the visible section in Ice or Bartender.

## Development

```sh
swift test                      # parsing tests
swift run Atus                  # run without bundling
./scripts/bundle.sh --open      # build build/Atus.app and launch it
swift scripts/make-icon.swift   # regenerate Resources/AppIcon.icns
```

Layout:

- `Sources/AtusCore`: providers and response parsing; no UI code
- `Sources/Atus`: AppKit status item with a SwiftUI panel (`main.swift`, `StatusItemController.swift`, `UsagePanel.swift`)
- `scripts/`: bundling, icon, DMG, and release scripts

## Releasing

One-time setup on the maintainer's Mac:

1. A **Developer ID Application** certificate and its private key, exported as a `.p12`. Only the team's Account Holder can create the certificate.
2. An **App Store Connect API key** (`.p8`) for notarization: App Store Connect → Users and Access → Integrations → Team Keys.
3. `cp release.env.example release.env` and point it at those files. `release.env` is git-ignored.
4. Log in to the `gh` CLI with push access to this repo.

Then, from a clean `main`:

```sh
./scripts/release.sh 0.1.0
```

This runs the tests and imports the `.p12` into a throwaway keychain, so the login keychain is never touched. It then builds a universal app, signs it with the hardened runtime, and notarizes and staples both the app and `Atus.dmg`. Finally it tags `v0.1.0` and uploads the DMG to a GitHub release. The README download link always points at the latest release.

## License

[MIT](LICENSE)

Claude is a trademark of Anthropic, and Grok is a trademark of xAI. Their logos are used only to label each service's numbers. Logo artwork comes from [Simple Icons](https://simpleicons.org) (CC0) for Claude and [LobeHub Icons](https://github.com/lobehub/lobe-icons) (MIT) for Grok; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). atus is not affiliated with either company.
