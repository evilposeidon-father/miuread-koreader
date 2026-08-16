# Legacy 网络层（保留并圈定边界）

本目录的模块用于**阅读时长上报**（read report）。它们基于早期微信读书接口实现，
由 `miuread.legacy_adapter_worker` 统一包装后供 `read_report_service` 与 `sync`
使用。

## 现状

- **保留**：阅读时长上报仍依赖 `legacy/read_report_worker` 及配套的
  `client` / `content` / `cookie` / `crypto` / `weread`。
- **边界**：除 `legacy_adapter_worker` 外，其他模块不得直接 require
  `miuread.legacy.*`。新功能必须使用 `miuread.http` / `miuread.api`。

## 迁移方向

当阅读时长上报迁移到新 `http` / `api` 层后，本目录可以整体删除，只保留
`legacy_adapter_worker` 的调用方改造记录。
