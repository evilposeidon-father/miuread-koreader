# Contributing to MiuRead

感谢你考虑为 MiuRead（觅阅 · 微信读书助手）贡献代码。MiuRead 是面向 KOReader 的
非官方微信读书客户端，使用 Lua 5.1（KOReader 运行时）编写。

## 快速开始

1. 安装 KOReader 开发环境（或至少能运行 Lua 5.1 语法检查）。
2. 本地跑通测试（见下）。
3. 在 `feature/<名称>` 分支上开发，一个 PR 聚焦一个主题。

## 本地测试

\`\`\`bash
# Lua 5.1 无头套件（Windows 本地：.tools/lua51.exe tests/lua/run.lua）
lua5.1 tests/lua/run.lua
python -m unittest discover -s tests
\`\`\`

## 提交约定

- 每个改动都要同步更新 `CHANGELOG.md` 与 `README.md`（当前版本）。
- 版本号统一维护在 `miuread.koplugin/_meta.lua`、`miuread.koplugin/miuread/config.lua`
  与 `README.md` 三处，必须一致。
- 改动后跑全量测试回归（Lua 套件 + Python 结构守卫）。

## 目录结构

- `miuread.koplugin/miuread/` 插件主体（深模块 + `plugin_*` 控制器）。
- `tests/lua/` Lua 5.1 无头测试套件。
- `tests/test_project_invariants.py` 结构回归守卫。
- `docs/` 设计与贡献文档。

## 架构边界

- 新功能网络请求必须走 `miuread.http` / `miuread.api`。
- 密码学（签名/混淆/MD5/SHA-256）统一走 `miuread.protocol` + `miuread.digests`。
- 阅读时长上报走 `miuread.read_report_worker` / `read_report_transport` /
  `read_report_context` / `read_report_adapter`。

## 命名规则

### Controller（`plugin_*.lua`）

- 每个 controller 是一个闭包文件，通过 `M.install(target)` 把方法安装到全局 `Plugin` 实例。
  所有 controller 共享同一个 `self`，所以字段命名必须可归属、可 grep。
- **方法**：`Plugin:_前缀_动词`（如 `_home_refresh_header_now`），`_前缀_` 表示归属域
  （`home_` / `reader_` / `sync_` / `download_` / `shelf_` / `device_` / `search_`）。
- **self 字段**：跨 controller 共享的字段必须以全局前缀开头，否则会被结构守卫
  `test_no_unprefixed_cross_controller_self_fields` 拦截。合法全局前缀：
  `_miuread_`（全局共享）、`_home_`、`_reader_`、`_sync_`、`_download_`、`_shelf_`、
  `_thought_`、`_progress_`、`_annotation_`、`_external_`。
- 新增 controller 必须登记到 `tests/test_project_invariants.py` 的
  `test_split_controllers_installed` 列表，并新增对应 `tests/lua/test_plugin_<名>.lua`。

### 深模块（`miuread.<名>.lua`）

- 纯逻辑、无 `self`、可独立无头测试。参照 `reader_geometry` / `sync_catalog_prepare` /
  `progress_position` 模板。
- 命名与职责一一对应：`<域>_<动词>`（如 `reader_geometry.progress_percent`）。
- 每个深模块必须有对应 `tests/lua/test_<名>.lua`。

### 命名边界

- `Reader`（`miuread.content_reader`）= 内容抓取；`plugin_reader` = 阅读 UI 控制器；
  `reader_*.lua` = 阅读对话框。
- `Home` 四个 controller 职责分界：`plugin_home`（模式/调度）、`plugin_home_content`
  （书架数据）、`plugin_home_preferences_io`（持久化）、`plugin_home_local_inline`
  （本地书架渲染）。
- `Sync`：`sync.lua`（核心进度）、`plugin_sync.lua`（UI 入口）、
  `sync_catalog_prepare` / `sync_inverse_mapping`（纯逻辑深模块）。
