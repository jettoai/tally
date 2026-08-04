#!/bin/bash
# Compiles the first-run-wizard seed (Tally/Core/ClaudeOnboarding.swift) with a small assertion
# harness and runs it. No Xcode test target needed; exits non-zero on failure.
#
# AddAccount.swift and its Foundation-only neighbours come along for two symbols the seed shares
# rather than restates: the provider's config-home base name and the rule for where the default
# home keeps its state file. Nothing in here reads a Keychain or a real config home - every
# assertion runs against a fake home directory the harness builds itself.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/onboarding/main.swift \
  Tally/Core/ClaudeOnboarding.swift Tally/Core/ClaudeStatePath.swift \
  Tally/Core/AddAccount.swift Tally/Core/SharedHarness.swift Tally/Core/TrustSeed.swift \
  Tally/Core/Keychain/KeychainReader.swift Tally/Core/Keychain/ClaudeKeychainService.swift
"$out"
