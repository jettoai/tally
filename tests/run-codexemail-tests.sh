#!/bin/bash
# Compiles the two pure rules of the Codex provider with a small assertion harness and runs it:
# the identity reader (Tally/Providers/Codex/CodexIdentity.swift) and why a read came home without
# numbers (CodexReadFailure.swift). Both are Foundation-only, so nothing else comes along; no Xcode
# test target needed. Exits non-zero on failure.
#
# CodexReadFailure is in a file of its own for exactly this reason: the classification is what a
# card's callout says, and the read itself cannot be driven from a harness (it spawns the vendor's
# CLI). Its translation stays in CodexProvider, which is asserted here as source rather than run.
#
# Every fixture the harness reads it wrote itself: no real credential is in the repo, no app-server
# is spawned, and no test here touches this machine's ~/.codex*/auth.json.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/codexemail/main.swift Tally/Providers/Codex/CodexIdentity.swift \
    Tally/Providers/Codex/CodexReadFailure.swift
"$out"
