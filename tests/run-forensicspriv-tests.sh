#!/bin/bash
# Compiles the root evidence helper's pure half (ProcessForensicsPrivilege, ProcessForensicsSetup,
# AdminShell) and the `tally forensics` request channel (TallyCLI/ForensicsRequest.swift) with an
# assertion harness and runs it. It never runs sudo, never raises a password window and writes no
# root file: the helper's script is run by /bin/sh with fake tools, the install script with a fake
# `visudo` and temp paths, and the rule text is checked by the real `visudo -cf` (which needs no root).
# Foundation only, no Xcode target; exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/forensicspriv/main.swift Tally/Core/ProcessForensicsPrivilege.swift \
  Tally/Core/ProcessForensicsSetup.swift Tally/Core/AdminShell.swift TallyCLI/ForensicsRequest.swift
"$out"
