#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 AnchorScroll 原理演示动画（MP4 / GIF / 封面图）。

本脚本用代码逐帧渲染演示动画，画面内容严格依据仓库源码：

* 速度曲线   Sources/Core.swift 中 ScrollTuning.speed(_:)
             excess   = max(0, |d| - deadZone)
             fraction = min(excess * sensitivity / fullDistance, 1)
             speed    = sign(d) * maxSpeed * fraction ** exponent
             默认 deadZone=6、fullDistance=240、exponent=1.5、maxSpeed=1800
* 位移积分   Sources/Core.swift 中 ScrollIntegrator.step(dx:dy:elapsed:)
             按实际经过时间计算位移，累计不足一像素的余量，
             速度为零或方向反转时清空余量，单步时间上限 50 毫秒
* 中心指示器 Sources/Indicator.swift 中 IndicatorDrawing
             34x34 圆形面板、上下两个三角箭头、中心 4x4 圆点，
             活动方向用 systemBlue，未活动方向用 secondaryLabelColor

本动画是依据上述参数渲染的原理演示，不是屏幕录制，也不会被描述为真实录屏。

用法：
    python3 scripts/make-demo.py --outdir docs/demo
    python3 scripts/make-demo.py --outdir docs/demo --fps 30 --seconds 22
