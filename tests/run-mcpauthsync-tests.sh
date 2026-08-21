#!/bin/bash
# Compiles the MCP authorization merge (TallyCLI/MCPAuthMerge.swift) together with a small assertion
# harness and runs it. No Xcode target is needed; exits non-zero on failure.
#
# ONE SOURCE FILE, and that is the point of the split it reflects: every rule this feature has about
# what may be copied, what supersedes what, and what must survive a rewrite lives in that file with
# no Keychain and no filesystem behind it, so the suite states the decision rather than a fixture of
# the machine it runs on. MCPAuthSync.swift is the other half (which items to read, where to write,
# what to restore when a verification fails) and is asserted against the real Keychain by hand,
# because a suite cannot create another program's item to be refused by.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/mcpauthsync/main.swift TallyCLI/MCPAuthMerge.swift
"$out"
