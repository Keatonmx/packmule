#!/usr/bin/env python3
"""Renders the Packmule app icon to a 1024x1024 PNG using only the standard
library, in the Tinbox icon's family: a leather-tan crate on dark timber with
stamped up/down chevron arrows.

    python3 Scripts/gen_icon.py

Output: Packmule/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
The squircle mask is applied by iOS; the PNG is a full opaque square.
"""
import math
import os
import struct
import sys
import zlib

SIZE = 1024
SS = 2                      # supersampling factor
SCALE = SIZE * SS / 240.0   # design units -> supersampled pixels


def hex_rgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def lerp(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def rrect_sdf(px, py, x, y, w, h, r_tl, r_tr, r_br, r_bl):
    """Signed distance to a rounded rectangle with per-corner radii."""
    cx, cy = x + w / 2, y + h / 2
    qx, qy = px - cx, py - cy
    if qx >= 0 and qy < 0:
        r = r_tr
    elif qx >= 0 and qy >= 0:
        r = r_br
    elif qx < 0 and qy >= 0:
        r = r_bl
    else:
        r = r_tl
    dx = abs(qx) - (w / 2 - r)
    dy = abs(qy) - (h / 2 - r)
    ox, oy = max(dx, 0), max(dy, 0)
    return math.hypot(ox, oy) + min(max(dx, dy), 0) - r


def capsule_sdf(px, py, cx, cy, length, th, deg):
    """Capsule of `length` x `th`, centred (cx, cy), rotated `deg` degrees."""
    a = math.radians(-deg)
    ca, sa = math.cos(a), math.sin(a)
    x = (px - cx) * ca - (py - cy) * sa
    y = (px - cx) * sa + (py - cy) * ca
    h = max(0.0, (length - th) / 2)
    return math.hypot(max(abs(x) - h, 0.0), y) - th / 2


def coverage(d):
    return max(0.0, min(1.0, 0.5 - d / 0.6))


BG_A, BG_B = hex_rgb('#291B0F'), hex_rgb('#0D0806')
LID_A, LID_B = hex_rgb('#D29659'), hex_rgb('#A9713B')
BODY_A, BODY_B = hex_rgb('#C08449'), hex_rgb('#8A5A2E')
STRAP = (52, 32, 15)
STRAP_ALPHA = 0.30
STAMP = (54, 30, 13)
STAMP_ALPHA = 0.52

BODY = (46, 84, 148, 92)      # x, y, w, h
LID = (38, 60, 164, 30)
STRAPS = ((58, 92, 10, 84), (172, 92, 10, 84))

ARROW_TH = 8.5
ARM = 23.0
ARM_OFF = ARM / 2 / math.sqrt(2)

# Up arrow (left): chevron apex + shaft below it.
UP_APEX = (100.0, 108.0)
UP_SHAFT = (100.0, 129.0, 42.0, 90)     # cx, cy, length, angle
# Down arrow (right): shaft above, chevron apex below.
DN_APEX = (140.0, 152.0)
DN_SHAFT = (140.0, 131.0, 42.0, 90)


def arrow_sdf(px, py, up):
    if up:
        ax, ay = UP_APEX
        arms = [
            (ax - ARM_OFF, ay + ARM_OFF, 135),
            (ax + ARM_OFF, ay + ARM_OFF, 45),
        ]
        shaft = UP_SHAFT
    else:
        ax, ay = DN_APEX
        arms = [
            (ax - ARM_OFF, ay - ARM_OFF, 45),
            (ax + ARM_OFF, ay - ARM_OFF, 135),
        ]
        shaft = DN_SHAFT
    d = capsule_sdf(px, py, shaft[0], shaft[1], shaft[2], ARROW_TH, shaft[3])
    for cx, cy, ang in arms:
        d = min(d, capsule_sdf(px, py, cx, cy, ARM, ARROW_TH, ang))
    return d


def shade(px, py):
    # Background: 160deg gradient.
    ang = math.radians(160)
    gx, gy = math.sin(ang), -math.cos(ang)
    t = ((px - 120) * gx + (py - 120) * gy) / 240.0 + 0.5
    t = max(0.0, min(1.0, t))
    color = lerp(BG_A, BG_B, t)

    # Soft drop shadow under the crate.
    sh = coverage(rrect_sdf(px, py - 6, 42, 68, 156, 112, 14, 14, 18, 18) - 6)
    color = lerp(color, (0, 0, 0), 0.35 * sh)

    # Body (rounded bottom corners only).
    d = rrect_sdf(px, py, *BODY, 4, 4, 16, 16)
    body_cov = coverage(d)
    if body_cov > 0:
        t = (py - BODY[1]) / BODY[3]
        body = lerp(BODY_A, BODY_B, max(0.0, min(1.0, t)))
        color = lerp(color, body, body_cov)

        # Straps.
        strap = 0.0
        for rr in STRAPS:
            strap = max(strap, coverage(rrect_sdf(px, py, *rr, 3, 3, 3, 3)))
        if strap > 0:
            color = lerp(color, STRAP, STRAP_ALPHA * strap * body_cov)

        # Stamped arrows, with a hair of light on their lower edge.
        stamp = max(coverage(arrow_sdf(px, py, True)), coverage(arrow_sdf(px, py, False)))
        if stamp > 0:
            color = lerp(color, STAMP, STAMP_ALPHA * stamp * body_cov)
            hl = max(coverage(arrow_sdf(px, py - 1.2, True)), coverage(arrow_sdf(px, py - 1.2, False)))
            edge = max(0.0, hl - stamp)
            color = lerp(color, (255, 255, 255), 0.15 * edge * body_cov)

    # Lid on top.
    d = rrect_sdf(px, py, *LID, 10, 10, 10, 10)
    c = coverage(d)
    if c > 0:
        t = (py - LID[1]) / LID[3]
        lid = lerp(LID_A, LID_B, max(0.0, min(1.0, t)))
        if py - LID[1] < 2:  # inset top highlight
            lid = lerp(lid, (255, 255, 255), 0.3)
        color = lerp(color, lid, c)

    return color


def render():
    w = SIZE
    rows = []
    inv = 1.0 / SCALE
    for y in range(w):
        row = bytearray()
        for x in range(w):
            r = g = b = 0.0
            for sy in range(SS):
                for sx in range(SS):
                    px = (x * SS + sx + 0.5) * inv
                    py = (y * SS + sy + 0.5) * inv
                    cr, cg, cb = shade(px, py)
                    r += cr
                    g += cg
                    b += cb
            n = SS * SS
            row += bytes((int(round(r / n)), int(round(g / n)), int(round(b / n))))
        rows.append(bytes(row))
        if y % 128 == 0:
            print(f"  {y}/{w}", file=sys.stderr)
    return rows


def write_png(path, rows):
    def chunk(tag, data):
        c = struct.pack('>I', len(data)) + tag + data
        return c + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF)
    raw = b''.join(b'\x00' + r for r in rows)
    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', SIZE, SIZE, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(raw, 9))
    png += chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(png)


if __name__ == '__main__':
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.join(root, 'Packmule', 'Resources', 'Assets.xcassets', 'AppIcon.appiconset')
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, 'AppIcon-1024.png')
    print('Rendering icon…', file=sys.stderr)
    write_png(out, render())
    print(f'Wrote {out}', file=sys.stderr)
