#!/usr/bin/env python3
"""Regenerate the menu-bar icon layers from the source artwork.

Inputs (scripts/assets/menubar/source/):
  zMeetIcon.png        white mic + badge, z cut out of the badge (the plain icon)
  zMeetIcon_color.png  same drawing with the z filled green (the recording look)

Outputs (scripts/assets/menubar/), each at 18pt tall in 1x and @2x:
  MenuBarIcon[@2x].png   the icon shape as a black alpha mask
  MenuBarIconZ[@2x].png  just the z, same canvas, as a black alpha mask
The app tints these at draw time (see Sources/ZMeetApp/MenuBarIcon.swift).
Requires Pillow: pip3 install pillow
"""
from pathlib import Path
from PIL import Image

HERE = Path(__file__).resolve().parent / "assets" / "menubar"
POINT_HEIGHT = 18

def z_mask(colored: Image.Image) -> Image.Image:
    """The green-dominant pixels of the colored version, as an alpha mask."""
    mask = Image.new("L", colored.size, 0)
    src, dst = colored.load(), mask.load()
    for x in range(colored.width):
        for y in range(colored.height):
            r, g, b, a = src[x, y]
            if a and g > r + 25 and g > b + 25:
                dst[x, y] = a
    return mask

def write(mask: Image.Image, name: str) -> None:
    for scale, suffix in ((1, ""), (2, "@2x")):
        h = POINT_HEIGHT * scale
        w = round(mask.width * h / mask.height)
        alpha = mask.resize((w, h), Image.LANCZOS)
        out = Image.new("RGBA", (w, h), (0, 0, 0, 255))
        out.putalpha(alpha)
        out.save(HERE / f"{name}{suffix}.png", optimize=True)

plain = Image.open(HERE / "source" / "zMeetIcon.png").convert("RGBA")
colored = Image.open(HERE / "source" / "zMeetIcon_color.png").convert("RGBA")
box = plain.getchannel("A").getbbox()            # crop both to the icon's bounds
write(plain.getchannel("A").crop(box), "MenuBarIcon")
write(z_mask(colored).crop(box), "MenuBarIconZ")
print("wrote", sorted(p.name for p in HERE.glob("MenuBarIcon*.png")))
