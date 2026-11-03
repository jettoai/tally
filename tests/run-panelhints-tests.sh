#!/bin/bash
# Compiles the panel's one-time nudge rules (Tally/Core/PanelHints.swift, Foundation-only) with a
# small assertion harness and runs it. No Xcode test target needed; exits non-zero on failure.
# Reads app sources as text for the orderings and gates that matter (see main.swift).
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/panelhints/main.swift Tally/Core/PanelHints.swift
"$out"
