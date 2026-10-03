#!/bin/bash
# A dry run of the release assembly: Release builds of the app and the CLI, the CLI copied into the
# bundle, and the overlay bundle check. No Developer ID signing, notarization, Sentry upload,
# 1Password access or push.
# Usage: scripts/release-dry.sh [--with-overlay]
#   default: built from a copy of the git-tracked files (scripts/stage-public-tree.sh) and checked
#            for the overlay's absence, as a public release is.
#   --with-overlay: built in place with the overlay at ./overlay and checked for its presence.
set -euo pipefail

cd "$(dirname "$0")/.."
MODE=public
if [ "${1:-}" = "--with-overlay" ]; then MODE=overlay; shift; fi
mkdir -p build

if [ "$MODE" = overlay ]; then
  echo "==> preflight: overlay (./overlay)"
  [ -f overlay/Overlay.xcconfig ] || { echo "overlay missing at ./overlay" >&2; exit 1; }
  echo "    overlay at $(git -C overlay/ rev-parse --short HEAD)"
  SRC=.
else
  echo "==> preflight: public build (no overlay)"
  rm -f build/overlay-markers
  if [ -s overlay/bundle-markers ]; then cp overlay/bundle-markers build/overlay-markers; fi
  SRC=$(scripts/stage-public-tree.sh)
  echo "    building from $SRC"
fi

export PATH="$HOME/.cargo/bin:$PATH"
xcodegen generate --spec "$SRC/project.yml"

DD="build/dry-dd-$MODE"
xcodebuild build -project "$SRC/Tally.xcodeproj" -scheme Tally -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DD" -quiet
xcodebuild build -project "$SRC/Tally.xcodeproj" -scheme TallyCLI -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DD" -quiet

APP=build/dry/Tally.app
rm -rf build/dry
mkdir -p build/dry
ditto "$DD/Build/Products/Release/Tally.app" "$APP"
# The Swift CLI goes where build-release.sh puts it; the Rust entry in front of it is not built here.
mkdir -p "$APP/Contents/Helpers/swift"
ditto "$DD/Build/Products/Release/tally" "$APP/Contents/Helpers/swift/tally"

if [ "$MODE" = overlay ]; then
  scripts/check-overlay-bundle.sh "$APP" "$APP/Contents/Helpers/swift/tally"
else
  scripts/check-overlay-bundle.sh --absent "$APP" "$APP/Contents/Helpers/swift/tally"
fi
echo "==> done: $APP"
