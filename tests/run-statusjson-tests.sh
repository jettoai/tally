#!/bin/bash
# Compiles the CLI's `status --json` contract (TallyCLI/Snapshot.swift) together with a small
# assertion harness and runs it. No Xcode test target needed; exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/statusjson/main.swift TallyCLI/Snapshot.swift TallyCLI/StatusReport.swift \
    TallyCLI/UsageAdvisor.swift
"$out"
