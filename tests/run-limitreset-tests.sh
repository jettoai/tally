#!/bin/bash
# Compiles Claude's weekly session-limit reset - the state machine and the record
# (Tally/Core/LimitReset.swift) plus the transcript matcher (TallyCLI/LimitResetSignals.swift) -
# with a small assertion harness and runs it. Both files are Foundation-only on purpose, so nothing
# else comes along; no Xcode test target needed. Exits non-zero on failure.
#
# THE SUPERVISOR'S OWN DECISION TABLE IS NOT HERE. Which wall spends a reset, what the gates are and
# what a timeout does all run inside a poll tick, whose dependencies are the whole supervisor tree,
# so those live in tests/supervisor/caplimitresetchecks.swift where that tree is already compiled.
# What this suite owns is everything a person could reason about without a session: the sentences,
# the record, the ageing rules, and the two pure tables the panel's control is drawn from.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/limitreset/main.swift tests/limitreset/limitresetchecks.swift \
  Tally/Core/LimitReset.swift TallyCLI/LimitResetSignals.swift
"$out"
