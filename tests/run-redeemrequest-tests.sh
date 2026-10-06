#!/bin/bash
# Compiles the `tally redeem` request channel (TallyCLI/RedeemRequest.swift, Foundation-only) with a
# small assertion harness and runs it. No credit is ever spent. Exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/redeemrequest/main.swift TallyCLI/RedeemRequest.swift
"$out"
