#!/bin/bash
# Compiles the pre-spawn check (TallyCLI/PreSpawnHook.swift, self-contained) with its assertion
# harness and runs it against a real /bin/sh. Exits non-zero on failure. Count assertions with
# `command grep -c '^PASS:'` (see run-supervisor-tests.sh for why it is anchored).
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/prespawn/main.swift TallyCLI/PreSpawnHook.swift
"$out"
