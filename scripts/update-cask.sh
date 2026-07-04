#!/bin/bash
set -euo pipefail

# Bumps the zmeet cask in umzcio/homebrew-tap to <version>.
#
# Run AFTER the v<version> GitHub release is published — the cask's download
# URL must resolve before users can `brew install`.
#
# Usage: scripts/update-cask.sh 1.0.0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: update-cask.sh <version>  e.g. 1.0.0}"
DMG="$ROOT/build/dist/zMeet-$VERSION.dmg"
TAP_REPO="git@github.com:umzcio/homebrew-tap.git"

if [[ -f "$DMG" ]]; then
    SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
else
    echo "==> No local $DMG; hashing the published release asset instead"
    URL="https://github.com/umzcio/zMeet/releases/download/v$VERSION/zMeet-$VERSION.dmg"
    SHA="$(curl -fsSL "$URL" | shasum -a 256 | awk '{print $1}')"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git clone --quiet --depth 1 "$TAP_REPO" "$TMP/tap"

CASK="$TMP/tap/Casks/zmeet.rb"
sed -i '' -E "s|^  version \".*\"|  version \"$VERSION\"|" "$CASK"
sed -i '' -E "s|^  sha256 \".*\"|  sha256 \"$SHA\"|" "$CASK"

if git -C "$TMP/tap" diff --quiet; then
    echo "==> Cask already at $VERSION; nothing to do"
    exit 0
fi

git -C "$TMP/tap" commit --quiet -am "zmeet $VERSION"
git -C "$TMP/tap" push --quiet
echo "==> Cask bumped: zmeet $VERSION ($SHA)"
