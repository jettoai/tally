#!/bin/bash
# Compiles project attribution (Tally/Core/TokenStats/TokenProjectMap.swift) together with a small
# assertion harness and runs it. No Xcode test target needed; exits non-zero on failure.
#
# The source list is the map's closure: TokenTotals.swift for the pooled row's key, with the
# harness stubbing the one localization call that file makes. Which directory owns which tokens is
# invisible to the compiler and to a screenshot taken on one machine, so the suite builds its own
# workspace tree in a temp directory and asks the map about it.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/tokenprojectmap/main.swift \
  Tally/Core/TokenStats/TokenProjectMap.swift Tally/Core/TokenStats/TokenTotals.swift \
  Tally/Core/WorktreeOrigins.swift
"$out"
