#!/bin/bash
# Compiles the "Start at login" row's reading of macOS (Tally/Core/LaunchAtLoginState.swift and
# the SMAppService status mapping in Tally/Core/LaunchAtLoginService.swift) with a small assertion
# harness and runs it. Foundation and ServiceManagement only, so no SwiftUI and no Xcode test
# target; the row that draws these states is Tally/Views/SettingsLaunchAtLoginRow.swift.
#
# Nothing here registers a login item or touches the machine's own: the states are named as enum
# values, so the mapping and the sentences are asserted without a single write.
#
# The deployment target is pinned because SMAppService starts at macOS 13 and a bare swiftc would
# leave it to the host's default. Exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -target "$(uname -m)-apple-macos14.0" -o "$out" tests/launchatlogin/main.swift \
  Tally/Core/LaunchAtLoginState.swift Tally/Core/LaunchAtLoginService.swift
"$out"
