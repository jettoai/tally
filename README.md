<p align="center">
  <a href="https://github.com/jettoai/tally/releases/latest"><img src="assets/app-icon.svg" height="140" alt="Tally app icon"></a>
</p>
<h1 align="center">Tally</h1>
<p align="center"><sub>by <a href="https://jetto.ai">Jetto</a></sub></p>

<p align="center">Every AI subscription you own, at a glance, in your macOS menu bar,<br>plus a launcher that puts every session on the account whose quota goes furthest.</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?style=flat-square&logo=apple&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-Native-f97316?style=flat-square&logo=swift&logoColor=white">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-0ea5e9?style=flat-square">
  <a href="https://github.com/jettoai/tally/releases/latest"><img alt="Download" src="https://img.shields.io/github/v/release/jettoai/tally?style=flat-square&label=download&color=22c55e"></a>
</p>

<p align="center"><a href="https://github.com/jettoai/tally/releases/latest/download/Tally.dmg"><b>⬇ Download for macOS 14+</b></a></p>

<p align="center"><b>English</b> · <a href="README.zh-TW.md">繁體中文</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a></p>

Tally is a native **macOS menu bar AI usage monitor for Claude and Codex rate limits**, built for
people who run **multiple Claude (Max/Pro) and Codex subscriptions** and are tired of guessing
which account still has room: every account's 5-hour session, weekly, and top-model quota windows
sit side by side under a fleet gauge that pools them into one combined budget and forecasts how
long it lasts at your measured pace, and the Smart pick starts every new session on the account
whose quota goes furthest right now, weighing reset times, not just remaining percent, then follows through
mid-conversation: rate-limit handoff, flagship-model rescue, and a status-line signal that shows
which account is burning.

<p align="center">
  <img src="assets/screenshot-menubar.png" alt="Tally's menu bar strip: five Claude accounts with index badges and stacked session/weekly percentages, followed by three Codex accounts" width="418">
</p>

<p align="center">
  <img src="assets/screenshot-panel.png" alt="Tally's pinned panel: per-provider fleet gauges pool nine accounts (five Claude Max, four Codex) into one weekly-budget bar each, with a pace forecast (lasts about 4d 10h; sustainable at this pace) and the next staggered refill; below, every account's own card shows its 5-hour session, weekly, and top-model windows with reset times, near-limit warnings, and purple Smart badges on the launcher's current picks" width="834">
</p>

## Why Tally

Menu bar usage meters already exist; what did not exist is one built for people who own several
subscriptions at once:

- **Per-account cards, not a fallback chain.** Every account renders as its own card, side by
  side, because "which account still has room" is exactly the question a multi-subscription user
  is asking.
- **Subscription quota, not spend estimates.** Tally shows the same 5-hour / weekly / top-model
  windows the vendors themselves enforce, instead of estimating dollars from token counts.
- **A launcher that acts on the answer.** A dashboard's whole point is deciding where to work
  next, so Tally makes that decision for you, every time, automatically, and keeps making it
  while the session runs (cap handoff, model-degradation rescue).

## Features

### The dashboard

- **Multi-account first.** Every `~/.claude*` login and Codex install is its own card: N accounts
  side by side, not a single-account fallback chain. Drag cards to reorder; the order applies
  everywhere.
- **The fleet gauge.** Each provider's accounts pooled into ONE meter: a continuous bar for the
  combined weekly budget, the total in accounts' worth ("2.9/5 left"), and the next staggered
  refill. A forecast estimates how long the pool lasts at your recently measured pace, counting
  the quota each reset brings back: "lasts about 4d 10h" when you are outspending the refill
  cycle, "sustainable at this pace" when you are not. No other usage meter pools accounts at all.
- **Menu bar strip.** Per-account brand marks with stacked session/weekly percentages; same-provider
  accounts get a tiny index badge; hover for every account's full numbers.
- **Pinnable glass panel.** Pin the dashboard as an always-on-top frosted-glass panel; drag the
  header to place it anywhere, and spread many accounts across 2, 3 or 4 columns.
- **Reset times everywhere.** Every window shows its own reset; click any reset label to flip all of
  them between countdown ("resets in 2d 4h") and exact time ("resets at 07/18 20:00").
- **Codex reset banking, visible and redeemable.** Banked rate-limit resets show right on the
  card ("3 resets available"), so you know your escape hatches before you hit a wall. Click to
  redeem one, behind a confirmation that names the account, spells out the cost, and warns you
  off when redeeming would mostly be wasted; the soonest-expiring credit goes first, and Tally
  never spends one automatically.

### The launch control plane

- **Smart pick.** New sessions start on the account whose binding quota window sustains the highest
  spend rate: remaining percent divided by time to reset, across the 5-hour, weekly, and top-model
  windows. Quota about to reset gets burned first (it would evaporate unused); quota that must last
  days is preserved; hysteresis keeps noise-level differences from bouncing you between accounts.
  The panel badge marks the current pick, with the reason in its tooltip.
- **Three modes per provider.** Smart (the algorithm decides at every launch), Manual (the circle
  on a card pins that account; clicking the check releases it back to Smart, live, even for the
  running session), or Off (a dashboard and nothing more).
- **Mid-session follow-through.** Hit a usage cap and tally resumes the *same conversation* on the
  next-best account (3-per-10-minutes fuse; opt out with `--no-handoff` or `TALLY_AUTO_HANDOFF=0`).
  If the server silently downgrades your model, a sibling account that can still serve your primary
  model takes the conversation over instead, and only when nobody can does your configured
  fallback pairing apply. Non-urgent switches wait for a quiet moment between turns.
