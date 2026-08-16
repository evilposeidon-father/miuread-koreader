# Legacy 网络层（已退役）

本目录原本存放**阅读时长上报**（read report）的早期微信读书接口实现，由
`miuread.legacy_adapter_worker` 统一包装后供 `read_report_service` 与 `sync`
使用。

## 退役记录（MiuRead 4.5.33）

- 密码学（MD5/SHA-256、签名/混淆）并入 `miuread.digests` + `miuread.protocol`。
- reader token 收敛到 `miuread.config.READER_TOKEN`。
- 传输层迁到 `miuread.read_report_transport`（基于 `miuread.http`，单次尝试、
  退避由 `read_report_service` 负责）。
- 阅读上下文/目录纯逻辑迁到 `miuread.read_report_context`。
- 工作器迁到 `miuread.read_report_worker`，适配器迁到
  `miuread.read_report_adapter`。

原 `legacy/` 目录已删除。新功能一律使用 `miuread.http` / `miuread.api`。
