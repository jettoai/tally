#!/bin/bash
# Compiles the reset-hint trigger/ranking/dedup logic (Tally/Core/ResetHintLogic.swift) together
# with a small assertion harness and runs it. It borrows DryPoolLogic's reset-cycle key and reads
# the normalized account types, so those two files come along, plus the Codex reset-bank decode
# whose absent-versus-empty list the expiry memory depends on; no Xcode target is needed. Exits
# non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/resethint/main.swift tests/resethint/expirychecks.swift \
    Tally/Core/ResetHintLogic.swift \
    Tally/Core/DryPoolLogic.swift Tally/Providers/ProviderModels.swift \
    Tally/Providers/Codex/CodexResetBank.swift
"$out"
