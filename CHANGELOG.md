# Changelog

本文件记录 MiuRead 的版本变化。尚未发布的内容写入 `Unreleased`；发布后移动到对应版本。

## Unreleased

- 暂无。

## 4.6.4 - Unreleased

- 架构 抽出 `miuread.plugin_reader_lifecycle_io` 控制器：从 main.lua 迁移 interactive network（_run_interactive_network / _request_catalog / _wait_for_network / _cancel_network_waits / _interactive_network_context(_valid) / _apply_interactive_auth / _cancel_interactive_network）与 reader lifecycle（_finalize_reader_instance_close / _start_reader_rebuild_candidate / _finish_reader_rebuild_candidate / _reader_rebuild_ready_state / _reader_rebuild_cancel）共 12 个方法，main.lua 2852 → 2412 行（-440）；新增 test_plugin_reader_lifecycle_io（5 用例，含 interactive_child_store 的 auth 会话一致性验证）。
- 架构 抽出 `miuread.reader_geometry` 深模块：plugin_reader 的 _reader_progress_percent / _reader_current_page / _reader_toc_items 纯逻辑下沉（progress_percent / current_page / nearest_toc_index / normalize_toc_items 4 纯函数），plugin_reader 3426 → 3389 行（-37）；新增 test_reader_geometry（8 用例）。
- 架构 self 字段命名空间化：4 个跨 controller 共享字段统一加 `_miuread_` 全局前缀（_miuread_auto_update_check_running / _miuread_repair_prompt_open / _miuread_shelf_refresh_generation / _miuread_thought_popup_busy），消除 plugin_home/plugin_update、plugin_reader_lifecycle_io/plugin_repair、plugin_home/plugin_shelf、plugin_preferences/plugin_thought_popup 之间的静默覆盖风险；新增结构守卫 test_no_unprefixed_cross_controller_self_fields（28 项守卫全绿，禁止未来跨 controller 字段无全局前缀）。
- 架构 plugin_navigation.onReaderReady 拆分：把 post-ready 后台 worker（sync progress pull + device-state refresh + 尺寸恢复）抽为 `_schedule_reader_ready_workers`，onReaderReady 从 171 行降至 ~137 行，ready 路径状态机保持可读。
- 工程 CONTRIBUTING.md 新增「命名规则」章节：controller 方法/self 字段全局前缀、深模块模板、Reader/Home/Sync 命名边界（content_reader vs plugin_reader vs reader_*；plugin_home 四 controller 职责分界；sync.lua vs plugin_sync vs 深模块）。

## 4.6.3 - Unreleased

- 架构 sync.lua 拆分深模块第一批：抽出 `miuread.sync_catalog_prepare` 深模块（5 纯函数：prepare_catalog_input / select_catalog_worker / merge_legacy_context / detect_catalog_drift / apply_cookies_change），`miuread.sync_inverse_mapping` 深模块（3 决策函数 should_use_inverse_mapping / compute_inverse_decision + merge_inverse_into_position）；sync.lua 3258 → 3146 行（-112），`_prepare_progress_catalog`（145 行）+ `_prefer_inverse_cloud_mapping`（116 行）改为薄委托，仅保留 worker:run() 调用与 callback 装配。所有 [MiuRead][ProgressMap] / [ProgressOffset] 日志文案、错误码、回调返回值结构原样保留；callback stale 检查与 saved/verified catalog drift 决策下沉到 prepare 模块。
- 架构 plugin_home_content 抽出本地书架内联子系统：13 个 `_home_local_*` 方法（_home_local_cache / _home_local_tree_cache / _home_local_roots / _home_local_root_for_path / _home_local_inline_context / _home_local_inline_parent_entry / _home_local_inline_rows / _home_local_inline_title / _home_local_empty_text / _home_local_folder_entry / _home_local_known_paths / _home_local_rows / _home_local_inline_navigate）下沉到独立 `miuread.plugin_home_local_inline` controller（247 行），plugin_home_content 3572 → 3353 行（-219）；4 个跨域编排方法（_home_apply_local_inline_section / _home_set_local_inline_location / _home_ensure_local_inline_loaded / _home_handle_back）留在 plugin_home_content（混合 home section 状态）。LocalLibrary 改用 Lazy 保持启动期不加载；test_split_controllers_installed 守卫新增 PluginHomeLocalInline 控制器声明。
- 架构 plugin_reader 抽出 highlight policy 段：5 个 highlight 方法（_restore_miuread_highlight_action_policy / highlight_selection_policy / _selection_menu_enabled / _apply_miuread_highlight_action_policy / _apply_miuread_highlight_defaults）并入 `miuread.highlight_policy`（23 → 163 行，原纯函数 M.policy / STYLES / style_label / is_style + 新 Plugin mixin），plugin_reader 3553 → 3426 行（-127，含 sed 范围误删 _reader_panel_active 后修复）；test_external_chapter_and_highlight 的 stub plugin 加装 HighlightPolicyController.install 后 4 个旧测试全绿。
- 架构 plugin_home 抽出偏好持久化 IO：6 个偏好方法（_home_preferences / _save_ui_preferences / _mark_ui_preferences_flushed / _save_home_preferences / _save_home_preferences_deferred / _flush_home_preferences）下沉到独立 `miuread.plugin_home_preferences_io` controller（444 行），plugin_home 2085 → 1682 行（-403）；layout_version 迁移（v20→v24）、network_metadata 一次性修复、generation/save_pending 状态机、UiScale.setDisplayMode/setFontName 联动均集中在新 controller，plugin_home 专注调度/模式 UI。HOME_ACTION_LAYOUT_VERSION / HOME_PANEL_LAYOUT_VERSION 等 12 个 HomeLayouts 常量 + Device require 集中在新文件头部；test_split_controllers_installed 守卫新增 PluginHomePreferencesIO 控制器声明并从 PluginHome 期望列表移除 _home_preferences。
- 修复 真机闪退（plugin_home_preferences_io.lua:296 / :299 缺 require）：Step 4 拆分时把 plugin_home.lua 里的 `local lfs=require("libs/libkoreader-lfs")` 与 `local LocalLibrary=Lazy("miuread.local_library")` 一起忘在新文件头部 require，_home_preferences 在 add_root / 根目录扫描两处分别命中 `LocalLibrary.normalize` 与 `lfs.attributes`，打开首页时 5 秒后闪退。新文件头部补上 Lazy("miuread.local_library") + lfs require；新增 test_plugin_home_preferences_io_crash（2 用例）覆盖 _home_preferences 实际运行路径，koreader_stubs.fake_modules 补 miuread.local_library。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）增至 296 个用例、结构守卫 27 项全绿：4 步重构新增 test_sync_catalog_prepare（8）/ test_sync_inverse_mapping（8）/ test_plugin_home_local_inline（11）/ test_highlight_policy（6）/ test_plugin_home_preferences_io（5）/ test_plugin_home_preferences_io_crash（2）共 40 个纯逻辑 + 迁移 + 回归单测；test_split_controllers_installed 扩为 23 个 controller 列表（新增 PluginHomeLocalInline 与 PluginHomePreferencesIO，从 PluginHome 移除 _home_preferences）；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿（test_changelog_current_version_records_controller_splits 验证 controller 拆分记录的回归门禁在 4.6.3 块通过）；bootstrap.lua 的 device stub 补 canSuspend / getPowerDevice（plugin_home_preferences_io 的 _home_preferences 依赖），koreader_stubs 的 fake_modules 补 device 与 miuread.local_library 表（UiScale / HomeLayouts / LocalLibrary 测试备用）。打 zip：dist/miuread-v4.6.3-dev-full.zip（SHA-256 8dc0889eee4dc211760c8e85f2afaaaa72dd3ebcfad968791cd1e8009f728fdd，本版含真机闪退修复）。


## 4.6.2 - 2026-08-18

