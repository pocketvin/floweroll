# 花卷 / floweroll — 当前能力与执行来源

更新：2026-09-14

这份文档维护当前能力层事实：Planner 能看到什么语义能力、能力从哪里执行、哪些属于用户前台动作，以及 readiness 如何判断。精确运行时状态仍以当前源码、`GET /v1/capabilities` 和真实环境为准。

## 1. 基本模型

小卷对 Planner 暴露的是 **semantic capability**，不是 Provider/SDK 名字。

```text
用户目标
  ↓
Capability policy / discovery
  ↓
CapabilitySpec
  ↓
Action / Attempt
  ↓
ExecutionRuntime
  ↓
Adapter
  ↓
Native / Function / HTTP / MCP / CLI / material tool
  ↓
readback / verification
  ↓
Observation
```

小卷自己应该维护：

- 语义能力名称和 schema；
- 用户授权、风险和前台策略；
- Planner 的能力发现；
- Action / Attempt identity；
- idempotency；
- verification / reconciliation / recovery；
- 用户可见结果。

底层 commodity infrastructure 优先复用成熟方案。

## 2. Readiness 不是静态文档状态

“源码里有类”不等于能力现在能执行。

描述能力时至少区分：

| 状态 | 含义 |
| --- | --- |
| `source-present` | 生产源码存在 semantic capability / adapter |
| `integrated` | Action → execution → verification/readback 已贯通 |
| `device/provider-verified` | 在目标设备/账号/Provider 验证过 |
| `ready` | 当前运行环境可向 Planner 暴露并执行 |
| `deferred` | 有源码/方案，但当前配置或证据不足，不向 Planner 暴露 |

Key、OAuth、权限、Provider discovery、账号状态都会影响 runtime readiness。

## 3. 当前 Planner 原生能力

`host/floweroll_host/capabilities_v0.py` 的 `product_native_capabilities()` 当前注册以下语义能力。

### 位置

- `location.current`

一次性读取当前 iPhone 位置。它不表示：

- 持续位置追踪；
- 位置历史；
- 附近 POI；
- 逆地理编码；
- 路线规划。

### 提醒事项

- `reminder.create`
- `reminder.query`
- `reminder.set_completion`
- `reminder.update`
- `reminder.remove`

update/remove 使用 fresh native identity/revision；completion 是 desired state，不做盲 toggle。

### 联系人

- `contacts.query`
- `contacts.create`
- `contacts.update`

当前设计是 bounded contact access：不把全量通讯录导出、模糊自动选人、联系人自动 merge/delete 当作默认能力。

### 闹钟

- `alarm.query`
- `alarm.create`
- `alarm.update`
- `alarm.pause`
- `alarm.resume`
- `alarm.cancel`

底层是 AlarmKit。只管理小卷能够证明 ownership/identity 的闹钟；App 本地记录不能伪造 native state。

### 日历

- `calendar.create`
- `calendar.freebusy`
- `calendar.query`
- `calendar.update`
- `calendar.remove`

底层是 EventKit。修改/删除需要 fresh event identity/readback；超出当前 contract 的复杂 recurrence/attendee 场景应拒绝或显式交接。

### 显式通知

- `notify.user`

这是一个主动用户通知 Tool。普通 Task terminal 不自动等价于调用该 Tool；App 内 completion attention / Inbox 有独立 presentation 逻辑。

## 4. iPhone executor 层

原生 Action 由 `RuntimeClient` 下的 executor 执行，主要包括：

- Calendar executor；
- Reminder executor；
- Contacts executor；
- AlarmKit executor；
- Location executor；
- Notification executor；
- `DeviceRuntimeWorker`；
- `DeviceExecutionCoordinator`；
- `DeviceActionJournal`。

原生 side effect 的基本规则：

1. Attempt 在副作用前已经有 durable identity；
2. iPhone 持久记录 may-have-started 边界；
3. native execution 后重新读回；
4. ambiguity 先 reconcile；
5. 不能因为 timeout 就直接再执行一次。