- **Launch defaults, in Settings.** Default permission mode, start mode (continue vs new), model
  and reasoning effort as one pairing, and a separate fallback pairing (fallback model + its own
  effort + extra flags). Injected only when you didn't type the flag yourself: your own arguments
  always win.
- **Shell integration.** One click installs PATH shims so even bare `claude` / `codex` commands
  follow your launch policy; one click removes them just as cleanly.
- **Status line integration.** Your Claude Code status line gains a purple ✦ Tally signal (this
  session runs under Tally) and the active account name; opt in to the full quota line and it
  carries the whole story in the app's own palette: meter bars, percents and reset countdowns
  for the model tier this session is actually consuming, the 5-hour window, and the weekly
  budget (the pooled fleet budget when the fleet gauge is on), following the panel's used/left
  toggle. An existing custom status line keeps running untouched with Tally's line appended,
  is restored byte-for-byte on removal, and keeps working even if you delete Tally without
  uninstalling.
- **`tally` CLI.** `tally claude [args…]`, `tally resume` (move this directory's latest
  conversation to another account), `tally claude --account <name>`, `tally status`,
  `tally best-dir <provider>`, all script-friendly.

### The chrome

- **5 languages.** English, 繁體中文, 简体中文, 日本語, 한국어, switchable in-app, live.
- **Native and dependency-free.** Swift 6 + SwiftUI + AppKit. No Electron, no packages, one binary
  each for the app and the CLI.

## How it works (and what it never does)

- **Zero credential access.** Tally never touches a token, a Keychain secret, or a vendor
  endpoint. Usage is read through the providers' **own official CLIs** (`claude -p "/usage"` and
  `codex app-server`), which talk to their vendors with their own first-party identity and manage
  their own credentials. Account discovery only checks that a login *exists* (an attribute probe);
  nothing is ever read out.
- **One poller, ever.** Only the menu-bar app runs the CLIs (every 5 minutes by default,
  configurable down to 1). The `tally` launcher reads a local snapshot
  (`~/.tally/snapshot.json`: percentages and paths, never tokens), so opening ten terminals
  costs zero extra reads.
- **Your own accounts only.** Multi-account means *your* paid subscriptions on *your* machine.
  Tally does not proxy, pool, share, or resell access, and account switching just launches the
  official CLI with the config directory you already own.
- **Local only.** No telemetry, no server, nothing leaves your machine except the provider usage
  reads themselves.

## Requirements

- macOS 14+
- [Claude Code](https://claude.com/claude-code) signed in; additional accounts are plain extra
  config dirs (`CLAUDE_CONFIG_DIR=~/.claude2 claude` and log in), and/or
- Codex CLI signed in (`~/.codex`)

## Install

Download the latest notarized DMG from [Releases](https://github.com/jettoai/tally/releases/latest),
drag **Tally.app** into Applications, and launch it. Updates arrive automatically in-app.

To use the `tally` CLI, link the copy bundled inside the app onto your PATH:

```sh
ln -s /Applications/Tally.app/Contents/Helpers/tally /usr/local/bin/tally
```

<details>
<summary>Build from source instead</summary>

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

</details>

Or skip the symlink and the aliases entirely: **Settings → Integrations** installs the CLI tool,
the shell shims (bare `claude` / `codex` follow your policy), and the status line signal, each
with one click and a clean removal.

Optional shell sugar:

```sh
alias c='tally claude'
alias cc='tally claude --continue'
```

## Localization

Tally ships in English, 繁體中文, 简体中文, 日本語, and 한국어, switchable live from Settings
with no relaunch. Every string lives in one Xcode String Catalog
([`Tally/Resources/Localizable.xcstrings`](Tally/Resources/Localizable.xcstrings)), so adding a
language is a single-file PR that fills in one more column. The bar is "reads like the OS, not
like a translation"; corrections to existing languages are as welcome as new ones.

## Contributing

Issues and pull requests are welcome. To get building, follow "Build from source" above; two
conventions keep the project healthy:

- `project.yml` is the single source of truth; `Tally.xcodeproj` is generated by XcodeGen and
  never edited by hand.
- New user-facing strings go through the `L("…")` helper and the String Catalog, with all five
  languages filled in.

Keep each PR to one intent, and put the why in the description.

## FAQ

**How is Tally different from ccusage or other usage trackers?**
Tools like [ccusage](https://github.com/ryoppippi/ccusage) are terminal CLIs that estimate token
spend from local logs, and most menu bar meters watch a single account. Tally is a native GUI
that shows the quota windows the vendors actually enforce (5-hour, weekly, top-model), across
multiple Claude and Codex accounts at once, and adds a launcher that acts on those numbers.
Read-only, on your own paid subscriptions.

**Why does macOS never ask me for keychain permission?**
Because Tally never reads a credential: usage comes through the providers' own CLIs, and account
discovery is an attribute-only Keychain probe (no secret returned → no consent prompt).

**What happens when every account is capped?**
Nothing dramatic: the dashboard shows it, `tally claude` warns and launches the bare CLI, and
auto-handoff stays put rather than looping.

**Does auto-handoff lose my conversation?**
No: it resumes the same session transcript on the next account (additively; your original
transcript is never modified). An interrupted tool call may re-run once after the switch.

**Will the status line integration break my custom status line?**
No. Your own command keeps running exactly as before, fed the same session JSON; Tally only
appends its signal, skips the account name if you already show one, restores your original
registration byte-for-byte on removal, and falls back to running your command directly if the
tally binary ever disappears.

## License

[MIT](LICENSE) © [jetto](https://jetto.ai)
