#!/bin/bash
# Build a signed, notarized, stapled Tally DMG (universal: arm64 + x86_64).
#
# Adapted from jetto's build-release.sh with two deliberate changes:
#   - the Sparkle EdDSA PUBLIC key is baked here at build time (the repo's project.yml keeps it
#     empty so dev builds stay dormant), and
#   - no service credentials appear in this script - notarization uses an App Store Connect API
#     key read from 1Password at build time (never stored in the repo), or an existing
#     Keychain profile selected with NOTARIZE_PROFILE.
#
# Prereqs (one-time):
#   op signin                                                # 1Password session for the ASC notary
#                                                            # key (op://dev/global-shared/ASC_*)
#   generate_keys --account ai.jetto.tally                   # Sparkle EdDSA pair (Keychain)
#
# Usage: scripts/build-release.sh [--with-overlay | --handoff] [BUILD_SETTING=value ...]
# Without --with-overlay the app is built from a copy of the git-tracked files
# (scripts/stage-public-tree.sh), so an overlay linked at ./overlay never reaches it, and the
# bundle is checked for its absence. With it, the build runs in place, requires the overlay, and
# checks for its presence. Remaining arguments are passed to both xcodebuild builds.
#
# --handoff (runs on the MBP, needs no credential): builds everything ad-hoc signed and stops
# before any signing identity, notary, Sentry or Sparkle-key step, leaving
# build/handoff/Tally-<version>-<public|overlay>.tar for scripts/sign-and-notarize.sh on the machine
# that holds the keys. TALLY_HANDOFF_HEAD must carry that machine's git HEAD (the MBP copy's own HEAD
# is a snapshot commit); with --with-overlay so must TALLY_HANDOFF_OVERLAY_HEAD for the overlay's.
# scripts/build-on-mbp.sh runs the whole split.
set -euo pipefail

cd "$(dirname "$0")/.."
STEP_NAME=""; STEP_T0=0
step_end() { [ -z "$STEP_NAME" ] || echo "[$(date +%T)] <== $STEP_NAME ($(( $(date +%s) - STEP_T0 ))s)"; STEP_NAME=""; }
step() { step_end; STEP_NAME="$1"; STEP_T0=$(date +%s); echo "[$(date +%T)] ==> $1"; }
trap 'echo "[$(date +%T)] FAILED during: $STEP_NAME" >&2' ERR
MODE=public
HANDOFF=0
while [ $# -gt 0 ]; do
  case "$1" in
    --with-overlay) MODE=overlay ;;
    --handoff) HANDOFF=1 ;;
    *) break ;;
  esac
  shift
done
EXTRA_SETTINGS=("$@")
if [ "$HANDOFF" = 1 ]; then
  [ "$MODE" = public ] || [ -n "${TALLY_HANDOFF_OVERLAY_HEAD:-}" ] \
    || { echo "--handoff --with-overlay needs TALLY_HANDOFF_OVERLAY_HEAD=<git HEAD of the overlay>" >&2; exit 1; }
  [ -n "${TALLY_HANDOFF_HEAD:-}" ] || { echo "--handoff needs TALLY_HANDOFF_HEAD=<git HEAD of the machine that signs>" >&2; exit 1; }
fi

TEAM_ID="87Z993GX39"
SIGN_IDENTITY="Developer ID Application: Jetto AI, LLC (${TEAM_ID})"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-7zissQ63o4tFhLie6cYtZnRSV6aas7x/0pqBOV3ZbxI=}"
ASC_NOTARY_ITEM="op://dev/global-shared"

