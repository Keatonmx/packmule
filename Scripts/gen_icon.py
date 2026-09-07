#!/usr/bin/env python3
"""Renders the Packmule app icon from Design/appicon-map.txt.

The map came from a ChatGPT concept (Design/icon-concept.png) snapped onto
a true grid by Scripts/snap_concept.py, then hand polished cell by cell.
Composition theirs, pixels ours. Edit the map, re-run this, done.

    python3 Scripts/gen_icon.py

Output: Packmule/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
Requires Pillow (python -m pip install pillow).
"""
import os
import sys
from PIL import Image, ImageDraw

SIZE = 1024
COLORS = {
    "o": (59, 41, 26), "b": (201, 122, 74), "l": (227, 168, 120),
    "m": (122, 79, 41), "c": (156, 107, 64), "t": (217, 161, 92),
    "s": (74, 51, 33), "e": (26, 20, 15),
}
BG_A, BG_B = (41, 27, 15), (13, 8, 6)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAP = os.path.join(ROOT, "Design", "appicon-map.txt")
OUT = os.path.join(ROOT, "Packmule", "Resources", "Assets.xcassets",
                   "AppIcon.appiconset", "AppIcon-1024.png")

cells = [line.rstrip("\n") for line in open(MAP) if line.strip("\n")]
grid = len(cells)

img = Image.new("RGB", (SIZE, SIZE))
d = ImageDraw.Draw(img)
for py in range(SIZE):
    t = min(1.0, max(0.0, (py / SIZE) * 0.85 + 0.1))
    col = tuple(int(BG_A[i] + (BG_B[i] - BG_A[i]) * t) for i in range(3))
    d.line([(0, py), (SIZE, py)], fill=col)
cell = SIZE / grid
for gy, row in enumerate(cells):
    for gx, ch in enumerate(row):
        if ch in COLORS:
            d.rectangle([int(gx * cell), int(gy * cell),
                         int((gx + 1) * cell) - 1, int((gy + 1) * cell) - 1],
                        fill=COLORS[ch])
img.save(OUT)
print("Wrote", OUT, file=sys.stderr)
