#!/bin/bash
# Source-text checks that the panel's and the menu bar's per-redraw waste stays gone (Sentry
# TALLY-7Z, TALLY-82, TALLY-37, TALLY-23). Exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/renderwaste/main.swift
"$out"
