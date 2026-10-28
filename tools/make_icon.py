#!/usr/bin/env python3
"""生成 IPASigner 的图标：渐变底 + 手机轮廓 + 手写签名弧线。

输出：
  Resources/AppIcon.icns     给 .app 用（Dock / Finder）
  Resources/appicon.png      512px，界面里当 logo 用
  docs/logo.png              1024px，README 用

用法：python3 tools/make_icon.py
"""
from __future__ import annotations

import math
import os
import subprocess
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SS = 4                     # 超采样倍数
SIZE = 1024                # 最终尺寸
S = SIZE * SS              # 画布尺寸

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "Resources")
DOCS = os.path.join(ROOT, "docs")


def scaled(v: float) -> float:
    """把 1024 坐标系的值换算到超采样画布"""
    return v * SS


def rounded_mask(size: int, box, radius: float) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def diagonal_gradient(size: int, stops) -> Image.Image:
    """stops: [(0.0, (r,g,b)), ..., (1.0, (r,g,b))]，沿左上→右下"""
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    t = (xx + yy) / (2.0 * (size - 1))
    out = np.zeros((size, size, 3), dtype=np.float32)
    for i in range(len(stops) - 1):
        p0, c0 = stops[i]
        p1, c1 = stops[i + 1]
        band = (t >= p0) & (t <= p1)
        local = np.clip((t - p0) / max(p1 - p0, 1e-6), 0, 1)
        for ch in range(3):
            a, b = float(c0[ch]), float(c1[ch])
            out[..., ch] = np.where(band, a + (b - a) * local, out[..., ch])
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), "RGB")


def cubic(p0, p1, p2, p3, n=180):
    pts = []
    for i in range(n + 1):
        u = i / n
        v = 1 - u
        x = v**3 * p0[0] + 3 * v * v * u * p1[0] + 3 * v * u * u * p2[0] + u**3 * p3[0]
        y = v**3 * p0[1] + 3 * v * v * u * p1[1] + 3 * v * u * u * p2[1] + u**3 * p3[1]
        pts.append((x, y))
    return pts


def stroke(layer: Image.Image, pts, width: float, color) -> None:
    """按法向量偏移成闭合多边形一次填充，避免 ImageDraw.line 大宽度下的接缝条纹"""
    left, right = [], []
    n = len(pts)
    half = width / 2
    for i, (x, y) in enumerate(pts):
        if i == 0:
            dx, dy = pts[1][0] - x, pts[1][1] - y
        elif i == n - 1:
            dx, dy = x - pts[-2][0], y - pts[-2][1]
        else:
            dx, dy = pts[i + 1][0] - pts[i - 1][0], pts[i + 1][1] - pts[i - 1][1]
        length = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / length, dx / length
        left.append((x + nx * half, y + ny * half))
        right.append((x - nx * half, y - ny * half))
    d = ImageDraw.Draw(layer)
    d.polygon(left + right[::-1], fill=color)
    for x, y in (pts[0], pts[-1]):
        d.ellipse([x - half, y - half, x + half, y + half], fill=color)


def draw_signature(layer: Image.Image, width: float, color) -> None:
    """一道手写感的签名弧线，从手机左下穿到右上收笔"""
    p = cubic((scaled(258), scaled(742)),
              (scaled(352), scaled(566)),
              (scaled(520), scaled(724)),
              (scaled(636), scaled(596)), n=220)
    p += cubic(p[-1],
               (scaled(714), scaled(516)),
               (scaled(786), scaled(470)),
               (scaled(806), scaled(346)), n=140)
    stroke(layer, p, width, color)


def build() -> Image.Image:
    # ---- 底：圆角方块 + 蓝紫渐变 ----
    base = diagonal_gradient(S, [(0.0, (74, 128, 255)), (0.52, (108, 78, 242)), (1.0, (46, 22, 130))])
    squircle = rounded_mask(S, (scaled(96), scaled(96), scaled(928), scaled(928)), scaled(214))
    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    icon.paste(base, (0, 0), squircle)

    # 顶部高光，给点体积感
    hl = Image.new("L", (S, S), 0)
    hd = ImageDraw.Draw(hl)
    for i in range(int(scaled(320))):
        d = 1 - i / scaled(320)
        hd.line([(0, i), (S, i)], fill=int(46 * d * d))
    hl = Image.composite(hl, Image.new("L", (S, S), 0), squircle)
    icon = Image.composite(Image.new("RGBA", (S, S), (255, 255, 255, 255)), icon, hl.point(lambda v: v))

    # ---- 手机轮廓 ----
    phone = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    pd = ImageDraw.Draw(phone)
    left, top = scaled(354), scaled(222)
    right, bottom = scaled(670), scaled(802)
    stroke = int(scaled(26))
    pd.rounded_rectangle([left, top, right, bottom], radius=scaled(64), outline=(255, 255, 255, 255), width=stroke)
    # 顶部挖孔
    cx = (left + right) / 2
    r = scaled(11)
    pd.ellipse([cx - r, top + scaled(46) - r, cx + r, top + scaled(46) + r], fill=(255, 255, 255, 235))
    # 底部 Home 指示条
    bar_w, bar_h = scaled(96), scaled(9)
    by = bottom - scaled(56)
    pd.rounded_rectangle([cx - bar_w / 2, by, cx + bar_w / 2, by + bar_h],
                         radius=bar_h / 2, fill=(255, 255, 255, 235))
    icon = Image.alpha_composite(icon, phone)

    # ---- 签名弧线（先外发光，再主线，再高光芯）----
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    draw_signature(glow, scaled(30), (64, 232, 255, 190))
    glow = glow.filter(ImageFilter.GaussianBlur(scaled(22)))
    icon = Image.alpha_composite(icon, glow)

    line = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    draw_signature(line, scaled(27), (70, 236, 255, 255))
    icon = Image.alpha_composite(icon, line)

    core = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    draw_signature(core, scaled(10), (232, 255, 255, 235))
    icon = Image.alpha_composite(icon, core)

    # ---- 边缘内描边，收敛轮廓 ----
    ring = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(ring).rounded_rectangle(
        [scaled(96), scaled(96), scaled(928), scaled(928)],
        radius=scaled(214), outline=(255, 255, 255, 46), width=int(scaled(4)))
    icon = Image.alpha_composite(icon, ring)

    return icon.resize((SIZE, SIZE), Image.LANCZOS)


def write_icns(png_path: str, out_icns: str) -> None:
    sizes = [16, 32, 64, 128, 256, 512, 1024]
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        src = Image.open(png_path).convert("RGBA")
        for s in sizes:
            img = src.resize((s, s), Image.LANCZOS)
            img.save(os.path.join(iconset, f"icon_{s}x{s}.png"))
            if s * 2 <= 1024:
                img2 = src.resize((s * 2, s * 2), Image.LANCZOS)
                img2.save(os.path.join(iconset, f"icon_{s}x{s}@2x.png"))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out_icns], check=True)


def main() -> None:
    os.makedirs(RES, exist_ok=True)
    os.makedirs(DOCS, exist_ok=True)
    icon = build()

    logo = os.path.join(DOCS, "logo.png")
    icon.save(logo)

    app_png = os.path.join(RES, "appicon.png")
    icon.resize((512, 512), Image.LANCZOS).save(app_png)

    icns = os.path.join(RES, "AppIcon.icns")
    write_icns(logo, icns)

    print("logo :", logo)
    print("png  :", app_png)
    print("icns :", icns)


if __name__ == "__main__":
    main()
