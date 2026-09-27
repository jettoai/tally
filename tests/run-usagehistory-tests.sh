#!/bin/bash
# Compiles UsageHistory (the incremental history.jsonl read cache) with an assertion harness that
# compares every read against a whole-file reference decode. Exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/usagehistory/main.swift Tally/Core/UsageHistory.swift \
    Tally/Providers/ProviderModels.swift Tally/Stores/DisplaySettings.swift
"$out"
