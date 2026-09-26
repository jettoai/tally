#!/bin/bash
# Compiles the automatic Codex redeem decision (Tally/Core/CodexAutoRedeem.swift) with the account
# types and the reset-cycle key it reads, plus a small assertion harness, and runs it. Foundation
# only; no Xcode target. Exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/codexautoredeem/main.swift Tally/Core/CodexAutoRedeem.swift \
  Tally/Core/DryPoolLogic.swift Tally/Providers/ProviderModels.swift
"$out"
