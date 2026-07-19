#!/bin/bash
# Compiles the shell-profile block surgery (IntegrationsStore) together with a small
# assertion harness and runs it. No Xcode test target needed; exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/integrations/main.swift \
  Tally/Stores/IntegrationsStore.swift Tally/Core/UsageSnapshot.swift \
  Tally/Core/AppLocale.swift Tally/Providers/ProviderModels.swift \
  Tally/Providers/Claude/ClaudeAccounts.swift Tally/Core/Keychain/KeychainReader.swift
"$out"
