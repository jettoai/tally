#!/bin/bash
# The key-holding half of the MBP build split: takes the tar that `build-release.sh --handoff`
# left (ad-hoc signed app, dSYMs, handoff.json), refuses unless it is exactly what this checkout
# would have built, then does what build-release.sh does after the build, in the same order:
# sign inside-out with the Developer ID, upload dSYMs to Sentry, DMG, notarize, staple. The Sparkle
# EdDSA signature is computed later (release.sh) on the stapled DMG, so that order must not change.
#
# Usage: scripts/sign-and-notarize.sh [--dist DIR] [--skip-sentry] [--version V] [--build N] <Tally-<version>-<public|overlay>.tar>
# NOTARIZE_PROFILE selects a Keychain profile instead of the 1Password notary key, as in
# build-release.sh. The mode comes from the tar's handoff.json. An overlay tar is also refused
# unless ./overlay is clean and at the commit the MBP built; its postsign.sh runs after the
# Resources are re-signed and before the app is sealed (it hashes the final agent bytes into the
# manifest). --version/--build, when given, must equal what the tar's app carries (build settings
# passed to the build are not part of the project.yml hash). The DMG goes to dist, or dist/overlay.
set -euo pipefail

cd "$(dirname "$0")/.."
STEP_NAME=""; STEP_T0=0
step_end() { [ -z "$STEP_NAME" ] || echo "[$(date +%T)] <== $STEP_NAME ($(( $(date +%s) - STEP_T0 ))s)"; STEP_NAME=""; }
step() { step_end; STEP_NAME="$1"; STEP_T0=$(date +%s); echo "[$(date +%T)] ==> $1"; }
on_err() { echo "[$(date +%T)] FAILED during: $STEP_NAME" >&2; }
trap on_err ERR
export PATH="$HOME/.cargo/bin:$PATH"

DIST=""
SKIP_SENTRY=0
EXPECT_VERSION=""
EXPECT_BUILD=""
while [ $# -gt 1 ]; do
  case "$1" in
    --dist) DIST="${2:?--dist needs a directory}"; shift ;;
    --skip-sentry) SKIP_SENTRY=1 ;;
    --version) EXPECT_VERSION="${2:?--version needs a value}"; shift ;;
    --build) EXPECT_BUILD="${2:?--build needs a value}"; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done
TAR="${1:?usage: sign-and-notarize.sh [--dist DIR] [--skip-sentry] <Tally-<version>-public.tar>}"
[ -f "$TAR" ] || { echo "no such tar: $TAR" >&2; exit 1; }

TEAM_ID="87Z993GX39"
SIGN_IDENTITY="Developer ID Application: Jetto AI, LLC (${TEAM_ID})"
SPARKLE_PUBLIC_ED_KEY="7zissQ63o4tFhLie6cYtZnRSV6aas7x/0pqBOV3ZbxI="
ASC_NOTARY_ITEM="op://dev/global-shared"
SENTRY_ENV="$HOME/.config/op-env/sentry.env"
WORK="${TALLY_SIGN_WORK:-build}"
STAGE="$WORK/sign-stage"
APP="$STAGE/Tally.app"

step "verify the handoff against this checkout"
rm -rf "$STAGE"
mkdir -p "$STAGE"
tar -xf "$TAR" -C "$STAGE"
[ -d "$APP" ] && [ -d "$STAGE/dSYMs" ] && [ -f "$STAGE/handoff.json" ] \
  || { echo "REFUSED: tar does not hold Tally.app, dSYMs and handoff.json" >&2; exit 1; }
scripts/handoff-machos.sh "$APP" > "$WORK/sign-machos.tsv"
scripts/handoff-machos.sh --agents "$APP" > "$WORK/sign-agents.tsv"
MODE=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("mode", ""))' "$STAGE/handoff.json")
OVERLAY_HEAD=""
case "$MODE" in
  public) : "${DIST:=dist}" ;;
  overlay)
    : "${DIST:=dist/overlay}"
    [ -x overlay/postsign.sh ] && [ -f overlay/bundle-markers ] \
      || { echo "REFUSED: overlay tar but no overlay linked at ./overlay" >&2; exit 1; }
    [ -z "$(git -C overlay status --porcelain)" ] || { echo "REFUSED: overlay has uncommitted changes" >&2; exit 1; }
    OVERLAY_HEAD=$(git -C overlay rev-parse HEAD) ;;
  *) echo "REFUSED: handoff mode '$MODE' is neither public nor overlay" >&2; exit 1 ;;
