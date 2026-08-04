#!/bin/bash
# Compiles the two rules an account row runs on - its login state
# (Tally/Core/AccountSignIn.swift) and its identity (Tally/Core/AccountIdentity.swift) - with a
# small assertion harness and runs it. Both are Foundation-only, so nothing else comes along; no
# Xcode test target needed. Exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/accountrow/main.swift \
  Tally/Core/AccountSignIn.swift Tally/Core/AccountIdentity.swift
"$out"
