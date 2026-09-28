#!/bin/bash
# Compiles the held-over reset judge (Tally/Core/HeldOverReset.swift) and its app wrapper with a
# small assertion harness and runs it. No Xcode test target needed; exits non-zero on failure.
#
# LastGoodFold.swift comes along for the replay: the state under test is exactly what that fold
# publishes after failed polls. Run from the repo root, which the cd below guarantees.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/resetpassed/main.swift Tally/Core/HeldOverReset.swift \
  Tally/Core/HeldOverResetUsage.swift Tally/Providers/ProviderModels.swift \
  Tally/Core/LastGoodFold.swift Tally/Core/UsageSnapshot.swift
"$out"