## 5. 用户前台系统动作

下面这些是当前产品能力，但不属于 Planner 自动 Tool surface：

- PhotosPicker；
- 普通相机多张拍摄；
- 手动文档扫描；
- Files export / 保存副本；
- Photos add-only save；
- QuickLook / ShareLink；
- 系统权限管理。

原因是这些动作本身需要用户前台交互或明确点击。

Photos save 只对已验证 JPEG/PNG Task output 开放，使用 PhotoKit `.addOnly`；如果 App 在系统回调前被杀，状态进入 `UNKNOWN_MAY_HAVE_COMMITTED`，提示用户先去 Photos 检查，避免盲目重复保存。

## 6. 材料 / 文件 / 文档能力

### Task 文件底座

Host 通过 `TaskAssetStore` 管理：

- input attachment；
- output Artifact；
- task/file/action lineage；
- manifest；
- progressive output；
- work-unit storage。

文件字节不塞进主 Task JSON/SQLite row。

### Task 材料语义工具

当前 `task_material_tools.py` 注册：

- `materials.inspect`
- `document.scan_pdf`
- `document.pdf_merge`
- `document.pdf_select`
- `deliverables.plan`
- `deliverables.status`
- `deliverables.verify`
- `deliverables.publish`

其中扫描 PDF 可以在 PDF 先生成后继续逐页 Vision OCR；OCR 失败/超时时，已经结构有效的 PDF 可以作为 progressive result 保留，但不能被误说成“OCR 已完成”。

### 感知（Perception）

Mac helper 当前有：

- `image.ocr`
- `pdf.extract_text`

底层使用 macOS Vision / PDFKit helper。

### 图片

- `image.inspect`
- `image.transform`

当前支持格式/尺寸/方向/alpha/privacy metadata 检查，以及 convert、resize、crop、JPEG compress、orientation normalize、metadata strip 等确定性变换。

这套能力**不是小卷角色/Rive 资产工具**，而是普通用户图片任务能力。

### Word 文档（DOCX）

当前有 DOCX inspect / generate semantic capability，并保留 source/Artifact lineage 和 package/readback verification。

它不是完整 Word 编辑器；当前 contract 只承诺源码实际支持的语义范围。

## 7. Work Unit

`deliverables.publish` 接受可选 `output_format=html|pdf`，默认 HTML 保持兼容。选择 PDF 时把已整理文字或 DOCX 解析结果用 Core Text 分页成带可检索文本的 PDF，并用 PDFKit 逐页可渲染检查及完整文本读回核验后才发布；来源 ID/URL 仍必须属于任务已验证证据。它是“解析/分析报告交付”，不是 DOCX 原版式、图片、表格的保真转换，也不代表房间已预订、邮件已发送或日历已写入。

当 TaskAsset subsystem 启用时，Host 会注册 `work.execute`。

`work.execute` 支持 `capability.search`、`document.docx.inspect/generate` 和 `travel.hotel.search`，但不是任意工具并行器。子能力名字受模型 schema 枚举与执行器白名单双重约束，设备写入不能嵌套；单项与批量发现共用持久预算。

用途：一个复杂 Task 内做一组**有界、可恢复、安全的 Host 工作项**。

支持：

- Work Unit identity；
- 依赖；
- 有界并行；
- lease；
- 重启恢复；
- 已完成项复用；
- 失败隔离；
- 文件级验证。

它不能把高影响动作绕过原本的 approval/idempotency/reconciliation，因此不是通用“任意 Tool DAG”。

## 8. Host local / HTTP / deterministic tools

当前 Host 可以注册：

- 本地文件 list/read；
- Artifact text write；
- document parse；
- data analyze；
- public HTTPS fetch；
- deterministic calculation；
- macOS perception helpers。

Planner 不获得任意 Shell 权限。

## 9. MCP

当前 Host 仍使用自研 MCP driver/worker：

- `mcp_driver.py`
- `mcp_adapter.py`
- `mcp_execution_worker.py`
- `mcp_catalog.py`

