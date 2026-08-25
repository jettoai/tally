#!/bin/bash
# Compiles the CLI's burn-rate account pick (TallyCLI/AccountPick.swift) together with a small
# assertion harness and runs it. No Xcode test target needed; exits non-zero on failure.
#
# Three harness files: main.swift is the scoring and the picks built on it, launchchecks.swift is the
# plumbing a launch runs through once an account is chosen (start-mode injection, resolving a manual
# pin), reservechecks.swift the personal account's reserve - the state file it is read from and the
# one subtraction it becomes. Split for file size, and the seams are "which account" versus
# "launched how" versus "how much of it is Tally's to spend".
#
# ResumePrompt is in the source list because the unsupervised launcher in Snapshot.swift asks it
# what to hand the exec'd child (`resumePromptSuppression`).
#
# LaunchResume/LastConversation are which CONVERSATION a launch picks up, which is the other half of
# the start mode: the injection in Snapshot.swift is now `--resume <id>` and those two decide the id.
# OpenTurn comes with them for `transcriptTail` (the half of a transcript read they share with the
# supervisor) and TranscriptSignals for the two smallest readings on that track, a line's timestamp
# and whether a string can name a transcript at all. None of them reaches the supervisor, which is
# what keeps this suite compiling a launch rather than a fleet.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/smartpick/main.swift tests/smartpick/launchchecks.swift \
  tests/smartpick/conversationchecks.swift tests/smartpick/reservechecks.swift \
  TallyCLI/Snapshot.swift TallyCLI/AccountPick.swift \
  TallyCLI/LaunchResume.swift TallyCLI/LastConversation.swift \
  TallyCLI/OpenTurn.swift TallyCLI/TranscriptSignals.swift \
  TallyCLI/AccountBinding.swift TallyCLI/AccountReserveReader.swift Tally/Core/AccountReserve.swift \
  Tally/Core/ArtifactHookContract.swift \
  TallyCLI/ResumePrompt.swift \
  TallyCLI/ProviderExecutable.swift TallyCLI/AccountComfort.swift
"$out"