ARCHIVE=build/Tally.xcarchive
EXPORT=build/export
DIST=dist
# Public and overlay DMGs never share a directory, so release.sh cannot pick up the wrong one.
if [ "$MODE" = overlay ]; then DIST=dist/overlay; fi
rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p build
[ "$HANDOFF" = 1 ] || mkdir -p "$DIST"
# Developer ID in a normal build; handoff builds are ad-hoc and get their identity on the signing machine.
SIGN_SETTINGS=(CODE_SIGN_IDENTITY="Developer ID Application" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID")
if [ "$HANDOFF" = 1 ]; then SIGN_SETTINGS=(CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=""); fi

# Resolve credentials before the build. An existing Keychain profile avoids
# exporting a private key; otherwise retain the 1Password workflow.
if [ "$HANDOFF" = 1 ]; then
  step "preflight: handoff build (no credentials involved)"
elif [ -n "${NOTARIZE_PROFILE:-}" ]; then
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

if [ "$MODE" = overlay ]; then
  step "preflight: overlay (./overlay)"
  [ -f overlay/Overlay.xcconfig ] || { echo "overlay missing at ./overlay" >&2; exit 1; }
  if [ "$HANDOFF" = 1 ]; then
    # The overlay here is a copy without .git; the machine that signs checks it is clean and at this commit.
    echo "    overlay at ${TALLY_HANDOFF_OVERLAY_HEAD:0:7}"
  else
    [ -z "$(git -C overlay/ status --porcelain)" ] || { echo "overlay has uncommitted changes" >&2; exit 1; }
    echo "    overlay at $(git -C overlay/ rev-parse --short HEAD)"
  fi
  SRC=.
else
  step "preflight: public build (no overlay)"
  # The overlay's own marker list, when one is linked here, is what the absence check looks for.
  rm -f build/overlay-markers
  if [ -s overlay/bundle-markers ]; then cp overlay/bundle-markers build/overlay-markers; fi
  SRC=$(scripts/stage-public-tree.sh)
  echo "    building from $SRC"
fi

SENTRY_ENV="$HOME/.config/op-env/sentry.env"
if [ "$HANDOFF" != 1 ]; then
  step "preflight: sentry-cli + Sentry auth env (dSYM upload)"
  command -v sentry-cli > /dev/null \
    || { echo "sentry-cli not found - brew install getsentry/tools/sentry-cli" >&2; exit 1; }
  [ -f "$SENTRY_ENV" ] \
    || { echo "Sentry env file missing ($SENTRY_ENV) - needs SENTRY_AUTH_TOKEN as an op:// reference" >&2; exit 1; }
fi

step "preflight: Rust toolchain (both Mac targets)"
export PATH="$HOME/.cargo/bin:$PATH"
command -v cargo > /dev/null || { echo "cargo not found - install rustup" >&2; exit 1; }
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  (cd "$SRC/rust" && rustup target list --installed) | grep -qx "$target" \
    || { echo "Rust target $target missing - (cd rust && rustup target add $target)" >&2; exit 1; }
done

# Committed UniFFI bindings that lag the Rust exports fail the first call in the shipped app.
step "preflight: UniFFI bindings current"
"$SRC/scripts/gen-uniffi.sh" --check

step "xcodegen"
xcodegen generate --spec "$SRC/project.yml"

step "archive (universal, $([ "$HANDOFF" = 1 ] && echo ad-hoc || echo Developer ID))"
xcodebuild archive \
  -project "$SRC/Tally.xcodeproj" -scheme Tally -configuration Release \
  -archivePath "$ARCHIVE" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  "${SIGN_SETTINGS[@]}" \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
  ${EXTRA_SETTINGS[@]+"${EXTRA_SETTINGS[@]}"} \
  -quiet

if [ "$HANDOFF" != 1 ]; then
  step "upload dSYMs to Sentry"
  # The token is injected by op run from op:// references; it never appears in this script or its output.
  op run --env-file="$SENTRY_ENV" -- \
    sentry-cli debug-files upload --org taiwanbigdata --project tally "$ARCHIVE/dSYMs"
fi

step "build tally CLI (universal)"
xcodebuild build \
  -project "$SRC/Tally.xcodeproj" -scheme TallyCLI -configuration Release \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  "${SIGN_SETTINGS[@]}" \
  ${EXTRA_SETTINGS[@]+"${EXTRA_SETTINGS[@]}"} \
  -derivedDataPath "build/cli-dd-$MODE" -quiet
CLI_BIN="build/cli-dd-$MODE/Build/Products/Release/tally"
lipo -archs "$CLI_BIN" | grep -q arm64 && lipo -archs "$CLI_BIN" | grep -q x86_64 \
  || { echo "CLI is not universal" >&2; exit 1; }
step "verify the Rust core is linked into both CLI slices"
for arch in arm64 x86_64; do
  lipo "$CLI_BIN" -thin "$arch" -output "build/cli-$arch.thin"
  strings "build/cli-$arch.thin" | grep 'tally_core ctx-v1' > /dev/null \
    || { echo "Rust core missing from the $arch CLI slice" >&2; exit 1; }
done

step "build the Rust tally entry (universal)"
ENTRY_BIN="build/tally-entry"
if [ -x "$SRC/overlay/rust/build-entry.sh" ]; then
  # An overlay linked at ./overlay may build its own entry in place of this one (the same hand-over
  # as scripts/build-rust-core.sh); the public tree has none, so this never fires there.
  SRCROOT="$SRC" "$SRC/overlay/rust/build-entry.sh" "$PWD/$ENTRY_BIN"
else
  entry_slices=()
  for triple in aarch64-apple-darwin x86_64-apple-darwin; do
    (cd "$SRC/rust" && MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --release --locked -p tally --target "$triple")
    entry_slices+=("$SRC/rust/target/$triple/release/tally")
  done
  lipo -create "${entry_slices[@]}" -output "$ENTRY_BIN"
fi
for arch in arm64 x86_64; do
  lipo "$ENTRY_BIN" -thin "$arch" -output "build/entry-$arch.thin"
  strings "build/entry-$arch.thin" | grep 'tally_entry forward-v1' > /dev/null \
    || { echo "entry marker missing from the $arch slice" >&2; exit 1; }
done

APP="$EXPORT/Tally.app"
if [ "$HANDOFF" = 1 ]; then
  # An export would re-sign with the Developer ID this machine does not have; the app is taken out
  # of the archive as is and signed explicitly by scripts/sign-and-notarize.sh.
  step "take the app out of the archive"
  mkdir -p "$EXPORT"
  ditto "$ARCHIVE/Products/Applications/Tally.app" "$APP"
else
  step "export"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist ExportOptions.plist -exportPath "$EXPORT" -quiet
fi

# Sparkle binary must be universal too, or generate_appcast narrows the appcast's hardware
# requirements silently.
lipo -archs "$APP/Contents/MacOS/Tally" | grep -q arm64 \
  && lipo -archs "$APP/Contents/MacOS/Tally" | grep -q x86_64 \
  || { echo "App binary is not universal" >&2; exit 1; }

step "embed the tally entry and the Swift CLI it forwards to (Contents/Helpers)"
mkdir -p "$APP/Contents/Helpers/swift"
ditto "$CLI_BIN" "$APP/Contents/Helpers/swift/tally"
ditto "$ENTRY_BIN" "$APP/Contents/Helpers/tally"
# The overlay's markers live in the Swift CLI; the public check also covers the Rust entry.
if [ "$MODE" = overlay ]; then
  scripts/check-overlay-bundle.sh "$APP" "$APP/Contents/Helpers/swift/tally"
else
  scripts/check-overlay-bundle.sh --absent "$APP" "$APP/Contents/Helpers/swift/tally" "$APP/Contents/Helpers/tally"
fi

if [ "$HANDOFF" = 1 ]; then
  step "handoff: ad-hoc seal, smoke, package"
  codesign --force --sign - "$APP/Contents/Helpers/swift/tally"
  codesign --force --sign - "$APP/Contents/Helpers/tally"
  codesign --force --sign - "$APP"
  codesign --verify --strict --deep "$APP"
  "$APP/Contents/Helpers/tally" help > /dev/null \
    || { echo "embedded tally entry does not run" >&2; exit 1; }
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
  PKG=build/handoff-pkg
  rm -rf build/handoff "$PKG"
  mkdir -p build/handoff "$PKG"
  ditto "$APP" "$PKG/Tally.app"
  ditto "$ARCHIVE/dSYMs" "$PKG/dSYMs"
  scripts/handoff-machos.sh "$PKG/Tally.app" > build/handoff-machos.tsv
  [ -s build/handoff-machos.tsv ] || { echo "no Mach-O found in the app" >&2; exit 1; }
  scripts/handoff-machos.sh --agents "$PKG/Tally.app" > build/handoff-agents.tsv
  if [ "$MODE" = overlay ]; then
    [ -s build/handoff-agents.tsv ] || { echo "overlay build carries no helper agents" >&2; exit 1; }
  fi
  H_MODE="$MODE" H_OVERLAY="${TALLY_HANDOFF_OVERLAY_HEAD:-}" \
  H_HEAD="$TALLY_HANDOFF_HEAD" H_PROJECT_SHA="$(shasum -a 256 "$SRC/project.yml" | cut -d' ' -f1)" \
  H_VERSION="$VERSION" \
  H_BUILD="$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")" \
  H_XCODE="$(xcodebuild -version | paste -sd' ' -)" H_RUSTC="$(cd "$SRC/rust" && rustc -V)" \
    python3 -I - build/handoff-machos.tsv build/handoff-agents.tsv "$PKG/handoff.json" <<'PY'
