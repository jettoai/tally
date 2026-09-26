#!/bin/bash
# Compiles the status line's rate-limit facts (TallyCLI/LiveRates.swift) and the cadence and overlay
# that read them (Tally/Core/ProbeCadence.swift) with a small assertion harness and runs it. No Xcode
# test target needed; exits non-zero on failure.
#
# The status line and the project file cannot be compiled in here, so the harness reads them as
# text to assert the wiring, the same arrangement the probe-cadence suite uses for the store.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/liverates/main.swift \
  TallyCLI/LiveRates.swift Tally/Core/ProbeCadence.swift Tally/Providers/ProviderModels.swift \
  TallyCLI/ReloadRequest.swift Tally/Core/SessionMonitoring.swift
"$out"
