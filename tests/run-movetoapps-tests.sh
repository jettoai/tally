#!/bin/bash
# Compiles the move-to-Applications decision layer (Tally/Core/InstallLocation.swift) and its file
# mover (Tally/Core/AppMover.swift) with an assertion harness and runs it. The mover is exercised on
# throwaway bundles in a temporary directory; nothing here writes to /Applications or the Trash.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -target "$(uname -m)-apple-macos14.0" -o "$out" tests/movetoapps/main.swift \
  Tally/Core/InstallLocation.swift Tally/Core/AppMover.swift Tally/Core/CaptureLaunch.swift
"$out"
