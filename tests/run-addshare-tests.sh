#!/bin/bash
# Compiles the CLI's `add --share` harness-linking (TallyCLI/Snapshot.swift) together with a
# small assertion harness and runs it. No Xcode test target needed; exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
# AddCommand.swift joins the list for `nextFreeSlot` (which slot `tally add` picks). Its two
# Keychain files are compiled, never called: every assertion injects its own probe, so the suite
# reads no Keychain and depends on no login existing on the machine running it.
swiftc -o "$out" tests/addshare/main.swift TallyCLI/SharedHarness.swift TallyCLI/Snapshot.swift \
  TallyCLI/ProviderExecutable.swift TallyCLI/AccountComfort.swift TallyCLI/AddCommand.swift \
  Tally/Core/Keychain/KeychainReader.swift Tally/Core/Keychain/ClaudeKeychainService.swift
"$out"
