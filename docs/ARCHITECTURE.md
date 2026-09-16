# 花卷 / floweroll — 现行架构与实现事实

更新：2026-09-15

这份文档是**当前源码架构的唯一总览**。它回答“现在小卷实际上由什么组成、数据怎么流、状态存在哪里、Task Mode 和 Observation Mode 各自怎么运行”。

它不是路线图、审计流水账或历史设计记录。这里的事实应以当前源码为依据；实现发生结构性变化时直接修改本文，不在末尾追加阶段日志。

## 1. 产品运行形态

当前小卷由两种彼此独立、但共享同一个 iOS App 和 Host 连接的工作模式组成：

### Task Mode — 把事情交给小卷执行

用户提交一个目标，小卷在 Host 中持久化 Task，调用 Planner 和能力，执行真实操作，验证结果，并把进度、需要用户的事项和成果投影回 iPhone。

典型任务：

- 查询、整理和研究；
- 日历、提醒事项、闹钟、联系人、位置等原生能力；
- PDF、扫描、OCR、图片、DOCX 等材料处理；
- Provider / MCP / CLI / HTTP / Host 本地工具；
- 多步骤任务、等待用户、恢复、取消和结果交付。

### Observation Mode — 陪用户一起看、听、记、整理

用户显式开启一段观察会话，小卷采集用户选定的屏幕、周围麦克风或手机声音，把可验证的记录持续保存和整理，并允许用户针对刚才的记录提问。

Observation **不是普通 Task 的一种 Tool**，也不经过 Task Planner/Action 状态机。它有自己独立的 capture、journal、Host service、数据库和总结流程，最终可以作为“观察记录”进入 Tasks 历史。

## 2. App 信息架构

根界面是三个 Tab：

```text
FlowerollApp
└─ ContentView
   └─ TabView
      ├─ 小卷 / Home
      ├─ 任务 / Tasks
      └─ 设置 / Settings
```

Observation 不是第四个 Tab。Home 左上区域有“观察”入口，使用 `fullScreenCover` 打开 `ObservationView`。

主要源码：

- `ios/Floweroll/App/FlowerollApp.swift`
- `ios/Floweroll/App/ContentView.swift`
- `ios/Floweroll/App/Observation/ObservationView.swift`

## 3. 总体部署拆分

```text
┌──────────────────────────── iPhone ────────────────────────────┐
│                                                               │
│  Home / Tasks / Settings / Observation                        │
│  Action Button / AppIntents                                   │
│  Native permissions + native executors                        │
│  Attachment capture / local recovery / presentation           │
│  Live Activity / Dynamic Island / Notification                │
│                                                               │
└───────────────────────┬───────────────────────────────────────┘
                        │ authenticated task-centric HTTPS
                        │ request/response + resumable reads
                        │ SSE only as live presentation optimization
                        ▼
┌──────────────────────────── Host ──────────────────────────────┐
│ FastAPI + Pydantic + Uvicorn                                  │
│                                                               │
│ Task Mode                       Observation Mode                │
│ ├─ TaskRuntime                  ├─ ObservationService           │
│ ├─ Planner                      ├─ observation SQLite           │
│ ├─ ExecutionRuntime             ├─ screen understanding         │
│ ├─ CapabilityRegistry           ├─ checkpoint/final summary     │
│ ├─ verification/recovery        └─ record Q&A                   │
│ ├─ materials/artifacts                                        │
│ └─ main SQLite                                                │
│                                                               │
│ Provider / MCP / CLI / HTTP / local tools / macOS helpers      │
└───────────────────────────────────────────────────────────────┘
```

开发期 Host 跑在 Mac；长期产品方向可以把同一 Host contract 移到持续在线的云运行时。iPhone 不应该依赖 Mac 特有实现细节。

## 4. Task Mode：持久任务执行链

### 4.1 输入

Task Mode 的主要输入来源包括：

- Home 输入框；
- Action Button / AppIntent；
- Task/Thread 内后续 UserTurn；
- 附件；
- clarification / action input；
- cancellation；
- 设备原生执行结果。

