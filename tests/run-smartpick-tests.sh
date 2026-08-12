#!/bin/bash
# Compiles the CLI's burn-rate account pick (TallyCLI/AccountPick.swift) together with a small
# assertion harness and runs it. No Xcode test target needed; exits non-zero on failure.
#
# Two harness files: main.swift is the scoring and the picks built on it, launchchecks.swift is the
# plumbing a launch runs through once an account is chosen (start-mode injection, resolving a manual
# pin). Split for file size, and the seam is "which account" versus "launched how".
#
# ResumePrompt is in the source list because the unsupervised launcher in Snapshot.swift asks it
# what to hand the exec'd child (`resumePromptSuppression`).
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/smartpick/main.swift tests/smartpick/launchchecks.swift \
  TallyCLI/Snapshot.swift TallyCLI/AccountPick.swift \
  TallyCLI/ResumePrompt.swift \
  TallyCLI/ProviderExecutable.swift TallyCLI/AccountComfort.swift
"$out"
