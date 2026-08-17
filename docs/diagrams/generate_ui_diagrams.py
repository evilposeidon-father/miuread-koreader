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


# 1. Home UI logic (4.6.2: bottom three tabs)
def home_ui_logic():
    lines = svg_open("0 0 960 720", "MiuRead 首页操作逻辑（4.6.2：底部三 Tab）",
                     markers({"arrow-blue": "#2563eb", "arrow-orange": "#ea580c"}))
    lines.append(box(["账号", "登录状态"], 40, 64, 128, 52))
    lines.append(box(["Wi-Fi", "点按开关"], 180, 64, 116, 52))
    lines.append(box(["同步", "点按: 静默同步全部", "长按: 同步诊断"], 308, 64, 200, 52, fill="#eff6ff", stroke="#bfdbfe"))
    lines.append(box(["时间"], 520, 64, 84, 52))
    lines.append(box(["电量"], 616, 64, 84, 52))
    lines.append(box(["更多"], 712, 64, 84, 52))
    lines.append('  <text x="40" y="148" class="node">顶部状态栏</text>')
    lines.append(box(["书架"], 40, 170, 280, 46, fill="#eff6ff", stroke="#bfdbfe"))
    lines.append(box(["书城"], 340, 170, 280, 46))
    lines.append(box(["我的"], 640, 170, 280, 46))
    lines.append('  <text x="40" y="248" class="node">底部三 Tab（切页防抖，不弹页面名提示）</text>')
    lines.append(box(["继续阅读大卡", "进度条 + 继续阅读"], 40, 268, 280, 76, fill="#f0fdf4", stroke="#86efac"))
    lines.append(box(["已下载", "书架排序: 最近/加入/书名/作者"], 40, 364, 280, 76))
    lines.append(box(["本地书籍 / 公众号", "来源分组 · 长按管理"], 40, 460, 280, 76))
    lines.append('  <text x="40" y="572" class="sub">书架页：继续阅读 + 分组书单 + 排序 + 空态「去书城逛逛吧」一键跳转。</text>')
    lines.append(box(["搜索微信读书", "本地内容不伪装成书城"], 340, 268, 280, 76, fill="#eff6ff", stroke="#bfdbfe"))
    lines.append(box(["公众号", "订阅号文章阅读"], 340, 364, 280, 76))
    lines.append(box(["线上分类", "待验证，可用后补齐"], 340, 460, 280, 76, fill="#f9fafb"))
    lines.append('  <text x="340" y="572" class="sub">书城页：搜索微信读书 + 公众号；无结果统一「换个关键词试试」。</text>')
    lines.append(box(["账号状态"], 640, 268, 280, 60))
    lines.append(box(["今日阅读 / 本周阅读", "点卡片=刷新时长", "阅读周报入口在列表"], 640, 348, 280, 96, fill="#fff7ed", stroke="#fdba74"))
    lines.append(box(["我的批注 · 全部书籍", "阅读历史 · 设置"], 640, 464, 280, 72))
    lines.append('  <text x="640" y="572" class="sub">我的页：时长卡（KOReader 统计）点击刷新；周报/批注/书架管理/历史/设置。</text>')
    lines.append(line("点按 / 长按", 408, 116, 408, 170, color="#2563eb", marker="arrow-blue"))
    lines.append(legend([("#2563eb", "点按 / 普通流程", None),
                         ("#ea580c", "长按 / 诊断", None)], 40, 640))
    lines.append('  <text x="40" y="620" class="sub">同步入口：点按 = 后台静默同步全部；长按 = 同步诊断。休眠前会先同步再息屏。</text>')
    lines.append("</svg>")
    write("home-ui-logic.svg", lines)


