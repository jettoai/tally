#!/bin/bash
# Compiles the CLI's worktree logic (TallyCLI/Worktree.swift) together with a small assertion
# harness and runs it. Worktree.swift depends only on Snapshot.swift, so no Xcode target is needed;
# ReloadRequest.swift joins the source list only for `scannedPidCount`, which the teardown's process
# scan shares, and WorktreeActivity.swift brings TranscriptWatcher.swift plus the files that one
# needs to compile, because the teardown's busy gate calls the supervisor's own quiet test rather
# than a copy of it. Exits non-zero on failure. Uses real git and a temp filesystem for the
# create/link scenarios (see the five groups in docs/specs/changes/worktree-launch/design.md).
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" \
  tests/worktree/main.swift \
  tests/worktree/teardownchecks.swift \
  tests/worktree/treechecks.swift \
  tests/worktree/killchecks.swift \
  TallyCLI/Worktree.swift \
  TallyCLI/WorktreeTeardown.swift \
  TallyCLI/WorktreeKill.swift \
  TallyCLI/WorktreeTree.swift \
  TallyCLI/WorktreeActivity.swift \
  TallyCLI/TranscriptWatcher.swift \
  TallyCLI/DriftMonitor.swift \
  TallyCLI/SafeguardDrift.swift \
  TallyCLI/KeyboardIdle.swift \
  TallyCLI/OpenTurn.swift \
  TallyCLI/SupervisorRuntime.swift \
  TallyCLI/WorktreeMenu.swift \
  TallyCLI/Snapshot.swift \
  TallyCLI/ProviderExecutable.swift \
  TallyCLI/AccountComfort.swift \
  TallyCLI/ReloadRequest.swift \
  TallyCLI/PendingNotice.swift
"$out"
