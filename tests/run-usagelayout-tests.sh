#!/bin/bash
# The shared layer of the usage-tab preview layouts (-TallyUsageLayout ledger|tray, B-2625): the
# tightest-window rule (LaunchPolicyStore.bindingWindow, with headroom held to its old values), the
# flag reader in a DEBUG and a non-DEBUG build, and text locks on the SwiftUI files that cannot be
# compiled here. No Xcode test target needed; exits non-zero on failure.
#
# The source list is LaunchPolicyStore's transitive closure, the same one run-integrations-tests.sh
# compiles for it minus the Integrations* stores, plus the demo fixtures (the equivalence check runs
# over them).
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
swiftc -target "$(uname -m)-apple-macos14.0" -o "$out/run" tests/usagelayout/main.swift \
  Tally/Core/UsageLayout.swift \
  Tally/Stores/LaunchPolicyStore.swift Tally/Stores/LaunchPolicyStore+AutoPick.swift Tally/Stores/LaunchPolicyScoring.swift \
  Tally/Views/UsageFormatting.swift Tally/Stores/DisplaySettings.swift \
  Tally/Core/AccountReserve.swift Tally/Core/PersonalAccount.swift \
  TallyCLI/AccountComfort.swift TallyCLI/Quarantine.swift \
  TallyCLI/QuotaKnockHookContract.swift \
  TallyCLI/SessionState.swift TallyCLI/CodexStartupScreenRecord.swift TallyCLI/AgentRoster.swift Tally/Core/SessionMonitoring.swift TallyCLI/ReloadRequest.swift \
  Tally/Core/UsageSnapshot.swift \
  Tally/Core/AppLocale.swift Tally/Providers/ProviderModels.swift \
  Tally/Core/DemoUsage.swift Tally/Core/DemoManyAccounts.swift Tally/Core/LimitReset.swift Tally/Core/BuildVariant.swift Tally/Core/FleetForecast.swift Tally/Core/UsageHistory.swift \
  Tally/Core/TokenStats/TokenTotals.swift \
  TallyCLI/UsageAdvisor.swift TallyCLI/UsageAdvisorMath.swift \
  Tally/Core/ProcessTreeStats.swift Tally/Core/ProcessTreePool.swift Tally/Core/ProcessTreeRates.swift Tally/Core/ProcessTreeLine.swift \
  Tally/Core/FootprintAlerts.swift Tally/Core/PickContract.swift
"$out/run"

# The flag end to end: the argument domain is what the app reads. DEBUG honours it, a build without
# DEBUG never does, and a value that names no layout is the default layout either way.
swiftc -DDEBUG -o "$out/debug" tests/usagelayout/flag.swift Tally/Core/UsageLayout.swift
swiftc -o "$out/plain" tests/usagelayout/flag.swift Tally/Core/UsageLayout.swift
EXPECT=ledger "$out/debug" -TallyUsageLayout ledger
EXPECT=tray "$out/debug" -TallyUsageLayout Tray
EXPECT=nil "$out/debug" -TallyUsageLayout orbit
EXPECT=nil "$out/debug"
EXPECT=nil "$out/plain" -TallyUsageLayout ledger
EXPECT=nil "$out/plain" -TallyUsageLayout tray