- 修复 时长卡显示 0 分钟：格式化函数 pcall 传参错误（点号定义被当 self 传入，秒数变表→tonumber=nil→0）；改为直接调用，卡片与弹窗数值一致（真机日志定位：查询秒数正确、仅格式化环节出错）。
- 修复 今日/本周时长按 UTC 日界计算：Kindle 进程时区与显示时区不一致，凌晨阅读被算进「昨天」导致今日 0；日界/周界改用纯日历算术 + 显示时区偏移（mode=device 且设备偏移为 0 时回退配置 offset）。
- 修复 返回首页后切「书城/我的」偶发无响应：阅读器关闭后 parked HomeView 仍在恢复，切 tab 的 nextTick 判不可见即丢弃点击；改为未显示时每 0.25s 重试（上限 6 次），不再吞点击。
- 修复 时长卡刷新不生效/与周报不一致：卡片读取走 reading_stats 默认 30s 缓存（显示旧值），弹窗用 force=true（新值）——卡片改为强制重读，点击刷新立即更新、与周报一致。
- 体验 我的页时长卡与「阅读周报」统一数据源（KOReader 阅读统计）：页面今日/本周与弹窗数值一致；时长卡点击=刷新阅读时长（重算+toast），「阅读周报」入口移入列表行。
- 体验 休眠按钮先同步再息屏：点击休眠→上传批注/想法与阅读时长→提示「已同步，即将休眠」或「同步未完成，即将休眠」→再息屏（8 秒超时兜底）；电源键息屏触发批注同步，恢复后提示结果。
- 修复 真机今日/本周时长「写入后读不到」：KOReader 对非 doc-only 插件在首页与阅读器各实例化一次，每次 Plugin:init() 都 Store:new() → 两个独立 settings db——阅读实例写账本（内存+文件），被 park 在阅读器下的首页实例用旧内存 flush 覆盖文件，账本消失、home 读 nil。Store:new 对同 settings_path 的非隔离实例改为单例复用（isolated worker 不受影响），跨实例共享 db。
- 修复 阅读记录列表重复：镜像行是原生划线的快照（同 pos0、不同 id 体系），列表把每条划线显示两次（37 原生 + 37 镜像 = 19 页）——按 pos0 位置去重，同位置镜像跳过，列表回归真实条数。
- 修复 阅读记录镜像行跳转失败：镜像行 xpointer 为空（本机快照只存本地 pos0），跳转却取 xpointer → 永远失败；改用 pos0（本地坐标）跳转，本机划线跳转恢复。
- 修复 阅读周报与我的页时长不一致：两处统一为 KOReader 阅读统计（用户拍板，页面与弹窗数值一致）。
- 修复 阅读记录云端划线跳转静默失败：云端坐标（微信读书 range）在本地 EPUB 里 getPosFromXPointer 必失败，跳转前先预检本地可定位性，失败提示「该划线来自云端，本机暂未定位到对应位置」（外部划线 locate 匹配质量另立专项）。
- 修复 真机「我的批注」闪退：local_annotation_database.recent_all 在 database_paths（local 声明于文件后部）之前调用，词法作用域使其变全局查找 nil；database_paths 上移至文件头，新增空 store 回归测试（本地套件此前未覆盖 recent_all 未抓到）。
- 修复 底部三 Tab 切换弹「书架/书城/我的」提示窗：_refresh_home_view 对非空 message 一律 toast，切 tab 不再传页面名（书籍信息更新等提示保留）。
- 修复/诊断 今日/本周时长未显示：账本写入/读取路径加 [MiuRead][Ledger] 诊断日志（add/final flush/home read），真机重测一次即可定位。
- 流畅 稳定性五角色复审落地：划线覆盖层增量更新保留位置缓存（setRecords 只按记录失效受影响项，章节同步不再清空缓存导致翻页 2N 次 XPointer 重算）；paintTo 取当前页改 pcall 多值安全（页码缓存不再偶发断裂）；nearest 冷查询加负缓存（未命中的位置只查一次）。
- 流畅 阅读记录/列表对话框的 categories 提供器打开时一次性求值并冻结：展开行/翻页/切 Tab 不再每次重建重跑批注库查询（此前每次交互 3×400 行 SQLite）；keep_open/内联操作等管理动作先失效缓存再重建，数据即时刷新；单列表 items 提供器（设置菜单等需逐次重快照勾选态）保持每次重建求值。
- 流畅 划线样式切换去抖合帧 + 局部重绘：菜单内连选样式不再每次全屏 flash——updateHighlightDrawer 已即时应用状态，最后一次点击 0.25s 后对阅读面做一次 "ui" 重绘。
- 流畅 外部划线覆盖层位置预热分帧化：章节同步/整书同步/重排后不再在下一帧绘制路径内同步 2N 次 XPointer 定位（每次调度帧最多预热 32 条，缺失位置查询与绘制/nearest 共用同一 lookup 与 30s 负缓存）；nearest 负缓存加 TTL（瞬时失败 30s 后重试，不再永久跳过）。
- 流畅 阅读记录页码换算按「书|xpointer」记忆化：同一位置在原生列表与镜像行合并时只转换一次，打开阅读记录不再逐条重复 CREngine 调用。
- 流畅 批注面板打开不再同步全量镜像 upsert：镜像刷新延迟 0.15s 移出打开关键路径 + 15s 节流（任意成功快照武装节流），面板立即渲染，计数/记录读照常。
- 流畅 我的批注列表打开不再全库扫描：recent_all 按批注库 mtime 只扫描最近 12 本书的 SQLite（默认上限 200→100）+ 30s 短期缓存（本模块全部写入与首页批注管理流显式失效），重复打开零扫描、管理删除后立即刷新。
- 稳定 同步守护进程的阅读时长归账：daemon 成功分支补记 read_time_ledger（与直接上传路径同源同秒），今日/本周时长不再漏记守护进程同步的时间；save_session 改延迟落盘、退出时统一补刷账本。
- 稳定 选词菜单设置不再覆盖用户全局配置：显示/隐藏选择菜单的开关只作用于 MiuRead 书（orig 保存/恢复 + saveHighlight 守卫），退出书籍后用户 KOReader 原设置原样保留。
- 界面 对齐微信读书手机端：首页改为底部三 Tab（书架/书城/我的）——书城页=搜索微信读书+公众号（线上分类待验证，本地内容不伪装成书城），我的页=账号状态+阅读时长卡（本机统计）+我的想法/划线/书架管理/阅读历史/设置；标题保留「觅阅」（微信读书为对齐目标，不冒充官方）。
- 界面 书架页：继续阅读大卡新增进度条与「继续阅读」标题；书架排序（最近阅读/最近加入/书名/作者，首页与书架→书架排序）；空书架提示「去书城逛逛吧」并一键跳转；来源分组（书架/已下载/本地书籍/公众号）作为页内分组保留。
- 阅读 快捷面板五组前置（更多/目录/进度 + 字体/亮度行）：新增「更多」入口直达控制中心（书签/想法/划线/搜索/设置）；存量用户迁移保留自定义按键排序与显隐（仅「更多」置首，超 8 项转为隐藏不丢失）。
- 阅读 夜间模式核对为 KOReader 原生 night_mode（快捷面板设备行/控制中心切换）；护眼米/纯白靠齐（cre 正文底色不可改）；长按选词=自动下划线主路径，笔记=点击划线弹层，复制/查词仅非自动划线书籍可用。
- 界面 我的页时长卡新增「阅读周报 ›」入口并标注本机统计口径（与手机端云端计数不同源）。
- 体验 底部 Tab 切换防抖（e-ink 连点不重复全量重建）与切页即时反馈；书城/我的页触控行高 ≥50dp。
- 统一 行组件全集收敛：miuread.ui_rows 提供纯几何（M.geometry，可无头断言）与双模式行布局（icon+label+副标题/右值+chevron），阅读记录/搜索/批注、阅读设置、我的页/书城行、控制中心全部同一骨架（几何覆写保证逐表面像素等价）；action_sheet/full_shelf_view 换用 Skin.frame；home_cards 的 UiScale.radius/line 全部换 Skin（结构守卫锁定：禁 Ui.frame/UiScale.radius/UiScale.line 回退、ui_rows 禁引 TapBox/tappable）。
- 统一 收尾：周界/时长格式并源（read_time_ledger.week_start 单源，HomeData 委托）；评论→想法术语统一；兜底文案（书页书签/无文字内容）入 annotation_kinds；home_view/快捷面板/本地浏览器换 Skin.frame（双轨清零）；控制中心设备分类新增「阅读界面设置」直达入口；结构守卫 +3（Ui.frame 清零、周界并源、兜底文案单点）。
- 统一 视觉基线单源化：外部页面卡片/行组件改用与阅读器同一套令牌（home_cards 统一到 Skin.frame；新增 miuread.ui_rows 共享行布局，我的页行与控制中心行同构；Skin.frame 补 margin 成为 Ui.frame 超集；结构守卫禁止 home_cards 回退 Ui.frame）。
- 统一 批注类型（书签/划线/想法）标签与图标内外单源：新增 miuread.annotation_kinds，阅读批注记录、外部「我的批注/搜索」与诊断日志共用同一套词与图标（此前 5 处重复定义，杜绝漂移）。
- 阅读 新增「默认划线样式」（阅读界面设置）：下划线（默认）/ 浅底 / 反白——微信读书划线样式的墨水屏灰阶靠齐（波浪线无替代，用反白）；新书首次划线应用所选样式（默认种子），阅读中切换即时重绘已有划线（单写者：doc_settings.saved_drawer + updateHighlightDrawer）。
- 阅读 新增「本章想法」（控制中心 → 阅读 → 本章想法）：聚合当前章已同步的划线与想法（按章内位置排序，想法/划线图标区分），点击跳转正文；空态区分「未同步/暂无想法」；纯函数 filter_records_by_chapter 按 chapter_uid 精确匹配、空 uid 按 chapter_idx 兜底。
- 阅读 章节行进度显示「剩余 N 页」（与页码同源，微读习惯）；新增「选词后显示选择菜单」设置（阅读界面设置，默认关，B12 缓解：开启后 MiuRead 书选词保留复制/查词/划线菜单；阅读中切换即时生效；首次划线给一次性引导提示）。
- 体验 书城/公众号搜索无结果文案统一为「换个关键词试试」。
- 阅读 快捷面板状态行新增「今日阅读时长」：与「我的」页时长卡共用同一账本（上传微信读书的同一秒数），阅读中即可见当日时长。
- 可观测 新增操作日志与崩溃上报骨架：`miuread.oplog` 环形记录最近 200 条后台操作（同步/下载/认证/崩溃上报），失败路径自动入日志；`miuread.crash_report` + `miuread.plugin_crash_report` 提供 opt-in 崩溃检测（启动时对比 crash.log 增量，生成含版本/设备/偏好 + crash 尾部 + 最近操作的脱敏报告，无端点时保存到 temp/crash-reports）；`miuread.diagnostic_context` 统一收集版本/设备/偏好并自动脱敏（token/cookie/secret/api_key 等）。
- 修复 登录失效显示不一致：首页显示已登录、打开书籍静默同步报「微信读书登录验证失败」——续期被服务器拒绝（HTTP 40x / 未接受续期）时归一化为 `[MiuReadAuth] error_code=-2012` 标记；repair 路径（force）与 fail() 的认证分支均回写 auth.health，`logged_in()` 立即感知服务端会话失效，首页同步显示「需要重新登录」，重新扫码后恢复。
- 体验 会话预防性保活：打开书籍与每日定时（≥24h 间隔 + 随机抖动）静默调用 /web/login/renewal 续期微信读书 Web 会话，延长会话寿命、降低会话被服务端回收后被迫重新扫码的频率；续期失败静默记录（oplog + 回写登录状态），不打断阅读。
- 阅读 新增「最近批注」快捷操作（阅读快捷面板，默认未启用可在替换按键中开启）：点击即定位当前阅读位置最近的云端划线/想法并弹出批注窗口，覆盖本人与网友批注；overlay 新增数值位置距离计算（Overlay:nearest），复用位置缓存避免重复 XPointer 查询。
- 批注 本地书同步合并个人与全量数据：个人书签/想法（bookmark_list + review_list_mine）不再独占同步流程，而是与逐章全量划线/想法（含网友）合并去重后一起显示；全量路径不可用时自动回退为「仅个人书签/想法」，中途失败也会落盘已收集的个人数据。
- 诊断 手动诊断包（工具与维护 → 生成诊断包）新增 oplog.txt（最近 200 条操作）与 context.txt（脱敏上下文）。
- 同步 sync.lua 失败路径埋点：progress_pull / read_report worker / upload / service / epub_identity 失败均写入操作日志，配合诊断包与崩溃报告可还原失败前操作序列。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）增至 232 个用例：新增 oplog 7、crash_report 8、diagnostic_context 5、auth_errors 5、keepalive 7、report_daemon 5、home_page 10（normalize_page/sort_rows）、reader_quick 6（QUICK_DEFAULT_VISIBLE/migrate_quick_actions）等纯逻辑单测；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。
- 测试 Lua 5.1 无头套件 256 个用例、结构守卫 26 项全绿：新增 recent_all 空 store 回归（database_paths 词法可见性）、overlay 分帧预热/负缓存 TTL、xpointer_overlay 多值 pcall、read_time_ledger 周界、ui_rows 几何、annotation_kinds 兜底等单测。


