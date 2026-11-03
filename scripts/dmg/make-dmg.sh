#!/bin/bash
# Builds the Tally disk image with its installer window (background, icon positions and the
# Applications shortcut) using dmgbuild, which writes the window layout without driving Finder.
# Usage: scripts/dmg/make-dmg.sh <Tally.app> <output.dmg>
# Uses dmgbuild from PATH when there is one; otherwise installs the pinned version below into
# build/dmgbuild-venv (TALLY_DMGBUILD_VENV overrides) once and reuses it. With neither an installed
# dmgbuild nor network access this fails: a plain hdiutil image would open with no layout at all.
set -euo pipefail

die() { echo "make-dmg: $*" >&2; exit 1; }
[ $# -eq 2 ] || die "usage: $0 <Tally.app> <output.dmg>"
[ -d "$1/Contents" ] || die "$1 is not an app bundle"
APP=$(cd "$1" && pwd)
mkdir -p "$(dirname "$2")"
OUT="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
[ -s "$HERE/background.tiff" ] || die "missing $HERE/background.tiff"
# dmgbuild hides the .app extension with SetFile and ignores its exit status.
xcrun --find SetFile > /dev/null 2>&1 || die "SetFile not found; install the Xcode command line tools"

PIN="dmgbuild==1.6.7"
VENV="${TALLY_DMGBUILD_VENV:-$ROOT/build/dmgbuild-venv}"

find_python() {
  local py
  for py in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
    command -v "$py" > /dev/null 2>&1 || continue
    if "$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2> /dev/null; then
      command -v "$py"; return 0
    fi
  done
  return 1
}

if command -v dmgbuild > /dev/null 2>&1; then
  DMGBUILD=$(command -v dmgbuild)
elif [ -x "$VENV/bin/dmgbuild" ] && [ "$(cat "$VENV/.tally-pin" 2> /dev/null)" = "$PIN" ]; then
  DMGBUILD="$VENV/bin/dmgbuild"
else
  PY=$(find_python) || die "dmgbuild needs Python 3.10 or newer and none is on PATH (/usr/bin/python3 is older)"
  # A virtualenv cannot be moved after creation (its scripts carry absolute paths), so it is built
  # in place and the pin stamp, written last, marks it complete.
  "$PY" -m venv --clear "$VENV" || die "could not create a virtualenv at $VENV with $PY"
  printf '%s\n' \
    "dmgbuild==1.6.7 --hash=sha256:37ee5771c377beb3203d9164aae8046ffed8531c06edf9227f5788b3c599b1bf" \
    "ds_store==1.3.3 --hash=sha256:b92a371efbf1b4ccce2a04d1ed13fceacc4736c81ba09cf5aefb74c088160a35" \
    "mac_alias==2.2.3 --hash=sha256:7362b521d2132ef92f606a37abfed5fcd849ceb2f28b6f9743e014b02af92f0d" \
    > "$VENV/requirements.txt"
  "$VENV/bin/python" -m pip install --quiet --no-input --disable-pip-version-check \
      --timeout 15 --retries 1 --require-hashes --only-binary=:all: -r "$VENV/requirements.txt" \
    || die "could not install $PIN from PyPI into $VENV (offline?). Connect once, or put dmgbuild on PATH. Not falling back to hdiutil: that image would open with no window layout."
  echo "$PIN" > "$VENV/.tally-pin"
  DMGBUILD="$VENV/bin/dmgbuild"
fi

echo "make-dmg: using $DMGBUILD"
"$DMGBUILD" --no-hidpi --detach-retries 30 -s "$HERE/settings.py" \
  -D app="$APP" -D background="$HERE/background.tiff" Tally "$OUT"
[ -s "$OUT" ] || die "dmgbuild finished but $OUT is missing"
