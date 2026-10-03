#!/bin/bash
# The token statistics' Rust core (rust/crates/core/src/tokenstats) and the Swift shells over it
# (Tally/Core/TokenStats): the Rust unit tests, the freshness of the committed UniFFI bindings,
# then tests/tokenstats/main.swift compiled with the bindings and the core linked (day arithmetic
# against the core across zones, a whole scan through the bindings, the Swift String rules).
# Count assertions with `command grep -c '^PASS:'`.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=14.0
(cd rust && cargo test --quiet --locked -p tally_core tokenstats && cargo test --quiet --locked -p tally_sys)
scripts/gen-uniffi.sh --check
out=$(mktemp -d)/run
swiftc -I rust/include -L rust/target/release -o "$out" tests/tokenstats/main.swift \
  Tally/Core/TokenStats/TokenTotals.swift Tally/Core/TokenStats/AppTokenStatsHost.swift \
  Tally/Core/TokenStats/TokenActivityHeatmap.swift Tally/Core/WorktreeOrigins.swift \
  rust/generated/swift/tally_ffi.swift
"$out"