- 架构 sync.lua 拆分深模块第一批：抽出 `miuread.sync_catalog_prepare` 深模块（5 纯函数：prepare_catalog_input / select_catalog_worker / merge_legacy_context / detect_catalog_drift / apply_cookies_change），`miuread.sync_inverse_mapping` 深模块（3 决策函数 should_use_inverse_mapping / compute_inverse_decision + merge_inverse_into_position）；sync.lua 3258 → 3146 行（-112），`_prepare_progress_catalog`（145 行）+ `_prefer_inverse_cloud_mapping`（116 行）改为薄委托，仅保留 worker:run() 调用与 callback 装配。所有 [MiuRead][ProgressMap] / [ProgressOffset] 日志文案、错误码、回调返回值结构原样保留；callback stale 检查与 saved/verified catalog drift 决策下沉到 prepare 模块。
- 架构 plugin_home_content 抽出本地书架内联子系统：13 个 `_home_local_*` 方法（_home_local_cache / _home_local_tree_cache / _home_local_roots / _home_local_root_for_path / _home_local_inline_context / _home_local_inline_parent_entry / _home_local_inline_rows / _home_local_inline_title / _home_local_empty_text / _home_local_folder_entry / _home_local_known_paths / _home_local_rows / _home_local_inline_navigate）下沉到独立 `miuread.plugin_home_local_inline` controller（247 行），plugin_home_content 3572 → 3353 行（-219）；4 个跨域编排方法（_home_apply_local_inline_section / _home_set_local_inline_location / _home_ensure_local_inline_loaded / _home_handle_back）留在 plugin_home_content（混合 home section 状态）。LocalLibrary 改用 Lazy 保持启动期不加载；test_split_controllers_installed 守卫新增 PluginHomeLocalInline 控制器声明。
- 架构 plugin_reader 抽出 highlight policy 段：5 个 highlight 方法（_restore_miuread_highlight_action_policy / highlight_selection_policy / _selection_menu_enabled / _apply_miuread_highlight_action_policy / _apply_miuread_highlight_defaults）并入 `miuread.highlight_policy`（23 → 163 行，原纯函数 M.policy / STYLES / style_label / is_style + 新 Plugin mixin），plugin_reader 3553 → 3426 行（-127，含 sed 范围误删 _reader_panel_active 后修复）；test_external_chapter_and_highlight 的 stub plugin 加装 HighlightPolicyController.install 后 4 个旧测试全绿。
- 架构 plugin_home 抽出偏好持久化 IO：6 个偏好方法（_home_preferences / _save_ui_preferences / _mark_ui_preferences_flushed / _save_home_preferences / _save_home_preferences_deferred / _flush_home_preferences）下沉到独立 `miuread.plugin_home_preferences_io` controller（444 行），plugin_home 2085 → 1682 行（-403）；layout_version 迁移（v20→v24）、network_metadata 一次性修复、generation/save_pending 状态机、UiScale.setDisplayMode/setFontName 联动均集中在新 controller，plugin_home 专注调度/模式 UI。HOME_ACTION_LAYOUT_VERSION / HOME_PANEL_LAYOUT_VERSION 等 12 个 HomeLayouts 常量 + Device require 集中在新文件头部；test_split_controllers_installed 守卫新增 PluginHomePreferencesIO 控制器声明并从 PluginHome 期望列表移除 _home_preferences。
- 修复 真机闪退（plugin_home_preferences_io.lua:296 / :299 缺 require）：Step 4 拆分时把 plugin_home.lua 里的 `local lfs=require("libs/libkoreader-lfs")` 与 `local LocalLibrary=Lazy("miuread.local_library")` 一起忘在新文件头部 require，_home_preferences 在 add_root / 根目录扫描两处分别命中 `LocalLibrary.normalize` 与 `lfs.attributes`，打开首页时 5 秒后闪退。新文件头部补上 Lazy("miuread.local_library") + lfs require；新增 test_plugin_home_preferences_io_crash（2 用例）覆盖 _home_preferences 实际运行路径，koreader_stubs.fake_modules 补 miuread.local_library。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）增至 296 个用例、结构守卫 27 项全绿：4 步重构新增 test_sync_catalog_prepare（8）/ test_sync_inverse_mapping（8）/ test_plugin_home_local_inline（11）/ test_highlight_policy（6）/ test_plugin_home_preferences_io（5）/ test_plugin_home_preferences_io_crash（2）共 40 个纯逻辑 + 迁移 + 回归单测；test_split_controllers_installed 扩为 23 个 controller 列表（新增 PluginHomeLocalInline 与 PluginHomePreferencesIO，从 PluginHome 移除 _home_preferences）；bootstrap.lua 的 device stub 补 canSuspend / getPowerDevice（plugin_home_preferences_io 的 _home_preferences 依赖），koreader_stubs 的 fake_modules 补 device 与 miuread.local_library 表（UiScale / HomeLayouts / LocalLibrary 测试备用）。打 zip：dist/miuread-v4.6.2-dev-full.zip（SHA-256 97b973653572f31fcc3eac5be7cddd835010a3f2e26b70d93e603f5276ede00e，本版含真机闪退修复）。
## 4.5.49 - 2026-08-17

- 修复 闪退：回滚 4.5.45 对「实例化类」的惰性加载（downloader/download_task/annotations/annotation_sync/cache_cleanup_task/content_reader 等）。Lazy 代理不能作为实例 metatable，`X:new()` 生成的实例方法查找会失效导致首页 shelf 刷新时 `busy` 调用崩溃；这些类改回启动即加载，并新增结构守卫防回归。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）保持 165 个用例全绿；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。

## 4.5.48 - 2026-08-17

- 性能 后台任务/主线程 I/O 审计：确认同步/阅读时长均走子进程 + 门控 + 防抖，非翻页路径；修正源坐标快照在阅读期间周期性触发同步写盘（save_session 默认 flush），改为内存写入 + 防抖落盘，避免周期性同步 I/O 卡主线程。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）保持 165 个用例全绿；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。

## 4.5.47 - 2026-08-17

- 性能 内存/GC 审计 + 划线覆盖层跨页缓存：确认 recent_reads（≤10）/想法弹窗缓存（≤8）/封面索引/书柜缓存均有界或自动剪枝、封面位图渲染后即释放；xpointer_overlay 的逐页框缓存改为只在重排/记录变更时清空，翻页前后往返同一页不再重复计算 CREngine 屏幕框。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）增至 165 个用例：新增覆盖层跨页缓存与重排清空 2 个单测；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。

## 4.5.46 - 2026-08-17

- 性能 翻页路径审计 + 划线覆盖层位置缓存：翻页只做「标记失效 + 防抖写盘 + 节流后的延迟预取」，无同步重活；xpointer_overlay 新增 per-record 文档位置缓存，XPointer→文档位置只在记录变更/重排时算一次，翻页时不再逐条重复查询，减少翻页时的 CREngine 调用。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）增至 163 个用例：新增 xpointer_overlay 位置缓存 3 个单测；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。

## 4.5.45 - 2026-08-17

- 性能 启动加载优化：把下载/划线/内容抓取等低频模块（downloader/content_reader/annotations/annotation_sync/download_* /external_annotation_sync 等）改为用到再加载（Lazy），启动无头基准 341ms → 217ms、加载模块 174 → 157，恢复并超过重构前基线，翻页路径不受影响。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）保持 160 个用例全绿；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。

## 4.5.44 - 2026-08-17

- 修复 登录过期误显示为「已登录」：当本地凭证存在但微信授权已在服务端失效（-2011/-2012/-2041）时，`logged_in()` 现在返回未登录，界面会提示重新扫码而不是继续显示「已登录」。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）保持 160 个用例全绿；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。

## 4.5.43 - 2026-08-17

- 修复 回滚阅读器 UI 原生委托：4.5.42 把目录/字体/进度/书签等面板委托给 KOReader 通用菜单，真机反馈只能弹出菜单、不能直达对应设置项，体验突兀。本版恢复 MiuRead 自绘面板直接调用，移除 panel_mode 与委托守卫；决策记录更新见 `docs/reader-ui-decision.md`。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）保持 160 个用例全绿；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。

## 4.5.42 - 2026-08-17

- 阅读 阅读器 UI 决策落地：新增 `reader_ui.panel_mode` 开关（默认 `"native"`），目录/进度/字体/间距/书签/页面显示/页边距等 8 个与 KOReader 原生重复的面板改为委托「KOReader 高级菜单」，仅保留云划线/想法/同步等 MiuRead 专属能力；可切回 `"miuread"` 使用自绘面板。决策记录见 `docs/reader-ui-decision.md`。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）保持 160 个用例全绿；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。

## 4.5.41 - 2026-08-17

