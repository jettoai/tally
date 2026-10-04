#!/bin/bash
# Build phase of the Tally app target, between the link and Xcode's own signing. In Debug it pins
# the main executable's LC_UUID, because macOS local network privacy keys its grant on that UUID
# (Apple TN3179) and the linker changes it on every rebuild, so Tally Dev.app was asked again each
# time. Then it checks what Xcode is about to sign. Release keeps the linker's UUID (crash
# symbolication needs it unique per version), and this asserts it was left alone.
set -euo pipefail
name=ai.jetto.tally.dev
bin="$TARGET_BUILD_DIR/$EXECUTABLE_PATH"
pin="$SRCROOT/scripts/pin-macho-uuid.py"
fail() { echo "error: pin-dev-uuid: $*" >&2; exit 1; }
uuids() { dwarfdump --uuid "$1" | sed -E 's/^UUID: ([^ ]+ \([^)]+\)).*/\1/'; }

expected=$(python3 "$pin" --expected "$bin" "$name")
if [ "$CONFIGURATION" != Debug ]; then
    [ "$(uuids "$bin")" != "$expected" ] || fail "$CONFIGURATION build carries the pinned dev UUID"
    exit 0
fi
python3 "$pin" "$bin" "$name"
actual=$(uuids "$bin")
[ "$actual" = "$expected" ] || fail "LC_UUID is '$actual', expected '$expected'"
id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET_BUILD_DIR/$INFOPLIST_PATH")
[ "$id" = "$name" ] || fail "bundle id is '$id', expected '$name'"
# The signature itself is written after this phase; check the team Xcode will sign with.
[ "$DEVELOPMENT_TEAM" = 87Z993GX39 ] || fail "signing team is '$DEVELOPMENT_TEAM'"
