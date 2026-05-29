#!/bin/bash
set -euo pipefail

# Notarizes and staples a .dmg (or .app .zip) so any Mac can open it without
# Gatekeeper warnings.
#
# ONE-TIME SETUP (stores credentials in the keychain as profile "zmeet-notary"):
#   xcrun notarytool store-credentials zmeet-notary \
#       --apple-id "you@example.com" \
#       --team-id "YOURTEAMID" \
#       --password "app-specific-password"   # from appleid.apple.com
#
# Usage: scripts/notarize.sh build/zMeet-0.1.0.dmg
ARTIFACT="${1:?usage: notarize.sh <path-to-dmg-or-zip>}"
PROFILE="${NOTARY_PROFILE:-zmeet-notary}"

echo "==> Submitting $ARTIFACT to Apple notary (profile: $PROFILE)"
xcrun notarytool submit "$ARTIFACT" --keychain-profile "$PROFILE" --wait

echo "==> Stapling ticket"
xcrun stapler staple "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"
echo "==> Notarized + stapled: $ARTIFACT"