- 架构 统一命名边界：把内容抓取模块 `miuread.reader` 更名为 `miuread.content_reader`（保留 `Reader` 类名），与阅读 UI 控制器 `plugin_reader` / `reader_control_center` 等区分，消除「reader.lua 是内容抓取还是阅读 UI」的歧义；更新 main.lua / download_task.lua 三处 require。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）保持 160 个用例全绿；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。

## 4.5.40 - 2026-08-17

- 架构 拆 external_annotation_sync.lua 上帝模块第一批：抽出 `miuread.external_annotation_parse` 深模块（9 个纯函数：range 收集/目录签名/章节字段/想法归一/scalar/记录收集/review 拆分/书名关键词清洗），external_annotation_sync.lua 从 1,548 行降至 1,458 行并保留本地别名委托。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）增至 160 个用例：新增 external_annotation_parse 6 个纯逻辑单测；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。

## 4.5.39 - 2026-08-17

- 架构 拆 downloader.lua 上帝模块第一批：抽出 `miuread.chapter_title` 深模块（12 个纯函数：标题归一/全角折叠/去前导/编号判定/HTML 属性/标题扫描/legacy 归一），downloader.lua 从 1,840 行降至 1,732 行并保留本地别名委托。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）增至 154 个用例：新增 chapter_title 6 个纯逻辑单测；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。

## 4.5.38 - 2026-08-16

- 架构 拆 annotations.lua 上帝模块第一批：抽出 `miuread.annotation_text` 深模块（10 个纯函数：UTF-8 宽度/编码、HTML 实体解码、单元切分、可忽略文本、标签解析、tokenize、UTF-16 宽度、文本索引、归一化），annotations.lua 从 991 行降至 814 行并保留本地别名委托。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）增至 148 个用例：新增 annotation_text 6 个纯逻辑单测；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。

## 4.5.37 - 2026-08-16

- 架构 拆 reader.lua 上帝模块第一批：抽出 `miuread.content_classify` 深模块（16 个纯函数：章节/封面/不可读判定、可见文本、内容标记、空章与服务错误分类），reader.lua 从 1,183 行降至 1,040 行并保留本地别名委托。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）增至 142 个用例：新增 content_classify 6 个纯逻辑单测；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。

## 4.5.36 - 2026-08-16

- 工程 补齐贡献与工程化配置：新增 `.luacheckrc`（Lua 5.1 lint 基线）、`CONTRIBUTING.md`（提交约定/目录结构/架构边界）、GitHub Issue 模板（Bug 报告/功能建议/讨论入口）与 PR 模板，向社区协作友好化对齐。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）保持 136 个用例全绿；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。

## 4.5.35 - 2026-08-16

- 架构 拆 plugin_home_content 上帝模块第一批：抽出 `miuread.home_network_metadata` 深模块（metadata_key/patch_has_data/patch_field_count/missing_fields/merge_patch 5 个纯函数），plugin_home_content 从 3,527 行降至 3,475 行并改为委托。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）增至 136 个用例：新增 home_network_metadata 5 个纯逻辑单测；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。

## 4.5.34 - 2026-08-16

- 架构 拆 sync.lua 上帝模块第一批：抽出 `miuread.sync_response` 深模块（14 个纯函数：response 确认/synckey/进度节点归一/远端进度选择/位置匹配/context 组装/catalog 进度），sync.lua 从 3,390 行降至 3,151 行并保留本地别名委托。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）增至 131 个用例：新增 sync_response 6 个纯逻辑单测；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。

## 4.5.33 - 2026-08-16

- 架构 退役 legacy 网络层第三步（完成）：把阅读时长上报传输迁到 `miuread.read_report_transport`（基于 `miuread.http`，所有请求 `retries=0` 单次尝试、退避仍由 `read_report_service` 负责），阅读上下文/目录迁到 `miuread.read_report_context`，工作器迁到 `miuread.read_report_worker`，适配器迁到 `miuread.read_report_adapter`，整个 `miuread/legacy` 目录删除。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）增至 125 个用例：新增 read_report_transport 请求形态测试（单次尝试/鉴权/Bearer/Origin/Referer）；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。

## 4.5.32 - 2026-08-16

- 架构 退役 legacy 网络层第二步：把 `miuread.legacy.client` 从 839 行精简到 275 行，删除已被 `miuread.api` / `miuread.auth` 取代的 QR 登录、公众号文章、章节划线、书评批次、web 进度等死代码，只保留阅读时长上报所需的 `request/post_json/get_text/gateway/get_progress/report_read`。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）保持 121 个用例全绿，验证精简后的 legacy client 仍被主插件加载链完整引用；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。

## 4.5.31 - 2026-08-16

- 架构 把硬编码的微信读书 Web reader token 从 `protocol.lua` 抽到 `config.lua` 的 `READER_TOKEN` 常量，`protocol.lua` 改为从配置读取（保留旧值兜底），legacy 层经 `miuread.legacy.weread` 自动继承，token 轮换时只需改一处。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）增至 121 个用例：新增 reader token 单一来源断言；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。

## 4.5.30 - 2026-08-16

- 架构 退役 legacy 网络层第一步：删除 `miuread.legacy.crypto`（重复的 MD5/SHA-256），并把 `miuread.legacy.weread` 的签名/混淆/reader URL/上报载荷改为 `miuread.protocol` + `miuread.digests` 的薄委托，消除两套签名算法并存，收窄 legacy 栈到 `client/content/cookie/read_report_worker`。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）增至 120 个用例：新增 legacy/protocol 密码学等价性与黄金向量回归；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。

## 4.5.29 - 2026-08-16

- 修复 选中文本后直接划线未生效：觅阅识别到的书籍在阅读期间临时把 KOReader 默认长按动作切到「划线」并在关闭书籍时恢复原设置；划线确认改为直接保存，不再依赖 `highlight_prompt` 为空，确保跳过样式选择直接生成下划线。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）增至 115 个用例：新增临时长按动作策略与直接划线保存回归测试；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。

## 4.5.28 - 2026-08-16

- 修复 进度锚点书签叠加：普通批注快照不再把合成进度锚点标记为缺失，避免本地行在“删除/重建”之间来回抖动；进度锚点现在始终只保留一个本地行，并在位置变化后先删除旧云端书签再上传新位置。
- 修复 进度锚点云书签带 `觅阅进度锚点：` 前缀，同步时会清理同前缀的旧锚点，官方书签列表不会再因为进度锚点不断增长；旧版本已产生的无前缀重复锚点请手动删除一次。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）增至 113 个用例，新增进度锚点识别/前缀/去重纯逻辑测试；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。

## 4.5.27 - 2026-08-16

- 下载 取消「纯净版 / 划线与想法版」二选一：新下载一律只生成纯净版；旧划线与想法版（整本、章节版、试读版）保留可读并在菜单中标注「旧版」，仅当某章只有旧版文件时更新才沿用旧版。重新生成纯净版后会自动清理该路径下的外部批注投影缓存，避免旧位置错配。
- 同步 阅读中动态拉取划线与想法：打开纯净版书籍后先静默拉取当前章，完成后预取下一章；翻页推进时按当前章+下一章续拉（每 4 秒节流），无划线的章节也会记录为已拉取、避免反复请求；隐藏划线与想法时暂停拉取，重新显示时立即补拉。
- 同步 动态拉取复用既有 XPointer 覆盖层与 SQLite 断点，完全静默（无进度窗/确认框），失败由静默调度器退避重试；旧版划线与想法版不再叠加投影，避免重复显示。
- 阅读 觅阅识别到的书籍默认划线样式改为下划线，并跳过选词后的样式确认直接划线；首次应用记录 per-book 标记，之后用户手动改过的样式不再被覆盖。点击已有划线仍走 KOReader 原生二次操作（笔记/样式/删除等）。
- 修复 位置冲突默认值 `progress_conflict_mode` 此前误写入 annotation_sync 默认块，现迁回 sync 默认块。
- 测试 Lua 5.1 无头套件（含 smoke 主插件加载）增至 112 个用例：新增动态章选择/预取与高亮默认值测试；Python 结构守卫新增「新下载只生成纯净版」回归检查；plugin_home_content、plugin_navigation、store_defaults、progress_position 等既有拆分继续全绿。

## 4.5.26 - 2026-08-16

- 同步 新增 `miuread.sync_scheduler` 深模块：静默同步的防抖合并、门控（登录/在线/挂起/任务忙）、线性退避重试与状态标签（已同步/等待同步/同步中/N 项未完成）；支持 skip（不适用）与 busy（稍后重试且不计失败）两种动作结果，支持 `cancel_all` 与运行中再次请求的续排定时器；新增 10 个纯逻辑单测。
- 同步 新增 `miuread.plugin_sync_center` 控制器：把调度器接上 UIManager 定时器、`logged_in`/`is_online`/忙碌门控与既有同步入口；本地批注改动后自动上传（快照成功后延迟约 12 秒）、打开书籍后自动静默拉取云端划线（延迟约 8 秒，失败自动退避重试）。
- 同步 `external_annotation_sync` 增加静默模式：自动拉取不弹进度窗口/确认框，完成或中断通过回调汇报给调度器；阅读退出后取消未执行的云端拉取请求，避免回到主页后持续空转。
- 同步 一键同步快捷键：主页头部「同步」点击 = 后台静默同步全部，长按 = 同步诊断；主页快捷面板同步块与阅读快捷按键「静默同步」接入同一入口；新增 KOReader 动作 `MiuReadSyncAll`（觅阅：静默同步全部）；主页同步状态文字在非已同步时显示 ● 圆点。
- 同步 阅读进度冲突自动策略：默认「自动采用云端」（静默跳转并确认，不弹窗），可在同步设置/诊断中切换为「询问我」；云端来源不一致（网页 vs 官方）仍保留人工选择；决策下沉 `progress_decision.conflict_policy` 并新增单测。
- 测试 Lua 5.1 无头套件（含 smoke 主插件与控制器加载）增至 106 个用例（sync_center 7 个、scheduler 10 个、conflict_policy 等），Python 结构守卫纳入 `plugin_sync_center` 与 `Scheduler` 依赖声明；既有拆分控制器（plugin_home_content、plugin_navigation、store_defaults、progress_position 等）回归继续全绿。

