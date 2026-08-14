#!/bin/bash
# Compiles the add-account chain (Tally/Core/AddAccount.swift + the login runner it hands the new
# home to + the watcher rules that turn a finished login into a visible card) with a small assertion
# harness and runs it. Every file is Foundation-only, so nothing else comes along; no Xcode test
# target needed. Exits non-zero on failure.
#
# The login is driven against stub CLIs the harness writes itself, never a real provider login.
# ClaudeOnboarding.swift comes along because AddAccount.swift's marker sweep leaves the first-run
# wizard's note as it clears (it is claude-only and writes to nothing this suite builds).
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/addaccount/main.swift \
  Tally/Core/AddAccount.swift Tally/Core/SharedHarness.swift Tally/Core/PathIdentity.swift \
  Tally/Core/TrustSeed.swift \
  Tally/Core/ClaudeOnboarding.swift \
  Tally/Core/Keychain/KeychainReader.swift Tally/Core/Keychain/ClaudeKeychainService.swift \
  Tally/Core/ClaudeStatePath.swift \
  Tally/Core/RenewLoginCommand.swift Tally/Core/RenewLoginRunner.swift \
  Tally/Core/AccountDirWatcher.swift Tally/Providers/ProviderModels.swift
"$out"
