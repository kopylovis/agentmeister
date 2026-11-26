"""Иконки выдуманных проектов для демо скриншотов: docs/screenshots/demo/icons/*.png, 512x512.
Рисует сам, без Chrome и PIL: фигуры заданы функциями расстояния, края сглажены."""
import math, os, struct, zlib
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "demo", "icons")
S = 512
def png(path, px):
    raw = b"".join(b"\x00" + bytes(row) for row in px)
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", S, S, 8, 6, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
def hexc(h): return tuple(int(h[i:i+2], 16) for i in (1, 3, 5))
def box(px, py, cx, cy, hw, hh, r):
    qx, qy = abs(px - cx) - hw + r, abs(py - cy) - hh + r
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r
def seg(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay; t = max(0, min(1, ((px-ax)*dx + (py-ay)*dy) / (dx*dx + dy*dy)))
    return math.hypot(px - ax - t*dx, py - ay - t*dy)
def ell(px, py, cx, cy, a, b, rot):
    c, s = math.cos(rot), math.sin(rot); x, y = (px-cx)*c + (py-cy)*s, -(px-cx)*s + (py-cy)*c
    k0 = math.hypot(x/a, y/b); k1 = math.hypot(x/(a*a), y/(b*b))
    return k0*(k0-1)/k1 if k1 else -min(a, b)
def cov(d): return max(0.0, min(1.0, 0.5 - d))
def draw(name, top, bottom, glyph):
    t, b = hexc(top), hexc(bottom); rows = []
    for y in range(S):
        row = []; py = y + 0.5; g = y / S
        base = [t[i] + (b[i]-t[i]) * g for i in range(3)]
        for x in range(S):
            px = x + 0.5
            a = cov(box(px, py, 256, 256, 240, 240, 108))
            if a <= 0: row += [0, 0, 0, 0]; continue
            col = list(base)
            if g < 0.5:  # блик сверху
                k = 0.18 * (1 - g / 0.5); col = [c + (255 - c) * k for c in col]
            w = cov(glyph(px, py))
            col = [c + (255 - c) * w for c in col]
            row += [int(col[0]), int(col[1]), int(col[2]), int(a * 255)]
        rows.append(row)
    png(os.path.join(OUT, name + ".png"), rows)
def stroke(d, w): return abs(d) - w / 2
def union(*ds): return min(ds)
draw("ledger-api", "#34d399", "#0f766e", lambda x, y: union(
    seg(x, y, 150, 170, 362, 170) - 13, seg(x, y, 150, 256, 280, 256) - 13, seg(x, y, 150, 342, 240, 342) - 13,
    seg(x, y, 300, 330, 334, 364) - 15, seg(x, y, 334, 364, 404, 284) - 15))
draw("orbit-ios", "#818cf8", "#4c1d95", lambda x, y: union(
    math.hypot(x-256, y-256) - 84, stroke(ell(x, y, 256, 256, 172, 58, math.radians(-24)), 22),
    math.hypot(x-392, y-150) - 22))
draw("atlas-web", "#fb923c", "#db2777", lambda x, y: union(
    stroke(math.hypot(x-256, y-256) - 148, 24), stroke(ell(x, y, 256, 256, 62, 148, 0), 22),
    max(seg(x, y, 108, 256, 404, 256) - 10, math.hypot(x-256, y-256) - 148),
    max(seg(x, y, 120, 182, 392, 182) - 10, math.hypot(x-256, y-256) - 148),
    max(seg(x, y, 120, 330, 392, 330) - 10, math.hypot(x-256, y-256) - 148)))
draw("infra", "#64748b", "#1e293b", lambda x, y: union(
    stroke(box(x, y, 256, 176, 120, 48, 22), 24), stroke(box(x, y, 256, 336, 120, 48, 22), 24),
    math.hypot(x-190, y-176) - 15, math.hypot(x-190, y-336) - 15,
    seg(x, y, 250, 176, 322, 176) - 11, seg(x, y, 250, 336, 322, 336) - 11))
