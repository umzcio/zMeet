#!/bin/bash
set -euo pipefail

# Packages build/zMeet.app into a drag-to-Applications .dmg.
# Run scripts/build-app.sh first.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="zMeet"
APP_DIR="$ROOT/build/$APP_NAME.app"
VERSION="${1:-$(defaults read "$APP_DIR/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo 0.1.0)}"
DMG="$ROOT/build/$APP_NAME-$VERSION.dmg"
STAGE="$ROOT/build/dmg-stage"

[ -d "$APP_DIR" ] || { echo "error: $APP_DIR not found — run scripts/build-app.sh first"; exit 1; }

echo "==> Staging DMG contents"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP_DIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating $DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

rm -rf "$STAGE"
echo "==> Done: $DMG"
