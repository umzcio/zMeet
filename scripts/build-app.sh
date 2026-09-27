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
SCRATCH="${ZMEET_SCRATCH:-$ROOT/.build}"

# App version (also stamped into the appcast on release).
# Single source of truth: release.sh asserts its version argument matches this.
VERSION="${ZMEET_VERSION:-1.16.0}"
BUILD="${ZMEET_BUILD:-27}"

# Sparkle auto-update: appcast feed URL + EdDSA public key (private key is in the
# login keychain via generate_keys).
SU_FEED_URL="https://raw.githubusercontent.com/umzcio/zMeet/main/appcast.xml"
SU_PUBLIC_ED_KEY="7KQVNte/Z3ts81v6gETASf21YKulzZZTiqMpF8uv5G8="

SPARKLE_ART="$SCRATCH/artifacts/sparkle/Sparkle"
if [[ -z "$SPARKLE_ART" || ! -e "$SPARKLE_ART" ]]; then
  echo "error: Sparkle artifacts not found in $SCRATCH. Run: rm -rf .build && swift build   (stale artifact cache)" >&2
  exit 1
fi
SPARKLE_FW="$SPARKLE_ART/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -e "$SPARKLE_FW" ]]; then
  echo "error: Sparkle artifacts not found in $SCRATCH. Run: rm -rf .build && swift build   (stale artifact cache)" >&2
  exit 1
fi

echo "==> Compiling ZMeetApp (release)"
# The extra rpath lets the bundled binary find Sparkle.framework in Contents/Frameworks.
RPATH_FLAGS="-Xlinker -rpath -Xlinker @executable_path/../Frameworks"
swift build -c release --product ZMeetApp --package-path "$ROOT" --scratch-path "$SCRATCH" $RPATH_FLAGS
BIN="$(swift build -c release --product ZMeetApp --package-path "$ROOT" --scratch-path "$SCRATCH" --show-bin-path)/ZMeetApp"

echo "==> Assembling bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR" "$FW_DIR"
cp "$BIN" "$MACOS_DIR/$APP_NAME"

# Embed Sparkle.framework.
echo "==> Embedding Sparkle.framework"
cp -R "$SPARKLE_FW" "$FW_DIR/"

# Bundle the wordmark font (auto-registered at launch via ATSApplicationFontsPath).
mkdir -p "$RES_DIR/Fonts"
cp "$ROOT/assets/fonts/DancingScript.ttf" "$RES_DIR/Fonts/DancingScript.ttf"

# App icon: compile the Icon Composer document into Assets.car (light, dark,
# and tinted appearances for macOS 26) plus a zMeet.icns fallback. Needs Xcode's
# actool; fail loudly rather than ship a flat icon. actool mis-resolves relative
# paths, so pass absolute ones.
if ! xcrun --find actool >/dev/null 2>&1; then
  echo "error: actool not found — install Xcode (xcode-select -s /Applications/Xcode.app)" >&2
  exit 1
fi
ICON_PLIST="$(mktemp -t zmeet-icon).plist"
xcrun actool "$ROOT/assets/app-icon/zMeet.icon" \
    --compile "$RES_DIR" \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --app-icon zMeet \
    --include-all-app-icons \
    --output-partial-info-plist "$ICON_PLIST" \
    --output-format human-readable-text >/dev/null
if [[ ! -f "$RES_DIR/Assets.car" || ! -f "$RES_DIR/zMeet.icns" ]]; then
  echo "error: actool did not produce Assets.car + zMeet.icns from assets/app-icon/zMeet.icon" >&2
  exit 1
fi
rm -f "$ICON_PLIST"

# Menu-bar icon layers (generated from the artwork by scripts/make-menubar-icon.py).
cp "$ROOT"/assets/menubar/MenuBarIcon*.png "$RES_DIR/"

# In-app "z" brand mark (ZMeetWordmark), 1x + 2x — regenerate with scripts/make-zmark.py.
cp "$ROOT"/assets/brand/ZMark*.png "$RES_DIR/"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>zMeet</string>
    <key>CFBundleIconName</key><string>zMeet</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>ATSApplicationFontsPath</key><string>Fonts</string>
    <key>NSMicrophoneUsageDescription</key><string>zMeet records your microphone during meetings to create notes.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>zMeet transcribes your meeting recordings on-device to create notes.</string>
    <key>NSLocalNetworkUsageDescription</key><string>zMeet connects to your Ollama server on your local network to write meeting notes.</string>
    <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
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