全局 Home / Action Button 输入采用 **new-task-by-default**：仅存在活动 Task 不足以把下一条用户输入捕获为 continuation。Task/Thread 详情中的输入则天然属于该 Thread。

### 4.2 核心数据流

```text
TaskSubmission / UserTurn / typed external event
        ↓
Host durable admission
        ↓
Task inbox + runtime revision
        ↓
TaskRuntime / TransitionEngine
        ↓
构造有界 Planner Context
        ↓
PlannerDecision
        ↓
Action
        ↓
ActionAttempt 在外部副作用前持久化
        ↓
ExecutionRuntime
   ├─ Function / HTTP / local tools
   ├─ MCP
   └─ iPhone native executor
        ↓
真实执行结果
        ↓
verification / readback / reconciliation
        ↓
Observation / Artifact / Trace
        ↓
complete / replan / wait / retry / cancel
```

### 4.3 Task 真相在哪里

以下都不是 Task 真相：

- LLM 当前对话；
- SwiftUI 页面状态；
- SSE 是否连接；
- Live Activity 是否还显示；
- 模型文字里声称“完成”。

Task 正确性来自 Host durable state 与真实副作用验证。

主要源码：

- `host/floweroll_host/task_runtime.py`
- `host/floweroll_host/transition_engine.py`
- `host/floweroll_host/execution_runtime.py`
- `host/floweroll_host/runtime_supervisor.py`
- `host/floweroll_host/recovery.py`
- `host/floweroll_host/storage.py`

## 5. Host 组合方式

`HostApp` 位于 `host/floweroll_host/server.py`，当前负责把各子系统组合起来，而不是自己维护 HTTP 路由。

一个 HostApp 实例主要拥有：

```text
Storage
DeveloperObservabilityService
RecoveryCoordinator
CapabilityRegistry
TaskAssetStore              (启用材料能力时)
ExecutionRuntime
MCPExecutionWorker          (存在 MCP source 时)
FunctionExecutionWorker     (存在 Host/function source 时)
LiveActivityProjectionService
TaskRuntime                 (Planner 已配置时)
ObservationService
RuntimeSupervisor
```

Task materials、image ops、DOCX semantic、capability discovery 和 work units 也是在这个组合边界注册进 Registry/Execution Runtime。

## 6. HTTP / API 层

当前真实 HTTP 路径已经是：

```text
run_host.py
  ↓
create_server()
  ↓
FlowerollHTTPServer
  ↓
Uvicorn
  ↓
FastAPI
  ↓
Pydantic request / response contracts
  ↓
HostApp services
```

主要文件：

- `host/floweroll_host/http_app.py` — FastAPI 组合与异常边界；
- `http_schemas.py` — Pydantic wire model；
- `http_tasks.py` — Task/read model/action endpoints；
- `http_interactions.py` — UserTurn、clarification、cancel 等；
- `http_files.py` — upload/download/material endpoints；
- `http_observations.py` — Observation API；
- `http_developer.py` — 只读 developer observability；
- `http_transport.py` — Uvicorn lifecycle。

Pydantic 已覆盖主要顶层 request/response。Trace、Provider payload、部分 work/material 内部结构仍保留 `dict[str, Any]` / `Any`，这是兼容和动态扩展边界，不要求为了“100% 类型化”强拆。

## 7. Planner、Context 与 Memory

### 规划器（Planner）

开发 Host 通过 `OpenAICompatibleChatPlannerAdapter` 使用 OpenAI-compatible 模型接口。具体模型由运行环境决定，不写死在 Runtime contract 中。

Planner 内部由 LangGraph `StateGraph`（依赖锁定 `langgraph==1.2.11`）组织，统一入口是 `TaskRuntime.planner_graph`。不是只给旧函数套一个节点：Memory 检索、Context 构造、能力选择、正常/恢复投影、Request 构造、模型调用、契约校验分别执行并记录节点耗时。

