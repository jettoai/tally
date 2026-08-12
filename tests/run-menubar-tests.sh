#!/bin/bash
# Compiles the menu-bar strip's segment builders (Tally/Core/MenuBarSegments.swift) together with
# the fleet math they pool through and a small assertion harness, and runs it. No Xcode test target
# needed; exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/menubar/main.swift Tally/Core/MenuBarSegments.swift Tally/Core/FleetMath.swift \
    Tally/Providers/ProviderModels.swift Tally/Stores/DisplaySettings.swift
"$out"
