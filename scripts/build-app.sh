#!/bin/bash
set -euo pipefail

# Builds Sources/ZMeetApp into a signed ZMeet.app bundle.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="zMeet"
BUNDLE_ID="edu.umontana.zmeet"
IDENTITY="Developer ID Application: The University of Montana (5JJ6G6A84S)"
APP_DIR="$ROOT/build/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"

echo "==> Compiling ZMeetApp (release)"
swift build -c release --product ZMeetApp --package-path "$ROOT"
BIN="$(swift build -c release --product ZMeetApp --package-path "$ROOT" --show-bin-path)/ZMeetApp"

echo "==> Assembling bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"
cp "$BIN" "$MACOS_DIR/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>zMeet records your microphone during meetings to create notes.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>zMeet transcribes your meeting recordings on-device to create notes.</string>
</dict>
</plist>
PLIST

echo "==> Code signing with: $IDENTITY"
codesign --force --options runtime \
    --entitlements "$ROOT/scripts/ZMeet.entitlements" \
    --sign "$IDENTITY" \
    --timestamp \
    "$APP_DIR"

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP_DIR"
echo "==> Done: $APP_DIR"
echo "Run it with:  open \"$APP_DIR\""
