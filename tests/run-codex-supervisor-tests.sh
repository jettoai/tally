#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -o "$out/run" tests/codex-supervisor/main.swift \
  Tally/Core/SessionMonitoring.swift Tally/Core/CodexSessionHooks.swift \
  TallyCLI/CodexSessionEvents.swift TallyCLI/SessionState.swift TallyCLI/ReloadRequest.swift
"$out/run"
