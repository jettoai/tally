#!/bin/bash
# Lists what the handoff pins inside an app bundle, one tab-separated line per file, sorted by path.
# One definition for both ends of the MBP handoff: build-release.sh --handoff records these lists,
# sign-and-notarize.sh recomputes them and refuses on any difference.
#   handoff-machos.sh <Tally.app>           every Mach-O: relative path, sha256, lipo archs
#   handoff-machos.sh --agents <Tally.app>  every file in the bundle directory TALLY_HANDOFF_AGENT_DIR
#                                           names (an overlay's helper agents, not all Mach-O; the
#                                           overlay's handoff.env supplies it, an exported value wins):
#                                           relative path, sha256. Nothing is listed when it is unset.
set -euo pipefail
AGENTS=0
if [ "${1:-}" = "--agents" ]; then AGENTS=1; shift; fi
# shellcheck disable=SC1091
[ ! -f "$(dirname "$0")/../overlay/handoff.env" ] || . "$(dirname "$0")/../overlay/handoff.env"
cd "${1:?usage: handoff-machos.sh [--agents] <Tally.app>}"
if [ "$AGENTS" = 1 ]; then
  [ -n "${TALLY_HANDOFF_AGENT_DIR:-}" ] && [ -d "$TALLY_HANDOFF_AGENT_DIR" ] || exit 0
  find "$TALLY_HANDOFF_AGENT_DIR" -type f | LC_ALL=C sort |
    while IFS= read -r f; do printf '%s\t%s\n' "$f" "$(shasum -a 256 "$f" | cut -d' ' -f1)"; done
  exit 0
fi
find . -type f -exec sh -c 'file -b "$1" | grep -q "^Mach-O"' _ {} \; -print | LC_ALL=C sort |
  while IFS= read -r f; do
    archs=$(lipo -archs "$f" | tr ' ' '\n' | LC_ALL=C sort | paste -sd, -)
    printf '%s\t%s\t%s\n' "${f#./}" "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$archs"
  done
