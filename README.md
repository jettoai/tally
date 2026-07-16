<h1 align="center">Tally</h1>

<p align="center">Every AI subscription you own, at a glance, in your macOS menu bar —<br>and a CLI that always launches on the account with the most headroom left.</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?style=flat-square&logo=apple&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-Native-f97316?style=flat-square&logo=swift&logoColor=white">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-0ea5e9?style=flat-square">
</p>

<p align="center"><b>English</b> · <a href="README.zh-TW.md">繁體中文</a></p>

Built for people who run **multiple Claude (Max/Pro) and Codex subscriptions** and are tired of
guessing which account still has room: Tally shows every account's 5-hour session, weekly, and
top-model windows side by side, and `tally claude` starts your next session on the best account —
switching accounts mid-conversation automatically when you hit a cap.

<!-- TODO: screenshot (menu bar strip + pinned panel) -->

## Features

- **Multi-account first.** Every `~/.claude*` login and Codex install is its own card — N accounts
  side by side, not a single-account fallback chain. Drag cards to reorder; the order applies
  everywhere.
- **Menu bar strip.** Per-account brand marks with stacked session/weekly percentages; same-provider
  accounts get a tiny index badge; hover for every account's full numbers.
- **Pinnable glass panel.** Pin the dashboard as an always-on-top frosted-glass panel; drag the
  header to place it anywhere.
- **Reset times everywhere.** Every window shows its own reset; click any reset label to flip all of
  them between countdown ("resets in 2d 4h") and exact time ("resets at 07/18 20:00").
- **`tally` CLI.**
  - `tally claude [args…]` — launch Claude Code on the account with the most proven headroom; all
    arguments pass through untouched.
  - **Auto-handoff**: hit a usage cap mid-session and tally terminates cleanly, re-picks the best
    account, and resumes the *same conversation* there — with a 3-per-10-minutes fuse, and opt-out
    via `--no-handoff` or `TALLY_AUTO_HANDOFF=0`.
  - `tally resume` — the manual one-liner version of the same handoff.
  - `tally claude --account <name>` — pin a specific account when you want to choose.
  - `tally status` / `tally best-dir <provider>` — inspect from any script or shell.
- **5 languages.** English, 繁體中文, 简体中文, 日本語, 한국어 — switchable in-app, live.
- **Native and dependency-free.** Swift 6 + SwiftUI + AppKit. No Electron, no packages, one binary
  each for the app and the CLI.

## How it works (and what it never does)

- **Read-only by design.** Tally reads the OAuth credentials your CLIs already store locally and
  calls the same usage endpoints the official CLIs poll — with an honest `Tally` User-Agent.
  It never writes, refreshes, or rotates a token, so it can never break your CLI logins.
- **One poller, ever.** Only the menu-bar app talks to the network (every 5 minutes by default).
  The CLI reads a local snapshot (`~/.tally/snapshot.json` — percentages and paths, never tokens),
  so opening ten terminals costs zero extra API calls.
- **Your own accounts only.** Multi-account means *your* paid subscriptions on *your* machine.
  Tally does not proxy, pool, share, or resell access, and account switching just launches the
  official CLI with the config directory you already own.
- **Local only.** No telemetry, no server, nothing leaves your machine except the provider usage
  reads themselves.

## Requirements

- macOS 14+
- [Claude Code](https://claude.com/claude-code) signed in — additional accounts are plain extra
  config dirs (`CLAUDE_CONFIG_DIR=~/.claude2 claude` and log in), and/or
- Codex CLI signed in (`~/.codex`)

## Install

Releases (signed, auto-updating) are coming. For now, build from source:

```sh
brew install xcodegen   # once
git clone https://github.com/jettoai/tally && cd tally
xcodegen generate
xcodebuild build -project Tally.xcodeproj -scheme Tally -configuration Release -destination 'platform=macOS'
xcodebuild build -project Tally.xcodeproj -scheme TallyCLI -configuration Release -destination 'platform=macOS'
```

Then move `Tally.app` from DerivedData to `/Applications`, and put the `tally` binary on your PATH:

```sh
ln -s <build-products>/tally /usr/local/bin/tally
```

Optional shell sugar:

```sh
alias c='tally claude'
alias cc='tally claude --continue'
```

## FAQ

**Why does macOS never ask me for keychain permission?**
Tally reads credential items through Apple's own `security` tool (the pattern proven by
[OpenUsage](https://github.com/robinebers/openusage)), which macOS trusts without re-prompting on
every app update.

**What happens when every account is capped?**
Nothing dramatic: the dashboard shows it, `tally claude` warns and launches the bare CLI, and
auto-handoff stays put rather than looping.

**Does auto-handoff lose my conversation?**
No — it resumes the same session transcript on the next account (additively; your original
transcript is never modified). An interrupted tool call may re-run once after the switch.

## License

[MIT](LICENSE) © jetto · Patterns and concepts adapted from
[OpenUsage](https://github.com/robinebers/openusage) and
[headroom](https://github.com/domanski-ai/headroom) — see
[THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES.md).