esac
H_MODE="$MODE" H_OVERLAY="$OVERLAY_HEAD" H_EXPECT_VERSION="$EXPECT_VERSION" H_EXPECT_BUILD="$EXPECT_BUILD" \
H_HEAD="$(git rev-parse HEAD)" H_PROJECT_SHA="$(shasum -a 256 project.yml | cut -d' ' -f1)" \
H_VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")" \
H_BUILD="$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")" \
H_XCODE="$(xcodebuild -version | paste -sd' ' -)" H_RUSTC="$(cd rust && rustc -V)" \
  python3 -I - "$STAGE/handoff.json" "$WORK/sign-machos.tsv" "$WORK/sign-agents.tsv" <<'PY'
import json, os, sys
e = os.environ
h = json.load(open(sys.argv[1]))
bad = []
if h.get("overlay_head") != (e["H_OVERLAY"] or None):
    bad.append("overlay_head: handoff %s, here %s" % (h.get("overlay_head"), e["H_OVERLAY"] or None))
for key, env in (("marketing_version", "H_EXPECT_VERSION"), ("build_number", "H_EXPECT_BUILD")):
    if e[env] and h.get(key) != e[env]:
        bad.append("%s: handoff %s, release wants %s" % (key, h.get(key), e[env]))
for key, env in (("git_head", "H_HEAD"), ("project_yml_sha256", "H_PROJECT_SHA"),
                 ("marketing_version", "H_VERSION"), ("build_number", "H_BUILD")):
    if h.get(key) != e[env]:
        bad.append("%s: handoff %s, here %s" % (key, h.get(key), e[env]))
have = {l.split("\t")[0]: l.rstrip("\n").split("\t") for l in open(sys.argv[2])}
want = {m["path"]: [m["path"], m["sha256"], m["archs"]] for m in h.get("machos", [])}
for p in sorted(set(have) | set(want)):
    if have.get(p) != want.get(p):
        bad.append("Mach-O %s: handoff %s, tar %s" % (p, want.get(p, ["", "absent"])[1:], have.get(p, ["", "absent"])[1:]))
have_agents = dict(l.rstrip("\n").split("\t") for l in open(sys.argv[3]))
want_agents = h.get("agents", {})
for p in sorted(set(have_agents) | set(want_agents)):
    if have_agents.get(p) != want_agents.get(p):
        bad.append("helper agent file %s: handoff %s, tar %s" % (p, want_agents.get(p), have_agents.get(p)))
for key, env in (("xcodebuild", "H_XCODE"), ("rustc", "H_RUSTC")):
    if h.get(key) != e[env]:
        print("warning: %s differs: handoff '%s', here '%s'" % (key, h.get(key), e[env]))
if bad:
    print("REFUSED: the handoff does not match this checkout:\n  " + "\n  ".join(bad), file=sys.stderr)
    sys.exit(1)
PY
[ "$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" "$APP/Contents/Info.plist")" = "$SPARKLE_PUBLIC_ED_KEY" ] \
  || { echo "REFUSED: SUPublicEDKey in the app is not the release key" >&2; exit 1; }
for arch in arm64 x86_64; do
  lipo -archs "$APP/Contents/MacOS/Tally" | grep -qw "$arch" || { echo "REFUSED: app binary is not universal" >&2; exit 1; }
done

# Credentials are resolved before anything is signed or sent anywhere; no 1Password access after.
if [ -n "${NOTARIZE_PROFILE:-}" ]; then
  step "preflight: notary Keychain profile"
  NOTARY_ARGS=(--keychain-profile "$NOTARIZE_PROFILE")
  xcrun notarytool history "${NOTARY_ARGS[@]}" --output-format json > /dev/null
else
  step "preflight: App Store Connect notary key"
  NOTARY_KEY_FILE=$(mktemp)
  trap 'rm -f "$NOTARY_KEY_FILE"' EXIT
  asc_read() {
    op read "$ASC_NOTARY_ITEM/$1" \
      || { echo "1Password not signed in or ASC notary key missing ($1) - run op signin" >&2; exit 1; }
  }
  asc_read ASC_NOTARY_KEY_P8 > "$NOTARY_KEY_FILE"
  NOTARY_KEY_ID=$(asc_read ASC_NOTARY_KEY_ID) || exit 1
  NOTARY_ISSUER_ID=$(asc_read ASC_NOTARY_ISSUER_ID) || exit 1
  NOTARY_ARGS=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