```text
Runtime 读取 durable basis、预留 Planner 次数
→ memory → build_context → select_capabilities
→ compact_context（正常）/ recovery_context（上次临时失败）
→ build_request → call_model → validate
→ Runtime policy/completion guard → revision fence → 原子提交 PlannerDecision
```

Graph 不持有 Task truth，不执行 Tool / iOS Action，不使用 ToolNode、Graph checkpointer、interrupt 或自己的自动重试队列。HTTP Adapter 的 `decide_once` 每轮只发一次请求；失败仍交给 Runtime 的持久退避，下一轮依据真实失败记录进入 recovery_context。默认连续两轮临时失败后暂停，不再叠加 Adapter 的原样 HTTP 重试；每轮都消耗同一个 Planner 预算。进程重启重建 Graph，而不是恢复第二套状态机。模型请求前检查 Runtime revision / Inbox watermark，模型结果提交仍使用原有原子过期检查。

证据投影只修改送给模型的副本：去除与 structured_content 完全相等的 MCP 文本包、已完整展开子回执的重复批次状态和重复 DOCX 段落；保留失败/未载入子项、精确 ID、原生写入核验与用户约束。长检索文本用结构化片段和显式截断标记表示，不再截断整个 JSON 字符串。原始回执仍在存储中。正常与恢复模式都保留 Mem0；恢复时不额外调用一个 LLM 做摘要。

Graph 节点事件写入本机 `planner.graph.node`，每次 `planner.call.metrics.graph_steps` 汇总节点耗时、错误类型和上下文大小。开发观察台现有 Planner → Metrics 可读取；未新增独立 Graph UI。Graph 调用显式禁用 LangSmith 自动 tracing，不能因继承环境变量把 Task/Memory 导出到新服务。


相关文件：

- `host/floweroll_host/openai_compatible_chat_adapter.py`
- `host/floweroll_host/planner_contracts.py`
- `host/floweroll_host/planner_request.py`
- `host/floweroll_host/context_builder.py`
- `host/floweroll_host/planner_graph.py`
- `host/floweroll_host/planner_compaction.py`

### 能力上下文

Registry 可以很大，但单次 Planner 只应看到小的工作集：

```text
用户目标
  ↓
policy / readiness / affinity
  ↓
有界 capability working set
  ↓
必要时 capability.search
  ↓
Planner
```

`capability_discovery.py` 负责逐步发现，避免全量 Tool schema 永久塞进 prompt。新发现的子目标优先进入工作集；已完成的定位/天气准备步骤不再永久占据快速路径，但同一工具仍可用于其他参数或地点。

能力发现的无进展预算由 Runtime SQLite 的 `budget_json.discovery` 持有：连续最多 6 次搜索，或连续 2 页没有新候选后暂时关闭搜索；单 Action 和并行 Work Unit 共用事务计数，不能用批处理绕过。`capability_searches` 记录实际调用，`revealed_capabilities_json` 记录当前目录已见候选。真实业务回执或新用户输入恢复连续预算；只有目录/就绪状态/授权集合变化才使旧目录记录失效。搜索回执进入模型上下文时只保留 ID、查询与覆盖信息，完整原始回执仍留在存储中。预算关闭不表示整个任务失败：先执行已知独立事项，未能满足的部分必须明确说明。

### 记忆（Memory）

当前 Host 已接入 Mem0：

- `host/floweroll_host/mem0_memory.py`
- Planner 启用时由 `run_host.py` 构造并注入 `TaskRuntime`。

Memory 用于跨 Task 的用户长期信息辅助，**不拥有 Task 真相**。SQLite TaskState、Memory、历史资料检索和某次 LLM Context 是四个不同概念。

## 8. Capability / Execution 架构

Planner 看到的是 semantic capability，不需要知道底层来源是 Apple Framework、MCP、CLI 还是本地 Python。

```text
CapabilitySpec
   ↓
CapabilityRegistry
   ↓
Action
   ↓
ExecutionRuntime
   ↓
CapabilityAdapter
   ↓
Source
```

来源类型包括：

- `ios` — iPhone 原生执行；
- `function` / Host local；
- `task_material`；
- `mcp`；
- `managed_cli`；
- HTTP/API。

