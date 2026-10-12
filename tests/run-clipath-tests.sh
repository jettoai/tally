#!/bin/bash
# Issue #8: a CLI installed outside the fixed locations (a custom npm prefix, nvm, fnm, volta) must
# be found through the login shell's PATH, must skip Tally's shim, and must START under a GUI app's
# minimal PATH even though its first line is `#!/usr/bin/env node`.
#
# Hermetic: the binary runs under `env -i` with HOME pointed at a scratch directory, so the login
# shell the default searcher starts reads no rc file of this machine's user, and PATH is the one a
# GUI app gets. The fake `node` is a shell script; no real node or codex is involved.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -o "$work/run" tests/clipath/main.swift \
    Tally/Core/CLISearchPath.swift Tally/Core/CLIRunner.swift Tally/Core/ClaudeStableExecutable.swift
mkdir -p "$work/home" "$work/fixture"
env -i HOME="$work/home" PATH=/usr/bin:/bin "$work/run" "$work/fixture"
