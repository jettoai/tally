#!/bin/bash
# Compiles the surface height cap (Tally/Views/ScreenFitStack.swift) together with a small assertion
# harness and runs it. No Xcode test target needed; exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/screenfit/main.swift Tally/Views/ScreenFitStack.swift Tally/Core/ResizeAnchor.swift
"$out"
