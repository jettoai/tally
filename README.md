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
  <img src="assets/screenshot-menubar.png" alt="Tally's menu bar strip: five Claude accounts with index badges and stacked session/Fable percentages, followed by four Codex accounts with session/weekly" width="445">
</p>

<p align="center">
  <img src="assets/screenshot-panel.png" alt="Tally's panel: per-provider fleet gauges pool nine accounts (five Claude Max, four Codex), Claude showing both its runways at once, a Fable pool bar and a weekly pool bar, each with a pace forecast (lasts about 4d 12h) and the next staggered refill, Codex a weekly pool that is sustainable at this pace; an advisor row of account pips shows each provider's running weekly demand, pooled for Claude's single plan (5.8 acct/wk) and split per plan for Codex (Pro 1.7 · Team 0.9), marking when the pace calls for one more account; below, every account's frosted-glass card shows its 5-hour session, weekly, and top-model windows with reset times, near-limit warnings, and purple Smart badges on the launcher's current picks; the header carries a Usage / Tokens switch" width="834">
</p>

<p align="center">
  <img src="assets/screenshot-tokens.png" alt="Tally's Tokens tab: total tokens over the selected range (today / 7 days / 30 days / all time) with the input, cache write, cache read and output breakdown, a per-provider split between Claude and Codex, and a per-project table with share bars showing where the tokens went" width="834">
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
- **The usage advisor.** Do you need another account? One line per provider under the gauges: a
  filled pip per account you own, a hollow one when your measured pace asks for another, and the
  running weekly demand as the figure to read ("5.8 acct/wk"). A fleet on two plans reads per tier
  ("Pro 1.7 · Team 0.9"), because one account-week of a $200 seat and of a $20 seat are not the same
  quantity, and pooling them produces a number no subscription can be bought against. The hover
  carries the breakdown per tier, the active burn rate, the starved hours, and the next refills;
  `tally status --json` publishes the same split as `tierDemands`.
- **Menu bar strip.** Per-account brand marks with stacked session/weekly percentages; same-provider
  accounts get a tiny index badge; hover for every account's full numbers.
- **Pinnable glass panel.** Pin the dashboard as an always-on-top frosted-glass panel; drag the
  header to place it anywhere. The account cards themselves render as glass over the panel's
  backdrop (solid whenever you turn the translucency off, or the system asks for reduced
  transparency).
- **Cards, or one row per account.** Past half a dozen accounts a card grid outgrows the display,
  so the panel carries a second density: every account on a single line, identity on the left, each
  window as a small bar plus its figure, the launch controls shrunk to icons. It hides words, never
  facts, so the window names, the resets and what each control does move into hover callouts (Tally
  draws its own, on the panel's own glass, rather than waiting on the system tooltip). Each density
  remembers its own column count behind the one picker, and the list's Auto asks the screen how many
  rows fit side by side instead of counting the cards.
- **Your layout, one card at a time.** A view-options card in the footer sets the density and the
  column count with layout tiles (each tile drawing the layout it produces), switches the fleet
  gauge and the advisor on or off, folds providers behind their gauges, and can seat the cards in a
  section per provider; drag cards to reorder within it. A folded provider keeps its heading, which
  is how it comes back. A fleet too tall for the screen scrolls instead of falling off it.
- **Token usage, by project.** A Tokens view behind a header switch on every surface: total
  tokens over today / 7 days / 30 days / all time with the input, cache and output breakdown, a
  per-provider split, and a per-project table that traces even agent and workflow sessions back
  to the project they served. Read from the CLIs' own local transcripts, aggregated behind an
  incremental cache (a refresh with nothing new costs well under a second), and it never leaves
  your machine.
- **Reset times everywhere.** Every window shows its own reset; click any reset label to flip all of
  them between countdown ("resets in 2d 4h") and exact time ("resets at 07/18 20:00").
- **Logins that look after themselves.** Hover a card for the account's signed-in email; when a
  login expires, the card says so with a red chip, one notification, and a click that runs the
  provider's own sign-in quietly in the background, browser consent only (a visible Terminal is
  the fallback, and Tally never touches a credential either way).
- **Add an account without leaving the app.** Settings prepares the next account home, offers the
  shared-harness default (one setup serving every account) with a plain privacy note, and drives
  the same quiet sign-in; the new card appears when the browser hands back.
