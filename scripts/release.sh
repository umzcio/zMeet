#!/bin/bash
set -euo pipefail

# End-to-end release: build -> sign -> .dmg -> notarize/staple -> appcast.
# Produces build/dist/{zMeet-<version>.dmg, appcast.xml} ready to upload.
#
# Prereqs:
#   - scripts/build-app.sh signing identity is set (+ VERSION bumped)
#   - Sparkle EdDSA key generated (generate_keys) — private key in keychain
#   - scripts/.notary-config.local set up (see .notary-config.example)
#
# Usage: scripts/release.sh 1.0.0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: release.sh <version>  e.g. 1.0.0}"
APP_NAME="zMeet"
APP_DIR="$ROOT/build/$APP_NAME.app"
DIST="$ROOT/build/dist"
DMG="$ROOT/build/$APP_NAME-$VERSION.dmg"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"

DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/umzcio/zMeet/releases/download/v$VERSION/}"

echo "==> [1/6] Build + sign app"
bash "$ROOT/scripts/build-app.sh"

echo "==> [2/6] Package .dmg"
bash "$ROOT/scripts/make-dmg.sh" "$VERSION"

echo "==> [3/6] Notarize the .dmg"
bash "$ROOT/scripts/notarize.sh" "$DMG"

echo "==> [4/6] Staple the .app, repackage, and notarize the final dmg"
xcrun stapler staple "$APP_DIR"
bash "$ROOT/scripts/make-dmg.sh" "$VERSION"
# The repackaged dmg is a new file, so it needs its own notarization + staple.
bash "$ROOT/scripts/notarize.sh" "$DMG"

echo "==> [5/6] Generate signed appcast"
rm -rf "$DIST"; mkdir -p "$DIST"
cp "$DMG" "$DIST/"
# generate_appcast reads the EdDSA private key from the keychain, signs each
# archive, and writes appcast.xml with correct enclosure URLs.
"$SPARKLE_BIN/generate_appcast" "$DIST" --download-url-prefix "$DOWNLOAD_URL_PREFIX"

echo "==> [6/6] Done"
echo "  DMG     : $DIST/$APP_NAME-$VERSION.dmg  -> upload to the v$VERSION GitHub release"
echo "  appcast : $DIST/appcast.xml             -> commit to main (SUFeedURL points there)"
echo "  cask    : after publishing the release, run scripts/update-cask.sh $VERSION"
