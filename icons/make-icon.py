#!/usr/bin/env python3
"""WordWand 菜单栏图标生成器

两套构图，靠文件顶部的 STYLE 切换，输出都是 18×18 pt 的矢量 PDF：

  "sf"（默认）  照 SF Symbols 的 wand.and.stars 描一遍：等宽圆头杖，
                杖尖那段是描边的（中间掏一道圆头槽），旁边三颗四角星
  "star"        早先自己排的三颗星，杖身带收细、杖尖斜切
  "rays"        杖尖一圈放射状短线，照 SF Symbols 的 wand.and.rays

为什么自己在矢量里重画一遍，而不是把那个 SF Symbol 导出来直接用：
Hammerspoon 的菜单栏图标吃的是 18×18 pt 的矢量 PDF（hs.menubar 把图标当
template image）。NSImage 把 SF Symbol 画进 PDF 上下文时得到的是一层位图，
位图在 hs.menubar 里会按像素尺寸绘制、再被画布裁掉，最后只剩中间一团。
所以这里按同样的构图用纯路径重画，顺带把线加粗一档——菜单栏里 1pt 的描边会发虚。

几个硬约束（改之前先看）：
  · 画布 18×18 pt，图案收在 1.2–16.8 之间，留出菜单栏的呼吸空间
  · 纯黑填充 + 透明通道，交给 hs.menubar 当 template image，深浅菜单栏自动反色
  · 杖宽 3.1pt 上下：18pt 下再细就退成一根头发丝，整枚只像"雪花"，看不出是魔杖
  · star 版：杖尖斜切一刀，斜口顺着星芒的左下凹口，中间留 1.5pt 空隙——
    硬顶上去会在交接处漏一个白三角
  · rays 版：七条光线（八条里跳掉 -45° 那根，那个方向是杖身），光线粗 1.0pt、
    长 2.45pt，内端离杖尖 4.55pt，别让光线糊到杖身上

用法：
  python3 icons/make-icon.py            # 输出 icons/rewrite.pdf
  python3 icons/make-icon.py out.pdf    # 指定输出
"""
import math
import os
import sys

SIZE = 18.0
K = 0.5522847498          # 圆角/圆弧的贝塞尔常数

STYLE = "sf"              # "sf" = 照 SF Symbols 的 wand.and.stars 重画（默认）
                          # "star" = 早先自己排的三颗星；"rays" = 杖尖一圈放射线

# ── sf 版：按 SF Symbols「wand.and.stars」的构图描一遍 ────────────────────
# 图上量出来的比例（150px 见方的内容，映射到 1.1–16.9 pt）：
#   杖：左上→右下 45°，宽 2.21pt，杖尖那段是描边的（中间掏一道槽）
#   星：右上一颗大的、左中一颗中的、下方一颗小的，三颗都是正四角星
SF_TIP = (5.37, 12.42)    # 杖尖圆心（左上）
SF_BUTT = (15.69, 2.21)   # 杖尾圆心（右下）
SF_WAND_W = 2.21          # 杖宽（通体等宽）
SF_SLOT_FROM = -0.21      # 杖尖那道槽：起点（相对杖尖，正方向指向杖尾）
SF_SLOT_TO = 4.32         #                终点
SF_SLOT_W = 0.68          #                槽宽
SF_STARS = ((12.74, 13.74, 3.16),
            (3.31, 6.47, 2.26),
            (5.95, 3.42, 1.45))
SF_STAR_Q = 0.50          # 凹腰：控制点落在相邻尖的轴上，0.5 最贴 SF 原图

# ── star 版：早先自己排的三颗星（杖尖是斜切的）────────────────────────────
BUTT = (2.60, 2.80)       # 杖尾圆心
AIM = (12.20, 12.40)      # 杖尖指着的方向（星在它右边偏上）
WAND_W0 = 3.00            # 杖尾直径
WAND_W1 = 2.40            # 杖尖直径
TIP_GAP = 2.40            # 杖尖根部停在离 AIM 多远
TIP_BEVEL = 1.40          # 杖尖斜切长度：靠星那一侧多探出去一截
# 三颗星：右上一颗大的，杖身两侧各一颗小的（闪烁感）
STARS = ((13.95, 14.15, 3.50, 0.16),
         (6.55, 10.55, 1.75, 0.15),
         (8.15, 4.35, 1.30, 0.15))