统一保留：Action identity、Attempt、timeout/retry policy、verification、reconciliation、Observation。

## 9. 当前 iPhone 原生语义能力

`host/floweroll_host/capabilities_v0.py` 的 `product_native_capabilities()` 当前包含：

### 位置

- `location.current`

只表示一次性当前位置，不代表持续跟踪或位置历史。

### 提醒事项

- `reminder.create`
- `reminder.query`
- `reminder.set_completion`
- `reminder.update`
- `reminder.remove`

### 联系人

- `contacts.query`
- `contacts.create`
- `contacts.update`

### 闹钟

- `alarm.query`
- `alarm.create`
- `alarm.update`
- `alarm.pause`
- `alarm.resume`
- `alarm.cancel`

使用 AlarmKit，管理小卷能够证明 ownership 的闹钟。

### 日历

- `calendar.create`
- `calendar.freebusy`
- `calendar.query`
- `calendar.update`
- `calendar.remove`

使用 EventKit，修改类动作依赖 fresh identity/readback。

### 通知

- `notify.user`

这是显式用户通知 capability；普通 Task 完成并不意味着必须调用它。

iOS 执行实现主要位于 `ios/Floweroll/App/RuntimeClient/`。

## 10. iPhone 原生前台动作

有些系统能力是用户明确触发的前台产品动作，不属于 Planner 自动执行 Tool：

- 文件导出 / “保存到文件”；
- 把已验证 JPEG/PNG 成果保存到 Photos；
- PhotosPicker；
- 相机多张拍摄；
- 文档扫描；
- ShareLink / QuickLook 等交接。

这些动作也有自己的 durable/recovery 边界。例如 Photos save 使用 add-only 权限，并持久记录“可能已经写入但回调丢失”的状态，避免进程重启后盲目重复保存。

## 11. 材料、附件与 Artifact

### iPhone 侧

主要文件：

- `TaskAttachmentCapture.swift`
- `RuntimeClient/Materials/`：Models、Attachments、Export 和 Views 按职责分区
- `AttachmentUploadTransport.swift`
- `PendingSubmissionStore.swift`

当前链路支持：

- 照片选择；
- 一次相机会话多张手动拍摄；
- 手动文档扫描；
- 附件预上传；
- Host 端 resumable upload：`file_id + sha256 + Upload-Offset` 是唯一续传真相；
- 普通/前台 resumable lane 保持 256 KiB 分片；远程 HTTPS 后台 lane 在取得 Host 已确认 offset 后，把“当前 offset → 文件末尾”的剩余区间写成临时文件，并作为**一个** `URLSessionConfiguration.background` file-backed PATCH 交给系统，避免每 256 KiB 都依赖 App 再次被唤醒；
- 后台大区间只对已认证、同时带 `X-Floweroll-Background-Upload: ?1` 与 `Upload-Complete: ?1`，且覆盖准确剩余区间的请求开放，仍受单附件 12 MB 上限约束；
- Host 逐段消费 HTTP 请求流，每累计 256 KiB 就落盘并推进 durable offset；连接中断时保留最后不足一段的已接收内容，不再等整份请求收完才保存。再次连接从 Host 确认位置续传；文件仅在完整长度、SHA/格式核验通过后发布，完整暂存文件可在重放 begin 时恢复最终核验；
- 上传显示接入 `didSendBodyData`，使用本次请求实际发送字节加已确认前缀；回前台读取系统任务字节数恢复显示。网络发送进度不是完成凭据，全部发送后仍要等待 Host receipt；
- 成功查询上传元数据不能重置失败预算；只有 Host 已确认 offset 前进才重置。TLS/隧道中断与 App 挂起必须分别诊断，系统后台传输并不保证网络始终可用；
- loopback/测试环境保留普通 URLSession 路径；后台 transport 不取得 Task lifecycle、LongRunningIntent 或 Live Activity ownership；
- 发送取消与 submission 对账；
- 消息级附件归属；
- 结果预览、分享、Files/Photos 保存。

