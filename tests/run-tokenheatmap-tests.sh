#!/bin/bash
# Compiles the token activity heatmap's arithmetic (Tally/Core/TokenStats/TokenActivityHeatmap.swift)
# together with a small assertion harness and runs it. No Xcode test target needed; exits non-zero
# on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/tokenheatmap/main.swift Tally/Core/TokenStats/TokenActivityHeatmap.swift
"$out"
