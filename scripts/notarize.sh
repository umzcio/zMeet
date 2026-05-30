#!/bin/bash
set -euo pipefail

# Notarizes a .dmg (or .zip) with Apple using an App Store Connect API key,
# then staples the ticket. Credentials come from scripts/.notary-config.local
# (see .notary-config.example).
#
# Usage: scripts/notarize.sh build/zMeet-1.0.0.dmg
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT="${1:?usage: notarize.sh <path-to-dmg-or-zip>}"
CONFIG="$ROOT/scripts/.notary-config.local"

[ -f "$CONFIG" ] || { echo "error: $CONFIG not found (copy .notary-config.example)"; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG"
KEY_PATH="$(eval echo "$NOTARY_KEY")"

echo "==> Submitting $(basename "$ARTIFACT") to Apple notary"
xcrun notarytool submit "$ARTIFACT" \
    --key "$KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
    --wait

echo "==> Stapling"
xcrun stapler staple "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"
echo "==> Notarized + stapled: $ARTIFACT"
