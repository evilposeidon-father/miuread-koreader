# Upstream Contribution Notes — MiuRead 4.5.x feature branch

本文档用于向上游 `miumiupy98-art/miuread-koreader` 提交 PR 时说明 `feature/local-book-annotations` 分支的全部改动。

## 1. 基线

- 对比基线：`b7d95ca`（当前 `main`，对应 MiuRead 4.5.0）
- 分支：`feature/local-book-annotations`
- 提交数：43
- 改动文件：112 个
- 净增量：约 +28,859 / -20,296 行
- 最新版本：`4.5.28`（含 `v4.5.25` / `v4.5.26` / `v4.5.27` / `v4.5.28` 四个发布 tag）

## 2. 全部提交列表

```text
45ee9dd feat: sync local-book WeRead underlines and thoughts with overlay
76a7b51 feat: auto-bind MiuRead books for external annotations
d00e2ea release: MiuRead 4.5.24 — main.lua 控制器拆分与结构回归
e610cf1 fix: restore missing requires in split controllers (device crash on book open)
babb09b test: add headless Lua 5.1 suite with smoke load of main and controllers
6aebf72 refactor: split search and MP domain into plugin_search_mp controller
5d45d31 refactor: split repair and preferences domains from main.lua
14071cf refactor: session_state module owns _G session tables; split thought popup controller
b187934 refactor: split device/home quick controls into plugin_device controller
128db95 refactor: split book menu and event entry points from main.lua
6b5e4d2 refactor: extract download_coordinator deep module for state and queue
7e1fa4f refactor: extract progress_decision deep module for sync rules
3d5f404 perf: lazy-load low-frequency modules with startup benchmark
5a7521e refactor: layer store defaults and downloads reader behind Store facade
c1c0e7e refactor: layer store auth and sessions readers behind Store facade
a74e016 refactor: layer store library and pending readers behind Store facade
c3eb771 refactor: layer store identity reader; fix basename regression
a652ae7 refactor: layer store_meta reader; sink progress compare into decision module
926e4b9 refactor: extract progress_position deep module for sync position math
041083a refactor: split exit controller and replace home snapshots with Session reads
61744f9 refactor: split reader navigation lifecycle into plugin_navigation controller
5dadc5b refactor: split native menu guard; fold reader-ready into navigation controller
e1f9013 refactor: split shelf domain into plugin_shelf controller
508186f refactor: split home mode domain; single-source layout constants
9d0f917 refactor: split home customization and ui menu framework
a075bd1 refactor: split home content domain into plugin_home_content
e596f19 refactor: extract report_daemon deep module for readtime service layout
f7f180e fix: restore unpack_args/ButtonDialog/HOME_SESSION locals missing after splits
5e95b5f release: MiuRead 4.5.25 — controller split milestone with device fixes
02b721e feat: add silent sync_scheduler deep module with debounce, gate, and backoff
274e56e feat: wire silent annotation sync (auto upload + quiet pull) through sync center
ef4f821 feat: add silent sync shortcut, status dot, and auto-cloud progress conflict policy
bbd0b74 fix: keep follow-up sync timer alive when a request arrives mid-run
7ab7b9b release: MiuRead 4.5.26 — silent sync scheduler, shortcut, and auto-cloud conflicts
d413584 feat: single clean edition with dynamic per-chapter annotations and underline-by-default
6577dcc release: MiuRead 4.5.27 — single edition, dynamic per-chapter annotations, underline default
d85a11c docs: refresh README for 4.5.27 single-edition and dynamic annotations
d1b1148 fix: restore AGPL license marker in main.lua for stable release workflow
b0c5e60 docs: move legacy README out of plugin dir for stable package workflow
bbae66a test: point legacy README guard at docs after release-package relocation
a3b29ec docs: add SVG UI operation diagrams for README
dfd9cfe fix: keep a single moving progress-anchor bookmark instead of accumulating duplicates
d1b395b release: MiuRead 4.5.28 — single progress-anchor bookmark fix
```

## 3. 功能改动总览

### 3.1 本地书微信读书划线与想法（feature 最早目标）

