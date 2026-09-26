#!/bin/bash
# Compiles ErrorReporting.swift with a crash-shaped event fixture and asserts scrub leaves no home
# directory in the serialized event. Links the static Sentry framework SwiftPM fetched for the app
# build (the version pinned in project.yml), so the Tally scheme must have been built once. No
# network, the SDK is never started. Exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(command grep -A2 '^  Sentry:' project.yml | command grep -o 'exactVersion: .*' | cut -d' ' -f2)
framework=""
for packages in build/*/SourcePackages ~/Library/Developer/Xcode/DerivedData/Tally-*/SourcePackages; do
    [ -f "$packages/workspace-state.json" ] || continue
    command grep -q "\"version\" : \"$version\"" "$packages/workspace-state.json" || continue
    for f in "$packages"/artifacts/sentry-cocoa/Sentry/Sentry.xcframework/macos-*/Sentry.framework; do
        [ -d "$f" ] && framework=$f && break 2
    done
done
[ -n "$framework" ] || { echo "no sentry-cocoa $version framework found: build the Tally scheme first" >&2; exit 1; }
out=$(mktemp -d)/run
swiftc -o "$out" -F "$(dirname "$framework")" -framework Sentry -lc++ -lz \
    tests/errorreporting/main.swift Tally/Core/ErrorReporting.swift
"$out"
