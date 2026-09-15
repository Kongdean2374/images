#!/usr/bin/env python3
"""Generate the 1024x1024 app icon (pure Python, no third-party deps).

構圖：深色地圖底 → 街道格線 → 等高線 → 海拔剖面 → 配速漸層軌跡（含描邊、
高光、途經點）→ 起終點標記 → 指北玫瑰 → 玻璃反光 → 邊緣輪廓光。
"""
import math
import os
import struct
import zlib

SIZE = 1024
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "GPSTracker", "Resources", "Assets.xcassets",
                   "AppIcon.appiconset", "AppIcon1024.png")

buf = bytearray(SIZE * SIZE * 3)


def lerp(a, b, t):
    return a + (b - a) * t


def mix(c1, c2, t):
    return (lerp(c1[0], c2[0], t), lerp(c1[1], c2[1], t), lerp(c1[2], c2[2], t))


def blend(x, y, color, alpha):
    if alpha <= 0 or x < 0 or y < 0 or x >= SIZE or y >= SIZE:
        return
    a = min(1.0, alpha)
    i = (y * SIZE + x) * 3
    buf[i] = int(lerp(buf[i], color[0], a))
    buf[i + 1] = int(lerp(buf[i + 1], color[1], a))
    buf[i + 2] = int(lerp(buf[i + 2], color[2], a))


def disc(cx, cy, r, color, alpha=1.0, feather=1.5):
    x0, x1 = max(0, int(cx - r) - 1), min(SIZE, int(cx + r) + 2)
    y0, y1 = max(0, int(cy - r) - 1), min(SIZE, int(cy + r) + 2)
    for y in range(y0, y1):
        dy = y - cy
        for x in range(x0, x1):
            dx = x - cx
            d = math.sqrt(dx * dx + dy * dy)
            if d > r:
                continue
            a = alpha if d < r - feather else alpha * (r - d) / feather
            blend(x, y, color, a)


def ring(cx, cy, r, width, color, alpha=1.0):
    inner = r - width
    x0, x1 = max(0, int(cx - r) - 1), min(SIZE, int(cx + r) + 2)
    y0, y1 = max(0, int(cy - r) - 1), min(SIZE, int(cy + r) + 2)
    for y in range(y0, y1):
        dy = y - cy
        for x in range(x0, x1):
            dx = x - cx
            d = math.sqrt(dx * dx + dy * dy)
            if d > r or d < inner - 1:
                continue
            a = alpha
            if d > r - 1.2:
                a *= (r - d) / 1.2
            elif d < inner + 1.2:
                a *= (d - inner) / 1.2
            blend(x, y, color, max(0.0, a))


def line(x0, y0, x1, y1, width, color, alpha=1.0):
    length = math.hypot(x1 - x0, y1 - y0)
    steps = max(2, int(length))
    r = width / 2
    for s in range(steps + 1):
        t = s / steps
        disc(lerp(x0, x1, t), lerp(y0, y1, t), r, color, alpha, feather=1.0)


def triangle(p0, p1, p2, color, alpha=1.0):
    minx = max(0, int(min(p0[0], p1[0], p2[0])))
    maxx = min(SIZE - 1, int(max(p0[0], p1[0], p2[0])) + 1)
    miny = max(0, int(min(p0[1], p1[1], p2[1])))
    maxy = min(SIZE - 1, int(max(p0[1], p1[1], p2[1])) + 1)

    def sign(a, b, c):
        return (a[0] - c[0]) * (b[1] - c[1]) - (b[0] - c[0]) * (a[1] - c[1])

    for y in range(miny, maxy + 1):
        for x in range(minx, maxx + 1):
            pt = (x + 0.5, y + 0.5)
            d1 = sign(pt, p0, p1)
            d2 = sign(pt, p1, p2)
            d3 = sign(pt, p2, p0)
            has_neg = (d1 < 0) or (d2 < 0) or (d3 < 0)
            has_pos = (d1 > 0) or (d2 > 0) or (d3 > 0)
            if not (has_neg and has_pos):
                blend(x, y, color, alpha)


