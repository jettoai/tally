#!/bin/bash
# Compiles the MCP authorization merge (TallyCLI/MCPAuthMerge.swift) and the freshness gate in front
# of it (TallyCLI/MCPSeedGate.swift) together with a small assertion harness and runs it. No Xcode
# target is needed; exits non-zero on failure.
#
# ONE SOURCE FILE OF RULES, and that is the point of the split it reflects: every rule this feature
# has about what may be copied, what supersedes what, which item a home may be addressed by, and what
# must survive a rewrite lives in that file with no Keychain and no filesystem behind it, so the
# suite states the decision rather than a fixture of the machine it runs on. MCPAuthSync.swift is the
# other half (which items to read, in what order, where to write, what to restore when a verification
# fails) and is asserted against the real Keychain by hand, because a suite cannot create another
# program's item to be refused by - and asserted here, off its source, for the parts that are an
# ORDER rather than a value.
#
# The two files beside it are the name rules it defers to (`claudeKeychainService`,
# `claudeStateFile`): leaves with nothing behind them either, compiled in rather than restated,
# because the whole point of the guard being tested is that it agrees with them about one directory
# and refuses to guess about the rest.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/mcpauthsync/main.swift tests/mcpauthsync/gate.swift \
    tests/mcpauthsync/wiring.swift \
    TallyCLI/MCPAuthMerge.swift TallyCLI/MCPSeedGate.swift \
    Tally/Core/Keychain/ClaudeKeychainService.swift Tally/Core/ClaudeStatePath.swift
"$out"