- 新增 `miuread/external_annotations_db.lua`：SQLite 保存本地书绑定、划线与想法断点
- 新增 `miuread/external_annotations.lua`：划线定位/引用匹配纯逻辑
- 新增 `miuread/external_annotation_sync.lua`：任意重排 EPUB/TXT 匹配微信读书书籍后同步个人划线/想法，XPointer 覆盖层绘制，支持断点续传、取消、手动/静默两种模式
- 新增 `miuread/xpointer_overlay.lua`：可测试的 XPointer 覆盖层渲染/命中测试
- 自动绑定：觅阅下载的书籍直接用已知 `book_id` 绑定，无需手动搜索书名

### 3.2 main.lua 控制器拆分（4.5.24 → 4.5.25）

- `main.lua` 从约 20,697 行降至 2,726 行（-87%）
- 新增控制器：`plugin_maintenance` / `plugin_update` / `plugin_sync` / `plugin_download` / `plugin_reader` / `plugin_search_mp` / `plugin_repair` / `plugin_preferences` / `plugin_thought_popup` / `plugin_device` / `plugin_book` / `plugin_events` / `plugin_exit` / `plugin_navigation` / `plugin_native_menu` / `plugin_shelf` / `plugin_home` / `plugin_home_customize` / `plugin_ui_menus` / `plugin_home_content`
- 统一 `local Plugin = {}` + `M.install(target)` 模式
- 真机级修复：补齐拆分控制器缺失的 `require`（`unpack_args` / `ButtonDialog` / `HOME_SESSION` / `Http` / `lfs` / `ActionSheet` 等），并新增结构守卫测试防止回归

### 3.3 Store / Sync 深模块分层

- `store_defaults`：持久化默认值单一来源
- `store_downloads`：下载状态/队列 reader
- `store_auth`：登录态/登录会话/健康度
- `store_sessions`：会话读写/失效/清空
- `store_library`：书籍/变体/路径
- `store_pending`：待安装/清理结果/阅读上报
- `store_identity`：EPUB 身份识别/文件匹配
- `store_meta`：最近阅读/书架缓存/封面
- `sync` 继续分层：`progress_decision` / `progress_position` / `report_daemon`
- `session_state`：统一接管 `_G.__MIUREAD_*` 会话表
- `download_coordinator`：下载状态机/队列去重/节流
- `lazy`：启动加载 Lazy 代理，无头基准约 -11%

### 3.4 静默同步体系（4.5.26）

- 新增 `sync_scheduler`：防抖/门控/退避/状态标签，支持 `skip` 与 `busy` 语义，运行中再次请求不丢定时器
- 新增 `plugin_sync_center`：把调度器接上 UIManager 定时器与登录/网络/忙碌门控
- 本地批注修改后自动静默上传
- 打开书籍后自动静默拉取云端划线（后来在 4.5.27 改为按章动态拉取）
- 主页/快捷面板/阅读面板一键同步快捷键 + 长按诊断 + 状态圆点
- KOReader 动作 `MiuReadSyncAll`
- 进度冲突自动策略：默认自动采用云端，可切换为询问

### 3.5 单一纯净版 + 动态逐章批注（4.5.27）

- 下载不再提供「纯净版 / 划线与想法版」二选一，新下载一律纯净版
- 旧划线与想法版保留可读，菜单标注「旧版」
- 阅读时按「当前章 + 下一章」动态静默拉取划线与想法，随翻页推进（4 秒节流）
- 无划线章节标记为已拉取，避免反复请求
- 隐藏划线与想法时暂停拉取，重新显示时立即补拉
- 重新生成纯净版后自动清理旧 XPointer 投影缓存
- 划线默认样式改为下划线，且跳过样式确认直接划线（仅觅阅识别书籍）
- 点击已有划线仍走 KOReader 原生二次操作（笔记/样式/删除等）

### 3.6 进度锚点书签修复（4.5.28）

- 进度锚点始终保留在每次快照中，普通批注快照不再误将其标记为缺失
- 锚点位置变化后先删除旧云端书签再上传新位置
- 锚点云书签带 `觅阅进度锚点：` 前缀，同步时自动清理同前缀旧锚点
- 修复书签无限叠加问题

### 3.7 文档与发布

- README 更新至 4.5.28，包含完整新特性说明
- 新增 5 张 SVG UI 操作示意图：首页/阅读页/划线交互/下载与动态批注/静默同步状态机
- `docs/diagrams/generate_ui_diagrams.py` 可重复生成 SVG
- 发布工作流兼容性修复：`main.lua` AGPL 标记恢复、legacy README 移出插件目录

