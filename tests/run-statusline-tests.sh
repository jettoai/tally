#!/bin/bash
# Compiles the status line's own formats (TallyCLI/Statusline.swift) with a small assertion harness
# and runs it. No Xcode test target needed; exits non-zero on failure.
#
# The source list is that file's transitive closure: the snapshot it reads, the account pick and
# comfort gate the snapshot types drag in, and the per-supervisor state the line renders (the drift
# badge, the pending notice, the session context, and the registry they all live in).
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/statusline/main.swift \
  TallyCLI/Statusline.swift TallyCLI/Snapshot.swift TallyCLI/AccountPick.swift \
  TallyCLI/AccountComfort.swift TallyCLI/SupervisorRuntime.swift TallyCLI/RelaunchPlan.swift TallyCLI/ReloadRequest.swift \
  TallyCLI/DriftMonitor.swift TallyCLI/PendingNotice.swift TallyCLI/SessionContext.swift \
  TallyCLI/SessionSwitch.swift TallyCLI/ManualMoveState.swift TallyCLI/SwitchDecision.swift TallyCLI/SwitchRequest.swift TallyCLI/AccountHome.swift TallyCLI/GitRepoRoot.swift TallyCLI/Reload.swift \
  TallyCLI/LaunchFlags.swift TallyCLI/ProviderExecutable.swift TallyCLI/ResumePrompt.swift \
  TallyCLI/TranscriptWatcher.swift TallyCLI/TranscriptFork.swift TallyCLI/OpenTurn.swift \
  TallyCLI/KeyboardIdle.swift TallyCLI/Quarantine.swift TallyCLI/SafeguardDrift.swift
"$out"
