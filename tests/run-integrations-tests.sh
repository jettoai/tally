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
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/integrations/main.swift tests/integrations/tallycommandchecks.swift \
  tests/integrations/statuslinechecks.swift \
  tests/integrations/notificationhookchecks.swift tests/integrations/switchgroupchecks.swift tests/integrations/selfhealchecks.swift \
  tests/integrations/localizationchecks.swift tests/integrations/renamechecks.swift tests/integrations/mergechecks.swift \
  tests/integrations/nativepickerchecks.swift tests/integrations/skillversionchecks.swift \
  tests/integrations/shimscriptchecks.swift \
  tests/integrations/completionchecks.swift tests/integrations/clitoolchecks.swift \
  Tally/Stores/IntegrationsStore.swift Tally/Stores/IntegrationsCLITool.swift \
  Tally/Stores/IntegrationsSharedHarness.swift \
  Tally/Core/ShareExisting.swift Tally/Core/SharedHarness.swift Tally/Core/AddAccount.swift \
  Tally/Core/AddAccountFlow.swift Tally/Core/TrustSeed.swift Tally/Core/ClaudeOnboarding.swift \
  Tally/Core/RemoveAccount.swift Tally/Providers/Codex/CodexAccounts.swift \
  Tally/Stores/IntegrationsCompletion.swift \
  Tally/Stores/IntegrationsSkill.swift \
  Tally/Stores/IntegrationsSkillContent.swift Tally/Stores/IntegrationsSkillFolderMove.swift \
  Tally/Stores/IntegrationsTallyCommand.swift Tally/Stores/IntegrationsPromptCommand.swift \
  Tally/Stores/IntegrationsPromptHook.swift Tally/Stores/IntegrationsMCPServer.swift \
  Tally/Stores/IntegrationsNotificationHook.swift \
  TallyCLI/SessionState.swift TallyCLI/ReloadRequest.swift \
  Tally/Stores/IntegrationsSelfHeal.swift \
  Tally/Core/PromptHookInput.swift Tally/Core/CLIRunner.swift \
  Tally/Core/UsageSnapshot.swift \
  Tally/Core/AppLocale.swift Tally/Providers/ProviderModels.swift \
  Tally/Core/DemoUsage.swift Tally/Core/BuildVariant.swift Tally/Core/FleetForecast.swift Tally/Core/UsageHistory.swift \
  Tally/Core/TokenStats/TokenTotals.swift Tally/Core/TokenStats/JSONScan.swift \
  TallyCLI/UsageAdvisor.swift \
  Tally/Providers/Claude/ClaudeAccounts.swift Tally/Core/Keychain/KeychainReader.swift \
  Tally/Core/Keychain/ClaudeKeychainService.swift Tally/Core/ClaudeStatePath.swift \
  Tally/Core/AccountDirWatcher.swift
"$out"
