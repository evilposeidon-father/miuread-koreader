# -*- coding: utf-8 -*-
"""Generate MiuRead UI operation-logic SVG diagrams for the README.

Pure Python standard library; each generated SVG is also validated with
the fireworks-tech-graph skill during the review pass. Run from repo root:

    python docs/diagrams/generate_ui_diagrams.py
"""

from pathlib import Path

OUT = Path(__file__).resolve().parent
FONT = ("'Helvetica Neue', Helvetica, Arial, 'PingFang SC', "
        "'Microsoft YaHei', 'Microsoft JhengHei', 'SimHei', sans-serif")

STYLE = (
    "    <style>\n"
    "      text { font-family: " + FONT + "; }\n"
    "      .title { font-size: 18px; font-weight: 600; fill: #111827; }\n"
    "      .node { font-size: 13px; font-weight: 600; fill: #111827; }\n"
    "      .sub  { font-size: 11px; fill: #6b7280; }\n"
    "      .zone { font-size: 11px; fill: #6b7280; }\n"
    "    </style>\n"
)


def markers(ids):
    out = []
    for mid, color in ids.items():
        out.append('    <marker id="%s" markerWidth="10" markerHeight="7" '
                   'refX="9" refY="3.5" orient="auto">' % mid)
        out.append('      <polygon points="0 0, 10 3.5, 0 7" fill="%s"/>' % color)
        out.append("    </marker>")
    return "\n".join(out)


def svg_open(viewbox, title, defs):
    w, h = viewbox.split(" ")[2], viewbox.split(" ")[3]
    return [
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="%s" width="%s" height="%s">' % (viewbox, w, h),
        STYLE.rstrip("\n"),
        "  <defs>",
        defs,
        "  </defs>",
        '  <rect width="%s" height="%s" fill="#ffffff"/>' % (w, h),
        '  <text x="40" y="38" class="title">%s</text>' % title,
    ]


def box(lines, x, y, w, h, fill="#ffffff", stroke="#d1d5db", radius=8, bold=True):
    cls = "node" if bold else "sub"
    out = ['  <rect x="%s" y="%s" width="%s" height="%s" rx="%s" ry="%s" fill="%s" stroke="%s" stroke-width="1.5"/>'
           % (x, y, w, h, radius, radius, fill, stroke)]
    if isinstance(lines, str):
        lines = [lines]
    total = len(lines)
    for i, line in enumerate(lines):
        ty = y + h / 2.0 - (total - 1) * 8.0 + i * 16.0 + 4.5
        out.append('  <text x="%s" y="%s" text-anchor="middle" class="%s">%s</text>'
                   % (x + w / 2.0, ty, cls, line))
    return "\n".join(out)


def line(lines, x1, y1, x2, y2, color="#2563eb", width=1.5, dash=None, marker=None, label=None, lx=None, ly=None):
    d = ' stroke-dasharray="%s"' % dash if dash else ""
    m = ' marker-end="url(#%s)"' % marker if marker else ""
    s = '  <line x1="%s" y1="%s" x2="%s" y2="%s" stroke="%s" stroke-width="%s"%s%s/>' % (
        x1, y1, x2, y2, color, width, d, m)
    if label:
        lx = lx if lx is not None else (x1 + x2) / 2.0
        ly = ly if ly is not None else (y1 + y2) / 2.0 - 7
        s += '\n  <text x="%s" y="%s" text-anchor="middle" class="zone">%s</text>' % (lx, ly, label)
    return s


def diamond(lines, cx, cy, w=150, h=74, fill="#ffffff", stroke="#f59e0b"):
    out = ['  <polygon points="%s,%s %s,%s %s,%s %s,%s" fill="%s" stroke="%s" stroke-width="1.5"/>'
           % (cx, cy - h / 2, cx + w / 2, cy, cx, cy + h / 2, cx - w / 2, cy, fill, stroke)]
    if isinstance(lines, str):
        lines = [lines]
    total = len(lines)
    for i, line_text in enumerate(lines):
        ty = cy - (total - 1) * 8.0 + i * 16.0 + 4.5
        out.append('  <text x="%s" y="%s" text-anchor="middle" class="node">%s</text>'
                   % (cx, ty, line_text))
    return "\n".join(out)


