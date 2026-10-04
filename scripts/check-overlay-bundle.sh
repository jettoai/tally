#!/bin/bash
# Checks an assembled Tally.app for the private overlay, in either direction.
# usage: scripts/check-overlay-bundle.sh [--absent] <Tally.app> <tally CLI binary>...
#
# The strings to look for come from the overlay itself (lines of `cli:<text>` or `app:<text>`), so
# this public script names nothing the overlay adds. A `file:<path>` line names a file inside the
# bundle, relative to Tally.app, that must exist (present) or must not (absent).
#
# Present (default): the overlay linked at ./overlay lists the markers (overlay/bundle-markers).
# Every CLI slice must carry every cli marker, the app binary every app marker, the Info.plist a
# non-empty NSLocalNetworkUsageDescription, and SUFeedURL an https feed other than the public one.
#
# Absent (--absent): every marker the overlay lists (build/overlay-markers, copied before the
# public build) must be missing from every CLI slice and the app binary,
# NSLocalNetworkUsageDescription must be empty or missing, and SUFeedURL must be the public feed.
# With no marker list here the plist checks stand alone, because the public build is
# made from a tree that cannot hold an overlay (scripts/stage-public-tree.sh).
# Any miss exits 1.
set -euo pipefail

cd "$(dirname "$0")/.."
PUBLIC_FEED=https://github.com/jettoai/tally/releases/latest/download/appcast.xml
USAGE="usage: check-overlay-bundle.sh [--absent] <Tally.app> <tally CLI>..."
MODE=present
if [ "${1:-}" = --absent ]; then MODE=absent; shift; fi
APP="${1:?$USAGE}"
shift
[ "$#" -gt 0 ] || { echo "$USAGE" >&2; exit 1; }
CLIS=("$@")

if [ "$MODE" = present ]; then
  MARKERS=overlay/bundle-markers
  [ -s "$MARKERS" ] || { echo "no $MARKERS - is the overlay linked at ./overlay?" >&2; exit 1; }
else
  MARKERS=build/overlay-markers
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

i=0
for cli in "${CLIS[@]}"; do
  i=$((i + 1))
  for arch in $(lipo -archs "$cli"); do
    lipo "$cli" -thin "$arch" -output "$work/cli$i-$arch" 2> /dev/null || cp "$cli" "$work/cli$i-$arch"
    strings "$work/cli$i-$arch" > "$work/cli$i-$arch.txt"
  done
done
strings "$APP/Contents/MacOS/Tally" > "$work/app.txt"

# expect <text> <strings file> <where>: the text is there when present, missing when absent.
expect() {
  if command grep -qF -- "$1" "$2"; then
    [ "$MODE" = present ] || { echo "overlay marker found in $3: $1" >&2; exit 1; }
  else
    [ "$MODE" = absent ] || { echo "overlay marker missing from $3: $1" >&2; exit 1; }
  fi
}

found=0
if [ -s "$MARKERS" ]; then
  while IFS= read -r line; do
    case "$line" in
      cli:*)
        for txt in "$work"/cli*.txt; do
          expect "${line#cli:}" "$txt" "CLI slice ${txt##*/}"
        done
        found=$((found + 1)) ;;
      app:*)
        expect "${line#app:}" "$work/app.txt" "the app binary"
        found=$((found + 1)) ;;
      file:*)
        if [ -e "$APP/${line#file:}" ]; then
          [ "$MODE" = present ] || { echo "overlay file found in the bundle: ${line#file:}" >&2; exit 1; }
        else
          [ "$MODE" = absent ] || { echo "overlay file missing from the bundle: ${line#file:}" >&2; exit 1; }
        fi
        found=$((found + 1)) ;;
    esac
  done < "$MARKERS"
fi

plist() { /usr/libexec/PlistBuddy -c "Print $1" "$APP/Contents/Info.plist" 2> /dev/null || true; }
usage=$(plist NSLocalNetworkUsageDescription)
feed=$(plist SUFeedURL)

if [ "$MODE" = present ]; then
  [ "$found" -gt 0 ] || { echo "$MARKERS lists no markers" >&2; exit 1; }
  [ -n "$usage" ] || { echo "NSLocalNetworkUsageDescription is empty in $APP" >&2; exit 1; }
  case "$feed" in https://*) ;; *) echo "SUFeedURL is not an https feed: '$feed'" >&2; exit 1 ;; esac
  [ "$feed" != "$PUBLIC_FEED" ] \
    || { echo "SUFeedURL is the public feed; an overlay build must follow its own" >&2; exit 1; }
  echo "    overlay present in bundle ($found markers, feed $feed)"
else
  [ -z "$usage" ] || { echo "NSLocalNetworkUsageDescription is set in $APP: $usage" >&2; exit 1; }
  [ "$feed" = "$PUBLIC_FEED" ] || { echo "SUFeedURL is not the public feed: '$feed'" >&2; exit 1; }
  if [ "$found" -gt 0 ]; then
    echo "    overlay absent from bundle ($found markers checked, public feed)"
  else
    echo "    no marker list on this tree; checking plist and feed only (public feed, no local network text)"
  fi
fi
