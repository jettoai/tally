#!/bin/bash
# Compiles the shell-profile block surgery (IntegrationsStore) together with a small
# assertion harness and runs it. No Xcode test target needed; exits non-zero on failure.
#
# The source list is that store's transitive closure, so it follows the app target's (project.yml),
# which reaches outside Tally/ for the advisor: UsageAdvisor.swift lives in the CLI folder, both
# targets compile the one copy, and the demo fixtures in DemoUsage.swift name it. The share engine
# and the account discovery behind it joined that closure when the store grew the "Shared harness"
# row (2026-08-13): the row's word is read off the filesystem for every account, so the store now
# reaches the same core `tally share` does.
#
# AND THE FOOTPRINT JOINED IT THROUGH THE FIXTURES, which is the last four files: DemoUsage paints a
# session card's readings as well as its account gauges, so it names ProcessFootprint, the alert
# tiers it sets on one, and the line those are spelled into (ProcessTreeLine, whose separator is
# PickContract's). The list had drifted behind that and this suite would not compile at all; a
# closure is only a closure while every name in it is followed.
# AND THE LAUNCH POLICY STORE JOINED IT WITH THE ARTIFACT ROW (2026-08-20): that row's install
# seeds the account the guard reads out of ~/.tally/state.json, which is the difference between a
# row that says Installed and a row that does anything at all, so the store that owns that file is
# now part of this store's closure (AccountComfort and Quarantine come in behind it, exactly as they
# do in the app target), along with its own two halves: the burn-rate scoring it was split from for
# file size, and the per-account block it publishes (AccountReserve.swift - the personal account and
# the reserve the Artifact seed now reads before it guesses). PersonalAccount.swift joined them with
# the flagship water line (2026-09-05): it is the app's translation of that ruling into the meters'
# own vocabulary, and this is the only suite that can ask it for a value rather than read its text.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/integrations/main.swift tests/integrations/tallycommandchecks.swift \
  tests/integrations/statuslinechecks.swift \
  tests/integrations/agenthookchecks.swift tests/integrations/knockhookchecks.swift tests/integrations/artifacthookchecks.swift tests/integrations/autofollowchecks.swift tests/integrations/notificationhookchecks.swift tests/integrations/switchgroupchecks.swift tests/integrations/selfhealchecks.swift \
  tests/integrations/localizationchecks.swift tests/integrations/renamechecks.swift tests/integrations/mergechecks.swift \
  tests/integrations/nativepickerchecks.swift tests/integrations/skillversionchecks.swift \
  tests/integrations/shimscriptchecks.swift tests/integrations/sharedharnesschecks.swift \
  tests/integrations/completionchecks.swift tests/integrations/clitoolchecks.swift \
  tests/integrations/smartbadgechecks.swift \
  Tally/Stores/IntegrationsStore.swift Tally/Stores/IntegrationsShim.swift \
  Tally/Stores/IntegrationsCLITool.swift \
  Tally/Stores/IntegrationsSharedHarness.swift \
  Tally/Core/ShareExisting.swift Tally/Core/SharedHarness.swift Tally/Core/PathIdentity.swift \
  Tally/Core/AddAccount.swift \
  Tally/Core/AddAccountFlow.swift Tally/Core/TrustSeed.swift Tally/Core/ClaudeOnboarding.swift \
  Tally/Core/RemoveAccount.swift Tally/Providers/Codex/CodexAccounts.swift \
  Tally/Stores/IntegrationsCompletion.swift \
  Tally/Stores/IntegrationsSkill.swift \
  Tally/Stores/IntegrationsSkillContent.swift Tally/Stores/IntegrationsSkillFolderMove.swift \
  Tally/Stores/IntegrationsTallyCommand.swift Tally/Stores/IntegrationsPromptCommand.swift \
  Tally/Stores/IntegrationsPromptHook.swift Tally/Stores/IntegrationsMCPServer.swift \
  Tally/Stores/IntegrationsNotificationHook.swift \
  Tally/Stores/IntegrationsAgentHook.swift \
  Tally/Stores/IntegrationsKnockHook.swift Tally/Stores/IntegrationsAutoFollow.swift \
  Tally/Stores/IntegrationsArtifactHook.swift Tally/Core/ArtifactHookContract.swift \
  Tally/Stores/LaunchPolicyStore.swift Tally/Stores/LaunchPolicyScoring.swift \
  Tally/Core/AccountReserve.swift Tally/Core/PersonalAccount.swift \
  TallyCLI/AccountComfort.swift TallyCLI/Quarantine.swift \
  TallyCLI/QuotaKnockHookContract.swift \
  TallyCLI/SessionState.swift TallyCLI/AgentRoster.swift TallyCLI/ReloadRequest.swift \
  Tally/Stores/IntegrationsSelfHeal.swift \
  Tally/Core/PromptHookInput.swift Tally/Core/CLIRunner.swift \
  Tally/Core/UsageSnapshot.swift \
  Tally/Core/AppLocale.swift Tally/Providers/ProviderModels.swift \
  Tally/Core/DemoUsage.swift Tally/Core/BuildVariant.swift Tally/Core/FleetForecast.swift Tally/Core/UsageHistory.swift \
  Tally/Core/TokenStats/TokenTotals.swift Tally/Core/TokenStats/JSONScan.swift \
  TallyCLI/UsageAdvisor.swift TallyCLI/UsageAdvisorMath.swift \
  Tally/Providers/Claude/ClaudeAccounts.swift Tally/Core/Keychain/KeychainReader.swift \
  Tally/Core/Keychain/ClaudeKeychainService.swift Tally/Core/ClaudeStatePath.swift \
  Tally/Core/AccountDirWatcher.swift \
  Tally/Core/ProcessTreeStats.swift Tally/Core/ProcessTreePool.swift Tally/Core/ProcessTreeRates.swift Tally/Core/ProcessTreeLine.swift \
  Tally/Core/FootprintAlerts.swift Tally/Core/PickContract.swift
"$out"