# 2. Reader UI logic
def reader_ui_logic():
    lines = svg_open("0 0 960 720", "MiuRead 阅读页操作逻辑（4.6.2）",
                     markers({"arrow-blue": "#2563eb", "arrow-orange": "#ea580c",
                              "arrow-green": "#16a34a", "arrow-purple": "#9333ea"}))
    lines.append('  <rect x="250" y="70" width="460" height="380" rx="10" fill="#f9fafb" stroke="#d1d5db" stroke-width="1.5"/>')
    lines.append('  <text x="480" y="92" text-anchor="middle" class="node">正文阅读区（状态行含今日阅读时长）</text>')
    lines.append('  <rect x="250" y="70" width="110" height="380" fill="#eff6ff" fill-opacity="0.5"/>')
    lines.append('  <text x="305" y="260" text-anchor="middle" class="zone">左边缘\n点按翻页</text>')
    lines.append('  <rect x="600" y="70" width="110" height="380" fill="#eff6ff" fill-opacity="0.5"/>')
    lines.append('  <text x="655" y="260" text-anchor="middle" class="zone">右边缘\n点按翻页</text>')
    lines.append('  <rect x="360" y="70" width="240" height="42" fill="#fef3c7" fill-opacity="0.65"/>')
    lines.append('  <text x="480" y="96" text-anchor="middle" class="zone">顶部下滑 → 快捷面板</text>')
    lines.append(box(["快捷面板（五组前置）", "更多 · 目录 · 进度 + 字体 · 亮度"], 40, 500, 880, 64, fill="#eff6ff", stroke="#bfdbfe"))
    lines.append(line("下滑", 480, 450, 480, 500, color="#2563eb", marker="arrow-blue"))
    lines.append(box(["更多 → 控制中心", "书签 · 想法 · 划线 · 搜索 · 设置", "批注面板 / 本章想法 / 最近批注"], 40, 140, 170, 96, fill="#faf5ff", stroke="#c4b5fd"))
    lines.append(line("点按", 210, 188, 250, 188, color="#9333ea", marker="arrow-purple"))
    lines.append(box(["长按选词", "自动下划线（默认样式）", "选词菜单开关可留复制/查词"], 40, 270, 170, 96, fill="#f0fdf4", stroke="#86efac"))
    lines.append(line("选词", 210, 318, 250, 318, color="#16a34a", marker="arrow-green"))
    lines.append(box(["点击已有划线", "笔记 / 样式 / 删除"], 40, 396, 170, 76))
    lines.append(line("点按", 210, 434, 250, 434, color="#2563eb", marker="arrow-blue"))
    lines.append(box(["夜间模式", "KOReader 原生 night_mode"], 720, 150, 190, 76, fill="#fff7ed", stroke="#fdba74"))
    lines.append(box(["边缘防误触", "边缘点击可转翻页"], 720, 250, 190, 76))
    lines.append(legend([("#2563eb", "点按 / 面板", None),
                         ("#16a34a", "选词划线", None),
                         ("#9333ea", "控制中心", None),
                         ("#ea580c", "夜间 / 防误触", None)], 40, 640))
    lines.append('  <text x="40" y="620" class="sub">批注面板：书签/划线/想法计数 + 搜索全部批注；本章想法聚合章内划线与想法（点击跳转）。</text>')
    lines.append("</svg>")
    write("reader-ui-logic.svg", lines)


