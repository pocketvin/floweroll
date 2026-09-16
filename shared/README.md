# 共享协议

`shared/` 保存 iPhone 与 Host 共同依赖、且不应绑定具体部署方式的协议定义。

当前主要入口：`PROTOCOL.md`。

核心概念包括：

- `Task`：持久化的用户目标与策略快照；
- `Action`：带稳定 identity / idempotency 的语义步骤；
- `Result`：设备或服务执行结果；
- `TaskState`：独立于模型对话的持久状态；
- `TraceEvent`：可恢复的执行证据。

不要把以下内容写进共享协议：

- ngrok / Cloudflare / LAN 等具体传输地址；
- 模型厂商配置；
- 仅 iPhone 本地有效的权限句柄或秘密数据。

当前架构见 `../docs/ARCHITECTURE.md`；历史原件不属于发布树。
