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
