#!/bin/bash
# Compiles the shared-login rule (Tally/Core/SharedLogin.swift, jettoai/tally#6) with a small
# assertion harness and runs it: which of two config homes signed into one Claude account keeps it,
# and the app wiring around it, read as text. Exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/sharedlogin/main.swift Tally/Core/SharedLogin.swift
"$out"
