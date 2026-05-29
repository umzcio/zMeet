#!/bin/bash
set -euo pipefail

# End-to-end release: build -> sign -> .dmg -> notarize/staple -> appcast.
# Produces build/dist/{zMeet-<version>.dmg, appcast.xml} ready to upload.
#
# Prereqs:
#   - scripts/build-app.sh signing identity is set
#   - Sparkle EdDSA key generated (generate_keys) — private key in keychain
#   - notarytool keychain profile set up (see scripts/notarize.sh)
#   - DOWNLOAD_URL_PREFIX points at where you host the .dmg (e.g. a GitHub
#     release's asset base URL)
#
# Usage: scripts/release.sh 0.2.0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: release.sh <version>  e.g. 0.2.0}"
APP_NAME="zMeet"
DIST="$ROOT/build/dist"
DMG="$ROOT/build/$APP_NAME-$VERSION.dmg"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"

# Where the .dmg will be downloadable from (edit for your host).
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/OWNER/zMeet/releases/download/v$VERSION/}"

echo "==> [1/5] Build + sign app (set VERSION=$VERSION in build-app.sh if not already)"
bash "$ROOT/scripts/build-app.sh"

echo "==> [2/5] Package .dmg"
bash "$ROOT/scripts/make-dmg.sh" "$VERSION"

echo "==> [3/5] Notarize + staple"
bash "$ROOT/scripts/notarize.sh" "$DMG"

echo "==> [4/5] Assemble dist + generate signed appcast"
rm -rf "$DIST"; mkdir -p "$DIST"
cp "$DMG" "$DIST/"
# generate_appcast reads the EdDSA private key from the keychain, signs each
# archive, and writes appcast.xml with correct enclosure URLs.
"$SPARKLE_BIN/generate_appcast" "$DIST" --download-url-prefix "$DOWNLOAD_URL_PREFIX"

echo "==> [5/5] Done"
echo "Upload these to your release ($DOWNLOAD_URL_PREFIX):"
echo "  - $DIST/$APP_NAME-$VERSION.dmg"
echo "And publish the appcast where SUFeedURL points:"
echo "  - $DIST/appcast.xml"
