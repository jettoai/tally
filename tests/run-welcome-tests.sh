#!/bin/bash
# Compiles the first-run welcome window's rules (Tally/Core/WelcomeFlow.swift, Foundation-only) with
# a small assertion harness and runs it. No Xcode test target needed; exits non-zero on failure.
# WelcomeCopy.swift is compiled against a pass-through L. Reads app sources as text for the orderings that matter (see main.swift).
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/welcome/main.swift Tally/Core/WelcomeFlow.swift Tally/Core/WelcomeCopy.swift
"$out"
