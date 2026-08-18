# MiuRead · WeRead Assistant

MiuRead（觅阅 · 微信读书助手）是面向 KOReader 的非官方微信读书客户端。本仓库为 **Stable / 正式版通道**。

## Current Release

当前版本：`4.6.4`。

完整版本记录见 [`CHANGELOG.md`](CHANGELOG.md)。

## Highlights

- **微信读书客户端**：搜索、书架、下载、阅读进度与阅读时间同步、扫码登录。
- **单一 EPUB 版本**：下载只生成「纯净版」，不再需要单独下载「划线与想法版」；旧的划线与想法版文件继续可读，并在菜单中标注为旧版。
- **动态划线与想法**：阅读时按「当前章 + 下一章」静默拉取微信读书划线与想法，随阅读推进自动补充；无需重新生成 EPUB，使用 XPointer overlay 直接绘制，支持取消与断点续传。
- **本地书匹配**：任意重排本地 EPUB/TXT 可匹配微信读书书籍，同步个人划线/想法到当前书显示；阅读快捷面板提供 `云端划线`、`本地上传`、`显隐划线` 等图标。
- **静默同步**：本地批注改动后自动上传，失败自动退避重试；主页同步入口点击一键同步、长按查看诊断。
- **阅读进度冲突自动处理**：默认自动采用云端位置（可在同步设置中改为询问），云端来源不一致时仍保留人工选择。
- **默认下划线**：觅阅识别到的书籍中，选词后默认直接下划线，不再二次确认样式；点击已有划线仍可进行笔记、样式、删除等操作。
- **微信读书手机端对齐（4.6.2）**：首页底部三 Tab（书架/书城/我的）——书城=搜索微信读书+公众号（线上分类待验证，本地内容不伪装成书城），我的=账号状态+阅读时长卡（本机统计）+想法/划线/书架管理/设置；书架排序、继续阅读进度条、快捷面板五组前置（更多/目录/进度+字体/亮度）、夜间模式（KOReader 原生 night_mode）、切页防抖、阅读面板状态行显示今日阅读时长（与我的页同账本）、批注标签内外统一（书签/划线/想法）、视觉基线单源化（外部卡片/行组件与阅读器共用 Skin.frame、共享行布局 ui_rows 与批注标签）、阅读进度显示剩余页数、选词菜单开关（复制/查词，B12 缓解）、本章想法聚合（章内划线与想法按位置排序，点击跳转）、默认划线样式三档（下划线/浅底/反白，灰阶靠齐）。
- **阅读时长卡（4.6.2）**：我的页时长卡显示今日/本周阅读时长（KOReader 阅读统计，与「阅读周报」同源同值），点击卡片刷新、周报入口在列表行；日界/周界按显示时区（上海等）计算，凌晨阅读也计入当天。
- **休眠前同步（4.6.2）**：休眠按钮先上传批注/想法与阅读时长，提示「已同步/未完成」后再息屏；电源键息屏也会触发批注同步，恢复后提示结果。
- **真机稳定性（4.6.2）**：我的批注入口闪退修复（database_paths 词法可见性）、阅读记录去重（同位置镜像行只显示一次）、镜像划线跳转修复（本地 pos0）、切 Tab 偶发无响应修复（恢复期自动重试）、Store 多实例共享（首页/阅读器同一 settings db，账本与偏好不再互相覆盖）、划线覆盖层分帧预热与负缓存（大批注书籍翻页不卡）。

## UI 操作示意图

以下 SVG 图放在 `docs/diagrams/`，用于快速理解 MiuRead 的主要操作逻辑。生成脚本：`docs/diagrams/generate_ui_diagrams.py`（纯 Python 标准库，可重复生成）。
> 示意图已随 4.6.2 更新：首页为底部三 Tab（书架/书城/我的）、阅读页为快捷面板五组前置与控制中心，划线流程含样式三档与选词菜单开关，同步状态机含休眠前同步。

### 首页操作逻辑

<img src="docs/diagrams/home-ui-logic.svg" alt="MiuRead 首页操作逻辑" width="860">

### 阅读页操作逻辑

<img src="docs/diagrams/reader-ui-logic.svg" alt="MiuRead 阅读页操作逻辑" width="860">

### 划线交互流程

<img src="docs/diagrams/highlight-interaction-flow.svg" alt="MiuRead 划线交互流程" width="860">

### 下载与动态批注流程

<img src="docs/diagrams/download-dynamic-annotations-flow.svg" alt="MiuRead 下载与动态批注流程" width="860">

### 静默同步状态机

<img src="docs/diagrams/sync-scheduler-state.svg" alt="MiuRead 静默同步状态机" width="860">

## Installation

1. 在 GitHub Releases 下载最新正式版 `miuread-vX.Y.Z-full.zip`。
2. 解压后将完整的 `miuread.koplugin` 目录放入 KOReader 的插件目录。
3. 完整重启 KOReader。
4. 后续正式版可使用 MiuRead 内置更新功能升级。

## Development

本仓库开发分支为 `feature/arch-optimization`（对齐与架构优化工作线）；正式版通过 `vX.Y.Z` tag 发布，tag、`miuread.koplugin/miuread/config.lua` 与 `miuread.koplugin/_meta.lua` 的版本保持一致。

完整的向上游贡献改动清单见 [`docs/UPSTREAM-CONTRIBUTION.md`](docs/UPSTREAM-CONTRIBUTION.md)。

本地测试：

```bash
# Lua 5.1 无头测试（Windows 本地：.tools\lua51.exe tests/lua/run.lua）
lua5.1 tests/lua/run.lua
python -m unittest discover -s tests
```

## OTA Update Channel

从 `4.3.0` 起，正式版更新清单由 GitHub Actions 在发布时自动生成，并发布到固定 `stable-channel` Release。

- 新版正式 OTA：`stable-channel/update.json`
- 仓库根目录 `update.json`：仅作为旧正式版桥接入口
- 发布 `4.3.0` 时，workflow 会把根目录 `update.json` 更新为 4.3.0 并保持冻结，使 4.1.2 等旧版先升级到 4.3.0，再自动切换到新 OTA 通道。

## Release Process

- Stable tag：`vX.Y.Z`
- Stable Release：GitHub 正式 Release
- 版本记录：统一维护 `CHANGELOG.md`
- 创建正式 tag 后，GitHub Actions 自动校验版本、执行 Lua 5.1 语法检查、构建 full.zip、校验 SHA-256 与公开下载地址，并更新固定正式 OTA 清单。
- tag、`miuread.koplugin/miuread/config.lua` 与 `miuread.koplugin/_meta.lua` 中的版本必须一致。

## Origin and License

MiuRead originated as a modified version of `finlater/weread.koplugin` v0.1.1 and has since undergone substantial restructuring, modification, and extension.

MiuRead is an unofficial community project and is not affiliated with or endorsed by WeRead, Tencent, KOReader, or their maintainers.

This project is distributed under the GNU Affero General Public License version 3 only (`AGPL-3.0-only`). See `LICENSE`, `NOTICE`, and `THIRD_PARTY_NOTICES` for details.
