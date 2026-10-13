#!/bin/bash
# Compiles the per-project launch profile (TallyCLI/ProjectPolicy.swift) together with a small
# assertion harness and runs it. No Xcode test target needed; exits non-zero on failure.
#
# The source list is the profile's transitive closure and nothing more: GitRepoRoot.swift for the
# repo identity a profile is keyed by (which is why that resolution does not live in the worktree
# files - this suite would otherwise have to compile the whole worktree subsystem to ask what
# directory it is in), AccountPick/AccountComfort for the pin resolution and the account pick a
# profile steers, and StatusReport/UsageAdvisor for the `status --json` block it publishes.
# ResumePrompt joins that closure through Snapshot.swift, whose unsupervised launcher asks it what
# to hand the exec'd child (`resumePromptSuppression`). AccountBinding/AccountReserveReader are in
# it for the same reason the pick is: these two commands predict a launch, so they can spend a
# personal account's reserve, and the line that says so has to travel in the script they print
# (reservenoticechecks.swift).
#
# ProviderReopen.swift is in it because its precheck predicts this same launch
# (reopenparitychecks.swift); the one SelfUpdate.swift function it names is stubbed in that file.
#
# Uses real git in a temp directory for the key scenarios: which repository a directory belongs to
# is git's answer, and a stub would only assert our own idea of it.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/projectpolicy/main.swift tests/projectpolicy/shellsafetychecks.swift \
  tests/projectpolicy/matcherchecks.swift tests/projectpolicy/exportedhomechecks.swift \
  tests/projectpolicy/reservenoticechecks.swift tests/projectpolicy/deletedcwdchecks.swift \
  tests/projectpolicy/defaultproviderchecks.swift tests/projectpolicy/reopenparitychecks.swift \
  TallyCLI/ProjectPolicy.swift TallyCLI/GitRepoRoot.swift \
  TallyCLI/Snapshot.swift Tally/Core/ClaudeStableExecutable.swift TallyCLI/CodexLaunchArgs.swift TallyCLI/AccountPick.swift TallyCLI/AccountPick+Handoff.swift \
  TallyCLI/AccountBinding.swift TallyCLI/AccountReserveReader.swift Tally/Core/AccountReserve.swift \
  TallyCLI/AccountComfort.swift \
  TallyCLI/ResumePrompt.swift \
  TallyCLI/ProviderExecutable.swift TallyCLI/StatusReport.swift TallyCLI/CodexStartupScreenRecord.swift Tally/Core/HeldOverReset.swift TallyCLI/UsageAdvisor.swift \
  TallyCLI/UsageAdvisorMath.swift \
  TallyCLI/LaunchDir.swift TallyCLI/Quarantine.swift TallyCLI/ProviderReopen.swift
"$out"
