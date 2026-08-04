#!/bin/bash
# Compiles the supervisor's transcript watcher (model tracking guards) with a small assertion
# harness and runs it. No Xcode test target needed; exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/supervisor/main.swift tests/supervisor/reloadchecks.swift \
  tests/supervisor/capgatechecks.swift tests/supervisor/capresetchecks.swift \
  tests/supervisor/forkchecks.swift tests/supervisor/dispatchlayoutchecks.swift \
  tests/supervisor/keyboardchecks.swift tests/supervisor/openturnchecks.swift \
  tests/supervisor/shimchecks.swift tests/supervisor/selfupdatefoldchecks.swift \
  tests/supervisor/rebalancechecks.swift tests/supervisor/rebalanceclaimchecks.swift \
  tests/supervisor/reloadrepickchecks.swift tests/supervisor/relaunchchecks.swift \
  tests/supervisor/safeguardchecks.swift \
  tests/supervisor/followchecks.swift tests/supervisor/pendingnoticechecks.swift \
  tests/supervisor/contextchecks.swift tests/supervisor/resumepromptchecks.swift \
  TallyCLI/Supervisor.swift TallyCLI/SupervisorRuntime.swift TallyCLI/LaunchFlags.swift TallyCLI/Quarantine.swift TallyCLI/DriftMonitor.swift \
  TallyCLI/TranscriptWatcher.swift TallyCLI/TranscriptFork.swift TallyCLI/Snapshot.swift TallyCLI/AccountPick.swift TallyCLI/Reload.swift \
  TallyCLI/ReloadRequest.swift TallyCLI/SelfUpdate.swift TallyCLI/AccountComfort.swift \
  TallyCLI/Rebalance.swift TallyCLI/SafeguardDrift.swift TallyCLI/ModelDegradation.swift \
  TallyCLI/KeyboardIdle.swift TallyCLI/OpenTurn.swift TallyCLI/ProviderExecutable.swift \
  TallyCLI/PendingNotice.swift TallyCLI/FollowAdoption.swift \
  TallyCLI/SessionContext.swift TallyCLI/ResumePrompt.swift
"$out"
