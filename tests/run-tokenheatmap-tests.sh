#!/bin/bash
# Compiles the token activity heatmap's arithmetic (Tally/Core/TokenStats/TokenActivityHeatmap.swift,
# which calls the Rust core through the UniFFI bindings) together with a small assertion harness and
# runs it. No Xcode test target needed; exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=14.0
(cd rust && cargo build --quiet --release --locked -p tally_ffi)
out=$(mktemp -d)/run
swiftc -I rust/include -L rust/target/release -o "$out" tests/tokenheatmap/main.swift \
  Tally/Core/TokenStats/TokenActivityHeatmap.swift rust/generated/swift/tally_ffi.swift
"$out"
