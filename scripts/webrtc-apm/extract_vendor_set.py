# Derives the exact file set to vendor from a configured+built meson tree of
# webrtc-audio-processing (arm64, -Dneon=enabled):
#   - WebRTC sources  = compile_commands.json entries outside subprojects/examples
#   - WebRTC headers  = `ninja -t deps` of those objects (+ the public forwarding headers)
#   - Abseil .cc      = transitive closure of absl symbols the WebRTC objects leave
#                       undefined, resolved against the Abseil objects meson built
#   - Abseil headers  = `ninja -t deps` of the WebRTC objects + those Abseil objects
# usage: python3 -I extract_vendor_set.py <build-dir> <out-dir>
import json, os, re, subprocess, sys

bdir, outdir = map(os.path.abspath, sys.argv[1:3])
os.makedirs(outdir, exist_ok=True)
cc = json.load(open(os.path.join(bdir, "compile_commands.json")))

def norm(p, base):
    return os.path.normpath(os.path.join(base, p))

web_objs, absl_objs = {}, {}  # object path -> source path
for c in cc:
    src = norm(c["file"], c["directory"])
    obj = norm(c["output"], c["directory"])
    if "/examples/" in src:
        continue
    (absl_objs if "/subprojects/" in src else web_objs)[obj] = src

def rel_webrtc(p): return p.split("/webrtc/", 1)[1] if "/subprojects/" not in p else None
def rel_absl(p): return "absl/" + p.split("/absl/", 1)[1]

def nm(obj, flags):
    out = subprocess.run(["nm"] + flags + [obj], capture_output=True, text=True).stdout
    return {l.split()[-1] for l in out.splitlines() if l.strip()}

defined_by = {}
for o in absl_objs:
    for s in nm(o, ["-g", "--defined-only"]):
        defined_by.setdefault(s, o)
web_defined = set().union(*(nm(o, ["-g", "--defined-only"]) for o in web_objs))
need = {s for o in web_objs for s in nm(o, ["-u"]) if "absl" in s} - web_defined
picked, queue = set(), list(need)
while queue:
    s = queue.pop()
    o = defined_by.get(s)
    if o is None or o in picked:
        continue
    picked.add(o)
    queue += [u for u in nm(o, ["-u"]) if "absl" in u]

deps = subprocess.run(["ninja", "-C", bdir, "-t", "deps"], capture_output=True, text=True).stdout
web_h, absl_h = set(), set()
wanted = set(web_objs) | picked
for block in re.split(r"\n(?=\S)", deps):
    lines = block.strip().splitlines()
    if not lines:
        continue
    target = norm(lines[0].split(":")[0], bdir)
    if target not in wanted:
        continue
    for l in lines[1:]:
        p = norm(l.strip(), bdir)
        if not p.endswith((".h", ".inc")):
            continue
        if "/subprojects/" in p and "/absl/" in p:
            absl_h.add(rel_absl(p))
        elif "/webrtc/" in p and "/subprojects/" not in p:
            web_h.add(rel_webrtc(p))
web_h |= {"modules/audio_processing/include/audio_processing.h",
          "modules/audio_processing/include/audio_processing_statistics.h"}

def write(name, items):
    with open(os.path.join(outdir, name), "w") as f:
        f.write("\n".join(sorted(items)) + "\n")
    print(f"{name}: {len(items)}")

write("apm21-arm64-sources.txt", {rel_webrtc(s) for s in web_objs.values()})
write("apm21-webrtc-headers.txt", web_h)
write("apm21-absl-sources.txt", {rel_absl(absl_objs[o]) for o in picked})
write("apm21-absl-headers-all.txt", absl_h)
