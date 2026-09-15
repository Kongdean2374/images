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


def mix(c1, c2, t):
    return (lerp(c1[0], c2[0], t), lerp(c1[1], c2[1], t), lerp(c1[2], c2[2], t))


def main():
    buf = bytearray(SIZE * SIZE * 3)

    # --- 背景：對角漸層 + 中央光暈 + 四角暗角 ---
    top = (14, 20, 48)
    mid = (26, 38, 86)
    bottom = (12, 18, 40)
    for y in range(SIZE):
        row = y * SIZE * 3
        fy = y / (SIZE - 1)
        for x in range(SIZE):
            fx = x / (SIZE - 1)
            d = (fx + fy) / 2
            if d < 0.55:
                base = mix(top, mid, d / 0.55)
            else:
                base = mix(mid, bottom, (d - 0.55) / 0.45)

            dx = (x - SIZE * 0.42) / SIZE
            dy = (y - SIZE * 0.38) / SIZE
            glow = max(0.0, 1.0 - math.hypot(dx, dy) * 1.9) ** 2.2 * 34

            vx = (x - SIZE * 0.5) / (SIZE * 0.5)
            vy = (y - SIZE * 0.5) / (SIZE * 0.5)
            vignette = 1.0 - min(1.0, (vx * vx + vy * vy) * 0.22)

            i = row + x * 3
            buf[i] = max(0, min(255, int((base[0] + glow * 0.35) * vignette)))
            buf[i + 1] = max(0, min(255, int((base[1] + glow * 0.75) * vignette)))
            buf[i + 2] = max(0, min(255, int((base[2] + glow) * vignette)))

    # --- 淡淡的等高線，暗示地圖 ---
    for ring in range(3):
        radius = 300 + ring * 132
        steps = 1500
        for s in range(steps):
            angle = s / steps * math.pi * 2
            px = SIZE * 0.5 + math.cos(angle) * radius
            py = SIZE * 0.52 + math.sin(angle) * radius * 0.82
            for oy in range(-2, 3):
                for ox in range(-2, 3):
                    xx, yy = int(px) + ox, int(py) + oy
                    if 0 <= xx < SIZE and 0 <= yy < SIZE:
                        i = (yy * SIZE + xx) * 3
                        buf[i] = min(255, buf[i] + 4)
                        buf[i + 1] = min(255, buf[i + 1] + 6)
                        buf[i + 2] = min(255, buf[i + 2] + 9)

    # --- 路徑取樣點 ---
    samples = 1700
    pts = []
    for s in range(samples + 1):
        t = s / samples
        x = lerp(226, 800, t) + math.sin(t * math.pi * 2.05) * 96
        y = lerp(800, 272, t) + math.sin(t * math.pi * 3.0 + 0.55) * 60
        pts.append((x, y, t))

    slow = (56, 150, 255)    # 慢 → 藍
    mid_c = (150, 110, 255)  # 中 → 紫
    fast = (255, 104, 72)    # 快 → 橘紅

    def path_color(t):
        return mix(slow, mid_c, t / 0.5) if t < 0.5 else mix(mid_c, fast, (t - 0.5) / 0.5)

    # 外層光暈（每 8 點取一次，控制運算量）
    glow_radius = 64.0
    for idx in range(0, len(pts), 8):
        px, py, t = pts[idx]
        cr, cg, cb = path_color(t)
        x0, x1 = max(0, int(px - glow_radius)), min(SIZE, int(px + glow_radius) + 1)
        y0, y1 = max(0, int(py - glow_radius)), min(SIZE, int(py + glow_radius) + 1)
        for y in range(y0, y1):
            dy = y - py
            row = y * SIZE * 3
            for x in range(x0, x1):
                dx = x - px
                d = math.sqrt(dx * dx + dy * dy)
                if d > glow_radius:
                    continue
                a = (1 - d / glow_radius) ** 2 * 0.10
                i = row + x * 3
                buf[i] = min(255, int(buf[i] + cr * a))
                buf[i + 1] = min(255, int(buf[i + 1] + cg * a))
                buf[i + 2] = min(255, int(buf[i + 2] + cb * a))

    # 實心路徑
    radius = 33.0
    for (px, py, t) in pts:
        cr, cg, cb = path_color(t)
        x0, x1 = max(0, int(px - radius) - 1), min(SIZE, int(px + radius) + 2)
        y0, y1 = max(0, int(py - radius) - 1), min(SIZE, int(py + radius) + 2)
        for y in range(y0, y1):
            dy = y - py
            row = y * SIZE * 3
            for x in range(x0, x1):
                dx = x - px
                d = math.sqrt(dx * dx + dy * dy)
                if d > radius:
                    continue
                a = 1.0 if d < radius - 1.6 else (radius - d) / 1.6
                i = row + x * 3
                buf[i] = int(lerp(buf[i], cr, a))
                buf[i + 1] = int(lerp(buf[i + 1], cg, a))
                buf[i + 2] = int(lerp(buf[i + 2], cb, a))

    def disc(cx, cy, r, color, alpha=1.0, feather=1.6):
        x0, x1 = max(0, int(cx - r) - 1), min(SIZE, int(cx + r) + 2)
        y0, y1 = max(0, int(cy - r) - 1), min(SIZE, int(cy + r) + 2)
        for y in range(y0, y1):
            dy = y - cy
            row = y * SIZE * 3
            for x in range(x0, x1):
                dx = x - cx
                d = math.sqrt(dx * dx + dy * dy)
                if d > r:
                    continue
                a = alpha if d < r - feather else alpha * (r - d) / feather
                i = row + x * 3
                buf[i] = int(lerp(buf[i], color[0], a))
                buf[i + 1] = int(lerp(buf[i + 1], color[1], a))
                buf[i + 2] = int(lerp(buf[i + 2], color[2], a))

    # 起點：薄荷綠小點
    sx, sy, _ = pts[0]
    disc(sx, sy, 34, (255, 255, 255), 0.95)
    disc(sx, sy, 24, (52, 217, 162))

    # 終點：白圈 + 橘紅實心 + 光暈
    ex, ey, _ = pts[-1]
    disc(ex, ey, 96, (255, 120, 80), 0.16, feather=60)
    disc(ex, ey, 62, (255, 255, 255), 0.96)
    disc(ex, ey, 48, (255, 104, 72))
    disc(ex, ey, 20, (255, 255, 255), 0.92)

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
