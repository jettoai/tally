#!/bin/bash
# Compiles the "Start at login" row's decision layer with a small assertion harness and runs it:
# the SMAppService status mapping and the failure rules (Tally/Core/LaunchAtLoginState.swift,
# Tally/Core/LaunchAtLoginService.swift) and the dev state preview behind -TallyLoginItemPreview
# (Tally/Core/LoginItemPreview.swift). No SwiftUI and no Xcode test target; the row that draws all
# of it is Tally/Views/SettingsLaunchAtLoginRow.swift.
#
# Nothing here registers a login item or touches the machine's own: every state is named as an enum
# value, so the mapping, the sentences and the preview walks are asserted without a single write.
#
# The trailing file list is DemoUsage's transitive closure, which the preview's build gate reaches
# through (the same closure run-integrations-tests.sh compiles, and for the same reason: one copy
# of "is this a demo launch", not a second spelling of the flag).
#
# THAT CLOSURE NOW REACHES THE FOOTPRINT, which is the last four files: the fixtures paint a session
# card's readings as well as its account gauges, so DemoUsage names ProcessFootprint, the alert
# tiers it sets on one, and the line those are spelled into (ProcessTreeLine, whose separator is
# PickContract's). The list had drifted behind that and this suite would not compile at all; a
# closure is only a closure while every name in it is followed.
#
# The deployment target is pinned because SMAppService starts at macOS 13 and a bare swiftc would
# leave it to the host's default. Exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -target "$(uname -m)-apple-macos14.0" -o "$out" tests/launchatlogin/main.swift \
  Tally/Core/LaunchAtLoginState.swift Tally/Core/LaunchAtLoginService.swift \
  Tally/Core/LaunchAtLoginDefault.swift \
  Tally/Core/LoginItemPreview.swift Tally/Core/CaptureLaunch.swift \
  Tally/Core/BuildVariant.swift Tally/Core/DemoUsage.swift Tally/Core/UsageSnapshot.swift \
  Tally/Core/AppLocale.swift Tally/Core/FleetForecast.swift Tally/Core/UsageHistory.swift \
  Tally/Core/TokenStats/TokenTotals.swift Tally/Core/TokenStats/JSONScan.swift \
  Tally/Providers/ProviderModels.swift TallyCLI/UsageAdvisor.swift \
  Tally/Core/ProcessTreeStats.swift Tally/Core/ProcessTreePool.swift Tally/Core/ProcessTreeRates.swift Tally/Core/ProcessTreeLine.swift \
  Tally/Core/FootprintAlerts.swift Tally/Core/PickContract.swift
"$out"
