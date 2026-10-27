#!/bin/bash
set -euo pipefail

# Notarizes a .dmg (or .zip) with Apple, then staples the ticket. Credentials
# come from a notarytool Keychain profile (default "notary"; override with
# NOTARY_PROFILE), saved once with `xcrun notarytool store-credentials`.
# See docs/RELEASING.md.
#
# Usage: scripts/notarize.sh build/zMeet-1.0.0.dmg
ARTIFACT="${1:?usage: notarize.sh <path-to-dmg-or-zip>}"
PROFILE="${NOTARY_PROFILE:-notary}"

echo "==> Submitting $(basename "$ARTIFACT") to Apple notary (profile: $PROFILE)"
xcrun notarytool submit "$ARTIFACT" --keychain-profile "$PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"
echo "==> Notarized + stapled: $ARTIFACT"
