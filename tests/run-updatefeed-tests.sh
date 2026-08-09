#!/bin/bash
# Compiles the update feed reader and the install plan built on it (Tally/Core/UpdateFeed.swift)
# with a small assertion harness and runs it. The file is Foundation-only, so nothing else comes
# along; no Xcode test target needed. Exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/updatefeed/main.swift Tally/Core/UpdateFeed.swift
"$out"
