#!/bin/bash
# scripts/pin-macho-uuid.py and the build phase around it (scripts/pin-dev-uuid.sh) against two
# universal binaries compiled here from different sources: their linker UUIDs differ, after the
# pin every slice of both carries the same derived UUID, and the phase's own checks fail a build
# whose pin did not land, whose bundle id or team is wrong, or a Release build that carries it.
# Count assertions with `command grep -c '^PASS:'`.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
name=ai.jetto.tally.dev
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
uuids() { dwarfdump --uuid "$1" | sed -E 's/^UUID: ([^ ]+ \([^)]+\)).*/\1/'; }

for v in 1 2; do
    printf 'int main(void) { return %s; }\n' "$v" > "$work/m$v.c"
    clang -arch arm64 -arch x86_64 -o "$work/m$v" "$work/m$v.c"
    cp "$work/m$v" "$work/m$v.orig"
done
[ "$(uuids "$work/m1")" != "$(uuids "$work/m2")" ] && pass "linker UUIDs differ before" || fail "linker UUIDs differ before"

expected=$(python3 scripts/pin-macho-uuid.py --expected "$work/m1" "$name")
want="$(python3 -c 'import uuid; print(str(uuid.uuid5(uuid.NAMESPACE_DNS, "ai.jetto.tally.dev/x86_64")).upper())') (x86_64)"
printf '%s\n' "$expected" | command grep -qxF "$want" && pass "expected UUID is uuid5 of name/arch" || fail "expected UUID is uuid5 of name/arch"
python3 scripts/pin-macho-uuid.py "$work/m1" "$name"
python3 scripts/pin-macho-uuid.py "$work/m2" "$name"
[ "$(printf '%s\n' "$expected" | wc -l)" -eq 2 ] && [ "$(uuids "$work/m1")" = "$expected" ] && [ "$(uuids "$work/m2")" = "$expected" ] \
    && pass "every slice of both pinned to the same UUID" || fail "every slice of both pinned to the same UUID"

# The build phase, driven with the variables Xcode gives it.
app="$work/Fake.app/Contents"
mkdir -p "$app/MacOS"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $name" "$app/Info.plist" >/dev/null
phase() { # <configuration> <srcroot> [bundle id] [team]
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${3:-$name}" "$app/Info.plist"
    env TARGET_BUILD_DIR="$work" EXECUTABLE_PATH=Fake.app/Contents/MacOS/Fake INFOPLIST_PATH=Fake.app/Contents/Info.plist \
        CONFIGURATION="$1" SRCROOT="$2" DEVELOPMENT_TEAM="${4:-87Z993GX39}" TALLY_DEV_BUNDLE_IDENTIFIER="${DEV_ID:-$name}" "$root/scripts/pin-dev-uuid.sh" >/dev/null 2>"$work/err"
}
refused() { command grep -qF "$1" "$work/err"; } # the refusal names its own reason
fresh() { cp "$work/m1.orig" "$app/MacOS/Fake"; }

fresh; phase Debug "$root" && [ "$(uuids "$app/MacOS/Fake")" = "$expected" ] && pass "Debug phase pins" || fail "Debug phase pins"
fresh; before=$(uuids "$app/MacOS/Fake")
phase Release "$root" && [ "$(uuids "$app/MacOS/Fake")" = "$before" ] && pass "Release phase leaves the linker UUID" || fail "Release phase leaves the linker UUID"
cp "$work/m1" "$app/MacOS/Fake"
! phase Release "$root" && refused "carries the pinned dev UUID" && pass "Release phase refuses a pinned binary" || fail "Release phase refuses a pinned binary"
fresh; ! phase Debug "$root" ai.jetto.tally && refused "bundle id is" && pass "Debug phase refuses a wrong bundle id" || fail "Debug phase refuses a wrong bundle id"
fresh; ! phase Debug "$root" "$name" XXXXXXXXXX && refused "signing team is" && pass "Debug phase refuses a wrong team" || fail "Debug phase refuses a wrong team"
# An overlay's own dev id pins to its own UUID; the id check and the .dev suffix gate follow it.
pro=ai.jetto.tally.pro.dev
pro_expected=$(python3 scripts/pin-macho-uuid.py --expected "$work/m1" "$pro")
fresh; DEV_ID=$pro phase Debug "$root" "$pro" && [ "$(uuids "$app/MacOS/Fake")" = "$pro_expected" ] && [ "$pro_expected" != "$expected" ] \
    && pass "Debug phase pins an overlay dev id to its own UUID" || fail "Debug phase pins an overlay dev id to its own UUID"
fresh; ! DEV_ID=$pro phase Debug "$root" "$name" && refused "bundle id is" && pass "Debug phase refuses an id that differs from the dev id" || fail "Debug phase refuses an id that differs from the dev id"
fresh; ! DEV_ID=ai.jetto.tally.dev.pro phase Debug "$root" ai.jetto.tally.dev.pro && refused "must end in .dev" \
    && pass "Debug phase refuses a dev id without the .dev suffix" || fail "Debug phase refuses a dev id without the .dev suffix"
fresh; /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $name" "$app/Info.plist"
! env -u TALLY_DEV_BUNDLE_IDENTIFIER TARGET_BUILD_DIR="$work" EXECUTABLE_PATH=Fake.app/Contents/MacOS/Fake INFOPLIST_PATH=Fake.app/Contents/Info.plist \
    CONFIGURATION=Debug SRCROOT="$root" DEVELOPMENT_TEAM=87Z993GX39 "$root/scripts/pin-dev-uuid.sh" >/dev/null 2>"$work/err" \
    && pass "phase refuses when Xcode did not set the dev id" || fail "phase refuses when Xcode did not set the dev id"
# A pinner whose rewrite does nothing: only the phase's UUID comparison can catch it.
mkdir -p "$work/noop/scripts"
sed 's/data\[at:at + 16\] = pinned.bytes/pass/' scripts/pin-macho-uuid.py > "$work/noop/scripts/pin-macho-uuid.py"
command grep -qF 'pinned.bytes' "$work/noop/scripts/pin-macho-uuid.py" && fail "no-op pinner was built"
fresh; ! phase Debug "$work/noop" && refused "LC_UUID is" && pass "Debug phase refuses a pin that did not land" || fail "Debug phase refuses a pin that did not land"

[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
