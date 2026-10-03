#!/bin/bash
# A dry run of the release assembly: Release builds of the app and the CLI with the private
# overlay at ./overlay, the CLI copied into the bundle, and the overlay bundle check. No Developer
# ID signing, notarization, Sentry upload, 1Password access or push.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> preflight: private overlay (./overlay)"
[ -f overlay/Overlay.xcconfig ] \
  || { echo "overlay missing at ./overlay - a release without it drops features installed copies have" >&2; exit 1; }
echo "    overlay at $(git -C overlay/ rev-parse --short HEAD)"

export PATH="$HOME/.cargo/bin:$PATH"
xcodegen generate

DD=build/dry-dd
xcodebuild build -project Tally.xcodeproj -scheme Tally -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DD" -quiet
xcodebuild build -project Tally.xcodeproj -scheme TallyCLI -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DD" -quiet

APP=build/dry/Tally.app
rm -rf build/dry
mkdir -p build/dry
ditto "$DD/Build/Products/Release/Tally.app" "$APP"
# The Swift CLI goes where build-release.sh puts it; the Rust entry in front of it is not built here.
mkdir -p "$APP/Contents/Helpers/swift"
ditto "$DD/Build/Products/Release/tally" "$APP/Contents/Helpers/swift/tally"

scripts/check-overlay-bundle.sh "$APP" "$APP/Contents/Helpers/swift/tally"
echo "==> done: $APP"