### Host 侧

`TaskAssetStore` 管理 Task 文件和 lineage。文件字节与主 Task SQLite 分开。

Task material semantic capabilities包括：

- `materials.inspect`
- `document.scan_pdf`
- `document.pdf_merge`
- `document.pdf_select`
- `deliverables.plan`
- `deliverables.status`
- `deliverables.verify`
- `deliverables.publish`

另外还有：

- `image.ocr`
- `image.inspect`
- `image.transform`
- PDF text extraction
- DOCX inspect/generate
- `work.execute`

`image_ops` 是真实用户图片处理能力，与小卷角色/Rive 资产完全分离。

## 12. Provider / MCP / CLI / Host 工具

`host/run_host.py` 当前可以组合：

- Exa search MCP；
- Context7 MCP（配置后）；
- Amap MCP；
- Amap WebService；
- 环境配置的通用 MCP catalog；
- FlyAI 酒店查询；
- 飞书受控 CLI；
- 钉钉受控 CLI；
- public HTTP；
- Host local file/data tools；
- macOS Vision/PDFKit perception；
- deterministic calculation。

是否真正 `ready` 由当前运行环境、Key/OAuth、Provider discovery 和 Registry 决定，不由文档静态声称。

当前自研 MCP 层继续使用；尚没有因为真实维护成本而迁官方 MCP Python SDK。

## 13. Work Unit

当 TaskAsset subsystem 启用时，Host 注册 `work.execute`，用于同一个 Task 内一组有界、可持久恢复的安全 Work Unit。

它不是通用工作流平台：

- 仍受 Task/Action ownership 约束；
- 每个子工作有固定输入和验证回执；
- 支持依赖、有限并行、失败隔离、lease/recovery；
- 高影响写操作不能仅因为放进 Work Unit 就绕过原有 approval/idempotency。

Planner 保留一个顶层 `action`；`work.execute.units` 表达 2–8 个子工作，默认最多 3 个同时执行。模型看到的子能力枚举来自当前已授权、已就绪且可见的安全工具，其参数使用相邻工具的 schema；Runtime 在真正执行时再次检查源、策略和只读/写入边界。支持能力发现、DOCX读取/生成、酒店只读查询、地图/网页读取和已定义文件输出；日历、闹钟、付款、预订等仍走原来的独立授权与核验通道。

实现：`host/floweroll_host/work_units.py`。

## 14. iPhone 本地状态与恢复

### 持久应用数据（Application Support）

当前会保存需要跨重启恢复的产品状态，例如：

- pending submission；
- attachment draft/文件；
- native DeviceAction journal；
- terminal/history presentation cache；
- Files export operation；
- Photos save operation；
- Observation session/event journal。

### 缓存（Cache）

下载后的 Task 结果文件放在 Caches，属于可重新下载的数据，不是任务权威状态。

### 凭据（Keychain）

Host bearer credential 放 Keychain，不进 UserDefaults、日志或普通 JSON。

## 15. Host 持久数据

默认开发 Host：

- 主 DB：`work/floweroll-v1.sqlite3`（可用 `--db` 覆盖）；
- Host workspace：`work/host-capabilities`（可用环境变量覆盖）；
- Task material root：通常为 `work/task-materials`。

Task material 区包含：

- 上传文件与生成文件；
- `manifest.sqlite3`；
- `work-units.sqlite3`。

Observation 使用独立数据库：

```text
<主 DB 路径>.observations.sqlite3
```

所以普通 Task Runtime 与 Observation 不共享同一 lifecycle schema。

## 16. Background / System Entry / Live Activity

主要实现：

- `FlowerollIntents.swift`
- `DeviceBackgroundExecutionController.swift`
- `SystemEntryRuntimeCoordinator.swift`
- `FlowerollActivitySession.swift`
- Live Activity extension。

系统后台窗口只是**获得执行机会**，不是 Agent 的生命周期 owner。

原则：

