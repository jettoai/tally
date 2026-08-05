#!/bin/bash
# Build a signed, notarized, stapled Tally DMG (universal: arm64 + x86_64).
#
# Adapted from jetto's build-release.sh with two deliberate changes:
#   - the Sparkle EdDSA PUBLIC key is baked here at build time (the repo's project.yml keeps it
#     empty so dev builds stay dormant), and
#   - no service credentials appear in this script - notarization uses an App Store Connect API
#     key read from 1Password at build time (never stored in the repo).
#
# Prereqs (one-time):
#   op signin                                                # 1Password session for the ASC notary
#                                                            # key (op://dev/global-shared/ASC_*)
#   generate_keys --account ai.jetto.tally                   # Sparkle EdDSA pair (Keychain)
set -euo pipefail

cd "$(dirname "$0")/.."

TEAM_ID="87Z993GX39"
SIGN_IDENTITY="Developer ID Application: Jetto AI, LLC (${TEAM_ID})"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-7zissQ63o4tFhLie6cYtZnRSV6aas7x/0pqBOV3ZbxI=}"
ASC_NOTARY_ITEM="op://dev/global-shared"

ARCHIVE=build/Tally.xcarchive
EXPORT=build/export
DIST=dist
rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p build "$DIST"

# Read the notary credentials up front, before the five-minute build rather than after it: a vault
# that locks mid-build (screen lock, desktop app integration) then cannot break notarization, and a
# missing key fails the release immediately. The .p8 only ever lands in a temp file removed on exit;
# nothing here echoes a value.
echo "==> preflight: App Store Connect notary key"
NOTARY_KEY_FILE=$(mktemp)
trap 'rm -f "$NOTARY_KEY_FILE"' EXIT
asc_read() {
  op read "$ASC_NOTARY_ITEM/$1" \
    || { echo "1Password not signed in or ASC notary key missing ($1) - run op signin" >&2; exit 1; }
}
asc_read ASC_NOTARY_KEY_P8 > "$NOTARY_KEY_FILE"
NOTARY_KEY_ID=$(asc_read ASC_NOTARY_KEY_ID) || exit 1
NOTARY_ISSUER_ID=$(asc_read ASC_NOTARY_ISSUER_ID) || exit 1

echo "==> xcodegen"
xcodegen generate

echo "==> archive (universal, Developer ID)"
xcodebuild archive \
  -project Tally.xcodeproj -scheme Tally -configuration Release \
  -archivePath "$ARCHIVE" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="Developer ID Application" CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
  -quiet

echo "==> build tally CLI (universal)"
xcodebuild build \
  -project Tally.xcodeproj -scheme TallyCLI -configuration Release \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="Developer ID Application" CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  -derivedDataPath build/cli-dd -quiet
CLI_BIN="build/cli-dd/Build/Products/Release/tally"
lipo -archs "$CLI_BIN" | grep -q arm64 && lipo -archs "$CLI_BIN" | grep -q x86_64 \
  || { echo "CLI is not universal" >&2; exit 1; }

echo "==> export"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions.plist -exportPath "$EXPORT" -quiet
APP="$EXPORT/Tally.app"

# Sparkle binary must be universal too, or generate_appcast narrows the appcast's hardware
# requirements silently.
lipo -archs "$APP/Contents/MacOS/Tally" | grep -q arm64 \
  && lipo -archs "$APP/Contents/MacOS/Tally" | grep -q x86_64 \
  || { echo "App binary is not universal" >&2; exit 1; }

echo "==> embed tally CLI in the bundle (Contents/Helpers)"
mkdir -p "$APP/Contents/Helpers"
ditto "$CLI_BIN" "$APP/Contents/Helpers/tally"

echo "==> strip Sparkle XPC services + deep re-sign (non-sandboxed app; leaving them in fails notarization)"
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$SPARKLE_FW/Versions/B/XPCServices"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --deep "$SPARKLE_FW"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/tally"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$DIST/Tally-$VERSION.dmg"

echo "==> dmg ($DMG)"
rm -f "$DMG"
STAGE=build/dmg-stage
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Tally.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Tally" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet

echo "==> notarize + staple"
# Credentials were read during preflight; no 1Password access happens after the build starts.
xcrun notarytool submit "$DMG" \
  --key "$NOTARY_KEY_FILE" \
  --key-id "$NOTARY_KEY_ID" \
  --issuer "$NOTARY_ISSUER_ID" \
  --wait
xcrun stapler staple "$DMG"

echo "==> done: $DMG"
