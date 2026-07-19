#!/bin/bash
# Compiles the fleet aggregation math (Tally/Core/FleetMath.swift) together with a small
# assertion harness and runs it. No Xcode test target needed; exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/fleet/main.swift Tally/Core/FleetMath.swift Tally/Core/FleetForecast.swift \
    Tally/Core/UsageHistory.swift Tally/Providers/ProviderModels.swift
"$out"
