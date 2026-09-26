#!/bin/bash
# Compiles the Claude probe cadence (Tally/Core/ProbeCadence.swift) with a small assertion harness
# and runs it. No Xcode test target needed; exits non-zero on failure.
#
# ReloadRequest.swift and SessionMonitoring.swift come along for the live-supervisor check the
# cadence reads. The store that runs the rounds cannot be compiled in here, so the harness reads it
# as text to assert the wiring, the same arrangement the last-good and account-row suites use.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/probecadence/main.swift \
  Tally/Core/ProbeCadence.swift Tally/Providers/ProviderModels.swift \
  TallyCLI/ReloadRequest.swift Tally/Core/SessionMonitoring.swift
"$out"
