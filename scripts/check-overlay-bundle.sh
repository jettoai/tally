#!/bin/bash
# Checks that an assembled Tally.app carries the private overlay linked at ./overlay.
# usage: scripts/check-overlay-bundle.sh <Tally.app> <tally CLI binary>
#
# The strings to look for come from the overlay itself (overlay/bundle-markers: lines of
# `cli:<text>` or `app:<text>`), so this public script names nothing the overlay adds. Every CLI
# slice must carry every cli marker, the app binary every app marker, and the app's Info.plist a
# non-empty NSLocalNetworkUsageDescription. Any miss exits 1.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="${1:?usage: check-overlay-bundle.sh <Tally.app> <tally CLI>}"
CLI="${2:?usage: check-overlay-bundle.sh <Tally.app> <tally CLI>}"
MARKERS=overlay/bundle-markers
[ -s "$MARKERS" ] || { echo "no $MARKERS - is the overlay linked at ./overlay?" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

found=0
for arch in $(lipo -archs "$CLI"); do
  lipo "$CLI" -thin "$arch" -output "$work/cli-$arch" 2> /dev/null || cp "$CLI" "$work/cli-$arch"
  strings "$work/cli-$arch" > "$work/cli-$arch.txt"
done
strings "$APP/Contents/MacOS/Tally" > "$work/app.txt"

while IFS= read -r line; do
  case "$line" in
    cli:*)
      for txt in "$work"/cli-*.txt; do
        command grep -qF -- "${line#cli:}" "$txt" \
          || { echo "overlay marker missing from CLI slice ${txt##*/}: ${line#cli:}" >&2; exit 1; }
      done
      found=$((found + 1)) ;;
    app:*)
      command grep -qF -- "${line#app:}" "$work/app.txt" \
        || { echo "overlay marker missing from the app binary: ${line#app:}" >&2; exit 1; }
      found=$((found + 1)) ;;
  esac
done < "$MARKERS"
[ "$found" -gt 0 ] || { echo "$MARKERS lists no markers" >&2; exit 1; }

usage=$(/usr/libexec/PlistBuddy -c 'Print NSLocalNetworkUsageDescription' "$APP/Contents/Info.plist" 2> /dev/null || true)
[ -n "$usage" ] || { echo "NSLocalNetworkUsageDescription is empty in $APP" >&2; exit 1; }

echo "    overlay present in bundle ($found markers)"
