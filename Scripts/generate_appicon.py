#!/usr/bin/env python3
"""Generate the 1024x1024 app icon (pure Python, no third-party deps)."""
import math
import os
import struct
import zlib

SIZE = 1024
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "GPSTracker", "Resources", "Assets.xcassets",
                   "AppIcon.appiconset", "AppIcon1024.png")


def lerp(a, b, t):
    return a + (b - a) * t


def main():
    buf = bytearray(SIZE * SIZE * 3)
    top = (10, 14, 32)
    bottom = (23, 42, 74)
    for y in range(SIZE):
        t = y / (SIZE - 1)
        r = int(lerp(top[0], bottom[0], t))
        g = int(lerp(top[1], bottom[1], t))
        b = int(lerp(top[2], bottom[2], t))
        row = y * SIZE * 3
        for x in range(SIZE):
            # subtle radial glow towards the centre
            dx = (x - SIZE * 0.5) / SIZE
            dy = (y - SIZE * 0.45) / SIZE
            glow = max(0.0, 1.0 - math.hypot(dx, dy) * 2.1) ** 2 * 26
            i = row + x * 3
            buf[i] = min(255, int(r + glow * 0.3))
            buf[i + 1] = min(255, int(g + glow * 0.7))
            buf[i + 2] = min(255, int(b + glow))

    # route path: a winding trail across the icon
    samples = 1600
    pts = []
    for s in range(samples + 1):
        t = s / samples
        x = lerp(190, 840, t) + math.sin(t * math.pi * 2.1) * 110
        y = lerp(830, 220, t) + math.sin(t * math.pi * 3.0 + 0.6) * 70
        pts.append((x, y, t))

    slow = (58, 150, 255)   # cyan-blue = slow
    fast = (255, 96, 72)    # red-orange = fast
    radius = 30.0
    for (px, py, t) in pts:
        cr = lerp(slow[0], fast[0], t)
        cg = lerp(slow[1], fast[1], t)
        cb = lerp(slow[2], fast[2], t)
        x0, x1 = int(px - radius) - 1, int(px + radius) + 2
        y0, y1 = int(py - radius) - 1, int(py + radius) + 2
        for y in range(max(0, y0), min(SIZE, y1)):
            dy = y - py
            row = y * SIZE * 3
            for x in range(max(0, x0), min(SIZE, x1)):
                dx = x - px
                d = math.sqrt(dx * dx + dy * dy)
                if d > radius:
                    continue
                a = 1.0 if d < radius - 1.5 else (radius - d) / 1.5
                i = row + x * 3
                buf[i] = int(lerp(buf[i], cr, a))
                buf[i + 1] = int(lerp(buf[i + 1], cg, a))
                buf[i + 2] = int(lerp(buf[i + 2], cb, a))

    # current-position marker at the end of the trail
    ex, ey, _ = pts[-1]
    for y in range(max(0, int(ey - 80)), min(SIZE, int(ey + 80))):
        row = y * SIZE * 3
        for x in range(max(0, int(ex - 80)), min(SIZE, int(ex + 80))):
            d = math.hypot(x - ex, y - ey)
            if d > 72:
                continue
            if d < 40:
                col, a = (255, 255, 255), 1.0
            elif d < 52:
                col, a = (255, 96, 72), 1.0
            else:
                col, a = (255, 96, 72), max(0.0, (72 - d) / 20.0) * 0.55
            i = row + x * 3
            buf[i] = int(lerp(buf[i], col[0], a))
            buf[i + 1] = int(lerp(buf[i + 1], col[1], a))
            buf[i + 2] = int(lerp(buf[i + 2], col[2], a))

    raw = bytearray()
    for y in range(SIZE):
        raw.append(0)
        raw += buf[y * SIZE * 3:(y + 1) * SIZE * 3]

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as fh:
        fh.write(png)
    print("wrote", OUT, os.path.getsize(OUT), "bytes")


if __name__ == "__main__":
    main()