# 3. Highlight interaction flow
def highlight_flow():
    lines = svg_open("0 0 960 760", "MiuRead 划线交互流程（4.6.2）",
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
    lines.append(box(["选词菜单开关？", "开启: 复制 / 查词 / 划线菜单", "关闭: 直接自动划线"], 40, y, 190, 88, fill="#fff7ed", stroke="#fdba74"))
    lines.append(diamond("选词菜单开关？", 560, y + 46))
    lines.append(line(None, 230, y + 44, 480, y + 44, color="#2563eb", marker="arrow-blue"))
    lines.append(box(["保留 KOReader 选择菜单", "复制 / 查词 / 划线"], 660, y + 16, 250, 62, fill="#f9fafb"))
    lines.append(line("开启", 660, y + 44, 710, y + 44, color="#2563eb", marker="arrow-blue"))
    y += 96
    lines.append(box(["自动应用默认样式", "下划线 / 浅底 / 反白", "（默认下划线，可切换）"], 300, y, 360, 92, fill="#f0fdf4", stroke="#86efac"))
    y += 92
    lines.append(line(None, 480, y, 480, y + 24, color="#2563eb", marker="arrow-blue"))
    y += 24
    lines.append(box(["写入本机批注", "本地快照 → 自动上传，失败退避重试"], 300, y, 360, 76))
    y += 76
    lines.append(line(None, 480, y, 480, y + 24, color="#2563eb", marker="arrow-blue"))
    y += 24
    lines.append(diamond("点击这条划线？", 480, y + 40))
    lines.append(line("点击", 480, y + 80, 480, y + 104, color="#2563eb", marker="arrow-blue", lx=500, ly=y + 94))
    y += 104
    lines.append(box(["批注操作", "添加笔记 / 修改样式 / 删除"], 260, y, 440, 80, fill="#eff6ff", stroke="#bfdbfe"))
    y += 80
    lines.append(line(None, 480, y, 480, y + 20, color="#2563eb", marker="arrow-blue"))
    lines.append(box(["完成", "改动继续触发静默同步"], 330, y + 20, 300, 64, fill="#f9fafb"))
    lines.append(legend([("#2563eb", "主流程", None),
                         ("#16a34a", "自动划线", None),
                         ("#ea580c", "选词菜单开关", None),
                         ("#6b7280", "非觅阅书籍", None)], 40, 690))
    lines.append("</svg>")
    write("highlight-interaction-flow.svg", lines)


# 4. Download and dynamic annotations flow
def download_flow():
    lines = svg_open("0 0 960 760", "MiuRead 下载与动态批注流程（4.6.2）",
                     markers({"arrow-blue": "#2563eb", "arrow-green": "#16a34a",
                              "arrow-purple": "#9333ea", "arrow-gray": "#6b7280",
                              "arrow-orange": "#ea580c"}))
    lines.append(box(["用户选择下载", "只生成一个版本"], 60, 80, 200, 72, fill="#eff6ff", stroke="#bfdbfe"))
    lines.append(box(["纯净版 EPUB", "正文完整，不内嵌划线"], 360, 80, 200, 72, fill="#f0fdf4", stroke="#86efac"))
    lines.append(line(None, 260, 116, 360, 116, color="#2563eb", marker="arrow-blue"))
    lines.append(box(["打开书籍", "自动匹配 WeRead 书籍", "本地书也可匹配并上传"], 640, 80, 240, 88))
    lines.append(line(None, 560, 116, 640, 116, color="#2563eb", marker="arrow-blue"))
    lines.append(box(["动态拉取调度器", "在线 + 登录 + 空闲", "当前章 + 下一章渐进", "断点续传 / 可取消"], 640, 230, 240, 112, fill="#faf5ff", stroke="#c4b5fd"))
    lines.append(line("翻页推进", 760, 168, 760, 230, color="#9333ea", marker="arrow-purple"))
    lines.append(box(["微信读书 API", "划线与想法按章返回", "个人 + 全量合并去重"], 360, 230, 220, 112))
    lines.append(line(None, 640, 286, 580, 286, color="#9333ea", marker="arrow-purple"))
    lines.append(box(["XPointer Overlay", "本地 EPUB 上绘制下划线", "位置缓存 + 分帧预热"], 60, 230, 220, 112, fill="#f0fdf4", stroke="#86efac"))
    lines.append(line(None, 360, 286, 280, 286, color="#2563eb", marker="arrow-blue"))
    lines.append(box(["阅读快捷面板", "「显隐划线」开关"], 360, 400, 220, 72))
    lines.append(line("显示 / 隐藏", 470, 342, 470, 400, color="#2563eb", marker="arrow-blue"))
    lines.append(box(["失败与重试", "网络/登录恢复后自动重试", "登录续期预防性保活"], 60, 420, 220, 96, fill="#fff7ed", stroke="#fdba74"))
    lines.append(line(None, 60, 342, 60, 420, color="#ea580c", marker="arrow-orange", lx=30, ly=380))
    lines.append(line("旧版不叠加投影", 60, 516, 280, 516, color="#6b7280", marker="arrow-gray", lx=170, ly=508))
    lines.append(legend([("#2563eb", "下载 / 显示路径", None),
                         ("#9333ea", "动态拉取", None),
                         ("#ea580c", "失败重试", None),
                         ("#6b7280", "旧版兼容", None)], 40, 690))
    lines.append("</svg>")
    write("download-dynamic-annotations-flow.svg", lines)


# 5. Sync scheduler state machine
def sync_state_machine():
    lines = svg_open("0 0 960 700", "MiuRead 静默同步状态机（4.6.2）",
                     markers({"arrow-blue": "#2563eb", "arrow-green": "#16a34a",
                              "arrow-red": "#dc2626", "arrow-orange": "#ea580c",
                              "arrow-gray": "#6b7280"}))
    lines.append('  <circle cx="120" cy="200" r="8" fill="#111827"/>')
    states = {
        "done": ("已同步", 240, 120, 180, 70, "#f0fdf4", "#86efac"),
        "wait": ("等待同步", 500, 120, 180, 70, "#eff6ff", "#bfdbfe"),
        "run": ("同步中", 500, 340, 180, 70, "#fff7ed", "#fdba74"),
        "fail": ("N 项未完成", 180, 430, 200, 70, "#fef2f2", "#fecaca"),
    }
    for key, (label, x, y, w, h, fill, stroke) in states.items():
        lines.append(box(label, x, y, w, h, fill=fill, stroke=stroke))
    lines.append(line(None, 128, 200, 240, 165, color="#2563eb", marker="arrow-blue"))
    lines.append(line("request(编辑/翻页)", 420, 155, 500, 155, color="#2563eb", marker="arrow-blue", lx=460, ly=145))
    lines.append(line("到期 & 门控通过", 590, 190, 590, 340, color="#2563eb", marker="arrow-blue", lx=600, ly=265))
    lines.append(line("成功", 500, 375, 420, 190, color="#16a34a", marker="arrow-green", lx=420, ly=290))
    lines.append(line("失败", 500, 375, 380, 430, color="#dc2626", marker="arrow-red", lx=410, ly=420))
    lines.append(line("退避重试", 280, 430, 500, 190, color="#ea580c", marker="arrow-orange", lx=360, ly=340))
    lines.append('  <path d="M 680 155 C 760 155, 760 260, 680 260" fill="none" stroke="#6b7280" stroke-width="1.5" marker-end="url(#arrow-gray)"/>')
    lines.append('  <text x="770" y="210" class="zone">门控关闭 / 忙</text>')
    lines.append(line("skip(不适用)", 500, 120, 330, 120, color="#6b7280", marker="arrow-gray", lx=420, ly=110))
    lines.append(box(["休眠", "休眠按钮: 先同步再息屏", "（8s 超时兜底，失败提示后息屏）"], 700, 400, 230, 96, fill="#fef3c7", stroke="#fde68a"))
    lines.append(line("触发同步", 590, 355, 700, 430, color="#ea580c", marker="arrow-orange", lx=700, ly=370))
    lines.append(line("电源键息屏也触发", 700, 496, 590, 410, color="#ea580c", marker="arrow-orange", lx=720, ly=470, dash="4 4"))
    lines.append(legend([("#2563eb", "请求 / 调度", None),
                         ("#16a34a", "成功", None),
                         ("#dc2626", "失败", None),
                         ("#ea580c", "退避 / 休眠触发", None),
                         ("#6b7280", "跳过 / 阻塞", None)], 40, 620))
    lines.append('  <text x="40" y="600" class="sub">覆盖：批注上传与云端划线拉取；进度/时长各自服务；休眠前同步失败也会正常息屏。</text>')
    lines.append("</svg>")
    write("sync-scheduler-state.svg", lines)


if __name__ == "__main__":
    home_ui_logic()
    reader_ui_logic()
    highlight_flow()
    download_flow()
    sync_state_machine()
    print("done")