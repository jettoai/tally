#!/bin/bash
# Compiles the Codex identity reader (Tally/Providers/Codex/CodexIdentity.swift) with a small
# assertion harness and runs it. The file is Foundation-only, so nothing else comes along; no Xcode
# test target needed. Exits non-zero on failure.
#
# Every fixture the harness reads it wrote itself: no real credential is in the repo, no app-server
# is spawned, and no test here touches this machine's ~/.codex*/auth.json.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/codexemail/main.swift Tally/Providers/Codex/CodexIdentity.swift
"$out"
