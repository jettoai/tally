#!/bin/bash
# PinnedStyle.resolve (Tally/Stores/DisplaySettings.swift): the pin choice read from the current keys,
# the legacy single key migrated once. Foundation only, no Xcode test target. Count assertions with
# `command grep -c '^PASS:'`; exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" Tally/Stores/DisplaySettings.swift tests/pinnedstyle/main.swift
"$out"
