#!/usr/bin/env python3
"""Regenerate the in-app "z" brand mark from the source artwork.

Input:   assets/brand/source/zMeet_z.png  (full-resolution mark, transparent background)
Outputs: assets/brand/ZMark.png (64px tall) and ZMark@2x.png (128px tall), trimmed
         to the artwork. build-app.sh copies them into the app bundle; the
         ZMeetWordmark view (Sources/ZMeetApp/ZMeetWordmark.swift) shows them.
Requires Pillow: pip3 install pillow
"""
from pathlib import Path
from PIL import Image

BRAND = Path(__file__).resolve().parent.parent / "assets" / "brand"

def main() -> None:
    art = Image.open(BRAND / "source" / "zMeet_z.png").convert("RGBA")
    art = art.crop(art.getbbox())
    for height, name in [(64, "ZMark.png"), (128, "ZMark@2x.png")]:
        width = round(art.width * height / art.height)
        art.resize((width, height), Image.LANCZOS).save(BRAND / name, optimize=True)
        print(f"wrote {name} ({width}x{height})")

if __name__ == "__main__":
    main()