# ── rays 版 ──────────────────────────────────────────────────────────────
CENTER = (8.80, 9.20)     # 光芒的中心，也是杖尖对着的位置（略偏左上，给右下角的杖身让位）
RAY_R0 = 4.55             # 光线内端半径（离杖尖远一点，让杖尖独立）
RAY_R1 = 7.00             # 光线外端半径
RAY_W = 1.00              # 光线粗细
RAY_ANGLES = (90, 45, 135, 180, 0, 270, 225)   # 跳掉 -45°：那个方向是杖身
RAY_WAND_LEN = 9.90       # 杖长（杖尖圆心到杖尾圆心）
RAY_BUTT_W = 2.55         # 杖尾直径
RAY_TIP_W = 2.30          # 杖尖直径
RAY_TIP_GAP = 0.60        # 杖尖圆心离光芒中心多远


def star4(cx, cy, r, q=0.5, style="sf"):
    """四角星：四个尖分别在上下左右，两条边之间用三次贝塞尔收出凹腰。

    style="sf"   控制点落在相邻那条尖轴上（q=0.5 最贴 SF Symbols 的 sparkle：
                 腰部半径 ≈ 0.45r，星臂从根部才开始收细）
    style="thin" 控制点落在自己这条尖轴上，腰更细更尖（旧版用 q≈0.16）
    """
    w = r * q
    tips = [(cx, cy + r), (cx + r, cy), (cx, cy - r), (cx - r, cy)]
    angles = [math.pi / 2, 0, -math.pi / 2, math.pi]
    ops = [('m',) + tips[0]]
    for i in range(4):
        a0, a1 = angles[i], angles[(i + 1) % 4]
        if style == "thin":
            c1 = (cx + w * math.cos(a0), cy + w * math.sin(a0))
            c2 = (cx + w * math.cos(a1), cy + w * math.sin(a1))
        else:
            c1 = (cx + w * math.cos(a1), cy + w * math.sin(a1))
            c2 = (cx + w * math.cos(a0), cy + w * math.sin(a0))
        ops.append(('c',) + c1 + c2 + tips[(i + 1) % 4])
    ops.append(('h',))
    return ops


def wand_star(butt, aim, w0, w1, gap, bevel):
    """一根杖：半圆杖尾 + 收细的杖身 + 斜切杖尖，朝 aim 方向伸过去"""
    dx, dy = aim[0] - butt[0], aim[1] - butt[1]
    d = math.hypot(dx, dy)
    ux, uy = dx / d, dy / d                  # 杖尾 → 杖尖
    nx, ny = -uy, ux
    L = d - gap                              # 杖身长度（杖尾圆心到杖尖根部）

    def P(lx, ly):
        return (butt[0] + ux * lx + nx * ly, butt[1] + uy * lx + ny * ly)

    r, k = w0 / 2, K * w0 / 2
    return [('m',) + P(0, -r),
            # 半圆杖尾，半径正好是杖身的一半
            ('c',) + P(-k, -r) + P(-r, -k) + P(-r, 0),
            ('c',) + P(-r, k) + P(-k, r) + P(0, r),
            ('l',) + P(L + bevel, w1 / 2),   # 斜切：靠星那一侧多探出去一截
            ('l',) + P(L, -w1 / 2),
            ('h',)]


def capsule(p0, p1, w, mirror=False):
    """两端都是半圆的短棍：用来画光线，也用来在杖尖掏槽。

    mirror=True 时把路径沿自身轴镜像——形状不变、绕向反了，
    因此跟外轮廓一起 `f` 填充（非零绕向）时，这块会被挖成洞。
    """
    (x0, y0), (x1, y1) = p0, p1
    dx, dy = x1 - x0, y1 - y0
    d = math.hypot(dx, dy)
    ux, uy = dx / d, dy / d
    nx, ny = -uy, ux
    s = -1.0 if mirror else 1.0
    r, k = w / 2, K * w / 2

    def P(px, py, lx, ly):
        return (px + ux * lx + s * nx * ly, py + uy * lx + s * ny * ly)

    return [('m',) + P(x0, y0, 0, -r),
            ('c',) + P(x0, y0, -k, -r) + P(x0, y0, -r, -k) + P(x0, y0, -r, 0),
            ('c',) + P(x0, y0, -r, k) + P(x0, y0, -k, r) + P(x0, y0, 0, r),
            ('l',) + P(x1, y1, 0, r),
            ('c',) + P(x1, y1, k, r) + P(x1, y1, r, k) + P(x1, y1, r, 0),
            ('c',) + P(x1, y1, r, -k) + P(x1, y1, k, -r) + P(x1, y1, 0, -r),
            ('h',)]


