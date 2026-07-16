# Third-Party Notices

Tally contains no vendored third-party source code and has zero package dependencies. Several
techniques and patterns were, however, adapted from open-source projects we studied — credited here
both because their licenses ask for it where code was adapted, and because they earned it.

## OpenUsage — MIT License, Copyright (c) 2026 Robin Ebers

<https://github.com/robinebers/openusage>

Patterns adapted (reimplemented in Tally's own Swift, closely modeled on theirs):

- **In-view drag-to-reorder** (`Tally/Views/CardReorder.swift`): plain `DragGesture` + frame
  preferences + floating lift preview instead of the pasteboard-backed `.draggable` APIs, including
  the crossing-threshold feel and trackpad-haptic discipline. OpenUsage's reorder index math in turn
  credits **crafcat7/Peakmon** (Apache-2.0).
- **Keychain reads via `/usr/bin/security`** (`Tally/Core/Keychain/KeychainReader.swift`): reading
  another app's credential item through the Apple-signed `security` tool so macOS never re-prompts.
- **Behind-window glass with a rounded mask** (`Tally/MenuBar/PinnedPanelController.swift`):
  `NSVisualEffectView` + stretchable rounded `maskImage` for the pinned panel's translucent base.

## headroom — MIT License, Copyright (c) 2026 Paul Domanski

<https://github.com/domanski-ai/headroom>

Concepts adapted (no code ported; Tally's implementation is independent Swift):

- **Config-home launching** (`tally claude` → `CLAUDE_CONFIG_DIR`/`CODEX_HOME` + exec), including
  the Keychain-namespacing gotcha that the DEFAULT home must launch with the variable unset.
- **Proven-headroom account selection** (only fresh, identity-bound readings are eligible) and the
  **auto-handoff architecture** (resident supervisor → clean terminate → additive transcript copy →
  fork-resume on the next account → rolling-window loop guard).

Where Tally deliberately differs: the app is the single usage poller (the CLI reads a published
snapshot and never calls a provider API), launching fails open instead of closed, and cap-hit
detection tails the session transcript rather than installing hooks.
