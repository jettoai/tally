#!/bin/bash
# The Detailed panel's interaction wiring, counted per file against main at ee65eda1
# (tests/panelanchors/main.swift). A source-reading harness: Foundation only, no AppKit and no Xcode
# test target, run from the repo root. Exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/panelanchors/main.swift
"$out"
