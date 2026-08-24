#!/bin/bash
# Compiles the early-start decision layer (Tally/Core/EarlyStart.swift) and the shape of the spawn
# it produces (Tally/Core/EarlyStartCommand.swift) together with a small assertion harness, and
# runs it. The command builder shares the default-home rule with the renewal path, and it reads the
# normalized account types, so those two files come along; no Xcode target is needed. Exits
# non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/earlystart/main.swift Tally/Core/EarlyStart.swift \
    Tally/Core/EarlyStartCommand.swift Tally/Core/RenewLoginCommand.swift \
    Tally/Providers/ProviderModels.swift
"$out"
