#!/bin/bash
# Compiles the failed-refresh fold (Tally/Core/LastGoodFold.swift) with a small assertion harness
# and runs it. No Xcode test target needed; exits non-zero on failure.
#
# ProviderModels.swift is the account model the fold folds; UsageSnapshot.swift comes along because
# the fold's whole purpose is a fact the CLI reads, and a fact the publisher drops on the way to
# the snapshot is a fact nobody downstream has. The store that owns the failure streaks cannot be
# compiled in here (it is a main-actor observable pulling in the providers and the network), so the
# harness reads it as text to assert the wiring, which is the same arrangement the account-row
# suite uses. Run from the repo root, which the cd below guarantees.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/lastgood/main.swift \
  Tally/Core/LastGoodFold.swift Tally/Core/UsageSnapshot.swift \
  Tally/Providers/ProviderModels.swift
"$out"
