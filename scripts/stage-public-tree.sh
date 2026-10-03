#!/bin/bash
# Copies the files git tracks (their working-tree content, so a version bump made just before is
# included) into build/public-src, the tree a public build is made from. Anything untracked,
# including an overlay linked at ./overlay, is absent there by construction, so neither
# Config/Overlay.xcconfig nor project.yml's optional sources can pick it up.
# Prints the staged tree's path.
set -euo pipefail

cd "$(dirname "$0")/.."
SRC=build/public-src
KEEP=build/public-rust-target
mkdir -p build
# Cargo's output survives the wipe so a release does not rebuild the Rust core from nothing.
if [ -d "$SRC/rust/target" ]; then mv "$SRC/rust/target" "$KEEP"; fi
rm -rf "$SRC"
mkdir -p "$SRC"
git ls-files -z | rsync -a --from0 --files-from=- ./ "$SRC/"
if [ -d "$KEEP" ]; then mv "$KEEP" "$SRC/rust/target"; fi
[ ! -e "$SRC/overlay" ] || { echo "staged tree carries an overlay, refusing" >&2; exit 1; }
echo "$SRC"
