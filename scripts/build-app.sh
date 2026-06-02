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
FW_DIR="$APP_DIR/Contents/Frameworks"

# App version (also stamped into the appcast on release).
VERSION="1.13.1"
BUILD="18"

# Sparkle auto-update: appcast feed URL + EdDSA public key (private key is in the
# login keychain via generate_keys).
SU_FEED_URL="https://raw.githubusercontent.com/umzcio/zMeet/main/appcast.xml"
SU_PUBLIC_ED_KEY="7KQVNte/Z3ts81v6gETASf21YKulzZZTiqMpF8uv5G8="

SPARKLE_FW="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

echo "==> Compiling ZMeetApp (release)"
# The extra rpath lets the bundled binary find Sparkle.framework in Contents/Frameworks.
RPATH_FLAGS="-Xlinker -rpath -Xlinker @executable_path/../Frameworks"
swift build -c release --product ZMeetApp --package-path "$ROOT" $RPATH_FLAGS
BIN="$(swift build -c release --product ZMeetApp --package-path "$ROOT" --show-bin-path)/ZMeetApp"

echo "==> Assembling bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR" "$FW_DIR"
cp "$BIN" "$MACOS_DIR/$APP_NAME"

# Embed Sparkle.framework.
echo "==> Embedding Sparkle.framework"
cp -R "$SPARKLE_FW" "$FW_DIR/"

# Bundle the wordmark font (auto-registered at launch via ATSApplicationFontsPath).
mkdir -p "$RES_DIR/Fonts"
cp "$ROOT/scripts/assets/DancingScript.ttf" "$RES_DIR/Fonts/DancingScript.ttf"

# App icon.
cp "$ROOT/scripts/assets/AppIcon.icns" "$RES_DIR/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>ATSApplicationFontsPath</key><string>Fonts</string>
    <key>NSMicrophoneUsageDescription</key><string>zMeet records your microphone during meetings to create notes.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>zMeet transcribes your meeting recordings on-device to create notes.</string>
    <key>SUFeedURL</key><string>$SU_FEED_URL</string>
    <key>SUPublicEDKey</key><string>$SU_PUBLIC_ED_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST

echo "==> Code signing Sparkle helpers (inside-out)"
SPK="$FW_DIR/Sparkle.framework/Versions/B"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPK/XPCServices/Downloader.xpc"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPK/XPCServices/Installer.xpc"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPK/Updater.app"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPK/Autoupdate"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$FW_DIR/Sparkle.framework"

echo "==> Code signing app with: $IDENTITY"
codesign --force --options runtime \
    --entitlements "$ROOT/scripts/ZMeet.entitlements" \
    --sign "$IDENTITY" \
    --timestamp \
    "$APP_DIR"

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP_DIR"
echo "==> Done: $APP_DIR"
echo "Run it with:  open \"$APP_DIR\""
