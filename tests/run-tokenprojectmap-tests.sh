#!/bin/bash
# Compiles project attribution (Tally/Core/TokenStats/TokenProjectMap.swift over the Rust core,
# rust/crates/core/src/tokenstats/project_map.rs) together with a small assertion harness and runs
# it. No Xcode test target needed; exits non-zero on failure.
#
# The source list is the map's closure: TokenTotals.swift for the pooled row's key, with the
# harness stubbing the one localization call that file makes, plus the host the core calls back
# (AppTokenStatsHost.swift) and the generated bindings. Which directory owns which tokens is
# invisible to the compiler and to a screenshot taken on one machine, so the suite builds its own
# workspace tree in a temp directory and asks the map about it.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=14.0
(cd rust && cargo build --quiet --release --locked -p tally_ffi)
out=$(mktemp -d)/run
swiftc -I rust/include -L rust/target/release -o "$out" tests/tokenprojectmap/main.swift \
  Tally/Core/TokenStats/TokenProjectMap.swift Tally/Core/TokenStats/TokenTotals.swift \
  Tally/Core/TokenStats/AppTokenStatsHost.swift rust/generated/swift/tally_ffi.swift \
  Tally/Core/WorktreeOrigins.swift
"$out"
