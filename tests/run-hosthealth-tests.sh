#!/bin/bash
# Compiles the host-health watch's pure halves (Tally/Core/HostHealthLogic.swift, the state machine
# and the report both targets read, and TallyCLI/HostHealthKnockLogic.swift, what the supervisor's
# station decides) together with an assertion harness, and runs it. KeystrokeText.swift comes with
# them: the sentence a session is told repairs the process names in it through that one rule. All
# three depend only on Foundation, so no Xcode target is needed; exits non-zero on failure.
#
# The harness is two files, the division tests/supervisor keeps: main.swift holds the fixtures,
# `expect` and the tally, and knockchecks.swift holds the knock's own half (split on size,
# 2026-09-05).
#
# The suite also reads this feature's sources as text at the end. Those assertions are the
# structural promises this feature was accepted under - no timer of its own, no subprocess, two
# syscalls on the ordinary sample, the process-table walk confined to the branch that has just
# raised an alarm (measured between that branch's own braces, not from where it opens), and the
# station speaking last through the knock's existing door - and not one of them can be driven from a
# harness: they need a running timer, a live session and a machine actually in trouble.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/hosthealth/main.swift tests/hosthealth/knockchecks.swift \
  Tally/Core/HostHealthLogic.swift \
  Tally/Core/KeystrokeText.swift TallyCLI/HostHealthKnockLogic.swift
"$out"
