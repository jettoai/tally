#!/bin/bash
# Compiles the shell-profile block surgery (IntegrationsStore) together with a small
# assertion harness and runs it. No Xcode test target needed; exits non-zero on failure.
#
# The source list is that store's transitive closure, so it follows the app target's (project.yml),
# which reaches outside Tally/ for the advisor: UsageAdvisor.swift lives in the CLI folder, both
# targets compile the one copy, and the demo fixtures in DemoUsage.swift name it.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/integrations/main.swift tests/integrations/tallycommandchecks.swift \
  tests/integrations/statuslinechecks.swift tests/integrations/switchgroupchecks.swift tests/integrations/selfhealchecks.swift \
  tests/integrations/localizationchecks.swift tests/integrations/renamechecks.swift tests/integrations/mergechecks.swift \
  tests/integrations/nativepickerchecks.swift tests/integrations/skillversionchecks.swift \
  Tally/Stores/IntegrationsStore.swift Tally/Stores/IntegrationsSkill.swift \
  Tally/Stores/IntegrationsTallyCommand.swift Tally/Stores/IntegrationsPromptCommand.swift \
  Tally/Stores/IntegrationsPromptHook.swift Tally/Stores/IntegrationsMCPServer.swift \
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
