#!/bin/bash
# Full release: bump version → build/notarize DMG → merge appcast (append-only, signed) →
# GitHub Release (DMG + appcast.xml as assets).
#
# The Sparkle feed URL baked into the app is
#   https://github.com/jettoai/tally/releases/latest/download/appcast.xml
# so every release MUST upload a MERGED appcast (full history) - that URL always resolves to the
# newest release's asset. The append-only and signature checks below guard exactly that.
#
# The app is compiled on the MBP and signed, notarized and stapled here (scripts/build-on-mbp.sh).
# --local builds everything on this Mac instead (scripts/build-release.sh); a failed MBP build is
# never retried locally on its own.
#
# Usage: scripts/release.sh <version> [--local]   e.g. scripts/release.sh 0.2.0
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version, e.g. 0.2.0> [--local]}"
LOCAL=0
case "${2:-}" in
  "") ;;
  --local) LOCAL=1 ;;
  *) echo "unknown option: $2" >&2; exit 1 ;;
esac
REPO="jettoai/tally"
TAG="v$VERSION"
DOWNLOAD_PREFIX="https://github.com/$REPO/releases/download/$TAG/"

echo "==> bump project.yml to $VERSION"
sed -i '' "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
# History was rewritten on 2026-10-03, so the commit count alone can fall below a shipped build
# and Sparkle would offer nothing.
PREV_BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml)
COUNT=$(git rev-list --count HEAD)
BUILD_NUM=$(( COUNT > PREV_BUILD ? COUNT : PREV_BUILD + 1 ))
sed -i '' "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$BUILD_NUM\"/" project.yml

echo "==> build + notarize"
if [ "$LOCAL" = 1 ]; then scripts/build-release.sh; else scripts/build-on-mbp.sh; fi
DMG="dist/Tally-$VERSION.dmg"
[ -f "$DMG" ] || { echo "expected $DMG" >&2; exit 1; }

echo "==> verify the DMG that will be uploaded carries no overlay"
MNT=$(mktemp -d)
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT" -quiet
check_rc=0
scripts/check-overlay-bundle.sh --absent "$MNT/Tally.app" \
  "$MNT/Tally.app/Contents/Helpers/swift/tally" "$MNT/Tally.app/Contents/Helpers/tally" || check_rc=$?
hdiutil detach "$MNT" -quiet
[ "$check_rc" -eq 0 ] || exit 1

echo "==> merge appcast (append-only)"
FEED=build/feed
rm -rf "$FEED"; mkdir -p "$FEED"
BEFORE=0
if curl -fsSL "https://github.com/$REPO/releases/latest/download/appcast.xml" -o "$FEED/appcast.xml"; then
  BEFORE=$(grep -c '<item>' "$FEED/appcast.xml" || true)
  echo "    existing appcast: $BEFORE item(s)"
else
  echo "    no existing appcast (first release)"
fi
cp "$DMG" "$FEED/"

GA=$(find ~/Library/Developer/Xcode/DerivedData/Tally-*/SourcePackages/artifacts -name generate_appcast -type f | head -1)
[ -n "$GA" ] || { echo "generate_appcast not found - build once so SPM fetches Sparkle" >&2; exit 1; }
"$GA" --account ai.jetto.tally \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --maximum-versions 0 \
  "$FEED"

AFTER=$(grep -c '<item>' "$FEED/appcast.xml" || true)
grep -q "Tally-$VERSION.dmg" "$FEED/appcast.xml" || { echo "new item missing from appcast" >&2; exit 1; }
grep -Eq "Tally-$VERSION\.dmg.*sparkle:edSignature|sparkle:edSignature.*Tally-$VERSION\.dmg" "$FEED/appcast.xml" \
  || { echo "new item unsigned - SUPublicEDKey / Keychain key mismatch?" >&2; exit 1; }
[ "$AFTER" -ge "$BEFORE" ] || { echo "appcast shrank ($BEFORE -> $AFTER)" >&2; exit 1; }

echo "==> commit version bump + tag"
git add project.yml
git commit -m "release: v$VERSION"
git tag "$TAG"

echo "==> GitHub release"
git push origin main "$TAG"
# A stable-named copy rides along so the README's download link
# (releases/latest/download/Tally.dmg) always fetches the newest version directly.
cp "$DMG" "$FEED/Tally.dmg"
gh release create "$TAG" "$DMG" "$FEED/Tally.dmg" "$FEED/appcast.xml" \
  --repo "$REPO" --title "Tally $VERSION" --generate-notes

echo "==> done - verify: curl -sL https://github.com/$REPO/releases/latest/download/appcast.xml | grep $VERSION"

# A linked overlay may publish its own build of this version through its own feed.
if [ -x overlay/release.sh ]; then
  echo "==> overlay release"
  overlay/release.sh "$VERSION" $([ "$LOCAL" = 1 ] && echo --local) \
    || { echo "public release $TAG is out; the overlay release failed" >&2; exit 1; }
fi