def legend(items, x, y):
    out = ['  <g transform="translate(%s,%s)">' % (x, y)]
    for i, (color, label_text, dash) in enumerate(items):
        yy = i * 22
        out.append('    <line x1="0" y1="%s" x2="26" y2="%s" stroke="%s" stroke-width="1.5"%s/>'
                   % (yy + 8, yy + 8, color, (' stroke-dasharray="%s"' % dash) if dash else ""))
        out.append('    <text x="32" y="%s" class="zone">%s</text>' % (yy + 12, label_text))
    out.append("  </g>")
    return "\n".join(out)


def write(name, content):
    path = OUT / name
    path.write_text("\n".join(content) + "\n", encoding="utf-8")
    print("wrote", path)


# ---------------------------------------------------------------------------
# 1. Home UI logic
# ---------------------------------------------------------------------------
def home_ui_logic():
    lines = svg_open("0 0 960 680", "MiuRead 首页操作逻辑",
                     markers({"arrow-blue": "#2563eb", "arrow-orange": "#ea580c"}))
    # Header band
    lines.append(box(["账号", "登录状态"], 40, 64, 128, 56))
    lines.append(box(["Wi-Fi", "点按开关"], 180, 64, 116, 56))
    lines.append(box(["同步", "点按: 静默同步全部", "长按: 同步诊断"], 308, 64, 196, 56, fill="#eff6ff", stroke="#bfdbfe"))
    lines.append(box(["时间"], 516, 64, 84, 56))
    lines.append(box(["电量"], 612, 64, 84, 56))
    lines.append(box(["更多"], 708, 64, 80, 56))
    lines.append('  <text x="40" y="156" class="node">顶部状态栏</text>')

    # Quick panel band
    qp = ["Wi-Fi", "蓝牙", "方向", "截图", "KO设置", "返回KO", "退出KO",
          "同步(点按/长按)", "觅阅设置", "下载", "重启", "全屏刷新"]
    qx, qy, qw, qh = 40, 176, 132, 52
    for i, label_text in enumerate(qp):
        x = qx + (i % 6) * (qw + 12)
        y = qy + (i // 6) * (qh + 12)
        fill = "#eff6ff" if label_text.startswith("同步") else "#ffffff"
        stroke = "#bfdbfe" if label_text.startswith("同步") else "#d1d5db"
        lines.append(box(label_text, x, y, qw, qh, fill=fill, stroke=stroke))
    lines.append('  <text x="40" y="316" class="node">主页快捷面板（顶部下滑或点按 Wi-Fi/同步展开）</text>')

    # Action bar
    actions = ["刷新", "搜索", "下载", "同步", "睡眠", "觅阅设置"]
    ax, ay, aw, ah = 40, 336, 132, 48
    for i, label_text in enumerate(actions):
        x = ax + i * (aw + 12)
        fill = "#eff6ff" if label_text == "同步" else "#ffffff"
        stroke = "#bfdbfe" if label_text == "同步" else "#d1d5db"
        lines.append(box(label_text, x, ay, aw, ah, fill=fill, stroke=stroke))
    lines.append('  <text x="40" y="416" class="node">首页动作条</text>')

    # Flows
    lines.append(line("点按", 406, 120, 406, 176, color="#2563eb", marker="arrow-blue"))
    lines.append(line("长按", 500, 120, 500, 176, color="#ea580c", marker="arrow-orange"))
    lines.append(line("点按", 250, 292, 472, 336, color="#2563eb", marker="arrow-blue", lx=340, ly=300))
    lines.append(line("点按", 462, 336, 462, 384, color="#2563eb", marker="arrow-blue"))

    lines.append(legend([("#2563eb", "点按 / 普通流程", None),
                         ("#ea580c", "长按 / 诊断", None)], 40, 600))
    lines.append('  <text x="40" y="580" class="sub">同步入口统一为：点按 = 后台静默同步全部；长按 = 同步诊断。</text>')
    lines.append("</svg>")
    write("home-ui-logic.svg", lines)


# ---------------------------------------------------------------------------
# 2. Reader UI logic
# ---------------------------------------------------------------------------
def reader_ui_logic():
    lines = svg_open("0 0 960 700", "MiuRead 阅读页操作逻辑",
                     markers({"arrow-blue": "#2563eb", "arrow-orange": "#ea580c",
                              "arrow-green": "#16a34a", "arrow-purple": "#9333ea"}))
    lines.append('  <rect x="250" y="70" width="460" height="420" rx="10" fill="#f9fafb" stroke="#d1d5db" stroke-width="1.5"/>')
    lines.append('  <text x="480" y="92" text-anchor="middle" class="node">正文阅读区</text>')

    # Tap zones
    lines.append('  <rect x="250" y="70" width="110" height="420" fill="#eff6ff" fill-opacity="0.5"/>')
    lines.append('  <text x="305" y="280" text-anchor="middle" class="zone">左边缘\n点按翻页</text>')
    lines.append('  <rect x="600" y="70" width="110" height="420" fill="#eff6ff" fill-opacity="0.5"/>')
    lines.append('  <text x="655" y="280" text-anchor="middle" class="zone">右边缘\n点按翻页</text>')
    lines.append('  <rect x="360" y="70" width="240" height="42" fill="#fef3c7" fill-opacity="0.65"/>')
    lines.append('  <text x="480" y="96" text-anchor="middle" class="zone">顶部下滑 → 阅读快捷面板</text>')

    # Quick panel
    lines.append(box(["阅读快捷面板", "搜索 · 回到阅读 · 云端划线", "本地上传 · 显隐划线 · 静默同步"], 40, 520, 880, 72))
    lines.append(line("下滑", 480, 490, 480, 520, color="#2563eb", marker="arrow-blue"))

    # Highlight interaction nodes
    lines.append(box(["长按选词", "自动使用下划线", "不弹样式确认"], 40, 140, 160, 76, fill="#f0fdf4", stroke="#86efac"))
    lines.append(line("选词", 200, 178, 250, 178, color="#16a34a", marker="arrow-green"))
    lines.append(box(["点击已有划线", "笔记 / 样式 / 颜色 / 删除"], 40, 250, 160, 76))
    lines.append(line("点按", 200, 288, 250, 288, color="#2563eb", marker="arrow-blue"))
    lines.append(box(["点击云划线", "评论弹层 · 原文与想法"], 40, 360, 160, 76, fill="#faf5ff", stroke="#c4b5fd"))
    lines.append(line("点按", 200, 398, 250, 398, color="#9333ea", marker="arrow-purple"))

    # Edge guard
    lines.append(box(["边缘防误触", "边缘点击可转翻页", "可关闭 / 调比例"], 720, 150, 190, 88, fill="#fff7ed", stroke="#fdba74"))

    lines.append(legend([("#2563eb", "点按 / 面板", None),
                         ("#16a34a", "选词划线", None),
                         ("#9333ea", "云划线评论", None),
                         ("#ea580c", "边缘防误触", None)], 40, 624))
    lines.append("</svg>")
    write("reader-ui-logic.svg", lines)


# ---------------------------------------------------------------------------
# 3. Highlight interaction flow
# ---------------------------------------------------------------------------
def highlight_flow():
    lines = svg_open("0 0 960 720", "MiuRead 划线交互流程",
                     markers({"arrow-blue": "#2563eb", "arrow-green": "#16a34a",
                              "arrow-orange": "#ea580c", "arrow-gray": "#6b7280"}))
    y = 84
    lines.append(box(["开始：长按 / 滑动选词"], 330, y, 300, 64, fill="#eff6ff", stroke="#bfdbfe"))
    y += 64
    lines.append(line(None, 480, y, 480, y + 24, color="#2563eb", marker="arrow-blue"))
    y += 24
    lines.append(diamond("觅阅识别到的书籍？", 480, y + 40))
    lines.append(line("是", 480, y + 80, 480, y + 104, color="#16a34a", marker="arrow-green", lx=500, ly=y + 94))
    lines.append(line("否", 555, y + 40, 700, y + 40, color="#6b7280", marker="arrow-gray", lx=640, ly=y + 32))
    lines.append(box(["KOReader 默认流程"], 700, y + 12, 190, 56, fill="#f9fafb"))
    y += 104
    lines.append(box(["自动应用默认样式「下划线」", "跳过样式选择，直接保存"], 300, y, 360, 76, fill="#f0fdf4", stroke="#86efac"))
    y += 76
    lines.append(line(None, 480, y, 480, y + 24, color="#2563eb", marker="arrow-blue"))
    y += 24
    lines.append(box(["写入本机批注", "本地快照 → 约 12 秒后自动上传"], 300, y, 360, 76))
    y += 76
    lines.append(line(None, 480, y, 480, y + 24, color="#2563eb", marker="arrow-blue"))
    y += 24
    lines.append(diamond("点击这条划线？", 480, y + 40))
    lines.append(line("点击", 480, y + 80, 480, y + 104, color="#2563eb", marker="arrow-blue", lx=500, ly=y + 94))
    y += 104
    lines.append(box(["KOReader 原生二次操作", "添加笔记 / 修改样式 / 颜色 / 删除"], 260, y, 440, 80, fill="#eff6ff", stroke="#bfdbfe"))
    y += 80
    lines.append(line(None, 480, y, 480, y + 20, color="#2563eb", marker="arrow-blue"))
    lines.append(box(["完成", "改动继续触发静默同步"], 330, y + 20, 300, 64, fill="#f9fafb"))
    lines.append(legend([("#2563eb", "主流程", None),
                         ("#16a34a", "觅阅自动下划线", None),
                         ("#ea580c", "长按 / 二次操作", None),
                         ("#6b7280", "非觅阅书籍", None)], 40, 650))
    lines.append("</svg>")
    write("highlight-interaction-flow.svg", lines)


# ---------------------------------------------------------------------------
# 4. Download and dynamic annotations flow
# ---------------------------------------------------------------------------
def download_flow():
    lines = svg_open("0 0 960 760", "MiuRead 下载与动态批注流程",
                     markers({"arrow-blue": "#2563eb", "arrow-green": "#16a34a",
                              "arrow-purple": "#9333ea", "arrow-gray": "#6b7280",
                              "arrow-orange": "#ea580c"}))
    lines.append(box(["用户选择下载", "只生成一个版本"], 60, 80, 200, 72, fill="#eff6ff", stroke="#bfdbfe"))
    lines.append(box(["纯净版 EPUB", "正文完整，不内嵌划线"], 360, 80, 200, 72, fill="#f0fdf4", stroke="#86efac"))
    lines.append(line(None, 260, 116, 360, 116, color="#2563eb", marker="arrow-blue"))

    lines.append(box(["打开书籍", "自动匹配 WeRead 书籍"], 640, 80, 220, 72))
    lines.append(line(None, 560, 116, 640, 116, color="#2563eb", marker="arrow-blue"))

    lines.append(box(["动态拉取调度器", "在线 + 登录 + 空闲", "当前章 + 下一章"], 640, 220, 220, 88, fill="#faf5ff", stroke="#c4b5fd"))
    lines.append(line("翻页推进", 750, 152, 750, 220, color="#9333ea", marker="arrow-purple"))

    lines.append(box(["微信读书 API", "划线与想法按章返回"], 360, 220, 220, 88))
    lines.append(line(None, 640, 264, 580, 264, color="#9333ea", marker="arrow-purple"))

    lines.append(box(["XPointer Overlay", "在本地 EPUB 上绘制下划线"], 60, 220, 220, 88, fill="#f0fdf4", stroke="#86efac"))
    lines.append(line(None, 360, 264, 280, 264, color="#2563eb", marker="arrow-blue"))

    lines.append(box(["阅读快捷面板", "「显隐划线」开关"], 360, 380, 220, 72))
    lines.append(line("显示 / 隐藏", 470, 308, 470, 380, color="#2563eb", marker="arrow-blue"))

    lines.append(box(["失败与重试", "网络/登录恢复后自动重试", "旧划线与想法版仅保留可读"], 60, 400, 220, 96, fill="#fff7ed", stroke="#fdba74"))
    lines.append(line(None, 60, 264, 60, 400, color="#ea580c", marker="arrow-orange", lx=30, ly=330))
    lines.append(line("旧版不叠加投影", 60, 496, 280, 496, color="#6b7280", marker="arrow-gray", lx=170, ly=488))

    lines.append(legend([("#2563eb", "下载 / 显示路径", None),
                         ("#9333ea", "动态拉取", None),
                         ("#ea580c", "失败重试", None),
                         ("#6b7280", "旧版兼容", None)], 40, 680))
    lines.append("</svg>")
    write("download-dynamic-annotations-flow.svg", lines)


# ---------------------------------------------------------------------------
# 5. Sync scheduler state machine
# ---------------------------------------------------------------------------
def sync_state_machine():
    lines = svg_open("0 0 960 660", "MiuRead 静默同步状态机",
                     markers({"arrow-blue": "#2563eb", "arrow-green": "#16a34a",
                              "arrow-red": "#dc2626", "arrow-orange": "#ea580c",
                              "arrow-gray": "#6b7280"}))
    # Initial
    lines.append('  <circle cx="120" cy="200" r="8" fill="#111827"/>')
    # States
    states = {
        "done": ("已同步", 240, 120, 180, 70, "#f0fdf4", "#86efac"),
        "wait": ("等待同步", 500, 120, 180, 70, "#eff6ff", "#bfdbfe"),
        "run": ("同步中", 500, 340, 180, 70, "#fff7ed", "#fdba74"),
        "fail": ("N 项未完成", 180, 430, 200, 70, "#fef2f2", "#fecaca"),
    }
    for key, (label, x, y, w, h, fill, stroke) in states.items():
        lines.append(box(label, x, y, w, h, fill=fill, stroke=stroke))
    lines.append(line(None, 128, 200, 240, 165, color="#2563eb", marker="arrow-blue"))

    # done -> wait: request
    lines.append(line("request(编辑/翻页)", 420, 155, 500, 155, color="#2563eb", marker="arrow-blue", lx=460, ly=145))
    # wait -> run: timer due + gate ok
    lines.append(line("到期 & 门控通过", 590, 190, 590, 340, color="#2563eb", marker="arrow-blue", lx=600, ly=265))
    # run -> done: success
    lines.append(line("成功", 500, 375, 420, 190, color="#16a34a", marker="arrow-green", lx=420, ly=290))
    # run -> fail: failure
    lines.append(line("失败", 500, 375, 380, 430, color="#dc2626", marker="arrow-red", lx=410, ly=420))
    # fail -> wait: backoff retry
    lines.append(line("退避重试", 280, 430, 500, 190, color="#ea580c", marker="arrow-orange", lx=360, ly=340))
    # wait -> wait: gate blocked/busy
    lines.append('  <path d="M 680 155 C 760 155, 760 260, 680 260" fill="none" stroke="#6b7280" stroke-width="1.5" marker-end="url(#arrow-gray)"/>')
    lines.append('  <text x="770" y="210" class="zone">门控关闭 / 忙</text>')
    # wait -> done: skip
    lines.append(line("skip(不适用)", 500, 120, 330, 120, color="#6b7280", marker="arrow-gray", lx=420, ly=110))

    lines.append(legend([("#2563eb", "请求 / 调度", None),
                         ("#16a34a", "成功", None),
                         ("#dc2626", "失败", None),
                         ("#ea580c", "退避重试", None),
                         ("#6b7280", "跳过 / 阻塞", None)], 40, 590))
    lines.append('  <text x="40" y="570" class="sub">四个状态覆盖：本地批注上传与云端划线动态拉取；进度与阅读时间仍由各自服务管理。</text>')
    lines.append("</svg>")
    write("sync-scheduler-state.svg", lines)


if __name__ == "__main__":
    home_ui_logic()
    reader_ui_logic()
    highlight_flow()
    download_flow()
    sync_state_machine()
    print("done")