- Host durable state 决定 Task 是否 active/terminal；
- iOS 后台窗口结束不能自动把 Host Task 判失败；
- 一个 Task 同一时刻应只有一个有效长期展示 owner；
- Live Activity / Dynamic Island / Notification 只是 presentation channel。

当前 Task Mode 的长后台链路按入口分成两条：

```text
App 内 Home / Task Detail / Thread Detail
→ 普通 AppIntent 接住真实用户动作
→ 立即申请全局 BGContinuedProcessingTask
→ persist-first submission_id / event_id + 附件引用
→ background URLSession 独立传输附件
→ Host durable Runtime / DeviceRuntimeWorker

Action Button / Siri / Shortcut / 其他系统入口
→ LongRunningIntent + performBackgroundTask
→ persist-first / Host durable Runtime / DeviceRuntimeWorker

两条入口
→ 共用 Host Task truth
→ 共用 background URLSession 数据面
→ 共用 BGProcessing 补偿恢复
```

- App 内用户启动的长期工作使用一个全局 BGCPT 执行与系统展示 owner；BGCPT 只消费 `continuedTaskIDs / continuedOutboxIDs`，不能把所有 durable tracked Task 自动据为己有。Action Button / Siri / Shortcut 创建或接手的 Task 继续使用 `LongRunningIntent`。
- durable recovery tracking 与 BGCPT ownership tracking 是两份集合。同一 durable Task 同一时刻只能属于一个长期 execution/presentation lane；系统入口明确 continuation 到正在由 BGCPT 处理的 Task 时，先从 BGCPT owner 集合移除该 taskID，再由 LongRunningIntent 获取 execution owner。
- 当前 iOS 27 已真实复现：App 内 `Button(intent:)` 可以进入 `LongRunningIntent.perform()`，但 `performBackgroundTask()` 会在 operation closure 开始前报 `PerformIntentError.noContext`（`LNContextErrorDomain / 2004`，UI 文案误导为 `UnsupportedValueType`）；零参数和单 String 参数均可复现。因此 App 内入口不再用 LongRunningIntent 做长执行 owner，也不保留 noContext fallback 作为产品架构。
- BGCPT 必须在前台真实用户动作期间申请。persist-first outbox 先保留精确 `submission_id / event_id`，短 UIKit background task 只负责把前台动作桥到 BGCPT scheduler admission，不是长期 owner。
- BGCPT expiration 只结束本次系统执行窗口，调用 `setTaskCompleted(success: true)` 收束系统 lease，保留 durable Host truth，并排队 BGProcessing 恢复；绝不能把 expiration 映射为 Host `failed`。
- `LongRunningIntent` 的 timeout / system interruption 同样只结束系统入口的 execution session，不写 Host Task failed；显式用户取消才映射为 Host cancel。
- 两种系统 owner 的进度都来自 durable admission 与 Host verified `work_summary` / semantic status，不使用按时间增长的假进度。`needs_user` 不是业务完成，Host terminal truth 优先于迟到 interaction。
- `blocked` 也不等于 `needs_user`：只有真实 pending clarification / action input 才进入“需要你”。`planner_runtime_error` 投影为非终态“已暂停”；用户显式“重新尝试”通过同一 Task 的 `POST /v1/tasks/{task_id}/retry` 写入 `task.operator_resumed` 并恢复 planning，不伪造 UserTurn、不创建新 Task，也不对权限/业务限制类 blocked 强行重试。
- `BGProcessingTask` 是不占产品展示的补偿恢复通道；具体启动时间由 iOS 决定，`earliestBeginDate` 不是执行时间承诺。
- 上传的数据平面独立使用 system-owned background URLSession；BGCPT / LongRunningIntent 都不接管附件字节传输 ownership。
- 系统上传唤醒后的补交接有有限预算；超时会交还系统 completion handler 并保留后续恢复，不把整个 Task 判失败。
- 取消发送先撤销 outbox 重放资格，再按确切编号核对已接收的 Host Task；普通传输失败保留原编号。进程内已确认编号仅用于消除前后台同时接收 ACK 的误取消，不是另一份 Task 状态。
- 带有效 `pending_interaction` 的任务不执行未授权后续动作，也不被记成完成；Host 终态优先于迟到的 interaction 投影。
- App 被系统暂停、网络断开、用户强制退出或权限需要前台时，不承诺 iPhone 任意代码无限运行；Host 上已接收的工作与本机原生步骤分别遵循各自执行条件。
- Host → APNs 远程更新仍暂缓，未新增 Push entitlement、token 注册或 provider。

