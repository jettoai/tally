#!/bin/bash
# Compiles the dual-dry notification's pure tier/dedup logic (Tally/Core/DryPoolLogic.swift)
# together with a small assertion harness and runs it. DryPoolLogic depends only on Foundation,
# so no Xcode target is needed; exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/dry-notify/main.swift Tally/Core/DryPoolLogic.swift
"$out"