def main():
    # ---------- 背景 ----------
    top = (13, 19, 46)
    mid = (28, 41, 92)
    bottom = (10, 15, 36)
    for y in range(SIZE):
        fy = y / (SIZE - 1)
        row = y * SIZE * 3
        for x in range(SIZE):
            fx = x / (SIZE - 1)
            d = (fx * 0.45 + fy * 0.55)
            base = mix(top, mid, d / 0.55) if d < 0.55 else mix(mid, bottom, (d - 0.55) / 0.45)

            dx = (x - SIZE * 0.44) / SIZE
            dy = (y - SIZE * 0.40) / SIZE
            glow = max(0.0, 1.0 - math.hypot(dx, dy) * 1.85) ** 2.2 * 30

            vx = (x - SIZE * 0.5) / (SIZE * 0.5)
            vy = (y - SIZE * 0.5) / (SIZE * 0.5)
            vignette = 1.0 - min(1.0, (vx * vx + vy * vy) * 0.26)

            i = row + x * 3
            buf[i] = max(0, min(255, int((base[0] + glow * 0.3) * vignette)))
            buf[i + 1] = max(0, min(255, int((base[1] + glow * 0.7) * vignette)))
            buf[i + 2] = max(0, min(255, int((base[2] + glow) * vignette)))

    # ---------- 街道格線（斜向，像地圖底圖） ----------
    street = (120, 160, 230)
    angle = math.radians(26)
    dxs, dys = math.cos(angle), math.sin(angle)
    for k in range(-14, 15):
        offset = k * 96
        cx = SIZE / 2 - dys * offset
        cy = SIZE / 2 + dxs * offset
        alpha = 0.05 if k % 3 else 0.085
        width = 2.0 if k % 3 else 3.4
        line(cx - dxs * 1400, cy - dys * 1400, cx + dxs * 1400, cy + dys * 1400,
             width, street, alpha)
    angle2 = angle + math.pi / 2
    dxs2, dys2 = math.cos(angle2), math.sin(angle2)
    for k in range(-14, 15):
        offset = k * 132
        cx = SIZE / 2 - dys2 * offset
        cy = SIZE / 2 + dxs2 * offset
        alpha = 0.04 if k % 2 else 0.07
        line(cx - dxs2 * 1400, cy - dys2 * 1400, cx + dxs2 * 1400, cy + dys2 * 1400,
             2.4, street, alpha)

    # ---------- 等高線 ----------
    contour = (150, 190, 255)
    for ringIndex in range(5):
        radius = 232 + ringIndex * 118
        steps = 1800
        wobble = 0.06 + ringIndex * 0.012
        for s in range(steps):
            a = s / steps * math.pi * 2
            rr = radius * (1 + math.sin(a * 3 + ringIndex) * wobble)
            px = SIZE * 0.47 + math.cos(a) * rr
            py = SIZE * 0.52 + math.sin(a) * rr * 0.84
            blend(int(px), int(py), contour, 0.16)
            blend(int(px) + 1, int(py), contour, 0.10)
            blend(int(px), int(py) + 1, contour, 0.10)

    # ---------- 底部海拔剖面 ----------
    profile = []
    for x in range(SIZE):
        t = x / SIZE
        h = (math.sin(t * 7.2) * 34 + math.sin(t * 3.1 + 1.2) * 52
             + math.sin(t * 13.5 + 0.4) * 14)
        profile.append(SIZE - 118 + h)
    for x in range(SIZE):
        topY = int(profile[x])
        for y in range(max(0, topY), SIZE):
            fade = 0.30 * (1 - (y - topY) / max(1, SIZE - topY)) + 0.10
            blend(x, y, (36, 62, 128), fade)
        for w in range(3):
            blend(x, topY + w, (120, 200, 255), 0.30 - w * 0.08)

    # ---------- 路徑 ----------
    samples = 1700
    pts = []
    for s in range(samples + 1):
        t = s / samples
        x = lerp(228, 792, t) + math.sin(t * math.pi * 2.05) * 98
        y = lerp(792, 268, t) + math.sin(t * math.pi * 3.0 + 0.55) * 62
        pts.append((x, y, t))

    slow = (56, 150, 255)
    mid_c = (152, 108, 255)
    fast = (255, 104, 72)

    def path_color(t):
        return mix(slow, mid_c, t / 0.5) if t < 0.5 else mix(mid_c, fast, (t - 0.5) / 0.5)

    # 外光暈
    glow_r = 62.0
    for idx in range(0, len(pts), 9):
        px, py, t = pts[idx]
        cr, cg, cb = path_color(t)
        x0, x1 = max(0, int(px - glow_r)), min(SIZE, int(px + glow_r) + 1)
        y0, y1 = max(0, int(py - glow_r)), min(SIZE, int(py + glow_r) + 1)
        for y in range(y0, y1):
            dy = y - py
            for x in range(x0, x1):
                dx = x - px
                d = math.sqrt(dx * dx + dy * dy)
                if d > glow_r:
                    continue
                a = (1 - d / glow_r) ** 2 * 0.09
                i = (y * SIZE + x) * 3
                buf[i] = min(255, int(buf[i] + cr * a))
                buf[i + 1] = min(255, int(buf[i + 1] + cg * a))
                buf[i + 2] = min(255, int(buf[i + 2] + cb * a))

    # 描邊 → 主體 → 高光，做出立體緞帶感
    for (px, py, t) in pts:
        disc(px, py, 39, (9, 13, 32), 0.9, feather=2.0)
    for (px, py, t) in pts:
        disc(px, py, 31, path_color(t), 1.0, feather=1.6)
    for idx, (px, py, t) in enumerate(pts):
        if idx % 2:
            continue
        c = path_color(t)
        bright = (min(255, c[0] + 90), min(255, c[1] + 90), min(255, c[2] + 90))
        disc(px, py - 9, 10, bright, 0.30, feather=4.0)

    # 途經點：依實際弧長等距分佈，避免在轉彎處擠在一起
    arc = [0.0]
    for i in range(1, len(pts)):
        arc.append(arc[-1] + math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]))
    total_arc = arc[-1]
    for k in range(1, 5):
        target = total_arc * k / 5
        idx = min(range(len(arc)), key=lambda j: abs(arc[j] - target))
        px, py, _ = pts[idx]
        disc(px, py, 16, (12, 17, 40), 0.92)
        disc(px, py, 9.5, (255, 255, 255), 0.94)

    # ---------- 起點 ----------
    sx, sy, _ = pts[0]
    disc(sx, sy, 40, (9, 13, 32), 0.55)
    disc(sx, sy, 33, (255, 255, 255), 0.96)
    disc(sx, sy, 23, (52, 217, 162))
    disc(sx, sy, 9, (255, 255, 255), 0.85)

    # ---------- 終點 ----------
    ex, ey, _ = pts[-1]
    disc(ex, ey, 104, (255, 120, 80), 0.16, feather=64)
    disc(ex, ey + 6, 64, (8, 12, 30), 0.45)
    disc(ex, ey, 62, (255, 255, 255), 0.97)
    disc(ex, ey, 47, (255, 104, 72))
    ring(ex, ey, 34, 4, (255, 190, 170), 0.55)
    disc(ex, ey, 19, (255, 255, 255), 0.95)

    # ---------- 指北玫瑰 ----------
    cx, cy, R = 168.0, 176.0, 74.0
    ring(cx, cy, R, 3, (170, 205, 255), 0.30)
    ring(cx, cy, R - 16, 1.6, (170, 205, 255), 0.18)
    for i in range(8):
        a = i * math.pi / 4 - math.pi / 2
        long_arm = (i % 2 == 0)
        length = R - 6 if long_arm else R - 30
        wide = 13 if long_arm else 7
        tip = (cx + math.cos(a) * length, cy + math.sin(a) * length)
        left = (cx + math.cos(a + math.pi / 2) * wide, cy + math.sin(a + math.pi / 2) * wide)
        right = (cx + math.cos(a - math.pi / 2) * wide, cy + math.sin(a - math.pi / 2) * wide)
        color = (255, 255, 255) if i == 0 else (150, 190, 250)
        alpha = 0.72 if i == 0 else 0.30
        triangle(tip, left, right, color, alpha)
    disc(cx, cy, 9, (255, 255, 255), 0.55)

    # ---------- 配速色階小圖例（右下，膠囊狀） ----------
    lx, ly, lw, lh = 676.0, 902.0, 244.0, 18.0
    radius = lh / 2
    cy_legend = ly + radius
    for i in range(int(lw)):
        t = i / lw
        c = path_color(t)
        px = lx + i
        # 兩端做成圓角
        if i < radius:
            half = math.sqrt(max(0.0, radius * radius - (radius - i) ** 2))
        elif i > lw - radius:
            half = math.sqrt(max(0.0, radius * radius - (i - (lw - radius)) ** 2))
        else:
            half = radius
        for j in range(int(-half), int(half) + 1):
            edge = 1.0 if abs(j) < half - 1.2 else 0.45
            blend(int(px), int(cy_legend + j), c, 0.9 * edge)
    # 兩端刻度
    for tick in (0.0, 0.5, 1.0):
        tx = lx + lw * tick
        for j in range(6):
            blend(int(tx), int(cy_legend + radius + 4 + j), (190, 215, 255), 0.35)

    # ---------- 玻璃反光 ----------
    for y in range(0, int(SIZE * 0.55)):
        for x in range(0, SIZE):
            fx = x / SIZE
            fy = y / SIZE
            d = 1.0 - min(1.0, math.hypot(fx - 0.18, fy - 0.05) * 1.5)
            if d <= 0:
                continue
            blend(x, y, (255, 255, 255), d * d * 0.055)

    # ---------- 邊緣輪廓光 ----------
    for i in range(6):
        a = 0.10 - i * 0.016
        for x in range(SIZE):
            blend(x, i, (255, 255, 255), a)
            blend(x, SIZE - 1 - i, (255, 255, 255), a * 0.4)
        for y in range(SIZE):
            blend(i, y, (255, 255, 255), a * 0.8)
            blend(SIZE - 1 - i, y, (255, 255, 255), a * 0.4)

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