长时间锁屏、多个任务、上传后继续原生步骤及强退后恢复，必须使用同一构建做无调试器真机验收；模拟器与源码测试只覆盖契约和恢复逻辑。

## 17. Home / Tasks / Inbox 的状态关系

Home 与 Tasks 都从 `RuntimeTaskStore` 和 Host read model 恢复，而不是各自维护生命周期真相。

当前包括：

- Home 当前 Thread；
- 其他 running / needs-user Inbox；
- completion attention；
- terminal review / 待看；
- Tasks 进行中/历史；
- normal Task history + Observation history 的统一列表；
- Task Detail / Thread history；
- cancel / bring-to-home / notification exact routing。

`seen/reviewed` 等属于 presentation state，不修改 Host Task terminal truth。

## 18. 小卷角色当前实现

`FlowerollPresentationView` 是当前 Home 的统一展示入口：

- `idle` / `listening`：批准母版拆出的 deterministic sprite body + 独立 eye layer；
- 支持 blink、bounded gaze、poke、轻微 bob；
- listening 有独立 signal；
- `thinking / working / waiting / done`：走 `FlowerollAnimatedStateView`。

Rive resource 仍在仓库中，但已经不是 Home idle/listening 的当前 body owner。

## 19. Observation Mode：当前真实实现

### 19.1 入口和 preset

Home 中“观察”按钮打开全屏 Observation。

Preset：

- 会议；
- 屏幕；
- 影音；
- 综合；
- 自定。

可选来源：

- `screen` — 屏幕画面；
- `ambientMicrophone` — 周围麦克风；
- `deviceAudio` — 手机/屏幕声音。

### 19.2 iPhone capture

主要实现：

- `ObservationCapture.swift`
- `ObservationModels.swift`
- `ObservationController.swift`
- `ObservationView.swift`

当前 iOS 27 路径使用：

- ScreenCaptureKit + `SCContentSharingPicker`；
- AVAudioEngine / AVAudioSession；
- SpeechAnalyzer / SpeechTranscriber；
- Vision `VNRecognizeTextRequest`；
- CoreImage 做 screen sampling/encoding。

屏幕观察只在小卷退到后台后处理画面，避免把花卷自己的 Observation UI 当作观察内容。

屏幕帧会做变化检测；画面/OCR 与 VLM 理解有节流，不会把每一帧都发给模型。

周围声音和手机声音是独立 source，并有 acoustic-echo fusion，避免扬声器内容同时被麦克风再次记录成两条用户时间线。

### 19.3 Observation 本地持久化

`ObservationJournal` 写入 Application Support：

```text
Observation/<session-id>/
├─ session.json
└─ events/<event-id>.json
```

不保存完整录音或完整视频。屏幕事件只保留必要截图/OCR evidence；Host ACK 后本地截图字节会被去除。

进程被杀后不会自动恢复采集：曾经处于 capture 状态的 session 会变成 `interrupted`，必须由用户明确继续。

### 19.4 Host Observation Service

`host/floweroll_host/observation_service.py` 是独立于 Task Planner 的服务。

它负责：

- exact session/event identity；
- bounded event ingestion；
- ACK/replay reconciliation；
- screen image VLM understanding；
- 周期 checkpoint summary；
- final summary；
- decisions / todos / open questions；
- 基于 observation record 的问答；
- analysis retry；
- delete + tombstone，防止晚到 replay 复活已删除 session。

Observation 内容始终作为**被观察数据**，不能改变 system rules，也不能调用 Task Tool。

### 19.5 Observation UX

当前支持：

