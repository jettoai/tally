#!/bin/bash
# Compile the real catalog and AppLocale into an isolated bundle; never launch the app.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tests/localization/check_catalog.py
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
app="$work/LocalizationChecks.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>ai.jetto.tally.localizationchecks</string><key>CFBundleExecutable</key><string>run</string><key>CFBundleDevelopmentRegion</key><string>en</string></dict></plist>' \
  > "$app/Contents/Info.plist"
xcrun xcstringstool compile Tally/Resources/Localizable.xcstrings \
  --output-directory "$app/Contents/Resources"
swiftc -o "$app/Contents/MacOS/run" tests/localization/main.swift Tally/Core/AppLocale.swift \
  Tally/Views/UsageFormatting.swift Tally/Stores/DisplaySettings.swift Tally/Providers/ProviderModels.swift \
  Tally/Core/TokenStats/TokenTotals.swift
"$app/Contents/MacOS/run" "$PWD"
