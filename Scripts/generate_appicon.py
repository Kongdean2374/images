#!/usr/bin/env python3
"""Generate the 1024x1024 app icon (pure Python, no third-party deps).

設計：速度儀表 + 導航箭頭
  深色漸層底 → 外圈刻度 → 灰底軌道 → 配速漸層弧（藍→綠→琥珀→橘）
  → 弧端光點 → 中央立體導航箭頭 → 玻璃反光 → 邊緣輪廓光
"""
import math
import os
import struct
import zlib

SIZE = 1024
CX, CY = 512.0, 508.0
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
    a = 1.0 if alpha > 1 else alpha
    i = (y * SIZE + x) * 3
    buf[i] = int(lerp(buf[i], color[0], a))
    buf[i + 1] = int(lerp(buf[i + 1], color[1], a))
    buf[i + 2] = int(lerp(buf[i + 2], color[2], a))


def add(x, y, color, alpha):
    if alpha <= 0 or x < 0 or y < 0 or x >= SIZE or y >= SIZE:
        return
    i = (y * SIZE + x) * 3
    buf[i] = min(255, int(buf[i] + color[0] * alpha))
    buf[i + 1] = min(255, int(buf[i + 1] + color[1] * alpha))
    buf[i + 2] = min(255, int(buf[i + 2] + color[2] * alpha))


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


def glow_disc(cx, cy, r, color, strength):
    x0, x1 = max(0, int(cx - r)), min(SIZE, int(cx + r) + 1)
    y0, y1 = max(0, int(cy - r)), min(SIZE, int(cy + r) + 1)
    for y in range(y0, y1):
        dy = y - cy
        for x in range(x0, x1):
            dx = x - cx
            d = math.sqrt(dx * dx + dy * dy)
            if d > r:
                continue
            add(x, y, color, (1 - d / r) ** 2 * strength)


def polygon(points, color, alpha=1.0):
    """凸多邊形掃描填色（含 1px 邊緣淡化）。"""
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    minx, maxx = max(0, int(min(xs)) - 1), min(SIZE - 1, int(max(xs)) + 1)
    miny, maxy = max(0, int(min(ys)) - 1), min(SIZE - 1, int(max(ys)) + 1)
    n = len(points)
    # 先判斷繞向，讓順時針與逆時針都能正確填色
    area = 0.0
    for i in range(n):
        ax, ay = points[i]
        bx, by = points[(i + 1) % n]
        area += ax * by - bx * ay
    sign = 1.0 if area >= 0 else -1.0

    for y in range(miny, maxy + 1):
        for x in range(minx, maxx + 1):
            px, py = x + 0.5, y + 0.5
            inside = True
            min_edge = 1e9
            for i in range(n):
                ax, ay = points[i]
                bx, by = points[(i + 1) % n]
                cross = ((bx - ax) * (py - ay) - (by - ay) * (px - ax)) * sign
                if cross < -0.7:
                    inside = False
                    break
                length = math.hypot(bx - ax, by - ay)
                if length > 0:
                    min_edge = min(min_edge, cross / length)
            if inside:
                blend(x, y, color, alpha * min(1.0, max(0.2, min_edge)))


def rotate(point, cx, cy, degrees):
    a = math.radians(degrees)
    dx, dy = point[0] - cx, point[1] - cy
    return (cx + dx * math.cos(a) - dy * math.sin(a),
            cy + dx * math.sin(a) + dy * math.cos(a))


def arc(radius, thickness, a0, a1, color_fn, alpha=1.0, step=0.25):
    r = thickness / 2
    a = a0
    while a <= a1:
        t = (a - a0) / max(1e-6, (a1 - a0))
        rad = math.radians(a)
        disc(CX + math.cos(rad) * radius, CY + math.sin(rad) * radius,
             r, color_fn(t), alpha, feather=1.4)
        a += step


