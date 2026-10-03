#!/bin/bash
# Regenerates the UniFFI bindings of the Rust core: rust/generated/swift/tally_ffi.swift (compiled
# into the app target, project.yml) and rust/include/tally_uniffi.h (part of the TallyRustCore
# module, rust/include/module.modulemap). Both are committed; run this after changing any
# `#[uniffi::export]` in rust/crates/ffi. With --check it writes nothing and exits 1 when the
# committed files differ from what the current Rust would generate (scripts/build-release.sh and
# tests/run-tokenstats-tests.sh run that, because stale bindings fail at the first call at
# runtime). Module and header names come from rust/crates/ffi/uniffi.toml, which library mode
# finds on its own.
set -euo pipefail

export PATH="$HOME/.cargo/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
check=0
[ "${1:-}" = "--check" ] && check=1

out="$(mktemp -d)"
(cd "$ROOT/rust" && cargo build --quiet --release --locked -p tally_ffi \
  && cargo run --quiet --release --locked -p uniffi-bindgen -- generate \
    --library target/release/libtally_ffi.a --language swift --out-dir "$out" --no-format)
# The repo allows no em dash anywhere (README, comments, strings). One comes from a UniFFI template
# comment, so rewrite it before comparing or copying; --check then compares like for like.
sed -i '' $'s/ \xe2\x80\x94/,/g' "$out/tally_ffi.swift"

swift_file="$ROOT/rust/generated/swift/tally_ffi.swift"
header_file="$ROOT/rust/include/tally_uniffi.h"
if [ "$check" = 1 ]; then
  if cmp -s "$out/tally_ffi.swift" "$swift_file" && cmp -s "$out/tally_uniffi.h" "$header_file"; then
    echo "uniffi bindings are current"
    exit 0
  fi
  echo "uniffi bindings are stale: run scripts/gen-uniffi.sh" >&2
  exit 1
fi
mkdir -p "$(dirname "$swift_file")"
cp "$out/tally_ffi.swift" "$swift_file"
cp "$out/tally_uniffi.h" "$header_file"
echo "wrote $swift_file and $header_file"
