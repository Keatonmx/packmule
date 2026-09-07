#!/usr/bin/env python3
"""Snaps an AI generated pixel art concept onto a true uniform grid in the
Packmule palette, over the clean timber gradient. This is how a ChatGPT
concept becomes a shippable asset: composition theirs, pixels ours.

    python3 Scripts/snap_concept.py <input.png> [--grid N] [--out path]

Without --grid it renders a contact sheet of candidate grids to pick from
(saved next to the input as <name>-contact.png).
"""
import argparse
import os
import sys
from PIL import Image, ImageDraw

# The kit palette.
SPRITE_COLORS = {
    "o": (59, 41, 26), "b": (201, 122, 74), "l": (227, 168, 120),
    "m": (122, 79, 41), "c": (156, 107, 64), "t": (217, 161, 92),
    "s": (74, 51, 33), "e": (26, 20, 15),
}
BG_A, BG_B = (41, 27, 15), (13, 8, 6)
# Background reference shades for classification (their gradients vary).
BG_REFS = [BG_A, BG_B, (30, 20, 11), (20, 13, 8), (50, 35, 22)]


def dist(a, b):
    return sum((a[i] - b[i]) ** 2 for i in range(3))


# Several reference shades per palette colour: AI concepts shade inside
# regions, and every shade of hide must flatten to hide, not to dark brown.
REFS = {
    "b": [(201, 122, 74), (180, 105, 60), (163, 95, 52), (214, 138, 88), (150, 88, 48)],
    "l": [(227, 168, 120), (240, 195, 155), (242, 222, 195), (215, 150, 105)],
    "m": [(122, 79, 41), (104, 66, 34), (90, 58, 30)],
    "c": [(156, 107, 64), (142, 96, 56), (172, 122, 76)],
    "t": [(217, 161, 92), (232, 182, 122)],
    "s": [(74, 51, 33)],
    "o": [(59, 41, 26), (70, 50, 32)],
    "e": [(26, 20, 15), (12, 10, 8)],
}


def classify(px):
    """Map a sampled pixel to a palette char or background."""
    best_bg = min(dist(px, ref) for ref in BG_REFS)
    best_ch, best_d = None, 10 ** 9
    for ch, refs in REFS.items():
        for col in refs:
            d = dist(px, col)
            if d < best_d:
                best_ch, best_d = ch, d
    # Paint must beat the background DECISIVELY; dim ambiguous cells are
    # gradient noise, and noise belongs to the background.
    if best_d < best_bg * 0.8:
        return best_ch
    return "."


def snap(img, grid):
    """Centre sample each cell, classify, then drop isolated outline specks
    that sit in open background (gradient noise)."""
    w, h = img.size
    cell_w, cell_h = w / grid, h / grid
    cells = []
    for gy in range(grid):
        row = []
        for gx in range(grid):
            px = img.getpixel((int((gx + 0.5) * cell_w), int((gy + 0.5) * cell_h)))[:3]
            row.append(classify(px))
        cells.append(row)
    # Two sweeps: any painted cell with no painted neighbour is a speck.
    for _ in range(2):
        for gy in range(grid):
            for gx in range(grid):
                if cells[gy][gx] != ".":
                    neighbours = 0
                    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                        nx, ny = gx + dx, gy + dy
                        if 0 <= nx < grid and 0 <= ny < grid and cells[ny][nx] != ".":
                            neighbours += 1
                    if neighbours == 0:
                        cells[gy][gx] = "."
    return cells


def render(cells, size=1024):
    grid = len(cells)
    img = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(img)
    for py in range(size):
        t = min(1.0, max(0.0, (py / size) * 0.85 + 0.1))
        col = tuple(int(BG_A[i] + (BG_B[i] - BG_A[i]) * t) for i in range(3))
        d.line([(0, py), (size, py)], fill=col)
    cell = size / grid
    for gy, row in enumerate(cells):
        for gx, ch in enumerate(row):
            if ch != ".":
                d.rectangle([int(gx * cell), int(gy * cell),
                             int((gx + 1) * cell) - 1, int((gy + 1) * cell) - 1],
                            fill=SPRITE_COLORS[ch])
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("--grid", type=int)
    ap.add_argument("--out")
    ap.add_argument("--dump-map", help="also write the cell map to this text file")
    args = ap.parse_args()

    src = Image.open(args.input).convert("RGB")
    if args.grid:
        cells = snap(src, args.grid)
        if args.dump_map:
            with open(args.dump_map, "w") as f:
                f.write("\n".join("".join(row) for row in cells) + "\n")
            print("wrote", args.dump_map)
        img = render(cells)
        out = args.out or os.path.splitext(args.input)[0] + "-snapped.png"
        img.save(out)
        print("wrote", out)
        return

    candidates = [44, 48, 52, 56, 62]
    thumb = 500
    sheet = Image.new("RGB", (thumb * len(candidates), thumb + 30), (0, 0, 0))
    d = ImageDraw.Draw(sheet)
    for i, g in enumerate(candidates):
        img = render(snap(src, g), size=thumb)
        sheet.paste(img, (i * thumb, 30))
        d.text((i * thumb + 8, 8), "grid " + str(g), fill=(255, 255, 255))
    out = os.path.splitext(args.input)[0] + "-contact.png"
    sheet.save(out)
    print("wrote", out)


if __name__ == "__main__":
    main()
