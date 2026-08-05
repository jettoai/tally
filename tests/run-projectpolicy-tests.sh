#!/bin/bash
# Compiles the per-project launch profile (TallyCLI/ProjectPolicy.swift) together with a small
# assertion harness and runs it. No Xcode test target needed; exits non-zero on failure.
#
# The source list is the profile's transitive closure and nothing more: GitRepoRoot.swift for the
# repo identity a profile is keyed by (which is why that resolution does not live in the worktree
# files - this suite would otherwise have to compile the whole worktree subsystem to ask what
# directory it is in), AccountPick/AccountComfort for the pin resolution and the account pick a
# profile steers, and StatusReport/UsageAdvisor for the `status --json` block it publishes.
#
# Uses real git in a temp directory for the key scenarios: which repository a directory belongs to
# is git's answer, and a stub would only assert our own idea of it.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/projectpolicy/main.swift \
  TallyCLI/ProjectPolicy.swift TallyCLI/GitRepoRoot.swift \
  TallyCLI/Snapshot.swift TallyCLI/AccountPick.swift TallyCLI/AccountComfort.swift \
  TallyCLI/ProviderExecutable.swift TallyCLI/StatusReport.swift TallyCLI/UsageAdvisor.swift
"$out"
