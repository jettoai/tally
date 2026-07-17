#!/bin/bash
# Full release: bump version → build/notarize DMG → merge appcast (append-only, signed) →
# GitHub Release (DMG + appcast.xml as assets).
#
# The Sparkle feed URL baked into the app is
#   https://github.com/jettoai/tally/releases/latest/download/appcast.xml
# so every release MUST upload a MERGED appcast (full history) - that URL always resolves to the
# newest release's asset. The append-only and signature checks below guard exactly that.
#
# Usage: scripts/release.sh <version>   e.g. scripts/release.sh 0.2.0
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version, e.g. 0.2.0>}"
REPO="jettoai/tally"
TAG="v$VERSION"
DOWNLOAD_PREFIX="https://github.com/$REPO/releases/download/$TAG/"

echo "==> bump project.yml to $VERSION"
sed -i '' "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
BUILD_NUM=$(git rev-list --count HEAD)
sed -i '' "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$BUILD_NUM\"/" project.yml

echo "==> build + notarize"
scripts/build-release.sh
DMG="dist/Tally-$VERSION.dmg"
[ -f "$DMG" ] || { echo "expected $DMG" >&2; exit 1; }

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
gh release create "$TAG" "$DMG" "$FEED/appcast.xml" \
  --repo "$REPO" --title "Tally $VERSION" --generate-notes

echo "==> done - verify: curl -sL https://github.com/$REPO/releases/latest/download/appcast.xml | grep $VERSION"