它已经能接当前项目所需 MCP 来源，并继续走统一 Action/Attempt/Observation Runtime。

当前没有因为“官方 SDK 更成熟”而迁移。迁移触发条件应是：协议兼容、transport、session/version 维护或 Provider 接入成本真的成为问题。

## 10. 当前可组合的 Provider 来源

`host/run_host.py` 当前会根据运行环境组合这些来源：

### Web 与文档检索

- Exa search MCP；
- Context7 MCP（显式启用后）；
- public HTTP fetch。

### 地图

- Amap MCP；
- Amap WebService。

需要有效 key 后才进入对应 ready path。

### 旅行

- FlyAI 酒店查询 adapter。

### 办公/通讯 CLI

- 飞书 `lark-cli`；
- 钉钉 `dws`。

CLI 安装存在不等于账号已经 OAuth，也不等于所有写操作可用。

### 通用 MCP

可以通过环境配置额外 MCP server catalog。只有 discovery 成功并完成 semantic mapping 的 Tool 才能进入 Registry。

## 11. 模型能力

Planner 通过 OpenAI-compatible adapter 使用模型 Provider。模型 Provider 不拥有 Task/Action schema。

当前原则：

- Provider 可以换；
- Planner structured contract 不因厂商改变；
- 不把模型聊天记录当持久状态；
- 真实 model latency/token 进入 observability。

当前还没有引入 LiteLLM。只有 Provider 数量和 fallback/routing/cost 管理复杂度实际增加后再评估。

## 12. Memory

当前已经接入 `Mem0Memory`。

它解决的是**跨 Task 的长期用户记忆辅助**，不是：

- TaskState；
- 当前 Thread；
- 全量聊天历史；
- 用户资料库/RAG；
- execution journal。

Memory 写入/读取应该有界，并且不能扩大用户未授权的数据范围。

## 13. Capability Discovery

`CapabilityRegistry` 可以容纳比单次 Planner Context 更多的能力。

Planner 默认只看到小 working set；必要时通过 `capability.search` 做 progressive discovery。

不要：

- 把所有 schema 永久塞给模型；
- 让 ranking score 变成执行授权；
- 用 capability retrieval 代替 Provider readiness；
- 因为 query 词相似就绕过 semantic policy。

## 14. Policy / Preferences

模型推理不等于用户授权。

```text
用户目标
  ↓
Planner 候选动作
  ↓
Policy / Preferences
  ↓
允许 / 受限 / 拒绝 / needs-user
  ↓
Execution
```

Policy 可以约束：

- Provider；
- 账号；
- 金额；
- 服务类别；
- 时间/地点；
- autonomy；
- 前台占用；
- destructive action。

高影响边界必须落在 deterministic runtime/policy，而不是只写在 system prompt。

## 15. 副作用规则

### 只读动作

明确 transient failure 时可以按 policy 重试。

### 写入 / 删除 / 发送 / 交易

必须考虑：

- exact target identity；
- 用户授权/确认；
- idempotency；
- readback；
- may-have-started ambiguity；
- reconcile before retry。

`timeout` 不等于失败，也不等于“可以再做一次”。

## 16. Observation 不是 Capability

Observation Mode 有独立 capture/service/lifecycle。

它不会把屏幕/录音作为一个 Planner Tool 注入普通 Task Runtime，也不会允许被观察的网页、字幕或声音直接触发 Tool。

Observation 最终可以把纪要和时间线保存到 Tasks History，但这只是统一历史入口，不意味着它被转成普通 Task。

## 17. 如何增加新能力

默认顺序：

1. 明确真实用户目标；
2. 找 Apple Framework / 官方 API/SDK / 成熟库 / CLI / MCP；
3. 定义最小 semantic capability；
4. 写 deterministic contract；
5. 接 Runtime verification/recovery；
6. 做 focused + regression；
7. 需要平台/账号语义时做真实设备/Provider 验证；
8. 最后才进入 Planner readiness。

不要先造通用基础设施，再寻找使用场景。
