#!/bin/bash
# Compiles the in-app Claude Code install (Tally/Core/ClaudeInstall.swift rules and
# Tally/Core/ClaudeInstallRunner.swift process driver) with a small assertion harness and runs it.
# The runner is driven against stub scripts the harness writes itself (bash one-liners); nothing is
# downloaded or installed. Exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/claudeinstall/main.swift \
  Tally/Core/ClaudeInstall.swift Tally/Core/ClaudeInstallRunner.swift Tally/Core/RenewLoginCommand.swift
"$out"
