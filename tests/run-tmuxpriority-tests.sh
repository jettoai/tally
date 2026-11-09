#!/bin/bash
# Compiles the tmux priority guard's rules and reader (Tally/Core/TmuxPriority{Logic,Readers}.swift,
# Foundation and Darwin only) with an assertion harness and runs it. Read-only: the harness asks
# `ps` about this process's parent and about any tmux server of the current user, and starts and
# signals nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/tmuxpriority/main.swift \
  Tally/Core/TmuxPriorityLogic.swift Tally/Core/TmuxPriorityReaders.swift
"$out"
