#!/bin/bash
# Compiles the shared "add an account" core (Tally/Core/AddAccount.swift + SharedHarness.swift +
# TrustSeed.swift, which BOTH targets build) together with a small assertion harness and runs it.
# No Xcode test target needed; exits non-zero on failure.
#
# The Keychain files are compiled, never called: every assertion injects its own probe, so the
# suite reads no Keychain and depends on no login existing on the machine running it.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/addshare/main.swift \
  Tally/Core/AddAccount.swift Tally/Core/SharedHarness.swift Tally/Core/TrustSeed.swift \
  Tally/Core/Keychain/KeychainReader.swift Tally/Core/Keychain/ClaudeKeychainService.swift \
  Tally/Core/ClaudeStatePath.swift
"$out"