## 4.5.25 - 2026-08-16

- 修复 真机 crash.log 定位：plugin_home_content 缺 `unpack_args` 局部导致打开主页崩溃；同源扫描又发现 plugin_navigation 缺 ButtonDialog/unpack_args、plugin_ui_menus 缺 HOME_SESSION/unpack_args，全部补齐；结构守卫扩展为覆盖普通局部变量引用。

- 架构 store.lua 分层第一批：抽出 `miuread/store_defaults`（持久化默认值单一来源）与 `miuread/store_downloads`（下载状态/队列 reader，8 个方法），Store 保留门面并在加载时合并；新增 5 个纯逻辑单测与结构守卫。
- 架构 store.lua 分层第二批：新增 `miuread/store_auth`（登录态/登录会话/健康度，8 方法）与 `miuread/store_sessions`（会话读写/失效/清空，6 方法 + 2 个共享失效 helper），Store 门面合并；新增 6 个纯逻辑单测；store.lua 约 2111 → 1998 行。
- 架构 store.lua 分层第三批：新增 `miuread/store_library`（书籍/变体/路径/遗忘/删除/全量列表，约 25 方法）与 `miuread/store_pending`（待安装/清理结果/阅读上报记录，约 9 方法），Store 门面合并；新增 6 个纯逻辑单测；store.lua 约 1998 → 1783 行。
- 架构 store.lua 分层第四批：新增 `miuread/store_identity`（EPUB 身份识别/文件匹配/重建目录，6 方法 + 全部识别 helper），并修复 library 组迁移后 `basename` 引用缺失的真机级隐患（新增回归单测）；store.lua 约 1783 → 1438 行。
- 架构 store.lua 分层第五批：新增 `miuread/store_meta`（最近阅读/书架缓存/封面/更新状态，约 11 方法），Store 门面合并；新增 3 个纯逻辑单测；store.lua 约 1438 → 1379 行。
- 架构 sync.lua 开始分层：进度比较判定 `compare` 下沉至 `progress_decision`（未知/相同/云领先/本地领先），sync 改为薄委托并新增单测。
- 架构 sync.lua 继续分层：新增 `miuread.progress_position` 深模块（章节字段归一、可读章节统计、按章节定位、精确映射→本地回退两段式 resolve），`Sync:position` 薄委托；新增 5 个纯逻辑单测；sync.lua 约 3491 → 3423 行。
- 架构 sync.lua 继续分层：新增 `miuread.report_daemon` 深模块（阅读时间后台服务路径/状态戳/legacy 退役清单/文件清理），`Sync:_daemon_paths` / `_retire_legacy_daemon` / `_cleanup_daemon_files` 薄委托；新增 4 个纯逻辑单测。
- 架构 新增 `miuread.download_coordinator` 深模块：接管下载状态读写/节流、active 状态合并、状态文案、payload 形状、队列去重与下一任务启动判定；`plugin_download` 改为薄委托，新增 8 个纯逻辑单元测试（可注入时钟与假 store）。
- 架构 启动加载基线 + Lazy 化：新增 `tests/lua/bench_startup.lua` 无头基准（stub KOReader 后多次加载 main 并输出每模块首次加载耗时）；按数据把 `epub`、`local_annotation_database`、`local_library`、`reader_toolbar`、`home_view`、`action_sheet`、`home_quick_panel`、`book_integrity`、`epub_installer`、`download_database` 等低频模块改为 Lazy 代理，无头基线 285ms → 254ms（约 -11%），启动模块数 154 → 147。
- 架构 新增 `miuread.progress_decision` 深模块：下沉进度同步纯决策（章节/偏移/百分比匹配、上传失败分类、本机-云端对齐判定）；`plugin_sync` 改为薄委托，新增 4 组纯逻辑单元测试。
- 架构 新增 `miuread.session_state`：统一接管 5 个 `_G.__MIUREAD_*` 会话表的创建/字段归一与访问器，main.lua 与拆分控制器不再直接 `rawget(_G, ...)`；新增 session_state 单元测试。
- 架构 继续拆分 `main.lua`：新增 `miuread.plugin_search_mp`、`miuread.plugin_repair`、`miuread.plugin_preferences`、`miuread.plugin_thought_popup`、`miuread.plugin_device`、`miuread.plugin_book`（书籍菜单/详情）、`miuread.plugin_events`（KOReader 事件入口），均沿用 `install(Plugin)` 模式；`main.lua` 从约 14430 行降至约 11700 行。
- 架构 继续拆分 `main.lua`：新增 `miuread.plugin_exit`（退出/重启/觅阅菜单），并把 main 内 6 个 HOME_* 快照局部变量全部替换为 `session_state` 活读（persist/sync_home_session 删除）；`main.lua` 约 11700 → 11589 行。
- 架构 继续拆分 `main.lua`：新增 `miuread.plugin_navigation`（阅读打开/关闭/重建/返回状态机，约 38 方法；主页渲染方法留在 main）；`normalized_reader_file` / `mark_reader_origin` 上收至 session_state；`main.lua` 约 11589 → 10553 行。
- 架构 继续拆分 `main.lua`：新增 `miuread.plugin_native_menu`（原生 KOReader 菜单守护，6 方法）；`onReaderReady` / `onSetDimensions` 并入 plugin_navigation；`main.lua` 约 10553 → 10087 行。
- 架构 继续拆分 `main.lua`：新增 `miuread.plugin_shelf`（书架加载/行构建/封面缓存/公众号书架，约 35 方法），SHELF_CACHE_TTL 常量迁入；`main.lua` 约 10087 → 9279 行。
- 架构 继续拆分 `main.lua`：新增 `miuread.plugin_home`（主页模式/后台调度/封面派生/时间显示，约 70 方法）；主页布局常量与匹配 helper 上收至 `miuread.home_layout_constants`（main/preferences/device 全部改为共享引用，删除镜像）；`main.lua` 约 9279 → 7305 行。
- 架构 继续拆分 `main.lua`：新增 `miuread.plugin_home_customize`（主页自定义菜单，约 35 方法）与 `miuread.plugin_ui_menus`（提醒设置/下载策略/菜单框架/阅读器原生页，约 45 方法）；`main.lua` 约 7305 → 6175 行。
- 架构 继续拆分 `main.lua`：新增 `miuread.plugin_home_content`（主页内容/本地书库/元数据/本地浏览器/动作弹窗，约 160 方法）；HOME_*_LABELS 上收 home_layout_constants；`main.lua` 约 6175 → 2726 行（自 14430 行累计 -81%）。
- 测试 新增 Lua 5.1 无头测试套件 `tests/lua/run.lua`：纯逻辑单测（digests/codec/util/timezone/ui_scale/lazy）与插件 smoke 加载测试（stub KOReader 后加载 main.lua、全部控制器与懒加载 UI 模块）；`scripts/bootstrap_lua51.py` 可本地编译 Lua 5.1，CI 在语法检查后直接运行该套件。
- 测试 Python 结构回归测试通过 `tests/test_lua_suite.py` 统一执行 Lua 套件（本地与 CI 均跑）。

## 4.5.24 - 2026-08-16

- 架构 继续拆分 `main.lua` 控制器：新增 `miuread.plugin_update`（更新与关于）、`miuread.plugin_sync`（进度/时间同步）、`miuread.plugin_download`（下载与存储清理）、`miuread.plugin_reader`（阅读快捷面板与阅读控制），统一沿用 `install(Plugin)` 模式；`main.lua` 从约 20697 行降至约 14430 行。
- 修复 补齐拆分控制器缺失的局部 require（下载：Http/lfs/TransientGuard/ActionSheet；阅读：HomeView/HomeQuickPanel/ActionSheet/ScreenshotMode），修复真机打开书籍时因 nil 全局调用直接崩溃闪退的问题。
- 测试 结构回归测试新增四个拆分控制器的安装与关键方法归属检查、控制器依赖声明守卫，懒加载模块检查改为跨控制器汇总。

## 4.5.23 - 2026-08-15

- 同步 息屏/休眠时自动保存当前阅读位置的进度锚点；唤醒并恢复 Wi-Fi 后自动同步到微信读书云端。
- 同步 本地批注同步与阅读进度上传均已集成“觅阅进度锚点”书签，不需要额外操作。

## 4.5.22 - 2026-08-15

- 同步 阅读进度上传并确认后，自动在微信读书云端生成/更新一条“觅阅进度锚点”书签；手机端打开书签即可跳到本机正在读的那段文字，避免排版分页差异。

## 4.5.21 - 2026-08-15

- 同步 手动上传阅读进度后，明确显示上传的章节、章节内位置与定位方式，并提示手机端微信读书排版与 KOReader 不同、同一进度可能落在相邻页。

## 4.5.20 - 2026-08-15

- 架构 明确 legacy 网络层去留：保留 `miuread.legacy` 仅用于阅读时长上报，新增 README 说明边界；除 `legacy_adapter_worker` 外禁止其他模块直接依赖，并新增回归测试防止越界。

## 4.5.19 - 2026-08-15

- 测试 新增 `tests/test_project_invariants.py` 结构回归测试（版本一致性、UI 组件唯一来源、控制器安装、弹窗骨架、懒加载模块与安装包结构），共 11 项。
- CI 新增 `.github/workflows/ci.yml`：push/PR 时执行 Lua 5.1 语法检查与 Python 结构测试。

## 4.5.18 - 2026-08-15

- 架构 新增 `miuread.plugin_maintenance` 控制器，把诊断包、缓存体检、备份恢复与阅读周报从 `main.lua` 抽出并安装到 Plugin；`main.lua` 减少约 150 行。

## 4.5.17 - 2026-08-15

- 阅读 新增“阅读周报”：在工具与维护中查看本周/今日阅读时长与阅读页数，数据来自 KOReader 本地阅读统计。

## 4.5.16 - 2026-08-15

