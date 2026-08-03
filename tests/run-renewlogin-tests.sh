#!/bin/bash
# Compiles the "Renew login" background flow (Tally/Core/RenewLoginCommand.swift +
# Tally/Core/RenewLoginRunner.swift) with a small assertion harness and runs it. Both files are
# Foundation-only, so nothing else comes along; no Xcode test target needed. Exits non-zero on
# failure.
#
# The runner is driven against stub CLIs the harness writes itself, never a real provider login.
# Two of the pure checks shell out to /bin/sh and osascript, which is the point: the shell quoting
# and the AppleScript literal are only correct if the interpreters that unquote them say so.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/renewlogin/main.swift \
  Tally/Core/RenewLoginCommand.swift Tally/Core/RenewLoginRunner.swift
"$out"
