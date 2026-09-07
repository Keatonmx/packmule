#!/usr/bin/env python3
"""Renders the Packmule app icon: the actual in-app pixel mule (same sprite
data as Shared/PixelArt.swift, same palette), mid stride on his dashed trail
with arrowheads both ways, motion streaks and hoof dust. Standard library
only.

    python3 Scripts/gen_icon.py

Output: Packmule/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
"""
import os
import struct
import sys
import zlib

SIZE = 1024
GRID = 64                 # virtual pixels per side
CELL = SIZE // GRID

# Palette (matches MuleSprites.palette in Shared/PixelArt.swift)
PALETTE = {
    "o": (59, 41, 26),      # outline
    "b": (201, 122, 74),    # hide (Mule tan)
    "l": (227, 168, 120),   # belly, muzzle
    "m": (122, 79, 41),     # mane, tail, hooves
    "c": (156, 107, 64),    # crate
    "t": (217, 161, 92),    # crate highlight
    "s": (74, 51, 33),      # strap
    "e": (26, 20, 15),      # eye
    "r": (122, 79, 41),     # trail dashes (mane brown)
    "u": (150, 118, 88),    # hoof dust
    "w": (227, 168, 120),   # motion streaks (light tan)
}

BG_A, BG_B = (41, 27, 15), (13, 8, 6)   # the family timber gradient

# ---- the mule, ported box for box from PixelArt.swift ----------------------
SPRITE_W, SPRITE_H = 26, 18

TORSO = [
    (6, 0, 6, 1, "t"), (5, 1, 8, 5, "c"), (8, 1, 1, 5, "s"),
    (0, 7, 3, 2, "m"), (0, 9, 2, 2, "m"),
    (3, 6, 15, 7, "b"), (8, 6, 1, 7, "s"), (5, 11, 11, 2, "l"),
    (16, 2, 2, 2, "m"), (16, 4, 1, 2, "m"),
    (17, 3, 6, 6, "b"),
    (22, 6, 2, 3, "l"), (24, 7, 1, 2, "l"),
    (17, 0, 1, 1, "m"), (16, 1, 2, 3, "m"),
    (21, 0, 1, 1, "m"), (20, 1, 2, 4, "m"),
    (21, 5, 1, 1, "e"), (24, 7, 1, 1, "m"),
]

def legs(positions):
    boxes = []
    for x, y, h in positions:
        boxes.append((x, y, 2, h, "b"))
        boxes.append((x, y + h - 1, 2, 1, "m"))
    return boxes

# walkB: mid stride, legs gathered — the most "moving" frame.
WALK_B = TORSO + legs([(3, 13, 4), (9, 14, 3), (12, 14, 3), (17, 13, 4)])


def build_grid():
    grid = [["." for _ in range(GRID)] for _ in range(GRID)]

    def stamp(x, y, ch):
        if 0 <= x < GRID and 0 <= y < GRID and ch != ".":
            grid[y][x] = ch

    # Mule at 2x cells, roughly centred with air on every side.
    ox, oy, scale = 7, 11, 2
    for bx, by, bw, bh, ch in WALK_B:
        for yy in range(by, by + bh):
            for xx in range(bx, bx + bw):
                if xx < SPRITE_W and yy < SPRITE_H:
                    for sy in range(scale):
                        for sx in range(scale):
                            stamp(ox + xx * scale + sx, oy + yy * scale + sy, ch)

    # Motion streaks behind the rump: he is going somewhere.
    for x0, y, ln in [(1, 25, 5), (0, 30, 7), (2, 35, 4)]:
        for x in range(x0, x0 + ln):
            stamp(x, y, "w")

    # Hoof dust: two small puffs kicked up right behind the stride.
    for x, y in [(12, 49), (13, 49), (13, 48), (20, 49), (21, 49)]:
        stamp(x, y, "u")

    # The trail: dashes under his hooves, arrowheads BOTH ways — files go
    # back and forth, and so does the mule.
    ty = 53
    for x in range(9, 55):
        if (x // 3) % 2 == 0:
            stamp(x, ty, "r")
            stamp(x, ty + 1, "r")
    # left arrowhead
    for i in range(4):
        stamp(5 + i, ty - i, "r")
        stamp(5 + i, ty + 1 + i, "r")
        stamp(5 + i, ty, "r")
        stamp(5 + i, ty + 1, "r")
    # right arrowhead
    for i in range(4):
        stamp(58 - i, ty - i, "r")
        stamp(58 - i, ty + 1 + i, "r")
        stamp(58 - i, ty, "r")
        stamp(58 - i, ty + 1, "r")

    # The classic one pixel dark outline around every painted region.
    outlined = [row[:] for row in grid]
    for y in range(GRID):
        for x in range(GRID):
            if grid[y][x] == ".":
                for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                    if 0 <= nx < GRID and 0 <= ny < GRID and grid[ny][nx] != ".":
                        outlined[y][x] = "o"
                        break
    return outlined


def render(grid):
    rows = []
    for py in range(SIZE):
        gy = py // CELL
        # vertical-ish 160 degree gradient
        t = min(1.0, max(0.0, (py / SIZE) * 0.85 + 0.1))
        bg = tuple(int(BG_A[i] + (BG_B[i] - BG_A[i]) * t) for i in range(3))
        row = bytearray()
        for px in range(SIZE):
            gx = px // CELL
            ch = grid[gy][gx]
            color = PALETTE.get(ch, bg) if ch != "." else bg
            row += bytes(color)
        rows.append(bytes(row))
    return rows


def write_png(path, rows):
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + r for r in rows)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


if __name__ == "__main__":
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.join(root, "Packmule", "Resources", "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, "AppIcon-1024.png")
    write_png(out, render(build_grid()))
    print("Wrote", out, file=sys.stderr)