- 同步 阅读位置冲突弹窗增加时间与来源对比：本机标为“当前阅读”，云端位置显示来源与相对更新时间，帮助用户一眼判断该用哪边。

## 4.5.15 - 2026-08-15

- 备份 新增“备份与恢复”：一键备份配置、登录态、下载断点与每本书的本地批注/想法数据库；可从最近备份恢复并自动重启。

## 4.5.14 - 2026-08-15

- 体验 下载、更新、本地批注同步的错误提示统一为“发生了什么 + 建议怎么办”，并补充限流、禁止访问与网络错误的人话识别。

## 4.5.13 - 2026-08-15

- 维护 新增“缓存体检与一键清理”：扫描已下载书籍、下载断点、受保护数据、封面缓存与临时文件大小，并支持一键清理全部可清理项。

## 4.5.12 - 2026-08-15

- 诊断 新增“生成诊断包”：一键导出插件版本、运行模式、设备信息、脱敏偏好与最近下载诊断，存放在觅阅数据目录的 temp/miuread-diagnostic-* 下。

## 4.5.11 - 2026-08-15

- 架构 拆分 `home_view.lua`：主页卡片/徽章/动作栏/分类页签等 20 个构建函数迁至新模块 `miuread.home_cards`，`home_view.lua` 从 1712 行降至 1125 行，保留主页生命周期与交互逻辑。

## 4.5.10 - 2026-08-15

- 架构 阅读列表弹窗与排版弹窗接入 `Ui.TapBox` 子类，保留“长按松手触发 + 点击防抖”的交互；至此除 `ui_components` 自身外，全部页面的 `TapBox` 已统一。

## 4.5.9 - 2026-08-15

- 架构 `TapBox` 与 `tappable` 收口到 `miuread.ui_components` 的 `Ui.TapBox` / `Ui.tappable`；主页、整架浏览、本地浏览、主页下滑工具栏、气泡菜单、阅读工具栏及 5 个阅读弹窗不再各自定义点击容器。
- 架构 `Ui.TapBox` 支持可选长按、长按延迟触发、点击防抖，兼容当前各页面的交互差异；剩余两个复杂长按页面（阅读列表、排版弹窗）留待下一轮迁移。

## 4.5.8 - 2026-08-15

- 架构 `fixed_frame` 收口到 `miuread.ui_components` 的 `Ui.frame`，主页、整架浏览、本地浏览、主页下滑工具栏与气泡菜单不再各自定义边框容器。

## 4.5.7 - 2026-08-15

- 架构 阅读设置弹窗、阅读列表弹窗、前光/色温弹窗、阅读控制中心、排版弹窗全部接入 `reader_panel_base` 公共骨架；7 个阅读弹窗生命周期现在完全一致。
- 架构 `reader_panel_base` 支持按 `panel_dimen`/`frame_dimen` 自适应取弹窗区域，兼容控制中心等全屏面板。

## 4.5.6 - 2026-08-15

- 架构 新增 `miuread/reader_panel_base.lua` 阅读弹窗公共骨架，统一关闭、点击外部关闭、下滑关闭、键盘返回与残影刷新逻辑。
- 架构 目录弹窗与阅读进度弹窗率先接入公共骨架，各自减少约 50 行重复生命周期代码；视觉与交互保持不变。

## 4.5.5 - 2026-08-15

- 界面 阅读菜单栏快捷按键标签自动适配：长标签在窄格内自动缩小字号，避免“云端划线”“本地上传”等四字标签被截断。

## 4.5.4 - 2026-08-15

- 菜单 主页菜单栏与主页下滑工具栏隐藏项目后即时提示恢复路径，与阅读快捷按键的恢复提示保持一致。

## 4.5.3 - 2026-08-15

- 菜单 首次打开阅读菜单栏时提示“长按快捷按键可排序、隐藏、替换或恢复”，提升长按管理的可发现性。
- 菜单 主页菜单栏与阅读快捷按键的设置页新增静态使用提示；隐藏阅读快捷按键后即时提示恢复路径。

## 4.5.2 - 2026-08-15

- 菜单 新增“菜单与快捷按键”聚合入口，统一管理主页菜单栏、主页下滑工具栏、阅读菜单栏与阅读界面设置，减少用户到处找入口。
- 菜单 原“主页快捷工具”更名为“主页菜单栏”，与“主页下滑工具栏”区分更清楚。

## 4.5.1 - 2026-08-15

- 性能 主页与阅读器中的重量级界面模块（设置、目录、阅读控制中心、整架浏览、截图与评论弹窗等）改为首次使用时才加载，减少插件启动阶段的模块装载与内存占用。
- 诊断 新增 `main.lua` 加载耗时日志，便于在设备日志中观察启动阶段的性能波动。
- 架构 新增 `miuread/lazy.lua` 惰性加载器；未打开过的弹窗在退出清理时不再被强制加载。
- 页面 统一页面基础组件：`OffsetContainer` 与 `face` 收口到 `miuread.ui_components`，主页、整架、本地浏览、阅读设置/目录/进度/前光/控制中心/工具栏/排版等页面不再各自重复定义。
- 菜单 阅读下滑菜单栏的快捷按键改为可配置：在“阅读界面 → 快捷按键”中可增删最多 8 个常用功能，默认保持原有 8 个入口，避免功能入口硬编码导致用户到处找。
- 菜单 阅读快捷按键支持长按管理：长按任意快捷按键可左移、右移、隐藏、替换或恢复隐藏功能，原有长按动作保留在管理弹窗中。

## 4.5.0 - 2026-08-14

- 界面 新安装默认使用插件模式并保留已有用户选择；主页与阅读下滑栏扩展为自适应快捷布局，支持条件 Bluetooth、长 Wi-Fi 名称和“退出 KO”。
- 阅读 重做正文与评论字体设置，加入实时预览、连续字号调整、当前书籍恢复、全书默认设置及完整普通/夜间刷新频率选项。
- 设备 前光、色温、夜间、方向、Bluetooth、截图与全屏刷新优先复用 KOReader 自身控制，减少不同设备和固件之间的兼容问题。
- 批注 优化搜索和批注管理，点击记录即可展开跳转、修改与删除操作，并修复异常图标文字及自定义界面字体缩放问题。

## 4.3.5 - 2026-08-14

- 同步 提升阅读进度定位与回读校验精度，完善旧书籍与异常状态的检查修复，减少章节映射变化造成的重复修复和位置偏差。
- 下载 修复熄屏、唤醒和断网后的下载停滞；连续网络失败会保存断点并等待恢复，后台无进度时主动降低耗电。
- 交互 完善横竖屏与方向锁定、Reader 重载过渡和主页手势兼容，减少旋转、重排或角落手势造成的异常跳转。
- 搜索 主页新增微信读书全库搜索、我的书籍搜索和跨书批注搜索，可查找未加入书架的书并直接进入下载。
- 批注 批注列表点击可直接跳回正文，长按支持添加或修改想法、删除想法、划线、书签或整条批注，并继续使用现有同步状态。
- 阅读 修复部分 TXT 网文章节缺少“第X章”以及部分书籍脚注在转换后重复显示的问题。

## 4.3.2 - 2026-08-11

- 性能 主页、下载、封面和元数据改为局部更新，减少闪屏、重建与操作卡顿。
- 稳定 修复 Kindle 休眠唤醒和 Reader 返回主页异常，休眠时冻结非必要后台任务。
- 交互 最近阅读按真实 Reader 会话更新，重整主页更新逻辑并保留用户设置。
- 性能 账号、书籍详情和章节目录改为后台读取；轻量模式按实际延迟降低后台任务频率。

## 4.3.1 - 2026-08-11

- 交互 新增可调节的阅读页边防误触区域，默认左右各 10%，减少翻页时误触划线与评论，并统一阅读快捷栏图标尺寸与位置。
- 同步 阅读进度上传增加 XPointer 与章节正文锚点精确定位，降低字体、排版和分页变化造成的位置偏差，定位失败时自动退回原有算法。
- 修复 手动更新最近阅读书籍信息不再被主页前台保护拦截；后台任务占用时短暂排队，并补充元数据补全诊断。
- 网络 下载异常缓慢时增加自动线路与 IPv4 对照验证，仅在两组测试均确认 IPv4 至少快 50% 且快 1 秒后提示切换。
- 兼容 下载网络默认保持自动；IPv4 模式仅影响 MiuRead 书籍下载，不关闭设备 IPv6，不影响 KOReader 其他联网功能，切换时保留当前下载进度与断点。

## 4.3.0-beta.32 - 2026-08-11

- 网络 下载默认继续自动选择 IPv4/IPv6；连续 4 个有效请求中至少 3 个首次响应超过 3 秒时才进入慢速验证。
- 网络 慢速验证对同一服务器执行两组自动线路与 IPv4 对照，两组均达到至少快 50% 且快 1 秒才提示切换，减少服务器慢响应造成的误判。
- 交互 下载设置新增“自动/仅 IPv4”；确认切换后当前任务从下一次请求开始使用 IPv4，已下载章节与断点不重置。
- 兼容 IPv4 限制仅作用于觅阅下载子进程，不关闭设备 IPv6，也不影响 KOReader 其他联网功能；用户拒绝后本次任务不再重复提示。

## 4.3.0-beta.31 - 2026-08-10

- 修复 用户主动更新最近阅读书籍信息时不再被主页交互保护窗口拦截，网络补全任务可正常启动。
- 稳定 手动网络元数据任务遇到后台 worker 占用时短暂排队，自动补全仍继续避让主页前台操作。
- 诊断 增加网络元数据补全结果、来源与缺失字段日志，并区分部分资料未找到与网络任务失败。

## 4.3.0-beta.30 - 2026-08-10

- 同步 阅读进度在上传前优先用当前 XPointer 与章节正文锚点精确换算，减少排版变化造成的位置偏差。
- 性能 精确定位只在自动上传前或手动同步时执行，翻页路径不新增正文解析，上传间隔仍保持 60 秒。
- 兼容 无法精确定位时自动退回原有进度算法，关闭书籍与休眠流程继续保持轻量。
- 修复 单章下载按章节内位置提交阅读进度，避免整书百分比被误作章节比例。