import json, os, sys
e = os.environ
machos = [dict(zip(("path", "sha256", "archs"), l.rstrip("\n").split("\t"))) for l in open(sys.argv[1])]
agents = dict(l.rstrip("\n").split("\t") for l in open(sys.argv[2]))
json.dump({"mode": e["H_MODE"], "git_head": e["H_HEAD"], "overlay_head": e["H_OVERLAY"] or None,
           "project_yml_sha256": e["H_PROJECT_SHA"],
           "marketing_version": e["H_VERSION"], "build_number": e["H_BUILD"],
           "xcodebuild": e["H_XCODE"], "rustc": e["H_RUSTC"], "machos": machos, "agents": agents},
          open(sys.argv[3], "w"), indent=1)
PY
  OUT="build/handoff/Tally-$VERSION-$MODE.tar"
  COPYFILE_DISABLE=1 tar -cf "$OUT" -C "$PKG" Tally.app dSYMs handoff.json
  step_end
  echo "==> done: $OUT (sign it with scripts/sign-and-notarize.sh)"
  exit 0
fi

step "strip Sparkle XPC services + deep re-sign (non-sandboxed app; leaving them in fails notarization)"
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$SPARKLE_FW/Versions/B/XPCServices"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --deep "$SPARKLE_FW"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/swift/tally"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/tally"
# Notarization wants every Mach-O in the bundle under the Developer ID, including any an overlay
# put in Resources; other files there are data. The public bundle has none.
resource_machos=$(find "$APP/Contents/Resources" -type f \
  -exec sh -c 'file -b "$1" | grep -q "^Mach-O"' _ {} \; -print)
while IFS= read -r f; do
  [ -z "$f" ] || codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$f"
done <<< "$resource_machos"
# Re-signing rewrote those files; an overlay that records their hashes updates them here, before
# the app seal covers the record.
if [ -x overlay/postsign.sh ]; then
  overlay/postsign.sh "$APP" || { echo "overlay postsign failed" >&2; exit 1; }
fi
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"
step "smoke: the embedded entry forwards to the Swift CLI"
"$APP/Contents/Helpers/tally" help > /dev/null \
  || { echo "embedded tally entry does not run" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$DIST/Tally-$VERSION.dmg"

step "dmg ($DMG)"
rm -f "$DMG"
STAGE=build/dmg-stage
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Tally.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Tally" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet

step "notarize + staple"
# Credentials were read during preflight; no 1Password access happens after the build starts.
xcrun notarytool submit "$DMG" \
  "${NOTARY_ARGS[@]}" \
  --wait
xcrun stapler staple "$DMG"

step_end
echo "==> done: $DMG"
