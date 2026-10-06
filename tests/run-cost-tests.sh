#!/bin/bash
# `tally cost` (TallyCLI/CostCommand.swift) and the snapshot contract it reads
# (Tally/Core/TokenStats/CostReport.swift), compiled with a small assertion harness. No Rust core:
# the CLI has none, which is the point of reading the app's snapshot. Exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/cost/main.swift TallyCLI/CostCommand.swift Tally/Core/TokenStats/CostReport.swift
"$out"