## 4.3.0-beta.29 - 2026-08-10

- 交互 新增“防误触”阅读快捷入口，边缘翻页保护默认开启，左右各 10%，可选择 5%、10%、15% 或 20%。
- 交互 点击页边划线时优先执行翻页，正文中间区域的划线评论操作保持不变。
- 界面 阅读快捷第一行改为五项等宽布局，并统一搜索、回到阅读、批注、评论与防误触图标的视觉尺寸和垂直位置。

## 4.3.0 - 2026-08-10

- 界面 重做主页、阅读控制中心与设置页，统一图标、字号、间距和快捷入口，提升电子墨水屏可读性。
- 同步 新增本地书签、划线与想法手动同步到微信读书云端，并加入章节、版本与 range 双向校验。
- 性能 减少阅读过程磁盘写入和后台任务抢占，优化主页返回、下滑工具栏、评论与封面处理的响应。
- 稳定 修复后台下载残留方框、下载窗口无法重开、自动旋转、长时间待机恢复及 Reader 异常退出重进。
- 书库 重做本地书扫描与浏览，过滤隐藏文件，改进封面补全、下载修复与书籍完整性检查。
- 模式 完善觅阅桌面与 KOReader 插件模式分离，更新和普通重启不再误触发模式选择。
- 更新 正式版迁移到固定 stable-channel OTA，并保留 4.1.2 到 4.3.0 的旧 update.json 桥接。
- 发布 采用 tag 驱动的正式发布流程，自动校验版本、Lua 语法、安装包内容、SHA-256 和公开下载地址。

## 4.3.0-beta.28 - 2026-08-10

- 界面 放大设置列表右侧状态与当前值字体，减少与左侧标题之间过大的字号落差。
- 界面 扩大右侧状态区域，长状态文字在字号增大后仍保留足够显示空间。
- 界面 同步调整阅读设置与阅读控制中心的右侧状态字级，统一设置页信息层级。
- 界面 放大设置列表分页页码，改善电子墨水屏上的辨识度。

## 4.3.0-beta.27 - 2026-08-10

- 修复 Reader 内部重建被误判为用户退出，避免无操作时返回主页并保留同书阅读会话。
- 修复 自动旋转与尺寸变化重复触发，稳定尺寸后只执行一次 Reader 与主页重建。
- 修复 长时间待机恢复时直接重排旧窗口层的问题，改为按当前尺寸分阶段恢复。
- 稳定 加强生命周期任务失效、超时回退与连续重建保护，Suspend 期间不新增计时任务。

## 4.3.0-beta.26 - 2026-08-10

- 修复 后台下载窗口关闭后清除失效引用 再次点击后台下载可重新打开实时进度
- 修复 下载进度窗口仅在实际显示时刷新 防止隐藏窗口持续刷新留下白色方框
- 修复 下载窗口被页面切换休眠或其他弹窗关闭时自动转为后台任务 保持任务与界面状态一致
- 界面 下载进度窗口关闭后重绘原区域 并清理遗留下载窗口 避免电子墨水残影

## 4.3.0-beta.25 - 2026-08-10

- 界面 主页中间快捷栏觅阅设置点击改为标准气泡菜单 长按继续保留扩展功能与快捷项管理
- 界面 书籍长按气泡移除底部横向分隔线 保留更多书籍操作并以留白和文字层级区分
- 界面 同类气泡底部操作统一去除多余分隔线并收紧上下间距 减少弹窗底部空白和割裂感
- 界面 更多书籍操作与返回书籍操作去除装饰性箭头 右上角更多和下滑控制中心保持原有独立逻辑

## 4.3.0-beta.24 - 2026-08-10

- 性能 评论弹窗减少异常保护写入并按具体评论内容复用缓存 同时记录查找解析显示分阶段耗时
- 性能 本地划线想法快照一次准备目录并复用章节映射 大量批注不再重复构建目录并记录耗时
- 性能 普通评论同步与更新设置合并空闲保存 关键账号下载会话数据仍保持即时可靠写入
- 性能 更新清单检查与安装包下载改为子进程后台执行 网络失败不再阻塞主页或阅读界面

## 4.3.0-beta.23 - 2026-08-10

- 性能 返回主页后增加前台保护期 浮层打开及关闭后的操作期间暂停封面元数据与下载恢复
- 性能 修复阅读返回后主页交互优先回调未恢复的问题 点击与滑动可立即让后台任务让路
- 性能 已生成封面先用文件状态快速确认 未变化时直接复用 不再重复读取书籍并解码比较封面
- 诊断 增加返回主页总耗时 FileManager 建立耗时与封面后台任务耗时记录 便于继续定位波动

## 4.3.0-beta.22 - 2026-08-10

- 性能 返回首页先释放页面 再延后安装与下载队列 无任务直接跳过
- 性能 待安装检查仅在确有任务时重载设置 并记录各阶段耗时
- 界面 阅读设置页不再默认显示右箭头 阅读同步三项开关行为与状态样式统一
- 更新 修复 UTF-8 项目符号替换与全角空格匹配 避免更新说明或中文文件键被破坏

## 4.3.0-beta.21 - 2026-08-10

- 交互 修复主页六快捷为刷新搜索下载同步休眠觅阅设置 彻底移除主页前光候选
- 菜单 右上更多觅阅设置自定义工具维护恢复普通页面 气泡仅用于快捷扩展与书籍操作
- 书架 点击直读或状态处理 长按统一管理气泡 奇数操作铺满并优化底部操作栏留白
- 前光 下滑六快捷下保留开关夜间亮度色温直调 改为事件级下拉隔离防误触

## 4.3.0-beta.20 - 2026-08-10

- 交互 主页六快捷点击主操作 长按扩展并保留左移右移更换隐藏
- 书架 已下载和本地书点击直读 未下载或异常书点击处理 长按统一管理
- 前光 下滑六快捷下新增前光开关 夜间模式 亮度色温直调和防误触
- 界面 设置维护确认统一规整气泡 休眠长按加入KOReader和设备电源操作

## 4.3.0-beta.19 - 2026-08-10

- 交互 恢复主页快捷栏点击气泡 长按独立管理气泡 书籍长按保留就地操作
- 界面 气泡统一为规整圆角与一体式尾巴 不使用手绘装饰
- 书架 长按书籍优先显示常用操作 其余功能收进更多操作
- 稳定 气泡关闭后销毁不复用 长按释放不再误触点击

## 4.3.0-beta.18 - 2026-08-10

- 稳定 修复设置 快捷面板和阅读工具栏重复打开后可能退出的问题
- 性能 阅读时间与状态写入从30秒调整为60秒 减少重复封面处理和后台预热
- 界面 重排主页Wi-Fi 同步 时间 电池区域 统一阅读快捷栏图标大小与基线
- 风格 重做觅阅设置为统一列表 移除手绘边框 角标与气泡尾巴

## 4.3.0-beta.17 - 2026-08-10

- 性能 缓存主页和阅读快捷面板 延后同步扫描与封面任务 降低首次下滑和翻页卡顿
- 交互 恢复更多为完整觅阅菜单 下载点击看状态长按进入管理 快捷设置去重
- 界面 统一阅读工具栏图标尺寸与基线 主页补充标准无线网络和电池图标
- 后台 用户操作时暂停书库封面下载等非必要任务 空闲后自动恢复

## 4.3.0-beta.16 - 2026-08-09

- 主页 重整刷新下载同步与觅阅设置 删除重复入口并统一阅读页导航
- 书库 重做本地书库浏览与自动更新 过滤隐藏文件 自动补全可见书籍封面
- 同步 汇总进度时间划线想法状态 支持跨书本地批注手动同步
- 界面 放大觅阅设置字体 支持界面字体选择 统一封面角标并修复地区时区显示

## 4.3.0-beta.15 - 2026-08-09

- 修复 addBookmark 最终请求使用 Base64 UTF8 markText
- 协议 同步层保留明文仅在 API 写入前编码
- 章节 优先使用微信读书 chapterIdx 避免本地索引
- 安全 保留真实 bookVersion 坐标校验和失败待同步

## 4.3.0-beta.14 - 2026-08-09

- 修复 划线上传改用微信读书真实书籍版本
- 版本 从阅读页状态 书架缓存 书籍信息多路解析
- 安全 无真实 bookVersion 时保留本地批注并停止错误请求
- 持久化 下载和书架记录保存真实书籍版本供后续同步

## 4.3.0-beta.13 - 2026-08-09

- 修复划线上传参数兼容并采用网页默认划线样式
- 批注同步改为独立手动入口并正确统计上传删除
- 统一阅读下滑工具栏批注图标视觉尺寸
- 自动批注上传暂不启用等待真机验证

## 4.3.0-beta.12 - 2026-08-09

- 划线 使用原文 markText 修复微信读书 addBookmark 参数
- 删除 接入批注云端删除并保留失败待办
- 安全 删除请求不盲重试 网络未知保留状态
- 同步 旧待同步划线与待删除记录可继续重试

## 4.3.0-beta.11 - 2026-08-09

- 坐标 完整解密 XHTML 作为书签 划线 想法统一 range 基准
- 修复 段尾选区不再吞入换行与缩进空白
- 安全 增加双向校验与微信读书官方 range 锚点校验
- 同步 恢复手动上传 旧坐标已同步记录不自动重传

## 4.3.0-beta.9 - 2026-08-09

- 界面 阅读页新增统一批注入口 书签划线想法不再分散显示
- 同步 阅读页可直接开启并手动同步当前书全部本地批注
- 设置 主页仅保留全局开关 手动说明和想法可见范围
- 整理 阅读控制中心合并批注入口并区分阅读进度同步

## 4.3.0-beta.8 - 2026-08-09

- 界面 修复桌面模式评论与标注未接入批注云同步入口
- 同步 账号与同步新增本地批注同步快捷入口并明确为手动上传
- 诊断 增加批注同步初始化 开关和手动触发日志
- 兼容 插件模式与桌面模式统一使用同一套批注设置菜单

