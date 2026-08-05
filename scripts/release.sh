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
SPARKLE_ART="$(ls -d "$ROOT"/.build*/artifacts/sparkle/Sparkle 2>/dev/null | head -1 || true)"
if [[ -z "$SPARKLE_ART" || ! -e "$SPARKLE_ART" ]]; then
  echo "error: Sparkle artifacts not found. Run: swift package resolve  (or: rm -rf .build/artifacts && swift build)" >&2
  exit 1
fi
SPARKLE_BIN="$SPARKLE_ART/bin"
if [[ ! -e "$SPARKLE_BIN" ]]; then
  echo "error: Sparkle artifacts not found. Run: swift package resolve  (or: rm -rf .build/artifacts && swift build)" >&2
  exit 1
fi

DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/umzcio/zMeet/releases/download/v$VERSION/}"

echo "==> [0/7] Verify version matches scripts/build-app.sh (single source of truth)"
SCRIPT_VERSION="$(sed -n 's/^VERSION="\${ZMEET_VERSION:-\(.*\)}"$/\1/p' "$ROOT/scripts/build-app.sh")"
if [[ "$VERSION" != "$SCRIPT_VERSION" ]]; then
  echo "error: release version $VERSION != build-app.sh VERSION $SCRIPT_VERSION" >&2
  echo "Bump VERSION/BUILD in scripts/build-app.sh first (single source of truth)." >&2
  exit 1
fi

echo "==> [1/7] Run tests"
swift test --scratch-path "$ROOT/.build-ci" --package-path "$ROOT"

echo "==> [2/7] Build + sign app"
bash "$ROOT/scripts/build-app.sh"

echo "==> [3/7] Package .dmg"
bash "$ROOT/scripts/make-dmg.sh" "$VERSION"

echo "==> [4/7] Notarize the .dmg"
bash "$ROOT/scripts/notarize.sh" "$DMG"

echo "==> [5/7] Staple the .app, repackage, and notarize the final dmg"
xcrun stapler staple "$APP_DIR"
bash "$ROOT/scripts/make-dmg.sh" "$VERSION"
# The repackaged dmg is a new file, so it needs its own notarization + staple.
bash "$ROOT/scripts/notarize.sh" "$DMG"

echo "==> [6/7] Generate signed appcast"
rm -rf "$DIST"; mkdir -p "$DIST"
cp "$DMG" "$DIST/"
# generate_appcast reads the EdDSA private key from the keychain, signs each
# archive, and writes appcast.xml with correct enclosure URLs.
"$SPARKLE_BIN/generate_appcast" "$DIST" --download-url-prefix "$DOWNLOAD_URL_PREFIX"

echo "==> [7/7] Done"
echo "  DMG     : $DIST/$APP_NAME-$VERSION.dmg  -> upload to the v$VERSION GitHub release"
echo "  appcast : $DIST/appcast.xml             -> commit to main (SUFeedURL points there)"
echo "  cask    : after publishing the release, run scripts/update-cask.sh $VERSION"

if [[ -z "$(git -C "$ROOT" status --porcelain)" ]]; then
  git -C "$ROOT" tag -a "v$VERSION" -m "v$VERSION"
  echo "  tagged  : v$VERSION (push with: git push origin v$VERSION)"
else
  echo "  WARNING : working tree dirty — tag v$VERSION manually after committing."
fi
