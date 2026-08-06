#!/bin/bash
# Compiles the CLI's worktree logic (TallyCLI/Worktree.swift) together with a small assertion
# harness and runs it. Worktree.swift depends only on Snapshot.swift and GitRepoRoot.swift (the repo
# identity it shares with the per-project launch profile), so no Xcode target is needed. The rest of
# the source list is what those two drag in: ReloadRequest.swift for `scannedPidCount`, which the
# teardown's process scan shares; ResumePrompt.swift for the child environment SupervisorRuntime
# assembles; SessionSwitch.swift for the documents that share PendingNotice's state-directory
# suffix list, and Reload.swift for the idle gate that switch borrows; and WorktreeActivity.swift
# for TranscriptWatcher.swift plus the files that one needs to compile, because the teardown's busy
# gate calls the supervisor's own quiet test rather than a copy of it.
# Exits non-zero on failure. Uses real git and a temp filesystem for the create/link scenarios
# (see the five groups in docs/specs/changes/worktree-launch/design.md).
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" \
  tests/worktree/main.swift \
  tests/worktree/teardownchecks.swift \
  tests/worktree/teardownpurechecks.swift \
  tests/worktree/treechecks.swift \
  tests/worktree/killchecks.swift \
  tests/worktree/originschecks.swift \
  TallyCLI/Worktree.swift \
  TallyCLI/GitRepoRoot.swift \
  TallyCLI/WorktreeTeardown.swift \
  TallyCLI/WorktreeKill.swift \
  TallyCLI/WorktreeProcessScan.swift \
  Tally/Core/WorktreeOrigins.swift \
  TallyCLI/WorktreeTree.swift \
  TallyCLI/WorktreeActivity.swift \
  TallyCLI/TranscriptWatcher.swift \
  TallyCLI/TranscriptFork.swift \
  TallyCLI/DriftMonitor.swift \
  TallyCLI/SafeguardDrift.swift \
  TallyCLI/KeyboardIdle.swift \
  TallyCLI/OpenTurn.swift \
  TallyCLI/SupervisorRuntime.swift \
  TallyCLI/ResumePrompt.swift \
  TallyCLI/LaunchFlags.swift \
  TallyCLI/WorktreeMenu.swift \
  TallyCLI/Snapshot.swift \
  TallyCLI/AccountPick.swift \
  TallyCLI/ProviderExecutable.swift \
  TallyCLI/AccountComfort.swift \
  TallyCLI/ReloadRequest.swift \
  TallyCLI/PendingNotice.swift \
  TallyCLI/SessionContext.swift \
  TallyCLI/SessionSwitch.swift TallyCLI/SwitchRequest.swift \
  TallyCLI/Reload.swift
"$out"
