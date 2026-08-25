#!/bin/bash
# Compiles the supervisor's transcript watcher (model tracking guards) with a small assertion
# harness and runs it. No Xcode test target needed; exits non-zero on failure.
#
# ProjectPolicy.swift is in the list because a tick lays this project's launch profile over the
# app policy it re-reads (TallyCLI/ProjectPolicy.swift); GitRepoRoot.swift is the repo identity
# that profile is keyed by, and StatusReport/UsageAdvisor come along because the profile also
# publishes itself into `tally status --json`.
#
# PickClaimGate is which build may answer the machine's picks (app-side, so the CLI target does not
# compile it the way it compiles the contract beside it); CaptureLaunch comes with it because that
# gate asks it two things: which flag hands the capability back to a build nobody installed, and how
# long that lasts (`pickClaimOverrideLifetime`).
#
# The Model*/SessionModel/SessionDirectives files are `tally model`, which is the same shape one
# axis over: a request file, a tick decision, and the CLI surfaces that write one. LaunchAxisNames
# is the shared effort enumeration both targets compile, and ResuperviseContract is the exec
# contract the self-update tests already assert (it was split out of SelfUpdate.swift).
#
# SessionRosterFreshness is the board's "which supervisor build is watching this" reading, split off
# the store on size; BuildVariant comes with it, being where the installed version it compares
# against is read from (and where the demo fixtures' lagging version is derived from), and
# SupervisorVersionStamp is where that reading comes FROM on a live machine: the build stamped into
# the supervisor's child at spawn, which is the half that reaches supervisors older than the state
# record's own field.
#
# DemoSessions.swift is the session board's capture fixtures (demoboardchecks.swift); DemoUsage and
# the five files after it are what IT needs to compile: the enum those fixtures extend, the usage
# model its account fixtures are built from, the fleet rate and the token sample it fabricates, and
# the localisation the token names go through. That is a bigger dependency than a fixture file
# suggests, and it buys the fixtures being EXERCISED rather than read: what a card would be handed
# is asserted directly, which is the only way to state that no field of a real session survives
# onto a screenshot. The two other suites that compile DemoUsage.swift need none of this, which is
# why the session fixtures are a file of their own.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/supervisor/main.swift tests/supervisor/reloadchecks.swift \
  tests/supervisor/capgatechecks.swift tests/supervisor/capresetchecks.swift \
  tests/supervisor/capselfupdatechecks.swift \
  tests/supervisor/forkchecks.swift tests/supervisor/requesttranscriptchecks.swift \
  tests/supervisor/requestforwardchecks.swift tests/supervisor/transcriptidentitychecks.swift \
  tests/supervisor/dispatchlayoutchecks.swift \
  tests/supervisor/keyboardchecks.swift tests/supervisor/openturnchecks.swift \
  tests/supervisor/terminaldrainchecks.swift \
  tests/supervisor/shimchecks.swift tests/supervisor/selfupdatefoldchecks.swift \
  tests/supervisor/rebalancechecks.swift tests/supervisor/rebalanceclaimchecks.swift \
  tests/supervisor/reservechecks.swift \
  tests/supervisor/windowrepickchecks.swift \
  tests/supervisor/reloadrepickchecks.swift tests/supervisor/relaunchchecks.swift tests/supervisor/positionalchecks.swift \
  tests/supervisor/safeguardchecks.swift \
  tests/supervisor/followchecks.swift tests/supervisor/pendingnoticechecks.swift \
  tests/supervisor/sessionstatechecks.swift tests/supervisor/sessionorderchecks.swift \
  tests/supervisor/supervisorfreshnesschecks.swift \
  tests/supervisor/demoboardchecks.swift \
  tests/supervisor/processtreechecks.swift tests/supervisor/processtreelinechecks.swift \
  tests/supervisor/processtreecensuschecks.swift \
  tests/supervisor/footprintchecks.swift \
  tests/supervisor/footprintalertchecks.swift tests/supervisor/footprinttrendchecks.swift \
  tests/supervisor/footprinttrendsurfacechecks.swift \
  tests/supervisor/sessioncardedgechecks.swift \
  tests/supervisor/agentrosterchecks.swift \
  tests/supervisor/turnendchecks.swift \
  tests/supervisor/steeringoffchecks.swift tests/supervisor/turnboundarychecks.swift \
  tests/supervisor/droughtchecks.swift \
  tests/supervisor/capresumechecks.swift \
  tests/supervisor/terminaljumpchecks.swift \
  tests/supervisor/sessioninputchecks.swift tests/supervisor/sessionsendchecks.swift \
  tests/supervisor/sessionclearchecks.swift tests/supervisor/draftstashchecks.swift \
  tests/supervisor/quotaknockchecks.swift \
  tests/supervisor/knockchannelchecks.swift tests/supervisor/knockhookchecks.swift \
  tests/supervisor/contextchecks.swift tests/supervisor/inventorychecks.swift \
  tests/supervisor/resumepromptchecks.swift \
  tests/supervisor/standdownchecks.swift tests/supervisor/switchchecks.swift \
  tests/supervisor/switchrequestchecks.swift tests/supervisor/switchsessionchecks.swift \
  tests/supervisor/switchhookchecks.swift tests/supervisor/sessionpinchecks.swift \
  tests/supervisor/capsessionpinchecks.swift \
  tests/supervisor/modelrequestchecks.swift tests/supervisor/modeltickchecks.swift \
  tests/supervisor/modelsurfacechecks.swift tests/supervisor/nativemodelchecks.swift \
  tests/supervisor/mcppickerchecks.swift tests/supervisor/accountwindowchecks.swift tests/supervisor/pickerchecks.swift tests/supervisor/pickgracechecks.swift \
  tests/supervisor/pickclaimchecks.swift tests/supervisor/pickheightchecks.swift \
  tests/supervisor/pickpalettechecks.swift tests/supervisor/pickrowchecks.swift \
  tests/supervisor/pickcirclechecks.swift \
  tests/supervisor/picksurfacechecks.swift tests/supervisor/pickmodifierchecks.swift \
  tests/supervisor/tallypromptchecks.swift \
  tests/supervisor/backstopchecks.swift \
  TallyCLI/Supervisor.swift TallyCLI/SupervisorRuntime.swift TallyCLI/RelaunchPlan.swift TallyCLI/LaunchFlags.swift TallyCLI/Quarantine.swift TallyCLI/CapDetection.swift TallyCLI/DriftMonitor.swift \
  TallyCLI/TranscriptWatcher.swift TallyCLI/SessionQuiet.swift TallyCLI/TranscriptSignals.swift TallyCLI/NativeModelCommand.swift TallyCLI/TranscriptFork.swift TallyCLI/RequestTranscript.swift TallyCLI/TranscriptIdentity.swift TallyCLI/Snapshot.swift TallyCLI/AccountPick.swift \
  TallyCLI/AccountBinding.swift TallyCLI/AccountReserveReader.swift Tally/Core/AccountReserve.swift \
  Tally/Core/ArtifactHookContract.swift TallyCLI/Reload.swift \
  TallyCLI/ReloadRequest.swift TallyCLI/SelfUpdate.swift TallyCLI/AccountComfort.swift \
  TallyCLI/Rebalance.swift TallyCLI/MoveField.swift TallyCLI/WindowRepick.swift TallyCLI/WindowRepickWindow.swift TallyCLI/SafeguardDrift.swift TallyCLI/ModelDegradation.swift \
  TallyCLI/AutoSteering.swift TallyCLI/TurnBoundaryMove.swift TallyCLI/DroughtWatch.swift \
  TallyCLI/CapResume.swift \
  TallyCLI/KeyboardIdle.swift TallyCLI/OpenTurn.swift TallyCLI/ProviderExecutable.swift \
  TallyCLI/LaunchResume.swift TallyCLI/LastConversation.swift \
  TallyCLI/TerminalHandover.swift \
  TallyCLI/PendingNotice.swift TallyCLI/SessionState.swift TallyCLI/UserNotice.swift TallyCLI/SessionTurnEnd.swift TallyCLI/HookNotify.swift TallyCLI/AgentRoster.swift TallyCLI/HookAgents.swift TallyCLI/SessionStateSync.swift TallyCLI/FollowAdoption.swift TallyCLI/StandDown.swift \
  TallyCLI/SessionContext.swift TallyCLI/SessionInventory.swift TallyCLI/MessagingSocket.swift \
  TallyCLI/SessionInput.swift TallyCLI/SessionInputTick.swift TallyCLI/SessionInputLanding.swift \
  TallyCLI/SessionInputDraft.swift \
  TallyCLI/SessionClear.swift TallyCLI/SessionInputLog.swift \
  TallyCLI/SessionInputRequest.swift \
  TallyCLI/SessionInputCommand.swift TallyCLI/SessionSendWait.swift \
  TallyCLI/QuotaKnock.swift TallyCLI/QuotaKnockLogic.swift \
  TallyCLI/QuotaKnockNotice.swift TallyCLI/QuotaKnockHookContract.swift TallyCLI/HookKnock.swift \
  TallyCLI/ResumePrompt.swift TallyCLI/SessionSwitch.swift TallyCLI/ManualMoveState.swift TallyCLI/SwitchDecision.swift TallyCLI/SwitchRequest.swift TallyCLI/SessionAddressing.swift TallyCLI/AccountHome.swift TallyCLI/SwitchCommand.swift TallyCLI/SwitchHook.swift TallyCLI/SwitchMenu.swift TallyCLI/WorktreeMenu.swift \
  TallyCLI/ProjectPolicy.swift TallyCLI/GitRepoRoot.swift \
  TallyCLI/ResuperviseContract.swift TallyCLI/ModelRequest.swift TallyCLI/SessionModel.swift \
  TallyCLI/ChildReaper.swift \
  TallyCLI/SessionDirectives.swift TallyCLI/ModelCommand.swift TallyCLI/ModelHook.swift \
  TallyCLI/ModelMenu.swift Tally/Core/LaunchAxisNames.swift \
  TallyCLI/MCPServe.swift TallyCLI/MCPPicker.swift TallyCLI/MCPAccountOffer.swift TallyCLI/MCPPickOffer.swift TallyCLI/TallyPrompt.swift TallyCLI/NativePick.swift TallyCLI/PickRows.swift Tally/Core/PickContract.swift \
  Tally/Core/PickPanelMetrics.swift Tally/Core/PickPalette.swift Tally/Core/PickKeyboard.swift Tally/Core/PanelGeometry.swift TallyCLI/PromptHookBackstop.swift \
  Tally/Core/PickClaimGate.swift Tally/Core/CaptureLaunch.swift \
  Tally/Core/PromptHookInput.swift \
  TallyCLI/MCPAuthSync.swift TallyCLI/MCPAuthMerge.swift TallyCLI/MCPSeedGate.swift TallyCLI/KeychainSecret.swift \
  TallyCLI/KeychainPartitionRepair.swift \
  Tally/Core/Keychain/KeychainReader.swift Tally/Core/Keychain/ClaudeKeychainService.swift \
  Tally/Core/ClaudeStatePath.swift Tally/Core/PathIdentity.swift \
  TallyCLI/StatusReport.swift TallyCLI/UsageAdvisor.swift \
  Tally/Core/TerminalJump.swift Tally/Core/TerminalJumpScript.swift Tally/Core/CLIRunner.swift Tally/Stores/SessionRosterStore.swift \
  Tally/Stores/SessionRosterFreshness.swift Tally/Core/BuildVariant.swift \
  Tally/Core/SupervisorVersionStamp.swift \
  Tally/Core/SessionSidecar.swift \
  Tally/Core/SessionBoardOrder.swift Tally/Core/ProcessTreeStats.swift \
  Tally/Core/ProcessTreeLine.swift Tally/Core/ProcessTreeCensus.swift \
  Tally/Core/ProcessTreeReaders.swift Tally/Core/FootprintAlerts.swift \
  Tally/Core/FootprintTrend.swift \
  Tally/Core/DemoSessions.swift Tally/Core/DemoUsage.swift \
  Tally/Providers/ProviderModels.swift Tally/Core/FleetForecast.swift \
  Tally/Core/UsageHistory.swift Tally/Core/TokenStats/TokenTotals.swift \
  Tally/Core/TokenStats/JSONScan.swift Tally/Core/AppLocale.swift
"$out"
