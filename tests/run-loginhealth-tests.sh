#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
login_health_build=$(mktemp -d)
trap 'rm -rf "$login_health_build"' EXIT
swiftc -warnings-as-errors -o "$login_health_build/run" \
  tests/loginhealth/main.swift Tally/Core/LoginHealthAlerts.swift Tally/Core/LoginUsageHealth.swift \
  Tally/Core/ClaudeLoginExpiry.swift Tally/Core/ClaudeLoginExpiryKeychain.swift \
  Tally/Core/Keychain/ClaudeKeychainService.swift Tally/Core/Keychain/KeychainReader.swift \
  Tally/Providers/Claude/ClaudeUsageCLI.swift Tally/Core/CLIRunner.swift \
  Tally/Core/LoginStatusCommand.swift Tally/Core/RenewLoginCommand.swift Tally/Core/LoginProbeGate.swift \
  Tally/Providers/ProviderModels.swift
"$login_health_build/run"
