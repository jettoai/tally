#!/bin/bash
# Compiles the host-health watch's pure halves (Tally/Core/HostHealthLogic.swift, the state machine
# and the report both targets read, and TallyCLI/HostHealthKnockLogic.swift, what the supervisor's
# station decides) together with an assertion harness, and runs it. Both depend only on Foundation,
# so no Xcode target is needed; exits non-zero on failure.
#
# The suite also reads five sources as text at the end. Those assertions are the structural promises
# this feature was accepted under - no timer of its own, no subprocess, two syscalls on the ordinary
# sample, the process-table walk confined to the branch that has just raised an alarm, and the
# station speaking last through the knock's existing door - and not one of them can be driven from a
# harness: they need a running timer, a live session and a machine actually in trouble.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/hosthealth/main.swift Tally/Core/HostHealthLogic.swift \
  TallyCLI/HostHealthKnockLogic.swift
"$out"
