#!/bin/bash
# Checks the Accounts table against the page skeleton's card C (B-4474): the column widths add up to
# the 700 content column, and every column name in every shipped language fits its column in the
# header's two lines. AccountTableStyle, SettingsChrome and the skeleton are SwiftUI-only, so they
# compile in here as they are; no Xcode test target needed. Exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/settingstable/main.swift Tally/Views/SettingsAccountTableStyle.swift \
  Tally/Views/SettingsChrome.swift Tally/Views/SettingsSkeleton.swift
"$out"
