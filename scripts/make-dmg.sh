#!/bin/bash
set -euo pipefail

# Packages build/zMeet.app into a branded drag-to-Applications .dmg
# (create-dmg + a background drawn by render-dmg-background.swift).
# Run scripts/build-app.sh first.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="zMeet"
APP_DIR="$ROOT/build/$APP_NAME.app"
VERSION="${1:-$(defaults read "$APP_DIR/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo 0.1.0)}"
DMG="$ROOT/build/$APP_NAME-$VERSION.dmg"

[ -d "$APP_DIR" ] || { echo "error: $APP_DIR not found — run scripts/build-app.sh first"; exit 1; }
command -v create-dmg >/dev/null || { echo "error: create-dmg not installed (brew install create-dmg)"; exit 1; }

STAGE="$(mktemp -d "$ROOT/build/dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP_DIR" "$STAGE/$APP_NAME.app"

ARTWORK="$ROOT/build/dmg-artwork"
mkdir -p "$ARTWORK"
swift "$ROOT/scripts/render-dmg-background.swift" "$ARTWORK/background.png" "$ROOT/assets/brand/ZMark@2x.png"

echo "==> Creating $DMG"
rm -f "$DMG"
# Icon positions here must match the arrow and label pills drawn in
# render-dmg-background.swift (app at x=200, Applications at x=520, y=218).
create-dmg \
    --volname "Install $APP_NAME" \
    --volicon "$APP_DIR/Contents/Resources/$APP_NAME.icns" \
    --background "$ARTWORK/background.png" \
    --window-pos 240 180 --window-size 720 468 \
    --icon-size 112 --text-size 14 \
    --icon "$APP_NAME.app" 200 218 --hide-extension "$APP_NAME.app" \
    --app-drop-link 520 218 \
    --format UDZO --filesystem HFS+ \
    "$DMG" "$STAGE" >/dev/null

echo "==> Done: $DMG"