def wand_sf(tip, butt, w, slot_from, slot_to, slot_w):
    """SF 版那根杖：等宽圆头，杖尖一截是描边的——外面一个胶囊，里面挖一道圆头槽"""
    dx, dy = butt[0] - tip[0], butt[1] - tip[1]
    d = math.hypot(dx, dy)
    ux, uy = dx / d, dy / d                      # 杖尖 → 杖尾

    def at(t):
        return (tip[0] + ux * t, tip[1] + uy * t)

    return (capsule(tip, butt, w)
            + capsule(at(slot_from), at(slot_to), slot_w, mirror=True))


def ray(center, deg, r0, r1, w):
    a = math.radians(deg)
    return capsule((center[0] + r0 * math.cos(a), center[1] + r0 * math.sin(a)),
                   (center[0] + r1 * math.cos(a), center[1] + r1 * math.sin(a)), w)


def wand_rays(tip, length, w0, w1, gap):
    """一根杖，两头都是半圆；杖尖朝 tip，从 -45° 方向伸进来"""
    a = math.radians(-45)
    ux, uy = math.cos(a), math.sin(a)            # 杖尖 → 杖尾的方向
    x1, y1 = tip[0] - ux * gap, tip[1] - uy * gap
    x0, y0 = x1 + ux * length, y1 + uy * length  # 杖尾圆心
    nx, ny = -uy, ux

    def P(lx, ly):
        return (x0 - ux * lx + nx * ly, y0 - uy * lx + ny * ly)

    r0, k0 = w0 / 2, K * w0 / 2
    r1, k1 = w1 / 2, K * w1 / 2
    return [('m',) + P(0, -r0),
            ('c',) + P(-k0, -r0) + P(-r0, -k0) + P(-r0, 0),
            ('c',) + P(-r0, k0) + P(-k0, r0) + P(0, r0),
            ('l',) + P(length, r1),
            ('c',) + P(length + k1, r1) + P(length + r1, k1) + P(length + r1, 0),
            ('c',) + P(length + r1, -k1) + P(length + k1, -r1) + P(length, -r1),
            ('h',)]


def icon():
    if STYLE == "rays":
        paths = []
        for deg in RAY_ANGLES:
            paths += ray(CENTER, deg, RAY_R0, RAY_R1, RAY_W)
        paths += wand_rays(CENTER, RAY_WAND_LEN, RAY_BUTT_W, RAY_TIP_W, RAY_TIP_GAP)
        return paths
    if STYLE == "sf":
        paths = wand_sf(SF_TIP, SF_BUTT, SF_WAND_W,
                        SF_SLOT_FROM, SF_SLOT_TO, SF_SLOT_W)
        for cx, cy, r in SF_STARS:
            paths += star4(cx, cy, r, SF_STAR_Q, style="sf")
        return paths
    paths = wand_star(BUTT, AIM, WAND_W0, WAND_W1, TIP_GAP, TIP_BEVEL)
    for cx, cy, r, q in STARS:
        paths += star4(cx, cy, r, q, style="thin")
    return paths


def write_pdf(paths, out_path, size=SIZE):
    ops = []
    for p in paths:
        if p[0] == 'm':
            ops.append("%.3f %.3f m" % (p[1], p[2]))
        elif p[0] == 'l':
            ops.append("%.3f %.3f l" % (p[1], p[2]))
        elif p[0] == 'c':
            ops.append("%.3f %.3f %.3f %.3f %.3f %.3f c" % p[1:])
        elif p[0] == 'h':
            ops.append("h")
    content = ("0 g\n" + "\n".join(ops) + "\nf\n").encode('latin-1')

    objs = [
        b"<</Type/Catalog/Pages 2 0 R>>",
        b"<</Type/Pages/Kids[3 0 R]/Count 1>>",
        ("<</Type/Page/Parent 2 0 R/MediaBox[0 0 %g %g]"
         "/Resources<</ProcSet[/PDF]>>/Contents 4 0 R>>" % (size, size)).encode(),
        b"<</Length " + str(len(content)).encode() + b">>\nstream\n" + content + b"\nendstream",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offs = []
    for i, o in enumerate(objs, 1):
        offs.append(len(out))
        out += str(i).encode() + b" 0 obj\n" + o + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 " + str(len(objs) + 1).encode() + b"\n0000000000 65535 f \n"
    for o in offs:
        out += ("%010d 00000 n \n" % o).encode()
    out += (b"trailer\n<</Size " + str(len(objs) + 1).encode()
            + b"/Root 1 0 R>>\nstartxref\n" + str(xref).encode() + b"\n%%EOF\n")

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, 'wb') as f:
        f.write(bytes(out))
    return out_path


if __name__ == "__main__":
    dest = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "rewrite.pdf")
    print("写好了 %s（%s 版）" % (write_pdf(icon(), dest), STYLE))
