#!/bin/bash
# Compiles the session-wait-event contract (TallyCLI/SessionWaitEvent.swift,
# TallyCLI/SessionWaitLogic.swift, TallyCLI/SessionWaitSpool.swift, TallyCLI/EventDelivery.swift,
# TallyCLI/EventsCommand.swift) together with a small assertion harness and runs it. No Xcode target
# is needed; exits non-zero on failure.
#
# The source list is that contract's closure and nothing more. SessionState.swift and
# UserNotice.swift bring the `UserWait`/`UserNotice` types the pure functions are built on;
# ReloadRequest.swift comes along because both of those default their directory argument to
# `supervisorStateDir`, which lives there; ReloadRequest.swift in turn needs
# Tally/Core/SessionMonitoring.swift (the live-session registry its reload-readiness check reads),
# which is otherwise self-contained. OpenTurn.swift brings `userQuestionTools`, the one lookup
# `openWaitRequest`'s question row needs and the only thing pulled in from outside the plan's own
# minimal list (docs/plans/[WIP] feature-session-wait-events.md §12), but OpenTurn.swift's OWN
# `openToolCall(inTail:)`, a function nothing here calls, needs `parseISO` (TallyCLI/Snapshot.swift),
# which pulls in that file's entire ~14-file quota/account closure. `tests/waitevents/support.swift`
# stands in for `parseISO` alone rather than pay that, and says why in its own header.
# EventDelivery.swift and EventsCommand.swift (§12 T11-T13, package P4) need nothing beyond what is
# already in this closure: CryptoKit and Foundation only.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/waitevents/main.swift tests/waitevents/support.swift \
  tests/waitevents/loopbackreceiver.swift tests/waitevents/deliveryhandoffchecks.swift \
  TallyCLI/SessionWaitEvent.swift TallyCLI/SessionWaitLogic.swift TallyCLI/SessionWaitSpool.swift \
  TallyCLI/EventDelivery.swift TallyCLI/EventsCommand.swift \
  TallyCLI/SessionState.swift TallyCLI/UserNotice.swift TallyCLI/ReloadRequest.swift \
  TallyCLI/OpenTurn.swift Tally/Core/SessionMonitoring.swift TallyCLI/EventDeliverySpawn.swift
"$out"
