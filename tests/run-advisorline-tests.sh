#!/bin/bash
# Compiles the advisor row's conclusion logic (Tally/Core/AdvisorConclusion.swift) with the usage
# advisor's pure math it reads the verdict from, plus a small assertion harness, and runs it.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/advisorline/main.swift Tally/Core/AdvisorConclusion.swift \
  TallyCLI/UsageAdvisor.swift TallyCLI/UsageAdvisorMath.swift
"$out"
