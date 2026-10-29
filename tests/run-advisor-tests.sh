#!/bin/bash
# Compiles the usage advisor's pure math (TallyCLI/UsageAdvisor.swift and its arithmetic half,
# TallyCLI/UsageAdvisorMath.swift - one unit split only for file size) together with a small
# assertion harness and runs it. No Xcode test target needed; exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/advisor/main.swift TallyCLI/UsageAdvisor.swift \
  TallyCLI/UsageAdvisorMath.swift
"$out"