"""

from __future__ import annotations

import argparse
import math
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter, ImageFont

# ---------------------------------------------------------------- 基本参数

W, H = 1280, 720          # 输出分辨率
SS = 2                    # 超采样倍数，先按 2 倍绘制再缩小，保证边缘平滑

FONT_CJK = "/System/Library/Fonts/Hiragino Sans GB.ttc"
FONT_MONO = "/System/Library/Fonts/Menlo.ttc"
IDX_REG, IDX_BOLD = 0, 2

FPS_DEFAULT = 30
SECONDS_DEFAULT = 22.0

# 与 ScrollTuning 默认值一致
DEAD_ZONE, FULL_DISTANCE, EXPONENT, MAX_SPEED = 6.0, 240.0, 1.5, 1800.0
STEP_LIMIT = 0.05        # ScrollIntegrator 单步时间上限（秒）

# 演示画面中 1 点对应的像素数（仅用于可视化，不影响速度计算）
PT_TO_PX = 1.4

# 颜色
C_DESK_TOP = (238, 242, 248)
C_DESK_BOTTOM = (214, 222, 234)
C_WIN = (255, 255, 255)
C_WIN_BORDER = (214, 220, 229)
C_TITLEBAR = (246, 247, 249)
C_TEXT = (60, 70, 86)
C_TEXT_DIM = (124, 134, 150)
C_BLUE = (10, 122, 255)
C_AMBER = (255, 159, 10)
C_GREEN = (48, 209, 88)
C_CAPTION_BG = (22, 35, 58)
C_CAPTION_FG = (232, 238, 252)

# 版式
DOC = (48, 76, 808, 524)          # 文档窗口 x, y, w, h
HUD = (880, 76, 352, 524)         # 右侧状态面板
BAND = (48, 616, 1184, 72)        # 底部字幕条
DOC_TITLEBAR = 38
ANCHOR = (DOC[0] + DOC[2] // 2, DOC[1] + DOC_TITLEBAR + (DOC[3] - DOC_TITLEBAR) // 2)

# 时间轴（秒）
T_CLICK = 2.90
T_ACTIVE = 3.00
T_SLOW_END = 5.60
T_FAST_END = 9.00
T_HOLD_END = 12.00
T_CENTER = 14.60
T_DOWN = 17.70
T_ESC = 17.95
T_OUTRO = 19.40

OFF_SLOW, OFF_FAST, OFF_DOWN = 60.0, 150.0, -110.0

CAPTIONS = [
    (3.00, 5.60, "点按鼠标中键并松开，以点击位置为速度中心"),
    (5.60, 9.00, "鼠标离中心越远，滚动越快"),
    (9.00, 12.00, "停在偏移位置不动，页面持续滚动"),
    (12.00, 14.60, "移回中心 6 点死区内，滚动自动停止"),
    (14.60, 17.70, "移到中心下方，滚动方向随之反转"),
    (17.70, 19.40, "点击鼠标左键或按 Esc，退出本次自动滚动"),
]

# 演示用占位文档。内容为本项目自撰的说明文字，用于展示滚动效果。
DOC_SECTIONS = [
    ("AnchorScroll 使用说明", [
        ("h2", "一、激活与退出"),
        ("p", "在任意可滚动窗口中点按鼠标中键，然后松开。"),
        ("p", "注意不要按住中键拖动，按住后移动超过 6 点会取消激活。"),
        ("p", "激活成功后，点击的位置会保留一个圆形指示器，"),
        ("p", "这个位置就是速度中心，在本次滚动结束前不会移动。"),
        ("p", "鼠标停住时页面会持续滚动，不需要持续移动鼠标。"),
        ("p", "把指针移回中心死区即可停止，也可以点击左键或按 Esc。"),
        ("p", "停止时会一并清除累计的不足一像素的余量，"),
        ("p", "因此下一次激活不会带着上一次的残留位移。"),
        ("s", ""),
    ]),
    ("", [
        ("h2", "二、速度与位移"),
        ("p", "滚动速度由鼠标与中心的距离决定，距离越近越慢。"),
        ("p", "中心 6 点以内属于死区，不产生任何滚动事件。"),
        ("p", "超过死区后速度按距离的 1.5 次方增长，"),
        ("p", "距离达到 240 点时速度到达上限，默认每秒 1800 像素。"),
        ("p", "活动期间以 120 Hz 调度，按实际经过的时间计算位移，"),
        ("p", "单步时间不超过 50 毫秒，避免运行循环阻塞后补播历史。"),
        ("p", "不足一像素的余量会累计到下一帧，不会被直接丢弃。"),
        ("p", "灵敏度、最高速度与加速距离都可以在菜单栏中调整。"),
        ("s", ""),
    ]),
    ("", [
        ("h2", "三、方向与坐标系"),
        ("p", "默认上下方向与鼠标移动方向一致，不做反转。"),
        ("p", "把指针移到中心上方，页面向上滚动；移到下方则向下。"),
        ("p", "指示器中高亮的那一侧箭头表示当前滚动方向。"),
        ("p", "如果习惯相反的手感，可以在设置里打开方向反转开关。"),
        ("p", "方向反转只影响输出方向，不影响指示器的判定。"),
        ("p", "反向时滚动余量会被立刻清除，避免出现反向粘滞。"),
        ("p", "切换前台应用、系统睡眠或显示器布局变化时，"),
        ("p", "自动滚动会被取消，需要重新点按中键激活。"),
        ("s", ""),
    ]),
    ("", [
        ("h2", "四、实现细节"),
        ("p", "滚动事件在 HID 层发送，并且使用当前真实指针位置。"),
        ("p", "早先使用固定锚点投递事件会把真实指针拉回中心，"),
        ("p", "表现为只能小幅慢滚，该问题已在 1.0.2 修复。"),
        ("p", "滚动目标跟随指针所在的滚动区域，"),
        ("p", "指针跨出文档区域时可能改为滚动侧栏或其他容器。"),
        ("p", "程序不修改普通滚轮的行为，也不改写鼠标按键映射。"),
        ("p", "浏览器中建议使用 Command 加左键打开新标签页。"),
        ("p", "Option 加中键会原样透传，在某些浏览器中可能触发分屏。"),
        ("s", ""),
    ]),
    ("", [
        ("h2", "五、系统要求与限制"),
        ("p", "当前交付目标为 Apple Silicon，系统要求 macOS 14 或更新。"),
        ("p", "首次启动需要在系统设置的辅助功能中完成授权。"),
        ("p", "如果更新版本后权限失效，应移除旧条目后重新添加。"),
        ("p", "应用为本机临时签名，未使用开发者证书，也未经公证。"),
        ("p", "首次打开时系统可能提示无法验证开发者，"),
        ("p", "请右键选择打开，不要通过关闭系统安全功能来安装。"),
        ("p", "真实手感与多应用兼容性仍需要在干净环境中实测。"),
        ("p", "程序不访问网络，不记录键盘文字，也不部署后台服务。"),
        ("s", ""),
    ]),
]

# 每一轮循环的正文长度（点），用于把内容铺满整个滚动行程
SECTION_PITCH = 300


def build_content_lines():
    """把分节文字展开成一个足够长的行序列。"""
    out = []
    for title, lines in DOC_SECTIONS:
        if title:
            out.append(("h", title))
        out.extend(lines)
    return out


# ---------------------------------------------------------------- 工具函数


def fnt(path: str, size: int, index: int = 0) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(path, int(size * SS), index=index)


def box(x: float, y: float, w: float, h: float):
    return [x * SS, y * SS, (x + w) * SS, (y + h) * SS]


def ease(t: float) -> float:
    t = min(1.0, max(0.0, t))
    return t * t * (3 - 2 * t)


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def speed_at(distance: float) -> float:
    """与 ScrollTuning.speed(_:) 完全一致。"""
    excess = max(0.0, abs(distance) - DEAD_ZONE)
    fraction = min(excess / FULL_DISTANCE, 1.0)
    return (1 if distance >= 0 else -1) * MAX_SPEED * fraction ** EXPONENT


def vertical_gradient(size, top, bottom):
    w, h = size
    grad = Image.new("RGB", (1, h))
    px = grad.load()
    for y in range(h):
        t = y / max(1, h - 1)
        px[0, y] = tuple(int(round(lerp(top[i], bottom[i], t))) for i in range(3))
    return grad.resize((w, h), Image.BILINEAR)


# ---------------------------------------------------------------- 光标轨迹


def cursor_offset(t: float) -> float:
    """光标相对中心的偏移，单位为点，正数表示位于中心上方。"""
    if t < 2.60:
        return -160.0
    if t < T_ACTIVE:
        return lerp(-160.0, 0.0, ease((t - 2.60) / (T_ACTIVE - 2.60)))
    if t < T_SLOW_END:
        return lerp(0.0, OFF_SLOW, ease((t - T_ACTIVE) / (T_SLOW_END - T_ACTIVE)))
    if t < T_FAST_END:
        return lerp(OFF_SLOW, OFF_FAST, ease((t - T_SLOW_END) / (T_FAST_END - T_SLOW_END)))
    if t < T_HOLD_END:
        return OFF_FAST
    if t < T_CENTER:
        return lerp(OFF_FAST, 0.0, ease((t - T_HOLD_END) / (T_CENTER - T_HOLD_END)))
    if t < T_DOWN:
        return lerp(0.0, OFF_DOWN, ease((t - T_CENTER) / (T_DOWN - T_CENTER)))
    return OFF_DOWN


# ---------------------------------------------------------------- 仿真


def simulate(fps: int, seconds: float):
    """按 120 Hz 推进物理，复现 ScrollIntegrator 的取整与余量语义。"""
    dt = 1.0 / 120.0
    n = int(seconds * fps)
    result = {}

    scroll = 0.0       # 累计滚动位移（像素，正数表示向上滚动的量）
    remainder = 0.0
    prev_speed = 0.0
    t = 0.0
    steps = int(seconds / dt) + 2

    for _ in range(steps):
        off = cursor_offset(t)
        active = T_ACTIVE <= t < T_ESC
        speed = speed_at(off) if active else 0.0

        if speed == 0.0 or (speed > 0) != (prev_speed > 0):
            remainder = 0.0
        prev_speed = speed
        if speed != 0.0:
            remainder += speed * min(dt, STEP_LIMIT)
            whole = math.trunc(remainder)
            remainder -= whole
            scroll += whole
        result[round(t, 6)] = (off, scroll, speed, active)
        t += dt

    samples = []
    for i in range(n):
        key = round(round(i / fps * 120) / 120, 6)
        if key not in result:
            key = min(result, key=lambda k: abs(k - key))
        samples.append(result[key])
    return samples


# ---------------------------------------------------------------- 静态图层


class Assets:
    """所有与时间无关的图层只构建一次，逐帧复用。"""

    def __init__(self, icon_path, content_height: int, content_min_scroll: float):
        self.content_height = content_height
        self.content_min_scroll = content_min_scroll
        self.background = self._background()
        self.window = self._window()
        self.hud = self._hud()
        self.band = self._band()
        self.content = self._content()
        self.icon = self._icon(icon_path)

    def _background(self):
        img = vertical_gradient((W * SS, H * SS), C_DESK_TOP, C_DESK_BOTTOM).convert("RGBA")
        d = ImageDraw.Draw(img)
        d.rectangle(box(0, 0, W, 56), fill=(255, 255, 255, 214))
        d.line([(0, 56 * SS), (W * SS, 56 * SS)], fill=(206, 214, 226, 255), width=max(1, SS))
        return img

    def _window(self):
        pad = 26
        layer = Image.new("RGBA", ((DOC[2] + pad * 2) * SS, (DOC[3] + pad * 2) * SS), (0, 0, 0, 0))
        shadow = Image.new("RGBA", layer.size, (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle(
            box(pad, pad + 4, DOC[2], DOC[3]), radius=14 * SS, fill=(84, 100, 126, 62))
        layer.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14 * SS)))
        d = ImageDraw.Draw(layer)
        d.rounded_rectangle(box(pad, pad, DOC[2], DOC[3]), radius=14 * SS,
                            fill=C_WIN, outline=C_WIN_BORDER, width=max(1, SS))
        d.rounded_rectangle(box(pad, pad, DOC[2], 14), radius=14 * SS, fill=C_TITLEBAR)
        d.rectangle(box(pad, pad + 14, DOC[2], DOC_TITLEBAR - 14), fill=C_TITLEBAR)
        d.line([(pad * SS, (pad + DOC_TITLEBAR) * SS),
                ((pad + DOC[2]) * SS, (pad + DOC_TITLEBAR) * SS)],
               fill=C_WIN_BORDER, width=max(1, SS))
        for i, color in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
            cx = pad + 22 + i * 20
            d.ellipse(box(cx - 6, pad + DOC_TITLEBAR / 2 - 6, 12, 12), fill=color)
        d.text(((pad + 92) * SS, (pad + DOC_TITLEBAR / 2) * SS), "AnchorScroll 使用说明.md — 预览",
               font=fnt(FONT_CJK, 13, IDX_REG), fill=C_TEXT_DIM, anchor="lm")
        self._win_pad = pad
        return layer

    def _content(self):
        width = DOC[2] - 2
        lines = build_content_lines()
        # 先把一节的排版高度量出来，再按需要的总高度循环铺满
        probe = Image.new("RGBA", (10 * SS, 10 * SS))
        pd = ImageDraw.Draw(probe)
        heights = []
        for kind, text in lines:
            if kind == "s":
                heights.append(16)
            elif kind == "h":
                heights.append(46)
            elif kind == "h2":
                heights.append(36)
            else:
                heights.append(30)
        cycle = sum(heights)
        total = 26
        rendered = 0
        plan = []
        while total < self.content_height + 120:
            y = total
            for (kind, text), hh in zip(lines, heights):
                # 文档大标题只在正文开头出现一次，循环铺满时不再重复
                if kind == "h" and rendered > 0:
                    y += hh
                    continue
                plan.append((kind, text, y))
                y += hh
            total = y
            rendered += 1
        height = total + 60

        img = Image.new("RGBA", (width * SS, height * SS), C_WIN)
        d = ImageDraw.Draw(img)
        for kind, text, y in plan:
            if kind == "s":
                continue
            if kind == "h":
                d.text((28 * SS, (y + 12) * SS), text, font=fnt(FONT_CJK, 21, IDX_BOLD),
                       fill=C_TEXT, anchor="lm")
            elif kind == "h2":
                d.text((28 * SS, (y + 10) * SS), text, font=fnt(FONT_CJK, 16, IDX_BOLD),
                       fill=(38, 48, 66), anchor="lm")
            else:
                d.text((28 * SS, (y + 10) * SS), text, font=fnt(FONT_CJK, 14, IDX_REG),
                       fill=C_TEXT_DIM, anchor="lm")
                d.line([(28 * SS, (y + 28) * SS), ((width - 28) * SS, (y + 28) * SS)],
                       fill=(240, 242, 246, 255), width=SS)
        self._content_pitch = cycle
        self._content_full = height
        return img

    def _hud(self):
        pad = 26
        layer = Image.new("RGBA", ((HUD[2] + pad * 2) * SS, (HUD[3] + pad * 2) * SS), (0, 0, 0, 0))
        shadow = Image.new("RGBA", layer.size, (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle(box(pad, pad + 4, HUD[2], HUD[3]),
                                                 radius=14 * SS, fill=(84, 100, 126, 62))
        layer.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14 * SS)))
        d = ImageDraw.Draw(layer)
        d.rounded_rectangle(box(pad, pad, HUD[2], HUD[3]), radius=14 * SS,
                            fill=(252, 253, 255), outline=C_WIN_BORDER, width=max(1, SS))
        self._hud_pad = pad
        return layer

    def _band(self):
        pad = 10
        layer = Image.new("RGBA", ((BAND[2] + pad * 2) * SS, (BAND[3] + pad * 2) * SS), (0, 0, 0, 0))
        ImageDraw.Draw(layer).rounded_rectangle(box(pad, pad, BAND[2], BAND[3]),
                                                radius=14 * SS, fill=C_CAPTION_BG)
        self._band_pad = pad
        return layer

    def _icon(self, path):
        if not path or not os.path.exists(path):
            return None
        icon = Image.open(path).convert("RGBA").resize((128 * SS, 128 * SS), Image.LANCZOS)
        mask = Image.new("L", icon.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            [0, 0, icon.size[0] - 1, icon.size[1] - 1], radius=28 * SS, fill=255)
        icon.putalpha(mask)
        return icon


# ---------------------------------------------------------------- 绘制


def draw_indicator(canvas, cx, cy, direction):
    """还原 IndicatorDrawing：圆形面板 + 上下三角 + 中心圆点。"""
    size, r = 34, 17
    glow = Image.new("RGBA", (int(60 * SS), int(60 * SS)), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([0, 0, 60 * SS - 1, 60 * SS - 1], fill=C_BLUE + (58,))
    canvas.alpha_composite(glow.filter(ImageFilter.GaussianBlur(12 * SS)),
                           (int((cx - 30) * SS), int((cy - 30) * SS)))

    panel = Image.new("RGBA", (size * SS, size * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(panel)
    d.ellipse([SS, SS, (size - 1) * SS, (size - 1) * SS], fill=(255, 255, 255, 242),
              outline=(90, 100, 116, 130), width=max(1, SS))
    for sign in (-1, 1):
        fill = C_BLUE if direction == sign else (170, 178, 190)
        d.polygon([(r * SS, (r + sign * 12) * SS),
                   ((r - 5) * SS, (r + sign * 6) * SS),
                   ((r + 5) * SS, (r + sign * 6) * SS)], fill=fill)
    d.ellipse([15 * SS, 15 * SS, 19 * SS, 19 * SS], fill=(58, 66, 80))
    canvas.alpha_composite(panel, (int((cx - r) * SS), int((cy - r) * SS)))


def draw_cursor(canvas, cx, cy, pressed=False):
    pts = [(0, 0), (0, 17), (4.4, 13.2), (7.4, 19.6), (10.4, 18.2), (7.4, 11.8), (12.4, 11.8)]
    layer = Image.new("RGBA", (int(40 * SS), int(40 * SS)), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.polygon([(x * SS, y * SS) for x, y in pts], fill=(255, 255, 255, 255),
              outline=(52, 58, 70, 255), width=max(1, int(SS * 1.2)))
    if pressed:
        layer = layer.resize((int(40 * SS * 0.88), int(40 * SS * 0.88)), Image.LANCZOS)
    canvas.alpha_composite(layer, (int(cx * SS), int(cy * SS)))


def draw_hud_dynamic(canvas, px, py, distance, speed, active):
    d = ImageDraw.Draw(canvas)
    L, R = px + 22, px + HUD[2] - 22

    d.text((L * SS, (py + 24) * SS), "运行状态", font=fnt(FONT_CJK, 14, IDX_BOLD),
           fill=C_TEXT_DIM, anchor="lm")
    d.text((L * SS, (py + 50) * SS), "滚动速度", font=fnt(FONT_CJK, 12, IDX_REG),
           fill=C_TEXT_DIM, anchor="lm")
    speed_text = f"{abs(speed):.0f}"
    d.text((L * SS, (py + 84) * SS), speed_text, font=fnt(FONT_MONO, 40),
           fill=C_BLUE if active else (150, 158, 172), anchor="lm")
    wnum = d.textlength(speed_text, font=fnt(FONT_MONO, 40)) / SS
    d.text(((L + wnum + 8) * SS, (py + 90) * SS), "像素/秒", font=fnt(FONT_CJK, 12, IDX_REG),
           fill=C_TEXT_DIM, anchor="lm")

    bar_y = py + 118
    d.rounded_rectangle(box(L, bar_y, R - L, 10), radius=5 * SS, fill=(232, 236, 243))
    frac = min(abs(speed) / MAX_SPEED, 1.0)
    if frac > 0.001:
        d.rounded_rectangle(box(L, bar_y, (R - L) * frac, 10), radius=5 * SS, fill=C_BLUE)

    cx0, cy0, cw, ch = L, py + 150, R - L, 118
    d.rounded_rectangle(box(cx0, cy0, cw, ch), radius=10 * SS, fill=(248, 250, 253),
                        outline=(232, 236, 243), width=max(1, SS))
    d.text(((cx0 + 10) * SS, (cy0 + 16) * SS), "速度曲线 ∝（距离 − 死区）^1.5",
           font=fnt(FONT_CJK, 10, IDX_REG), fill=C_TEXT_DIM, anchor="lm")
    gx, gy, gw, gh = cx0 + 12, cy0 + 36, cw - 24, ch - 50
    d.line([(gx * SS, (gy + gh) * SS), ((gx + gw) * SS, (gy + gh) * SS)],
           fill=(210, 216, 226), width=SS)
    d.line([(gx * SS, gy * SS), (gx * SS, (gy + gh) * SS)], fill=(210, 216, 226), width=SS)
    curve = [((gx + gw * (FULL_DISTANCE * i / 60) / FULL_DISTANCE) * SS,
              (gy + gh * (1 - abs(speed_at(FULL_DISTANCE * i / 60)) / MAX_SPEED)) * SS)
             for i in range(61)]
    d.line(curve, fill=C_BLUE, width=max(1, int(SS * 1.6)), joint="curve")
    dx = gx + gw * DEAD_ZONE / FULL_DISTANCE
    d.line([(dx * SS, gy * SS), (dx * SS, (gy + gh) * SS)], fill=C_AMBER, width=max(1, SS))
    dv = abs(speed_at(distance)) / MAX_SPEED if active else 0.0
    dot_x = gx + gw * min(abs(distance), FULL_DISTANCE) / FULL_DISTANCE
    dot_y = gy + gh * (1 - dv)
    d.ellipse(box(dot_x - 4, dot_y - 4, 8, 8), fill=C_BLUE, outline=(255, 255, 255),
              width=max(1, SS))

    rows = [
        ("距中心距离", f"{abs(distance):.0f} pt" if active else "—"),
        ("滚动方向", ("向上" if distance > 0 else "向下")
         if active and abs(distance) > DEAD_ZONE else "停止"),
        ("中心死区", f"{DEAD_ZONE:.0f} pt"),
        ("加速距离", f"{FULL_DISTANCE:.0f} pt"),
        ("最高速度", f"{MAX_SPEED:.0f} 像素/秒"),
        ("曲线指数", f"{EXPONENT:.1f}"),
    ]
    ry = py + 288
    for i, (k, v) in enumerate(rows):
        yy = ry + i * 26
        if i:
            d.line([(L * SS, (yy - 13) * SS), (R * SS, (yy - 13) * SS)],
                   fill=(238, 241, 246), width=SS)
        d.text((L * SS, yy * SS), k, font=fnt(FONT_CJK, 12, IDX_REG), fill=C_TEXT_DIM, anchor="lm")
        d.text((R * SS, yy * SS), v, font=fnt(FONT_CJK, 12, IDX_BOLD), fill=C_TEXT, anchor="rm")

    by = py + HUD[3] - 50
    label = "自动滚动中" if active else "已停止"
    color = C_GREEN if active else (150, 158, 172)
    d.rounded_rectangle(box(L, by, 122, 30), radius=15 * SS, fill=color + (44,))
    d.ellipse(box(L + 12, by + 12, 7, 7), fill=color)
    d.text(((L + 28) * SS, (by + 15) * SS), label, font=fnt(FONT_CJK, 12, IDX_BOLD),
           fill=(32, 44, 60), anchor="lm")


def render_frame(assets: "Assets", t: float, sample, dim: float = 0.0):
    offset, scroll, speed, active = sample
    canvas = assets.background.copy()
    d = ImageDraw.Draw(canvas)

    d.text((24 * SS, 28 * SS), "AnchorScroll", font=fnt(FONT_CJK, 15, IDX_BOLD),
           fill=C_TEXT, anchor="lm")
    d.text((172 * SS, 29 * SS), "1.0.3 · 中键自动滚动", font=fnt(FONT_CJK, 12, IDX_REG),
           fill=C_TEXT_DIM, anchor="lm")
    badge = "原理演示动画 · 非屏幕录制"
    bw = d.textlength(badge, font=fnt(FONT_CJK, 11, IDX_REG)) / SS
    d.rounded_rectangle(box(W - 28 - bw - 24, 14, bw + 24, 28), radius=14 * SS,
                        fill=(255, 255, 255), outline=C_WIN_BORDER, width=max(1, SS))
    d.text(((W - 28 - bw / 2 - 12) * SS, 28 * SS), badge, font=fnt(FONT_CJK, 11, IDX_REG),
           fill=C_TEXT_DIM, anchor="mm")

    if dim < 1.0:
        canvas.alpha_composite(assets.window,
                               (int((DOC[0] - assets._win_pad) * SS),
                                int((DOC[1] - assets._win_pad) * SS)))

        chh = DOC[3] - DOC_TITLEBAR - 1
        local = scroll - assets.content_min_scroll
        src_top = int(max(0, min(assets._content_full - chh - 1, local)) * SS)
        content = assets.content.crop((0, src_top, (DOC[2] - 2) * SS, src_top + int(chh * SS)))
        canvas.alpha_composite(content, (int((DOC[0] + 1) * SS), int((DOC[1] + DOC_TITLEBAR) * SS)))

        # 右侧滚动条：直观显示当前滚动位置
        track_x = DOC[0] + DOC[2] - 11
        track_y = DOC[1] + DOC_TITLEBAR + 6
        track_h = chh - 12
        d.rounded_rectangle(box(track_x, track_y, 6, track_h), radius=3 * SS,
                            fill=(240, 242, 246))
        total_h = assets._content_full
        knob_h = max(28.0, track_h * chh / total_h)
        knob_y = track_y + (track_h - knob_h) * (local / max(1.0, total_h - chh))
        d.rounded_rectangle(box(track_x, knob_y, 6, knob_h), radius=3 * SS,
                            fill=(186, 194, 208))

        ax, ay = ANCHOR
        cur_y = ay - offset * PT_TO_PX

        if active:
            d.line([(ax * SS, ay * SS), (ax * SS, cur_y * SS)], fill=C_AMBER + (150,),
                   width=max(1, int(SS * 1.6)))
            r = DEAD_ZONE * PT_TO_PX
            d.ellipse(box(ax - r, ay - r, 2 * r, 2 * r), outline=C_BLUE + (150,), width=max(1, SS))
            direction = 0 if abs(offset) <= DEAD_ZONE else (-1 if offset > 0 else 1)
            draw_indicator(canvas, ax, ay, direction)
        draw_cursor(canvas, ax + 7, cur_y + 2, pressed=(abs(t - T_CLICK) < 0.12))

        canvas.alpha_composite(assets.hud, (int((HUD[0] - assets._hud_pad) * SS),
                                            int((HUD[1] - assets._hud_pad) * SS)))
        draw_hud_dynamic(canvas, HUD[0], HUD[1], offset, speed, active)

    band_layer = assets.band
    if dim > 0:
        # 片头片尾让字幕条整体淡出，而不是留下一条更深的色带
        band_layer = assets.band.copy()
        band_layer.putalpha(band_layer.getchannel("A").point(lambda v: int(v * (1.0 - dim))))
    canvas.alpha_composite(band_layer, (int((BAND[0] - assets._band_pad) * SS),
                                        int((BAND[1] - assets._band_pad) * SS)))
    for a, b, text in CAPTIONS:
        if a <= t < b:
            local_t = min(t - a, b - t)
            alpha = 255 if local_t > 0.25 else int(255 * local_t / 0.25)
            alpha = int(alpha * (1.0 - dim))
            d = ImageDraw.Draw(canvas)
            d.ellipse(box(BAND[0] + 28, BAND[1] + BAND[3] / 2 - 4, 8, 8), fill=C_BLUE + (alpha,))
            d.text(((BAND[0] + 52) * SS, (BAND[1] + BAND[3] / 2) * SS), text,
                   font=fnt(FONT_CJK, 19, IDX_BOLD), fill=C_CAPTION_FG + (alpha,), anchor="lm")
            break

    if dim > 0:
        veil = Image.new("RGBA", canvas.size, (18, 26, 42, int(238 * dim)))
        canvas.alpha_composite(veil)
        d = ImageDraw.Draw(canvas)
        if assets.icon is not None:
            canvas.alpha_composite(assets.icon, (int((640 - 64) * SS), int(186 * SS)))
        d.text((640 * SS, 362 * SS), "AnchorScroll", font=fnt(FONT_CJK, 40, IDX_BOLD),
               fill=(255, 255, 255, 255), anchor="mm")
        d.text((640 * SS, 406 * SS), "macOS 菜单栏中键自动滚动工具", font=fnt(FONT_CJK, 17, IDX_REG),
               fill=(196, 208, 228, 255), anchor="mm")
        d.text((640 * SS, 458 * SS), "1.0.3  ·  macOS 14 及以上  ·  Apple Silicon",
               font=fnt(FONT_CJK, 14, IDX_REG), fill=(150, 166, 190, 255), anchor="mm")
        d.text((640 * SS, 522 * SS), "本片由仓库脚本逐帧渲染，用于说明速度曲线与交互方式",
               font=fnt(FONT_CJK, 12, IDX_REG), fill=(130, 146, 170, 255), anchor="mm")

    return canvas.resize((W, H), Image.LANCZOS).convert("RGB")


def dim_at(t: float) -> float:
    if t < 0.60:
        return 1.0 - ease(t / 0.60)
    if t >= T_OUTRO:
        return ease((t - T_OUTRO) / 0.60)
    return 0.0


# ---------------------------------------------------------------- 输出


def run_ffmpeg(args, label):
    proc = subprocess.run(args, capture_output=True, text=True)
    if proc.returncode != 0:
        print(f"[{label}] ffmpeg 失败：\n{proc.stderr[-2000:]}", file=sys.stderr)
        raise SystemExit(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--outdir", default="docs/demo")
    ap.add_argument("--fps", type=int, default=FPS_DEFAULT)
    ap.add_argument("--seconds", type=float, default=SECONDS_DEFAULT)
    ap.add_argument("--icon", default="assets/icon.png")
    ap.add_argument("--gif-width", type=int, default=760)
    ap.add_argument("--gif-fps", type=int, default=10)
    ap.add_argument("--gif-colors", type=int, default=256)
    ap.add_argument("--gif-dither", type=int, default=0,
                    help="Bayer 抖动强度；0 表示关闭抖动")
    ap.add_argument("--no-gif", action="store_true")
    ap.add_argument("--ffmpeg", default=shutil.which("ffmpeg") or "ffmpeg")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)

    samples = simulate(args.fps, args.seconds)
    scrolls = [s[1] for s in samples]
    lo, hi = min(scrolls), max(scrolls)
    window_h = DOC[3] - DOC_TITLEBAR - 1
    content_height = int(hi - lo) + window_h + 80
    print(f"==> 滚动行程 {hi - lo:.0f} 点，正文高度 {content_height} 点")

    assets = Assets(args.icon if os.path.exists(args.icon) else None, content_height, lo)

    frames_dir = tempfile.mkdtemp(prefix="anchorscroll-demo-")
    print(f"==> 渲染 {len(samples)} 帧")
    for i, sample in enumerate(samples):
        frame = render_frame(assets, i / args.fps, sample, dim=dim_at(i / args.fps))
        frame.save(os.path.join(frames_dir, f"f{i:05d}.png"))
        if (i + 1) % 120 == 0:
            print(f"    {i + 1}/{len(samples)}")

    poster_idx = min(len(samples) - 1, int(10.2 * args.fps))
    poster = os.path.join(args.outdir, "poster.png")
    Image.open(os.path.join(frames_dir, f"f{poster_idx:05d}.png")).save(poster, optimize=True)
    print(f"==> 封面图 {poster}")

    mp4 = os.path.join(args.outdir, "anchorscroll-demo.mp4")
    run_ffmpeg([
        args.ffmpeg, "-y", "-loglevel", "error",
        "-framerate", str(args.fps), "-i", os.path.join(frames_dir, "f%05d.png"),
        "-c:v", "libx264", "-preset", "slow", "-crf", "20",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart", mp4,
    ], "mp4")
    print(f"==> 视频 {mp4}")

    if args.no_gif:
        print("==> 已按参数跳过动图生成")
        for path in (mp4, poster):
            print(f"    {os.path.getsize(path) / 1048576:.2f} MB  {path}")
        shutil.rmtree(frames_dir, ignore_errors=True)
        return

    gif_dir = tempfile.mkdtemp(prefix="anchorscroll-gif-")
    gif_fps, gif_w = args.gif_fps, args.gif_width
    gif_h = int(gif_w * H / W / 2) * 2
    stride = max(1, int(round(args.fps / gif_fps)))
    kept = 0
    for i in range(int(3.0 * args.fps), int(19.4 * args.fps), stride):
        Image.open(os.path.join(frames_dir, f"f{i:05d}.png")) \
            .resize((gif_w, gif_h), Image.LANCZOS) \
            .save(os.path.join(gif_dir, f"g{kept:05d}.png"))
        kept += 1
    palette = os.path.join(gif_dir, "palette.png")
    run_ffmpeg([args.ffmpeg, "-y", "-loglevel", "error",
                "-i", os.path.join(gif_dir, "g%05d.png"),
                "-vf", f"palettegen=max_colors={args.gif_colors}:stats_mode=diff",
                palette], "gif-palette")
    gif = os.path.join(args.outdir, "anchorscroll-demo.gif")
    # gif_dither <= 0 时使用无抖动量化：浅色大面积背景不会出现明显噪点
    if args.gif_dither > 0:
        use = f"paletteuse=dither=bayer:bayer_scale={args.gif_dither}:diff_mode=rectangle"
    else:
        use = "paletteuse=dither=none:diff_mode=rectangle"
    run_ffmpeg([args.ffmpeg, "-y", "-loglevel", "error",
                "-framerate", str(gif_fps), "-i", os.path.join(gif_dir, "g%05d.png"),
                "-i", palette, "-lavfi", use, "-loop", "0", gif], "gif")
    print(f"==> 动图 {gif}（{gif_w}x{gif_h} @ {gif_fps}fps，{kept} 帧）")

    for path in (mp4, gif, poster):
        print(f"    {os.path.getsize(path) / 1048576:.2f} MB  {path}")

    shutil.rmtree(gif_dir, ignore_errors=True)
    shutil.rmtree(frames_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