## 4.3.0-beta.7 - 2026-08-09

- 批注 修复本地划线与想法分类并补全上下文定位
- 坐标 上传统一走 PosMap Bridge 并验证章节与 range
- 同步 增加相邻章节校验和分阶段失败原因
- 安全 定位不唯一或校验失败时继续只保留本地

## 4.3.0-beta.6 - 2026-08-09

- 本地批注 支持书签 划线 想法手动云同步
- 坐标 统一 Range Runes PosMap 定位和校验
- 同步 支持去重 bookmarkId 保存及书签划线云端删除
- 安全 失败不误传 网络结果未知不重复提交

## 4.3.0-beta.4 - 2026-08-09

- 阅读 恢复稳定工具栏生命周期 仅缓存轻量状态并增加性能日志
- 模式 更新和普通重启不再弹出模式提醒 仅首次安装或主动切换后提示
- 封面 保留高清锁屏与主页缩略图并让后台处理避让阅读操作

## 4.3.0-beta.3 - 2026-08-09

- 阅读 复用工具栏并优先处理前台手势 降低首次下滑与偶发卡顿
- 封面 增强锁屏清晰度 后台生成主页专用高清缩略图
- 性能 阅读时间上报避让前台操作 保持原有同步规则

## 4.3.0-beta.2 - 2026-08-09

- 修复: 主页与阅读界面弹窗分页残留和重叠
- 锁屏: 优先高清封面 按屏幕比例裁切并铺满

## 4.2.0-beta.17 - 2026-08-09

- 同步: 区分未确认与真实故障 普通网络和服务器波动不再反复要求修复
- 性能: 主页和阅读下滑面板改用缓存状态 减少网络磁盘读取和重复刷新
- 主页: 恢复用户名账户入口 统一同一本书的主页阅读进度

## 4.2.0-beta.16 - 2026-08-09

- 主页: 重排顶部状态栏 分离电量并以当前Wi-Fi名称显示网络状态
- 下滑: 六列布局保持不变 统一图标标题副标题高度 修正图标水平对齐
- 界面: 移除主页顶部账户占位 更多改为明确文字入口

## 4.2.0-beta.15 - 2026-08-09

- 优化: 下滑工具栏恢复六列并放大图标文字 Wi-Fi显示当前网络名
- 界面: 主页相关入口统一觅阅样式 阅读页顶部和快捷操作放大并优化间距
- 调整: 加入休眠 系统操作收进工具与维护 保留自定义布局

## 4.2.0-beta.14 - 2026-08-09

- 优化: 下滑工具栏改为三列双行 放大图标与文字 Wi-Fi直接显示当前网络名
- 调整: 默认加入休眠 退出与重启关机收进工具与维护 并保留自定义布局
- 阅读: 放大阅读页顶部与快捷操作字体图标 优化首页 Wi-Fi 同步 电量与更多的间距

## 4.2.0-beta.13 - 2026-08-09

- 重做: 阅读下拉工具栏改为秩序横条式 书名 章节与状态分层显示
- 直达: 搜索 书签 划线 想法 评论 字体 行距 页面均可一级操作
- 显示: 前光与色温独立调节 新增夜间模式 旋转 截图 全屏刷新

## 4.2.0-beta.12 - 2026-08-09

- 重做: 阅读下拉菜单改为三组轻量入口, 书签划线想法分开
- 修复: 关闭评论后内部链接不再报错, 书内搜索可正常使用
- 统一: 阅读同步和诊断改用觅阅界面, 字体设置精简并新增独立行距

## 4.2.0-beta.11 - 2026-08-09

- 新增: 阅读快捷面板加入完整功能入口, 书签, 返回, 页面和设备快捷操作
- 优化: 顶部面板改为固定布局, 调整间距与图标比例, 取消动态展开和重叠结构
- 优化: 完整阅读菜单分为阅读, 排版, 书籍和设备, 常用排版不再进入 KOReader 总菜单

## 4.2.0-beta.10 - 2026-08-09

- 新增: 顶部阅读控制中心, 前光和色温直接调节, 评论状态可快速切换
- 优化: 取消底部菜单和更多分类, 改为五个阅读入口与原地工具展开
- 修复: 目录打开后自动跟随当前阅读章节, Wi-Fi和返回逻辑同步整理

## 4.2.0-beta.9 - 2026-08-09

- 新增: 阅读评论开关, 前光和色温可在阅读菜单直接调节
- 优化: 阅读主菜单固定为主页, 目录, 进度, 字体, 评论和更多
- 优化: 增加 Wi-Fi 等设备快捷操作, 精简更多菜单和重复入口

## 4.2.0-beta.8 - 2026-08-08

- 新增: 检测界面冲突, 并根据当前环境提示切换运行模式
- 优化: 插件模式彻底隔离桌面主页和阅读界面, 不再加载桌面专属设置
- 优化: 移除临时桌面入口, 仅在界面环境变化后再次提醒

## 4.2.0-beta.6 - 2026-08-08

- 修复: 阅读时后台下载暂停现在会真正作用到下载进程
- 优化: 评论窗口首屏优先 后续分页按需生成
- 新增: 轻量模式和卡顿检测 低内存模式更名为低内存保护

## 4.2.0-beta.5 - 2026-08-08

- 修复: 阅读进度按完整目录和当前章节换算 切书后旧同步状态不会写回
- 修复: 同步修复增加云端回读确认 未确认的上下文不会保存
- 优化: 已生成但批注未完整的书可直接修复 仅补缺失内容并保留正文

## 4.2.0-beta.4 - 2026-08-08

- 修复: 修复同步先验证登录并保留原有章节状态 不再提前清空同步上下文
- 修复: 新章节上下文仅在微信读书确认同步成功后替换旧状态
- 优化: 增加章节映射诊断并隐藏普通界面的内部错误路径

## 4.2.0-beta.3 - 2026-08-08

- 修复: 单本书同步异常时直接提供修复同步 不再后台反复重试
- 修复: 特殊章节可按可信章节 ID 建立同步 不再因字数为零直接丢弃
- 优化: 阅读时间失败不补传 同步异常仅暂停当前书 其他书籍不受影响

## 4.2.0-beta.2 - 2026-08-07

- 修复: 最近阅读刷新同步强制更新当前书籍封面
- 优化: 新封面立即替换主页书架和锁屏缓存
- 优化: 已下载书籍无需重新生成文件即可刷新封面

## 4.2.0-beta.1 - 2026-08-07

- 新增: 时间与时区设置 支持常用地区时区和固定 UTC 偏移
- 优化: 下载进度改为书籍卡片细进度条 已下载和阅读进度取消白框
- 优化: 提升主页和锁屏封面清晰度 锁屏封面按设备缓存

## 4.1.2-beta.10 - 2026-08-07

- 优化: 下滑工具栏改为六列双排 最多十二项 工具维护独立收纳
- 新增: 主页快捷自定义和当前书籍元数据手动刷新
- 优化: 元数据默认开启 仅最近阅读变化时自动补全
- 修复: Wi-Fi开启时长按换网列表立即关闭

## 4.1.2-beta.9 - 2026-08-07

- 清理: 删除已失效和未调用的旧版兼容代码
- 优化: 精简已关闭的访问验证和锁定逻辑
- 优化: 移除无效的后台评论索引维护代码
- 保持: 旧书恢复 评论读取 下载与阅读功能不变

## 4.1.2-beta.8 - 2026-08-06

- 修复: 已连接时Wi-Fi网络列表打开后立即消失
- 修复: 切换网络期间主页刷新覆盖网络选择窗口
- 优化: 网络列表关闭后再刷新主页Wi-Fi状态
- 保持: Wi-Fi短按开关 长按进入网络列表

## 4.1.2-beta.7 - 2026-08-06

- 修复: 评论字号改为18 22 26 30四档最终值
- 修复: 评论特大字号仍小于常用正文字号的问题
- 新增: 主页觅阅设置弹窗增加更新设置入口
- 修复: 主页Wi-Fi长按无法进入网络列表的问题

## 4.1.2-beta.6 - 2026-08-06

- 修复: 评论与正文统一使用同一字体来源
- 修复: 评论字号取消重复换算并统一四档大小
- 调整: 字体排版移除重复评论入口 快捷面板统一为评论显示
- 新增: 主页 Wi-Fi 长按进入网络列表切换连接

## 4.1.2-beta.5 - 2026-08-06

- 新增: 多页评论加入左右翻页提示
- 新增: 评论增加中文 符号和 Emoji 字体回退
- 优化: 连续翻阅六页后清理评论弹窗残影
- 修复: 部分用户名 评论和箭头中的特殊符号显示异常

## 4.1.2-beta.4 - 2026-08-06

- 新增: 正文与评论之间加入保留左右留白的实线分隔
- 新增: 不同评论之间加入保留左右留白的虚线分隔
- 调整: 用户名 点赞数和续页标记改为灰色
- 优化: 分隔线高度纳入分页计算 避免评论截断和额外留白

## 4.1.2-beta.3 - 2026-08-05

- 新增: 想法弹窗支持上下滑动翻页 保留点击和实体键
- 调整: 评论字号整体减小一级 现在的小改为标准
- 优化: 保留评论换行 清理尾部异常空白并显示页码
- 优化: 复用弹窗和分页结果 翻页只刷新评论区域

## 4.1.2-beta.2 - 2026-08-05

- 新增: 想法 评论和下载断点统一改用 SQLite
- 迁移: 打开旧书时可立即迁移 稍后处理或不再提示
- 进度: 大量数据迁移时显示进度 支持停止后继续
- 优化: 取消外部评论索引 现有书籍无需重新下载

## 4.1.2-beta.1 - 2026-08-05

- 降低划线和想法下载触发频率限制的概率
- 优先使用 Web 接口并将想法请求改为自适应批次
- 受限时保留断点并继续生成正文且支持稍后补全
- 建立独立内测更新通道

## Earlier history

更早的个人测试通道历史仍保留在 Git 历史和旧 tag 中，不在此处重新整理。
