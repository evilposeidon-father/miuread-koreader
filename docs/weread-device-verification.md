# Kindle 微信读书 · 真机验证协议（P5）

> 目标：在 Kindle PaperWhite 3（KOReader v2026.07.1）上执行发版回归清单，逐项通过后方可发版。
> 每项给出：操作步骤 / 通过标准 / 失败处理。失败处理原则：记录 crash.log 与 miuread.lua 偏好、回退旧插件包、按项修复后重验。

## 0. 准备

1. 构建 dist：`python scripts/build_package.py`（产出 dist/miuread-vX.Y.Z-dev-full.zip + SHA256SUMS.txt）。
2. USB 挂载 Kindle，整包覆盖 `F:\koreader\plugins\miuread.koplugin`（先删残留目录再解压）。
3. 完整重启 KOReader；日志：`F:\koreader\crash.log`（搜 `[MiuRead]`）；数据：`F:\koreader\settings\miuread.lua`。
4. 备份旧插件包与 miuread.lua（回滚用）。

## 1. 执行顺序与通过标准

| # | 项 | 操作 | 通过标准 |
| --- | --- | --- | --- |
| 1 | 启动 | 冷启动 KOReader 进入觅阅主页 | 无 crash；日志无 `[MiuRead]` 报错；首页正常渲染 |
| 2 | 迁移 | 检查 miuread.lua | home_ui.layout_version=24；reader_ui.quick_actions_layout_version=3；page 字段为 shelf/store/me 之一 |
| 3 | Tab 连点 | 书架/书城/我的 快速连点 ×20 | 不崩；无重复全量重建（观察刷新次数）；最终停在最后点击页 |
| 4 | 空态 | 登出账号/空书架/无 statistics.sqlite3/无公众号 各看一眼 | 空态文案正确；「去书城」跳转书城页 |
| 5 | 旋转 | 书架/书城/我的 各旋转一次 | 布局重排正确；Tab 不遮挡页脚；页码不丢 |
| 6 | 网格/hero | 竖屏书架 | 4×2 网格完整（若降 1 行需记录原因）；hero 进度条可见；「继续阅读」标题正确 |
| 7 | 时长对拍 | 我的页 vs 手机端微信读书 | 卡片显示今日/本周（本机统计口径，见 A16/B13）；点击「阅读周报 ›」弹出周报 |
| 8 | 快捷面板 | 阅读中下滑 | 五组前置：更多/目录/进度 + 字体/亮度行；长按按键可替换/隐藏/恢复；「更多」打开控制中心 |
| 9 | 触摸命中 | 书城/我的各行 | 实际可点区域 ≥48px；无错触相邻行 |
| 10 | 低内存 | 下载中 + 翻页 + 切 Tab | 不闪退；下载进度正常更新 |
| 11 | 返回链 | 书城→返回→书架→返回→退出 | 逐层正确；书城/我的页返回键回书架 |
| 12 | 状态恢复 | 读一本书→返回首页 | page 状态（书架/书城/我的）保持；hero 更新为最近阅读 |

## 2. 附加真机检查（对齐项抽查）

- 长按选词（MiuRead 书）：直接下划线；点击划线→想法/笔记/删除弹层。
- 夜间模式（快捷面板设备行）：整屏反色；关闭后恢复；自绘面板同步反色无花屏。
- 书城搜索：全库搜索微信读书、未加入书架可下载。
- 公众号入口：书城/书架入口均可达文章列表。
- 书架排序（首页与书架→书架排序）：四种排序均生效且分页正确。
- 人工必查：① 夜间模式切换前后自绘面板同步反色无花屏；② 目录/字体面板直达且可改（4.5.43 复检——逐个映射 KOReader 具体事件，不可用则回退自绘）；③ 登录失效提示（模拟会话失效，首页与「我的」页应显示需要重新登录）。

## 3. 失败处理与回滚

1. 收集：`F:\koreader\crash.log` 尾部 + `settings\miuread.lua`（脱敏后附 issue）。
2. 回滚：恢复备份的 miuread.koplugin 目录与 miuread.lua，重启 KOReader。
3. 复验：修复项单独回归 + 全清单重跑一遍。

## 4. 通过后

- 全 12 项 ✅ + 抽查 ✅ → 更新 CHANGELOG 版本节日期（`## X.Y.Z - YYYY-MM-DD`），推 tag vX.Y.Z。
- GitHub Actions 自动：版本校验 → Lua 5.1 语法检查 → 构建 full.zip → SHA-256 → 更新 stable-channel update.json。

> 本协议由 R5 发布评审确认后作为发版门禁。