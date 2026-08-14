#!/bin/bash
# Compiles the shared "add an account" core (Tally/Core/AddAccount.swift + SharedHarness.swift +
# ShareExisting.swift + TrustSeed.swift, which BOTH targets build) together with a small assertion
# harness and runs it.
# No Xcode test target needed; exits non-zero on failure.
#
# The Keychain files are compiled, never called: every assertion injects its own probe, so the
# suite reads no Keychain and depends on no login existing on the machine running it.
# ClaudeOnboarding.swift comes along because AddAccount.swift's marker sweep leaves the first-run
# wizard's note as it clears; the sweep assertions here are codex ones, which it declines.
set -euo pipefail
cd "$(dirname "$0")/.."
#
# The CLI half of `tally share` joined that list (2026-08-13): what the command reads a line as is
# a refusal rule, and the thing it refuses (`tally share codex work --help`) used to MOVE that
# account's files - so it is asserted behaviourally rather than as text, the way `switchIntent` is.
# The five files after ShareCommand.swift are simply its transitive closure.
out=$(mktemp -d)/run
swiftc -o "$out" tests/addshare/main.swift tests/addshare/shareexistingchecks.swift \
  tests/addshare/sharecommandchecks.swift \
  Tally/Core/AddAccount.swift Tally/Core/SharedHarness.swift Tally/Core/ShareExisting.swift \
  Tally/Core/TrustSeed.swift \
  Tally/Core/AddAccountFlow.swift Tally/Core/ClaudeOnboarding.swift \
  Tally/Core/Keychain/KeychainReader.swift Tally/Core/Keychain/ClaudeKeychainService.swift \
  Tally/Core/ClaudeStatePath.swift \
  TallyCLI/ShareCommand.swift \
  TallyCLI/Snapshot.swift TallyCLI/AccountPick.swift TallyCLI/AccountComfort.swift \
  TallyCLI/ResumePrompt.swift TallyCLI/ProviderExecutable.swift
"$out"