- **Codex reset banking, visible and redeemable.** Banked rate-limit resets show right on the
  card ("3 resets available"), so you know your escape hatches before you hit a wall. Click to
  redeem one, behind a confirmation that names the account, spells out the cost, and warns you
  off when redeeming would mostly be wasted; the soonest-expiring credit goes first, and Tally
  never spends one automatically.

<p align="center">
  <img src="assets/screenshot-list.png" alt="The same nine accounts in Tally's compact list density, two columns wide: one row per account carrying the provider mark, the account name and its plan, then every quota window as a small bar with its percentage, a warning triangle on the account whose login expired, a banked-reset count on the Codex rows that have one, the purple Smart mark on the launcher's current pick, and the pin and drag controls at the end of each row; above them the same fleet gauges and advisor line the card density shows, with Codex reading Pro 1.7 · Team 0.9" width="900">
</p>

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
- **Change the model once, every session follows.** Re-point the default model or effort and
  every running supervised session adopts it at its next quiet moment, resuming the same
  conversation; no walking terminals to type `/model` one by one. A model or effort you typed
  yourself is never touched, and `--no-follow` opts a session out.
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
- **Claude Code skill.** One click drops a small skill into every Claude account's skills
  folder, teaching agent sessions to answer quota questions and pick accounts from
  `tally status --json` (and to check the binding window before heavy multi-agent work);
  removed just as cleanly.
- **`tally` CLI.** `tally claude [args…]`, `tally resume` (move this directory's latest
  conversation to another account), `tally claude --account <name>`, `tally status`
  (add `--json` for a versioned machine-readable report: every account's windows, reset
  times, and which account a launch would land on right now, ready for your own scripts,
  hooks, and agent skills), `tally add <provider>` (log in one more account: next free
  number picked and the config directory created for you; the main account's harness,
  CLAUDE.md/AGENTS.md, skills, hooks, agents, settings, and conversation history, is
  symlinked in by default so one setup serves every account, opt out with `--no-share`),
  `tally best-dir <provider>`, all script-friendly.

### The chrome

- **5 languages.** English, 繁體中文, 简体中文, 日本語, 한국어, switchable in-app, live.
- **Native.** Swift 6 + SwiftUI + AppKit, no Electron. The single third-party dependency is
  [Sparkle](https://sparkle-project.org), the standard macOS update framework; one binary each
  for the app and the CLI.

## How it works (and what it never does)

- **Zero credential access.** Tally never touches a token, a Keychain secret, or a vendor
  endpoint. Usage is read through the providers' **own official CLIs** (`claude -p "/usage"` and
  `codex app-server`), which talk to their vendors with their own first-party identity and manage
  their own credentials. Account discovery only checks that a login *exists* (an attribute probe);
  nothing is ever read out.
- **Read-only, with one named exception.** `claude auth login` finishes the OAuth round trip and
  stops there, so a config home Tally created and signed in for you would still meet its first
  session with the first-run wizard: a theme picker, and a request to sign in to the account that
  just signed in. So after a login Tally itself drove (adding an account, or renewing one from a
  card), it merges Claude Code's own note that the wizard is done, `hasCompletedOnboarding`, into
  that one home's state file, and a home Tally creates is seeded with the folder-trust answers you
  already gave on an existing account. A merge, never a replacement; a file it cannot parse is
  refused rather than rewritten; a home that has been through the wizard is left byte for byte.
  Never a credential, and never a scan for other homes to repair.
- **One poller, ever.** Only the menu-bar app runs the CLIs (every minute by default,
  relaxable to 2/5/15). The `tally` launcher reads a local snapshot
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
multiple Claude and Codex accounts at once, and adds a launcher that acts on those numbers. The
Tokens view covers the "how much did I burn, and on what" question too, per project, straight
from the local transcripts, with no dollar guessing. Read-only, on your own paid subscriptions.

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

## Acknowledgments

Tally builds on a trail mapped by some excellent projects:

- [ccusage](https://github.com/ryoppippi/ccusage) pioneered turning Claude Code's local logs into
  usage insight, and showed how much developers want to see their numbers.
- [OpenUsage](https://github.com/robinebers/openusage) and
  [AIUsage](https://github.com/sylearn/AIUsage) proved the at-a-glance menu bar meter; Tally
  exists because we wanted that glance across many accounts at once.
- [Sparkle](https://sparkle-project.org) powers the in-app updates.

## License

[MIT](LICENSE) © [jetto](https://jetto.ai)
