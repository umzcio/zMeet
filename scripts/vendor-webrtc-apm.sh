#!/bin/bash
set -euo pipefail

# Regenerates the vendored WebRTC audio processing module (AEC3) in
# Sources/CWebRTCAPM/webrtc and Sources/CWebRTCAPM/abseil from the pinned
# webrtc-audio-processing release. NEVER hand-edit that output: change the pin
# here and re-run. Sources/CWebRTCAPM/include/ and zmeet/ (zMeet's C facade)
# are left untouched.
#
# Needs meson and ninja (brew install meson ninja) plus network: it downloads
# the tarball, and meson fetches the pinned Abseil wrap and checks its sha256.
# meson builds the library once (arm64, NEON on) so the exact compiled file set
# can be read back from its compile commands, ninja deps and object symbols;
# nothing from that build is kept.
#
#   scripts/vendor-webrtc-apm.sh
URL=https://freedesktop.org/software/pulseaudio/webrtc-audio-processing/webrtc-audio-processing-2.1.tar.xz
SHA256=ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/scripts/webrtc-apm"
TARGET="$ROOT/Sources/CWebRTCAPM"

[ "$(uname -m)" = arm64 ] || { echo "error: run on Apple silicon — the vendored set is the arm64 + NEON build"; exit 1; }
for tool in meson ninja; do
  command -v "$tool" >/dev/null || { echo "error: $tool not installed (brew install meson ninja)"; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Resolved (pwd -P): meson records real paths, and the helpers match them
# against this one, so a symlinked temp dir (/var -> /private/var) would
# silently drop every header from the vendored set.
WORK="$(cd "$WORK" && pwd -P)"

TARBALL="$WORK/$(basename "$URL")"
curl -fsSL --retry 3 -o "$TARBALL" "$URL"
echo "$SHA256  $TARBALL" | shasum -a 256 -c -
mkdir -p "$WORK/src"
tar -xf "$TARBALL" -C "$WORK/src"
SRC="$(find "$WORK/src" -mindepth 1 -maxdepth 1 -type d | head -1)"

# -Dneon=enabled: 2.1's default (auto) silently leaves out the NEON sources,
# which the CWebRTCAPM target needs (it defines WEBRTC_HAS_NEON).
export MACOSX_DEPLOYMENT_TARGET=26.0
meson setup "$WORK/build" "$SRC" --buildtype release --default-library static \
  --force-fallback-for abseil-cpp -Dabseil-cpp:default_library=static -Dneon=enabled
ninja -C "$WORK/build"

python3 -I "$TOOLS/extract_vendor_set.py" "$WORK/build" "$WORK/lists"
ABSL="$(find "$SRC/subprojects" -mindepth 1 -maxdepth 1 -type d -name 'abseil-cpp-*' | head -1)"
python3 -I "$TOOLS/vendor_copy.py" "$SRC/webrtc" "$ABSL" "$WORK/lists" "$WORK/out"

# A broken extraction yields a short list, not an error: refuse to swap it in.
for list in apm21-webrtc-headers.txt apm21-absl-headers-all.txt; do
  [ "$(wc -l < "$WORK/lists/$list")" -ge 10 ] || { echo "error: $list is nearly empty — extraction failed"; exit 1; }
done

# Swap in the fresh trees only once they are complete.
mkdir -p "$TARGET"
rm -rf "$TARGET/webrtc" "$TARGET/abseil"
mv "$WORK/out/webrtc" "$TARGET/webrtc"
mv "$WORK/out/abseil" "$TARGET/abseil"
echo "Vendored $(find "$TARGET/webrtc" "$TARGET/abseil" -type f | wc -l | tr -d ' ') files into $TARGET/{webrtc,abseil}"
