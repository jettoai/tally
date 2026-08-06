#!/bin/bash
# Compiles the supervisor's transcript watcher (model tracking guards) with a small assertion
# harness and runs it. No Xcode test target needed; exits non-zero on failure.
#
# ProjectPolicy.swift is in the list because a tick lays this project's launch profile over the
# app policy it re-reads (TallyCLI/ProjectPolicy.swift); GitRepoRoot.swift is the repo identity
# that profile is keyed by, and StatusReport/UsageAdvisor come along because the profile also
# publishes itself into `tally status --json`.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/supervisor/main.swift tests/supervisor/reloadchecks.swift \
  tests/supervisor/capgatechecks.swift tests/supervisor/capresetchecks.swift \
  tests/supervisor/forkchecks.swift tests/supervisor/dispatchlayoutchecks.swift \
  tests/supervisor/keyboardchecks.swift tests/supervisor/openturnchecks.swift \
  tests/supervisor/terminaldrainchecks.swift \
  tests/supervisor/shimchecks.swift tests/supervisor/selfupdatefoldchecks.swift \
  tests/supervisor/rebalancechecks.swift tests/supervisor/rebalanceclaimchecks.swift \
  tests/supervisor/reloadrepickchecks.swift tests/supervisor/relaunchchecks.swift \
  tests/supervisor/safeguardchecks.swift \
  tests/supervisor/followchecks.swift tests/supervisor/pendingnoticechecks.swift \
  tests/supervisor/contextchecks.swift tests/supervisor/resumepromptchecks.swift \
  tests/supervisor/standdownchecks.swift tests/supervisor/switchchecks.swift \
  TallyCLI/Supervisor.swift TallyCLI/SupervisorRuntime.swift TallyCLI/LaunchFlags.swift TallyCLI/Quarantine.swift TallyCLI/DriftMonitor.swift \
  TallyCLI/TranscriptWatcher.swift TallyCLI/TranscriptFork.swift TallyCLI/Snapshot.swift TallyCLI/AccountPick.swift TallyCLI/Reload.swift \
  TallyCLI/ReloadRequest.swift TallyCLI/SelfUpdate.swift TallyCLI/AccountComfort.swift \
  TallyCLI/Rebalance.swift TallyCLI/SafeguardDrift.swift TallyCLI/ModelDegradation.swift \
  TallyCLI/KeyboardIdle.swift TallyCLI/OpenTurn.swift TallyCLI/ProviderExecutable.swift \
  TallyCLI/TerminalHandover.swift \
  TallyCLI/PendingNotice.swift TallyCLI/FollowAdoption.swift TallyCLI/StandDown.swift \
  TallyCLI/SessionContext.swift TallyCLI/ResumePrompt.swift TallyCLI/SessionSwitch.swift TallyCLI/SwitchRequest.swift \
  TallyCLI/ProjectPolicy.swift TallyCLI/GitRepoRoot.swift \
  TallyCLI/StatusReport.swift TallyCLI/UsageAdvisor.swift
"$out"
