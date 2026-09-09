#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete Tally/Core/Harness/*.swift TallyCLI/HarnessCommand.swift TallyCLI/HarnessToolsCommand.swift TallyCLI/CodexHookCommand.swift \
    TallyCLI/InboxCommand.swift tests/harness/main.swift -o "$work/tally"
TALLY_HARNESS_TEST_BINARY="$work/tally" python3 -m unittest discover -s tests/harness -p '*checks.py' -v
