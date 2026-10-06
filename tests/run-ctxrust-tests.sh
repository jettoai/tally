#!/bin/bash
# The live transcript scan's Rust line reader (rust/, TallyCLI/TranscriptLineRust.swift) against
# the substring readers it replaces. Runs the Rust unit tests, builds the core with the test-only
# panic probe (its own target dir, so the shipped build never carries it), then compiles the
# watcher with the core linked and compares the two readers member by member and state by state.
# Count assertions with `command grep -c '^PASS:'`.
#
# The source list is the chromegap suite's closure of the watcher (run-chromegap-tests.sh).
#
# Speed gate G1 (not part of the suite): CTXRUST_BENCH=<file listing transcripts, one per line>.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=14.0
(cd rust && cargo test --quiet --locked --workspace)
(cd rust && cargo build --quiet --release --locked -p tally_ffi --features panic-probe \
  --target-dir target/ctxrust-probe)
lib=rust/target/ctxrust-probe/release
out=$(mktemp -d)/run
swiftc -O -I rust/include -L "$lib" -D TALLY_RUST_REQUIRED -o "$out" \
  tests/ctxrust/main.swift tests/ctxrust/dump.swift tests/ctxrust/bench.swift \
  TallyCLI/ChromePreflight.swift \
  TallyCLI/ChromeRun.swift \
  TallyCLI/ChromeRunStream.swift \
  TallyCLI/SwitchCommand.swift \
  TallyCLI/TranscriptLineBytes.swift \
  TallyCLI/QuotaKnock.swift \
  TallyCLI/CapResume.swift \
  TallyCLI/CapResumeLog.swift \
  TallyCLI/NativeModelCommand.swift \
  TallyCLI/QuotaKnockLogic.swift \
  TallyCLI/SelfSwitchResume.swift \
  TallyCLI/TranscriptWatcherScan.swift TallyCLI/RestartLiveWork.swift \
  TallyCLI/TranscriptLineView.swift \
  TallyCLI/TranscriptLineRust.swift \
  TallyCLI/ModelMenu.swift \
  TallyCLI/MCPAccountOffer.swift \
  TallyCLI/MCPPickOffer.swift \
  TallyCLI/ModelCommand.swift \
  TallyCLI/ModelHook.swift \
  TallyCLI/PickRows.swift \
  TallyCLI/TallyPrompt.swift \
  Tally/Core/PromptHookInput.swift \
  TallyCLI/MCPPicker.swift \
  TallyCLI/PromptHookBackstop.swift \
  TallyCLI/SwitchHook.swift \
  TallyCLI/WorktreeMenu.swift \
  TallyCLI/SwitchMenu.swift \
  Tally/Core/AccountReserve.swift \
  Tally/Core/ChromeSettingSignal.swift \
  Tally/Core/LaunchAxisNames.swift \
  Tally/Core/LimitReset.swift \
  Tally/Core/PickContract.swift \
  Tally/Core/SessionMonitoring.swift \
  Tally/Core/SessionPinScope.swift \
  TallyCLI/AccountBinding.swift \
  TallyCLI/AccountComfort.swift \
  TallyCLI/AccountHome.swift \
  TallyCLI/AccountPick.swift \
  TallyCLI/AccountReserveReader.swift \
  TallyCLI/AgentRoster.swift \
  TallyCLI/ChromeReach.swift \
  TallyCLI/CodexLaunchArgs.swift \
  TallyCLI/CodexSessionEvents.swift \
  TallyCLI/CodexSessionInput.swift \
  TallyCLI/DriftMonitor.swift \
  TallyCLI/FollowAdoption.swift \
  TallyCLI/GitRepoRoot.swift \
  TallyCLI/HookKnock.swift \
  TallyCLI/HostHealthKnockLogic.swift \
  Tally/Core/HostHealthLogic.swift \
  Tally/Core/KeystrokeText.swift \
  TallyCLI/KeyboardIdle.swift \
  TallyCLI/LaunchFlags.swift \
  TallyCLI/LimitResetSignals.swift \
  TallyCLI/ManualMoveState.swift \
  TallyCLI/MessagingSocket.swift \
  TallyCLI/ModelRequest.swift \
  TallyCLI/MoveField.swift \
  TallyCLI/OpenTurn.swift \
  TallyCLI/PendingNotice.swift \
  TallyCLI/ProjectPolicy.swift \
  TallyCLI/ProviderExecutable.swift \
  TallyCLI/Quarantine.swift \
  TallyCLI/QuotaKnockHookContract.swift \
  TallyCLI/QuotaKnockNotice.swift \
  TallyCLI/Rebalance.swift \
  TallyCLI/RelaunchPlan.swift \
  TallyCLI/Reload.swift \
  TallyCLI/ReloadRequest.swift \
  TallyCLI/RequestTranscript.swift \
  TallyCLI/ResumePrompt.swift \
  TallyCLI/SafeguardDrift.swift \
  TallyCLI/SessionAddressing.swift \
  TallyCLI/SessionAddressLookup.swift \
  TallyCLI/SessionClear.swift \
  TallyCLI/SessionContext.swift \
  TallyCLI/SessionInput.swift \
  TallyCLI/SessionInputAutomatic.swift \
  TallyCLI/SessionInputCommand.swift \
  TallyCLI/SessionInputDraft.swift \
  TallyCLI/SessionInputLanding.swift \
  TallyCLI/SessionInputLog.swift \
  TallyCLI/SessionInputOccupant.swift \
  TallyCLI/SessionInputRequest.swift \
  TallyCLI/SessionInputTick.swift \
  TallyCLI/SessionInventory.swift \
  TallyCLI/SessionModel.swift \
  TallyCLI/SessionProjectAddress.swift \
  TallyCLI/SessionQuiet.swift \
  TallyCLI/SessionSendVerb.swift \
  TallyCLI/SessionSendWait.swift \
  TallyCLI/SessionState.swift \
  TallyCLI/SessionSwitch.swift \
  TallyCLI/SessionTurnEnd.swift \
  TallyCLI/Snapshot.swift \
  Tally/Core/ClaudeStableExecutable.swift \
  TallyCLI/StatusReport.swift \
  Tally/Core/HeldOverReset.swift \
  TallyCLI/SupervisorRuntime.swift \
  TallyCLI/TaskListPin.swift \
  TallyCLI/SwitchBadges.swift \
  TallyCLI/SwitchDecision.swift \
  TallyCLI/SwitchRequest.swift \
  TallyCLI/TranscriptFork.swift \
  TallyCLI/TranscriptIdentity.swift \
  TallyCLI/TranscriptLoginSignals.swift \
  TallyCLI/TranscriptSignals.swift \
  TallyCLI/TranscriptWatcher.swift \
  TallyCLI/UnmanagedLaunch.swift \
  TallyCLI/UsageAdvisor.swift \
  TallyCLI/UsageAdvisorMath.swift \
  TallyCLI/UserNotice.swift \
  TallyCLI/WindowRepick.swift \
  TallyCLI/WindowRepickWindow.swift \

if [ -n "${CTXRUST_BENCH:-}" ]; then
  "$out" bench "$CTXRUST_BENCH"
else
  "$out"
fi