## 4. 测试基础设施

- 新增 Lua 5.1 无头测试套件 `tests/lua/run.lua`（bootstrap + KOReader stubs + 26 个 suite）
- `scripts/bootstrap_lua51.py`：本地编译 Lua 5.1
- Python 结构回归测试 `tests/test_project_invariants.py`：
  - 控制器安装/方法归属
  - 依赖声明守卫
  - 版本/CHANGELOG 一致性
  - 下载单一纯净版守卫
  - legacy README 位置守卫
- CI：`tests/test_lua_suite.py` 统一跑 Lua 套件

当前验证结果：

- Lua 5.1：113/113 通过
- Python：21/21 通过

## 5. 关键文件清单

### 新增（核心）

```text
miuread.koplugin/miuread/external_annotation_sync.lua
miuread.koplugin/miuread/external_annotations.lua
miuread.koplugin/miuread/external_annotations_db.lua
miuread.koplugin/miuread/xpointer_overlay.lua
miuread.koplugin/miuread/sync_scheduler.lua
miuread.koplugin/miuread/plugin_sync_center.lua
miuread.koplugin/miuread/download_coordinator.lua
miuread.koplugin/miuread/progress_decision.lua
miuread.koplugin/miuread/progress_position.lua
miuread.koplugin/miuread/report_daemon.lua
miuread.koplugin/miuread/session_state.lua
miuread.koplugin/miuread/store_defaults.lua
miuread.koplugin/miuread/store_downloads.lua
miuread.koplugin/miuread/store_auth.lua
miuread.koplugin/miuread/store_sessions.lua
miuread.koplugin/miuread/store_library.lua
miuread.koplugin/miuread/store_pending.lua
miuread.koplugin/miuread/store_identity.lua
miuread.koplugin/miuread/store_meta.lua
miuread.koplugin/miuread/plugin_*.lua（20 个控制器）
tests/lua/**、tests/test_project_invariants.py
docs/diagrams/*.svg
```

### 修改（重点）

```text
miuread.koplugin/main.lua（20,697 → 2,726 行）
miuread.koplugin/miuread/store.lua
miuread.koplugin/miuread/sync.lua
miuread.koplugin/miuread/annotation_sync.lua
miuread.koplugin/miuread/local_annotation_database.lua
miuread.koplugin/miuread/plugin_reader.lua
miuread.koplugin/miuread/plugin_download.lua
miuread.koplugin/miuread/plugin_navigation.lua
CHANGELOG.md / README.md
```

## 6. 兼容性说明

- 旧「划线与想法版」EPUB 仍可打开，不会破坏既有文件
- 旧版无前缀进度锚点书签需要用户手动删除一次；新锚点带前缀并可自动清理
- 进度冲突默认策略从“询问”改为“自动采用云端”，如需保留旧行为可在同步设置中切回“询问我”
- 设备 OTA manifest 当前指向 `miumiupy98-art/miuread-koreader` 的 `stable-channel`；若 fork 自行发版，需要同步改 `Config.UPDATE_MANIFEST` 与 release workflow 校验地址

## 7. 建议的 PR 拆分

如果上游希望更小的 PR，可按以下顺序拆分：

1. **测试基础设施 + 结构守卫**（`babb09b`、`e610cf1` 等）
2. **store/sync 深模块分层**（`5a7521e` → `926e4b9`）
3. **main.lua 控制器拆分**（`041083a` → `5e95b5f`）
4. **本地书划线与想法 overlay**（`45ee9dd`、`76a7b51`）
5. **静默同步体系**（`02b721e` → `7ab7b9b`）
6. **单一纯净版 + 动态批注 + 默认下划线**（`d413584` → `6577dcc`）
7. **进度锚点修复 + 文档/发布修复**（`dfd9cfe` → `d1b395b`）

## 8. 真机验证状态

- 4.5.24/4.5.25 拆分后真机崩溃已通过 crash.log 定位修复
- 4.5.26/4.5.27/4.5.28 的新功能尚未在真机逐项回归，建议上游合并前在真机验证：
  - 打开书籍后动态划线是否随章节出现
  - 划线默认下划线且无二次确认
  - 显隐划线快捷键
  - 同步后微信读书书签列表只剩一个锚点书签
