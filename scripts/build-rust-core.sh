#!/bin/bash
# Builds rust/ (the tally_ffi static library) for every architecture Xcode is building and
# merges the slices into $BUILT_PRODUCTS_DIR/libtally_ffi.a. Called by the pre-build phase of both
# targets (project.yml); runnable by hand with BUILT_PRODUCTS_DIR (and optionally ARCHS)
# set. Always the release profile: the Rust core is measured against optimized Swift, and a
# debug build of it would be the slower of the two for no reason anyone wants.
set -euo pipefail

# Xcode runs scripts with a minimal PATH that does not include rustup's shims.
export PATH="$HOME/.cargo/bin:$PATH"
ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
OUT="${BUILT_PRODUCTS_DIR:?BUILT_PRODUCTS_DIR is not set}"
WANT_ARCHS="${ARCHS:-$(uname -m)}"
# Matches the CLI's deployment target, so the linker does not warn that the Rust objects were
# built for a newer macOS than the binary they land in.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

command -v cargo > /dev/null \
  || { echo "error: cargo not found; install rustup (https://rustup.rs)" >&2; exit 1; }

slices=()
for arch in $WANT_ARCHS; do
  case "$arch" in
    arm64) triple=aarch64-apple-darwin ;;
    x86_64) triple=x86_64-apple-darwin ;;
    *) echo "error: no Rust target for architecture $arch" >&2; exit 1 ;;
  esac
  # Run inside rust/ so rustup picks up rust/rust-toolchain.toml, not the cwd's toolchain.
  (cd "$ROOT/rust" && cargo build --release --locked -p tally_ffi --target "$triple") \
    || { echo "error: cargo build failed for $triple (first build needs the crates.io index for memchr)" >&2; exit 1; }
  slices+=("$ROOT/rust/target/$triple/release/libtally_ffi.a")
done

mkdir -p "$OUT"
lipo -create "${slices[@]}" -output "$OUT/libtally_ffi.a.partial"
mv -f "$OUT/libtally_ffi.a.partial" "$OUT/libtally_ffi.a"
for arch in $WANT_ARCHS; do
  lipo "$OUT/libtally_ffi.a" -verify_arch "$arch"
done
