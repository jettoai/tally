#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
# CodexWaitEvents.swift is the Codex wait-event adapter under test; SessionWaitEvent.swift and
# SessionWaitLogic.swift are the shared contract it builds on, and UserNotice.swift and
# OpenTurn.swift are what SessionWaitLogic.swift needs to compile (support.swift stands in for
# the one Snapshot.swift symbol OpenTurn.swift would otherwise drag in).
swiftc -o "$out/run" tests/codex-supervisor/main.swift tests/codex-supervisor/waitchecks.swift tests/codex-supervisor/waitquestionchecks.swift \
  tests/codex-supervisor/support.swift \
  Tally/Core/SessionMonitoring.swift Tally/Core/CodexSessionHooks.swift \
  TallyCLI/CodexSessionEvents.swift TallyCLI/CodexSessionContext.swift \
  TallyCLI/SessionState.swift TallyCLI/ReloadRequest.swift \
  TallyCLI/CodexWaitEvents.swift TallyCLI/SessionWaitEvent.swift TallyCLI/SessionWaitLogic.swift \
  TallyCLI/UserNotice.swift TallyCLI/OpenTurn.swift
"$out/run"
