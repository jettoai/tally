#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
swiftc -warnings-as-errors -o "$build_dir/run" \
    tests/loginexpiry/main.swift \
    Tally/Core/ClaudeLoginExpiry.swift Tally/Core/ClaudeLoginExpiryKeychain.swift \
    Tally/Core/Keychain/ClaudeKeychainService.swift Tally/Core/Keychain/KeychainReader.swift
"$build_dir/run"
