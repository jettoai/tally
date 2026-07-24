#!/bin/bash
# Compiles the CLI's worktree logic (TallyCLI/Worktree.swift) together with a small assertion
# harness and runs it. Worktree.swift depends only on Snapshot.swift, so no Xcode target is
# needed; exits non-zero on failure. Uses real git and a temp filesystem for the create/link
# scenarios (see the five groups in docs/specs/changes/worktree-launch/design.md).
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/worktree/main.swift TallyCLI/Worktree.swift TallyCLI/Snapshot.swift
"$out"