- 开始、暂停、继续、结束；
- 返回 Home 后继续观察；
- Home 普通语音输入可复用正在运行的 Observation 麦克风 transcript，避免重复占用麦克风；
- 实时时间线；
- 屏幕理解摘要；
- 阶段整理和最终纪要；
- 针对记录提问；
- 查看原始记录；
- 分享纪要；
- 保存到 Tasks 历史；
- 从 Tasks 历史重新打开；
- 删除本机和 Host 记录。

Observation history 与普通 Task history 在 Tasks 页面统一排序展示，但两者后台 lifecycle 仍完全不同。

## 20. Developer Observability

当前已经有自己的开发观察体系，不依赖 DeepEval：

- Runtime Trace；
- Planner call trace；
- opt-in Planner request capture；
- token / latency / attempts；
- developer-only API；
- iOS Settings → 开发者模式 → Agent 调试。

`developer_observability.py` 是**只读投影**，不会修改 Task、执行 Tool 或成为第二套 Runtime。

## 21. 当前刻意没有做的架构迁移

目前不为了“框架成熟度”进行以下大迁移：

- 不整体迁 TCA；
- 不整体迁 Temporal/LangGraph；
- 不迁官方 MCP Python SDK；
- 不接 DeepEval；
- 不因为使用 Mem0 就把 Memory 当 TaskState；
- 不为了 ORM 一次性重写 6000+ 行 Storage。

当前工程优化优先级是：**先明确职责、拆大文件、减少重复自研，再在真实维护成本出现时替换底层实现。**

## 22. 主要代码地图

```text
ios/Floweroll/App/
├─ ContentView.swift                  App Shell 组合与导航入口
├─ FlowerollApp.swift                 App 入口
├─ FlowerollIntents.swift             系统入口 / AppIntent
├─ FlowerollActivitySession.swift     冻结的本地 Live Activity
├─ Shell/                            Tab 容器、全局导航与完成提醒
├─ Home/                             首页状态、线程、收件箱和时间线
├─ Tasks/                            任务列表、历史行与原生滚动
├─ Settings/                         设置、权限、工具与闹钟管理
├─ Schedule/                         时间安排聚合、来源、移除与视图
├─ Developer/                        Agent 调试视图
├─ Observation/                      独立 Observation Mode（本轮不改）
└─ RuntimeClient/
   ├─ RuntimeTaskStore.swift         唯一前台 read/presentation owner
   ├─ FlowerollHostClient.swift      Host client
   ├─ HostModels.swift               wire/read models
   ├─ Policies/                      输入路由、滚动、待看与终态策略
   ├─ Materials/                     Models / Attachments / Export / Views
   ├─ Presentation/                  任务/线程详情、结构化结果与成果视图
   ├─ RuntimeConnectionSettingsView.swift  仅 Host 连接设置
   ├─ DeviceRuntimeWorker.swift      native action worker
   ├─ DeviceActionJournal.swift      native side-effect recovery
   └─ *Executor.swift                native capability executors

ios/FlowerollTests/
├─ Interaction/                      按领域分文件，保留原 XCTest identity
├─ Support/                          共享 fixture 与源码路径检查
└─ *Tests.swift                      其他既有回归

host/floweroll_host/
├─ server.py                          HostApp composition
├─ http_*.py                          FastAPI/Pydantic HTTP boundary
├─ storage.py                         durable Task database
├─ task_runtime.py                    semantic lifecycle
├─ execution_runtime.py               execution/verification
├─ runtime_supervisor.py              runtime scheduling
├─ capability_registry.py             capability source registry
├─ capability_discovery.py            bounded discovery
├─ task_assets.py                     task file/material store
├─ task_material_tools.py             material semantic tools
├─ work_units.py                      bounded durable work units
├─ image_ops.py                       image inspect/transform
├─ docx_semantic.py                   DOCX semantics
├─ mem0_memory.py                     cross-task memory adapter
├─ observation_service.py             Observation Host runtime
├─ developer_observability.py         read-only developer view
└─ planner_capture.py                 opt-in planner request capture
```
