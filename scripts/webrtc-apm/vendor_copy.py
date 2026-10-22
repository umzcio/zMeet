# Copies the exact meson-derived file sets into a SwiftPM C++ target.
# usage: python3 -I vendor_copy.py <webrtc-src-root> <abseil-root> <list-dir> <target-dir>
import os, shutil, sys
webrtc_root, absl_root, lists, target = sys.argv[1:5]
def lines(name):
    return [l.strip() for l in open(os.path.join(lists, name)) if l.strip()]
def cp(src_root, rel, dst_root):
    s = os.path.join(src_root, rel); d = os.path.join(dst_root, rel)
    os.makedirs(os.path.dirname(d), exist_ok=True); shutil.copy2(s, d)
n = 0
for rel in lines("apm21-arm64-sources.txt") + lines("apm21-webrtc-headers.txt"):
    cp(webrtc_root, rel, os.path.join(target, "webrtc")); n += 1
for rel in lines("apm21-absl-headers-all.txt") + lines("apm21-absl-sources.txt"):
    cp(absl_root, rel, os.path.join(target, "abseil")); n += 1
# license files travel with the code
for rel in ["LICENSE", "PATENTS", "third_party/rnnoise/COPYING", "third_party/pffft/LICENSE",
            "modules/third_party/fft/LICENSE", "common_audio/third_party/spl_sqrt_floor/LICENSE",
            "common_audio/third_party/ooura/LICENSE"]:
    cp(webrtc_root, rel, os.path.join(target, "webrtc")); n += 1
cp(absl_root, "LICENSE", os.path.join(target, "abseil")); n += 1
print("copied", n, "files")
