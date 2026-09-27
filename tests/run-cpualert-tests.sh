#!/bin/bash
# Compiles the CPU watch's pure half (Tally/Core/CPUAlertLogic.swift) with KeystrokeText.swift and
# an assertion harness, and runs it. Foundation only, no Xcode target; exits non-zero on failure.
# The end of the harness reads the monitor, readers and timer sources as text for the structural
# promises a pure harness cannot drive (clock throttle, no timer of its own, the process scan
# confined to the announcing branch, names never argv, every string translated).
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/cpualert/main.swift Tally/Core/CPUAlertLogic.swift Tally/Core/KeystrokeText.swift
"$out"
