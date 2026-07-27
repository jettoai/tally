#!/bin/bash
# Compiles the idle self-install rule (Tally/Core/IdleInstall.swift) with a small assertion harness
# and runs it. The file is Foundation-only, so nothing else comes along; no Xcode test target
# needed. Exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/idleinstall/main.swift Tally/Core/IdleInstall.swift
"$out"
