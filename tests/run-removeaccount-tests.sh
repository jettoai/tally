#!/bin/bash
# Compiles the "remove an account" core (Tally/Core/RemoveAccount.swift, plus AddAccount.swift for
# the config-home naming both acts share) with a small assertion harness and runs it. No Xcode test
# target needed; exits non-zero on failure.
#
# Nothing here moves a folder: the Trash is injected, so the suite never touches the Trash of the
# machine running it. ClaudeOnboarding.swift is here for AddAccount.swift alone: its marker sweep
# leaves the first-run wizard's note as it clears, and nothing in this suite calls either.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/removeaccount/main.swift \
  Tally/Core/RemoveAccount.swift Tally/Core/AddAccount.swift \
  Tally/Core/AccountRemovals.swift \
  Tally/Core/SharedHarness.swift Tally/Core/PathIdentity.swift \
  Tally/Core/TrustSeed.swift Tally/Core/ClaudeStatePath.swift \
  Tally/Core/ClaudeOnboarding.swift \
  Tally/Core/Keychain/KeychainReader.swift Tally/Core/Keychain/ClaudeKeychainService.swift
"$out"