fi
if [ "$SKIP_SENTRY" != 1 ]; then
  step "preflight: sentry-cli + Sentry auth env (dSYM upload)"
  command -v sentry-cli > /dev/null || { echo "sentry-cli not found - brew install getsentry/tools/sentry-cli" >&2; exit 1; }
  [ -f "$SENTRY_ENV" ] || { echo "Sentry env file missing ($SENTRY_ENV)" >&2; exit 1; }
fi
step "preflight: signing identity"
security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY" \
  || { echo "signing identity missing or Keychain locked: $SIGN_IDENTITY" >&2; exit 1; }

step "sign inside-out (Sparkle XPC services stripped first: the app is not sandboxed and they fail notarization)"
sign() { codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@"; }
FW="$APP/Contents/Frameworks"
rm -rf "$FW/Sparkle.framework/Versions/B/XPCServices"
sign "$FW/Sentry.framework"
sign --deep "$FW/Sparkle.framework"
sign "$APP/Contents/Helpers/swift/tally"
sign "$APP/Contents/Helpers/tally"
# Every other Mach-O in the bundle (the public bundle has none outside the parts above) is signed
# before the app seal covers it.
while IFS=$'\t' read -r path _; do
  case "$path" in
    Contents/MacOS/Tally|Contents/Helpers/tally|Contents/Helpers/swift/tally) ;;
    Contents/Frameworks/Sentry.framework/*|Contents/Frameworks/Sparkle.framework/*) ;;
    *) sign "$APP/$path" ;;
  esac
done < "$WORK/sign-machos.tsv"
# An overlay records the hashes of what it put in Resources; the re-signing above rewrote them, so
# its manifest is rewritten (and checked) here, before the app seal covers it.
if [ "$MODE" = overlay ]; then
  overlay/postsign.sh "$APP" || { echo "overlay postsign failed" >&2; exit 1; }
fi
sign "$APP"
codesign --verify --strict --deep "$APP"
[ ! -e "$FW/Sparkle.framework/Versions/B/XPCServices" ] || { echo "Sparkle XPCServices still present" >&2; exit 1; }
# Signing here carries no entitlements, so Tally.entitlements must be empty; the check keeps a
# future key from being dropped silently.
for bin in "$APP" "$APP/Contents/Helpers/tally" "$APP/Contents/Helpers/swift/tally"; do
  codesign -d --entitlements :- "$bin" 2> /dev/null > "$WORK/sign-entitlements.plist"
  python3 -I - "$WORK/sign-entitlements.plist" Tally/Resources/Tally.entitlements "$bin" <<'PY' \
    || { echo "entitlements of the signed output differ from Tally.entitlements" >&2; exit 1; }
import plistlib, sys
raw = open(sys.argv[1], "rb").read()
signed = plistlib.loads(raw) if raw.strip() else {}
if signed != plistlib.load(open(sys.argv[2], "rb")):
    print("%s: signed %r" % (sys.argv[3], signed), file=sys.stderr)
    sys.exit(1)
PY
done
"$APP/Contents/Helpers/tally" help > /dev/null || { echo "embedded tally entry does not run" >&2; exit 1; }
if [ "$MODE" = overlay ]; then
  overlay/postsign.sh --check "$APP" || { echo "overlay helper manifest does not match the signed bytes" >&2; exit 1; }
  scripts/check-overlay-bundle.sh "$APP" "$APP/Contents/Helpers/swift/tally"
fi

if [ "$SKIP_SENTRY" != 1 ]; then
  step "upload dSYMs to Sentry"
  # The token is injected by op run from op:// references; it never appears in this script or its output.
  op run --env-file="$SENTRY_ENV" -- \
    sentry-cli debug-files upload --org taiwanbigdata --project tally "$STAGE/dSYMs"
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
mkdir -p "$DIST"
DMG="$DIST/Tally-$VERSION.dmg"
step "dmg ($DMG)"
rm -f "$DMG"
rm -rf "$WORK/dmg-stage"
mkdir -p "$WORK/dmg-stage"
ditto "$APP" "$WORK/dmg-stage/Tally.app"
ln -s /Applications "$WORK/dmg-stage/Applications"
hdiutil create -volname "Tally" -srcfolder "$WORK/dmg-stage" -ov -format UDZO "$DMG" -quiet

step "notarize + staple"
xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
xcrun stapler staple "$DMG"

step_end
echo "==> done: $DMG"
