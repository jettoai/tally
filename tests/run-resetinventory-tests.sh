#!/bin/bash
# Compiles the Claude limit-reset inventory (parser, kind rule, credential handling, client name,
# per-login ledger) with a small assertion harness and runs it. No network and no Keychain: every credential read is injected.
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
swiftc -warnings-as-errors -o "$build_dir/run" \
    tests/resetinventory/main.swift \
    Tally/Core/ClaudeResetInventory.swift Tally/Core/ClaudeResetInventoryFetch.swift \
    Tally/Core/ClaudeResetInventoryLedger.swift \
    Tally/Core/ClaudeLoginExpiry.swift Tally/Core/ClaudeLoginExpiryKeychain.swift \
    Tally/Core/Keychain/ClaudeKeychainService.swift Tally/Core/Keychain/KeychainReader.swift
"$build_dir/run"