def main():
    # ---------- 背景 ----------
    deep = (9, 12, 30)
    indigo = (30, 34, 84)
    for y in range(SIZE):
        for x in range(SIZE):
            d = math.hypot((x - CX) / SIZE, (y - CY * 0.92) / SIZE) * 1.55
            base = mix(indigo, deep, min(1.0, d))
            glow = max(0.0, 1.0 - d * 1.22) ** 2.2 * 52
            i = (y * SIZE + x) * 3
            buf[i] = max(0, min(255, int(base[0] + glow * 0.30)))
            buf[i + 1] = max(0, min(255, int(base[1] + glow * 0.55)))
            buf[i + 2] = max(0, min(255, int(base[2] + glow)))

    # 細微同心圓，做出金屬錶面感
    for k in range(9):
        rr = 120 + k * 46
        steps = int(rr * 7)
        for s in range(steps):
            a = s / steps * math.pi * 2
            blend(int(CX + math.cos(a) * rr), int(CY + math.sin(a) * rr),
                  (150, 180, 255), 0.030)

    A0, A1 = 135.0, 405.0          # 儀表開口朝下
    R = 338.0
    THICK = 58.0
    PROGRESS = 0.80                # 弧線填滿比例

    slow = (58, 142, 255)
    mid = (46, 214, 160)
    warm = (255, 196, 66)
    fast = (255, 96, 66)

    def pace_color(t):
        if t < 0.38:
            return mix(slow, mid, t / 0.38)
        if t < 0.72:
            return mix(mid, warm, (t - 0.38) / 0.34)
        return mix(warm, fast, (t - 0.72) / 0.28)

    # ---------- 外圈刻度 ----------
    ticks = 24
    for i in range(ticks + 1):
        t = i / ticks
        a = math.radians(lerp(A0, A1, t))
        major = (i % 4 == 0)
        inner = R + THICK / 2 + 16
        outer = inner + (38 if major else 17)
        width = 9.0 if major else 4.0
        color = (226, 238, 255) if major else (146, 174, 226)
        alpha = 0.70 if major else 0.24
        steps = int(outer - inner)
        for s in range(steps + 1):
            rr = inner + s
            disc(CX + math.cos(a) * rr, CY + math.sin(a) * rr,
                 width / 2, color, alpha, feather=1.0)

    # ---------- 軌道 ----------
    arc(R, THICK, A0, A1, lambda t: (36, 44, 82), 0.95)
    arc(R, THICK - 16, A0, A1, lambda t: (22, 28, 58), 0.85)

    # ---------- 進度弧（含外光暈） ----------
    a_end = lerp(A0, A1, PROGRESS)
    a = A0
    while a <= a_end:
        t = (a - A0) / (A1 - A0)
        rad = math.radians(a)
        px, py = CX + math.cos(rad) * R, CY + math.sin(rad) * R
        glow_disc(px, py, 58, pace_color(t / PROGRESS), 0.05)
        a += 3.0
    arc(R, THICK - 4, A0, a_end, lambda t: pace_color(t), 1.0, step=0.2)
    # 弧內側高光
    arc(R - 13, 10, A0, a_end, lambda t: mix(pace_color(t), (255, 255, 255), 0.55), 0.35, step=0.4)

    # 弧端光點
    rad_end = math.radians(a_end)
    ex, ey = CX + math.cos(rad_end) * R, CY + math.sin(rad_end) * R
    glow_disc(ex, ey, 92, fast, 0.30)
    disc(ex, ey, 34, (255, 255, 255), 0.95)
    disc(ex, ey, 23, fast)

    # ---------- 中央導航箭頭 ----------
    # 整體上移，讓箭頭在儀表開口內視覺置中
    AY = CY - 26
    tip = (CX, AY - 232)
    left = (CX - 174, AY + 186)
    notch = (CX, AY + 92)
    right = (CX + 174, AY + 186)
    tilt = -16.0
    tip_r = rotate(tip, CX, CY, tilt)
    left_r = rotate(left, CX, CY, tilt)
    notch_r = rotate(notch, CX, CY, tilt)
    right_r = rotate(right, CX, CY, tilt)

    # 兩層位移陰影，讓箭頭在弧線上浮起來
    for offset, alpha in ((30, 0.30), (16, 0.45)):
        shadow = [(p[0], p[1] + offset) for p in (tip_r, left_r, notch_r, right_r)]
        polygon([shadow[0], shadow[1], shadow[2]], (5, 8, 22), alpha)
        polygon([shadow[0], shadow[2], shadow[3]], (5, 8, 22), alpha)

    polygon([tip_r, left_r, notch_r], (255, 255, 255), 1.0)
    polygon([tip_r, notch_r, right_r], (186, 201, 236), 1.0)
    # 箭頭上的細亮邊
    polygon([tip_r,
             (lerp(tip_r[0], left_r[0], 0.12), lerp(tip_r[1], left_r[1], 0.12)),
             (lerp(tip_r[0], notch_r[0], 0.3), lerp(tip_r[1], notch_r[1], 0.3))],
            (255, 255, 255), 0.85)

    # ---------- 玻璃反光 ----------
    for y in range(0, int(SIZE * 0.62)):
        for x in range(SIZE):
            fx, fy = x / SIZE, y / SIZE
            d = 1.0 - min(1.0, math.hypot(fx - 0.22, fy - 0.02) * 1.45)
            if d > 0:
                blend(x, y, (255, 255, 255), d * d * 0.065)

    # ---------- 邊緣輪廓光 ----------
    for i in range(7):
        a = 0.11 - i * 0.015
        for x in range(SIZE):
            blend(x, i, (255, 255, 255), a)
            blend(x, SIZE - 1 - i, (255, 255, 255), a * 0.35)
        for y in range(SIZE):
            blend(i, y, (255, 255, 255), a * 0.75)
            blend(SIZE - 1 - i, y, (255, 255, 255), a * 0.35)

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
