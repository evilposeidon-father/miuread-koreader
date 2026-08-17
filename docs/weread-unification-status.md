# 内外界面统一 · 收束状态（2026-08 R7）

> 目标：微信读书的阅读界面与外部界面尽量统一（菜单/操作/页面/隐式逻辑）。六轮讨论-共识-开发-测试-文档闭环后收束。

## 1. 已落地（✅ 共 8 组）

| 组 | 内容 | 轮次 | 测试 |
| --- | --- | --- | --- |
| 批注 kind 单点 | annotation_kinds（标签/图标/summary/兜底文案）内外共用 | R1/R7 | test_annotation_kinds |
| 时长同源 | read_time_ledger 账本 + 阅读面板状态行 + 我的页卡片；周界/格式单源 | R1/R7 | test_read_time_ledger |
| Skin 全局化 | home_cards/action_sheet/full_shelf_view/home_view/home_quick_panel/local_browser_view 全部 Skin.frame；UiScale→Skin | R2/R7 | 结构守卫 |
| 行组件全集 | ui_rows（normalize/build/geometry 覆写全集）我的页/控制中心/批注记录/阅读设置同骨架 | R3 | test_ui_rows |
| G3 剩余页 | 章节行「· 剩 N 页」（页码同源） | R4 | —（UI） |
| G4 选词菜单开关 | highlight_policy（B12 缓解：复制/查词/划线原生菜单可选） | R4 | test_reader_quick |
| G5 划线样式 | 下划线/浅底/反白三档（灰阶靠齐），marker 默认种子 + 单写者 + 即时重绘 | R6 | test_reader_quick |
| G6 本章想法 | 控制中心入口 + filter_records_by_chapter（uid 精确/idx 兜底）+ 本机镜像合入 + 空态分流 | R5 | test_external_chapter_thoughts |

## 2. 术语统一（R7）

- 评论 → 想法（同指 _thoughts_enabled，对齐批注 kind 术语）。
- 兜底文案（书页书签/无文字内容）入 annotation_kinds 单点。
- 「觅阅设置」保留为品牌词（用户决策：标题/品牌保留觅阅）；设置入口语义一致。

## 3. 挂起项（真机门禁，协议已备 docs/weread-device-verification.md）

- G1+G2 常驻顶/底栏 + 点正文呼出收起（tap 冲突，五角色一致要求真机先行）。
- paper 卡片令牌截图定稿（radius 9/6/15 vs 9/6/14，结构守卫已钉住）。
- G4 选词菜单真机验收；G7 书签角标手势（tap 拦截）。
- 选词两路互斥的默认/快捷切换（发烧友 R7：默认开 or 快捷键）——下批。
- 章末想法入口提升为面板快捷键（发烧友 R7）。

## 4. 收束结论

- 代码侧可对齐点已全部处理（R1-R7）；剩余均为真机依赖或交互偏好变更。
- 测试：Lua 256 + 结构守卫 26 全绿；CHANGELOG 4.6.2 节含各轮条目。
- 用户接 Kindle 完成真机项后，按 docs/weread-device-verification.md 回归清单走查。