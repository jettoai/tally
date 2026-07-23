#!/bin/bash
# Compiles the supervisor's transcript watcher (model tracking guards) with a small assertion
# harness and runs it. No Xcode test target needed; exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/supervisor/main.swift \
  TallyCLI/Supervisor.swift TallyCLI/SupervisorRuntime.swift \
  TallyCLI/TranscriptWatcher.swift TallyCLI/Snapshot.swift
"$out"
