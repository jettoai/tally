#!/bin/bash
# Compiles the Claude usage-text mapper (reset-time year inference) with a small assertion
# harness and runs it. No Xcode test target needed; exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/claudereset/main.swift \
  Tally/Providers/Claude/ClaudeUsageCLI.swift Tally/Core/CLIRunner.swift \
  Tally/Providers/ProviderModels.swift
"$out"
