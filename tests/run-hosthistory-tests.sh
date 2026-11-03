#!/bin/bash
# Compiles the load history's pieces (Tally/Core/HostLoadHistory.swift, the line format and its
# reader; HostLoadStats.swift, the rates; HostLoadHistoryWriter.swift, the app's writer;
# TallyCLI/HostHistoryCommand.swift, `tally status --history`) with an assertion harness and runs
# it. The command's default gate comes from HostHealthLogic.swift, which brings its two neighbours.
# Only Foundation and Darwin, so no Xcode target is needed; exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/hosthistory/main.swift \
  Tally/Core/HostLoadHistory.swift Tally/Core/HostLoadStats.swift Tally/Core/HostLoadHistoryWriter.swift \
  TallyCLI/HostHistoryCommand.swift \
  Tally/Core/HostHealthLogic.swift Tally/Core/HostHealthNaming.swift Tally/Core/HostHealthSessions.swift \
  Tally/Core/KeystrokeText.swift
"$out"
