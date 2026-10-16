#!/bin/bash
# The Cost table's "vs prev" rules (B-2039): the >999% cap and the previous-window coverage test,
# compiled alone, plus source assertions that the table and CostSummary use them. Exits non-zero
# on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/costchange/main.swift Tally/Core/TokenStats/CostChange.swift
"$out"
