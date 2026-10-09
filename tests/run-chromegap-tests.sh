#!/bin/bash
# Compiles the Chrome-gap notice (TallyCLI/ChromeReach.swift, the branch in TallyCLI/HookKnock.swift)
# with its assertion harness and runs it. No Xcode target is needed;
# exits non-zero on failure. Every collaborator is injected, so nothing here touches a real ~/.tally,
# supervisor, snapshot, Claude session or browser.
#
# The source list is the closure of `runHookKnock` and the live defaults it names (the supervisor's
# account and child readers, the snapshot), found by compiling and adding each file a missing symbol
# lives in. It is about a third of the supervisor suite's list and compiles in about a third of the
# time. Count assertions with `command grep -c '^PASS:'`.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/chromegap/main.swift tests/chromegap/routingchecks.swift \
  tests/chromegap/preflightchecks.swift tests/chromegap/runnerchecks.swift TallyCLI/ChromePreflight.swift TallyCLI/ChromeRun.swift TallyCLI/ChromeRunStream.swift TallyCLI/SwitchCommand.swift \
  TallyCLI/TranscriptLineBytes.swift \
  TallyCLI/QuotaKnock.swift \
  TallyCLI/CapResume.swift TallyCLI/CapResumeLog.swift TallyCLI/NativeModelCommand.swift TallyCLI/QuotaKnockLogic.swift \
  TallyCLI/SelfSwitchResume.swift TallyCLI/TranscriptWatcherScan.swift TallyCLI/RestartLiveWork.swift TallyCLI/TranscriptLineView.swift TallyCLI/TranscriptLineRust.swift \
  TallyCLI/ModelMenu.swift \
  TallyCLI/MCPAccountOffer.swift TallyCLI/MCPPickOffer.swift TallyCLI/ModelCommand.swift TallyCLI/ModelHook.swift TallyCLI/PickRows.swift TallyCLI/TallyPrompt.swift \
  Tally/Core/PromptHookInput.swift TallyCLI/MCPPicker.swift \
  TallyCLI/PromptHookBackstop.swift \
  TallyCLI/SwitchHook.swift TallyCLI/WorktreeMenu.swift \
  TallyCLI/SwitchMenu.swift \
   \
   \
   \
   \
   \
   \
   \
   \
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
  TallyCLI/HookKnock.swift TallyCLI/HostHealthKnockLogic.swift \
  Tally/Core/HostHealthLogic.swift Tally/Core/KeystrokeText.swift \
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
  TallyCLI/SessionInput.swift TallyCLI/AutomaticInput.swift \
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
  TallyCLI/Snapshot.swift Tally/Core/ClaudeStableExecutable.swift \
  TallyCLI/StatusReport.swift Tally/Core/HeldOverReset.swift \
  TallyCLI/SupervisorRuntime.swift TallyCLI/TaskListPin.swift \
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
  TallyCLI/WindowRepickWindow.swift
"$out"
