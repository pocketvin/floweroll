# 花卷 / floweroll — 当前工程状态

更新：2026-09-21

这份文档只回答“现在开发时应该知道什么”。它不保存旧候选 SHA、历史 Builder 状态、累计 PASS 数或阶段流水账。

## 1. 当前整体状态

- 小卷已经是一个真实的 iOS + Host Agent 工程，不是单一 demo/probe。
- Task Mode 的 durable Runtime、Planner、Capability、材料/附件、原生执行、恢复和产品 UI 都已有真实实现。
- Observation Mode 已进入当前产品源码，是与 Task Mode 独立的第二工作模式。
- Host HTTP 已迁到 FastAPI + Pydantic + Uvicorn。
- Mem0 已接入 Planner Runtime，作为跨 Task 的辅助长期记忆。
- Planner 内部已使用 LangGraph StateGraph：分节点处理 Memory、能力选择、Context 投影、单次模型请求和校验；Task/Action/Attempt 的持久状态和恢复仍由原 Runtime 拥有。
- Planner 传输重试已收敛到 Runtime 一层；恢复请求走 recovery_context，不额外叠加 Adapter 重试。复杂任务的 capability discovery、酒店/天气/检索 evidence 和 Memory 会做有界投影，避免已完成回执反复膨胀工作集；Kimi K3 的逐步 Planner 默认使用 low reasoning effort。新节点记录在开发观察台现有 Metrics 中，无独立 Graph UI。

- iOS 长执行采用双入口 owner：Home / Task Detail / Thread Detail 的 App 内用户动作由普通 `AppIntent` 完成短 admission，并立即申请单个全局 `BGContinuedProcessingTask`；Action Button / Siri / Shortcut 等真实系统入口继续使用 `LongRunningIntent`。BGCPT owner 集合与 durable recovery 集合分离，系统入口接手同一 Task 前会先从 BGCPT 集合转交，避免同一 Task 双 owner。APNs 远程更新仍暂缓。
- 品牌、工程、Swift 模块、Python package、资源及配置 namespace 统一为 Floweroll / floweroll；App 为花卷，助手为小卷。
- 日常开发已建立提交基线，后续结构整理与功能修复分别提交；发布仍使用经过命名/隐私/密钥检查的独立源码仓库，不包含本机旧历史。签名、平台真机验收与开源许可分别确认，不能由构建或单测结果替代。

## 2. Task Mode

当前成立：

- Task / Action / Attempt / Observation / Trace durable state；
- TaskRuntime / ExecutionRuntime / RuntimeSupervisor；
- stale Planner fencing；
- UserTurn、clarification、action input、cancel、retry、UNKNOWN reconciliation；
- CapabilityRegistry + progressive discovery；
- Host/iPhone read models、Timeline、Task Index、Task View；
- Home / Tasks / Task Detail / Inbox / completion attention；
- Action Button / system entry / background presentation；
- 附件 preupload / system-owned background URLSession / resumable offset reconciliation / Task material lineage；
- PDF/OCR、图片处理、DOCX、Work Unit；
- Calendar / Reminder / Contacts / Alarm / Location / Notification 原生能力。

长后台执行已接入源码，发送/outbox/Host truth 不依赖某一次 iOS 执行窗口；BGCPT 与 `LongRunningIntent` 都只是系统授予的 execution session，不等于进程无限常驻。BGCPT expiration、LongRunning timeout / interruption 都不能把 durable Host Task 写成失败；background URLSession 继续负责附件字节传输，BGProcessing 只做机会式补偿恢复。App 内 BGCPT 与系统 LongRunning 必须分别做签名真机持续运行 / Dynamic Island 验收。需要权限 / 确认 / 前台交接的步骤继续保留真实边界。

近期真机集中修复已经收口：检索正文/Planner working set、长 DOCX 续读、附件 receipt 与消息提交、旧删除任务的 Inbox/取消恢复、原生 capability family 权限粒度、AlarmKit 配置替换、needs-user 回复路由、capability discovery 召回以及 destructive confirmation ownership 都已进入当前代码。前台恢复由 lifecycle owner 负责，列表读取无副作用；闹钟更新使用持久 cancel/absence/schedule 事务并支持原配置回滚。

当前同一开发候选已经完成真机 AlarmKit 配置替换/readback/cleanup、旧取消状态收口，以及一条天气/交通/住宿/DOCX/Reminder create→query→remove→query 的复杂 Task 闭环；删除操作只在 binding-aware `ACTION_INPUT` 获得用户批准后创建 Attempt。needs-user 下与 pending 对象同域的明确流程纠正保持在原 Task，不再因文本较长自动新开 Task。

系统后台窗口的授予与完成回告时机仍受 iOS 调度限制；未接入 APNs，也不为运行中第二次长按侧键无法再次输入新增规避方案。附件 background URLSession / pending submission 的 post-fix 自动化回归已覆盖，但不同锁屏时机与网络条件仍应在目标设备上做发布前抽样，不把单测通过写成所有平台条件都成立。具体行为和安全边界见 `ARCHITECTURE.md`。

## 3. Observation Mode

Observation 当前不是计划项，而是已存在的产品代码。

已经实现：

- Home 入口和全屏 Observation UI；
- 会议 / 屏幕 / 影音 / 综合 / 自定 preset；
- 屏幕、周围麦克风、手机声音 source；
- iOS 27 ScreenCaptureKit；
- SpeechAnalyzer / SpeechTranscriber；
- Vision OCR；
- screen change sampling + VLM understanding；
- 周围声音/手机声音 echo fusion；
- 本机 ObservationJournal；
- Host 独立 ObservationService + `.observations.sqlite3`；
- periodic checkpoint summary；
- final summary；
- 基于 record 的问答；
- pause/resume/end/retry/delete；
- share；
- 存入 Tasks History；
- Tasks History 中重新查看观察时间线。

Observation 与普通 Task Planner/Tool Runtime 保持独立。

## 4. Host HTTP

真实 HTTP serving path：

```text
run_host
→ create_server
→ FlowerollHTTPServer
→ Uvicorn
→ FastAPI routers
→ Pydantic wire contracts
→ HostApp
```

旧手写 `BaseHTTPRequestHandler` routing 已不是当前实现主体。

Pydantic 已覆盖主要顶层 request/response；动态 Trace/Provider/material payload 中仍保留部分 `dict[str, Any]` / `Any`，当前不追求无意义的 100% model 化。

## 5. Model / Memory

- Planner 使用 OpenAI-compatible adapter；具体 Provider 由运行配置决定。Kimi K3 的当前默认逐步规划配置显式使用 `reasoning_effort=low`，可通过运行配置提高。
- Mem0 作为跨 Task 用户长期记忆层接入 `TaskRuntime`。
- Memory 不拥有 Task truth；SQLite Runtime 仍是执行真相。
- Capability working set 有界，必要时 progressive discovery。
- 当前没有引入 LiteLLM；等多 Provider routing/fallback/cost 真的变复杂再评估。

## 6. MCP

当前自研 MCP driver/worker 仍然使用。

没有迁官方 MCP Python SDK，因为目前协议/transport 维护量尚未成为主要痛点。未来如果兼容和升级成本明显上升，再做渐进迁移。

## 7. 图片 / 文档

`image.inspect` / `image.transform` 是真实用户能力，不是 Rive 残留。

当前还有：

- image OCR；
- PDF text/OCR/scan/merge/select；
- DOCX inspect/generate；
- Task file/Artifact；
- Files export；
- Photos add-only save。

后续可以用成熟库替换普通 transform 等底层实现，但 semantic contract、lineage、hash/readback 和 verifier 不应丢失。

## 8. 小卷角色

Home `idle/listening` 当前真实实现是 approved sprite + 独立 eyes/listening signal，不是 Rive body。

统一展示入口为 `FlowerollPresentationView`，不以动画库命名。

视觉当前事实见 `DESIGN.md`。

## 9. Developer Observability

当前已有：

- Runtime Trace；
- Planner capture；
- token / latency / retry evidence；
- Host developer read model/API；
- 本机开发观察台可在 Task 与 Observation 两条 lifecycle 间切换，Observation 直接只读独立 SQLite，显示来源证据、时间线、屏幕理解、Checkpoint/Final Summary 与分析错误；
- iOS Settings → Developer Mode → Agent 调试。

暂不接 DeepEval。先使用现有 deterministic regression、真实 trace 和人工/真机验收。

## 10. 文档体系

当前文档已收敛，不再使用 `docs/current/`。

当前核心：

1. `ARCHITECTURE.md`
2. `PRODUCT.md`
3. `CAPABILITIES.md`
4. `DESIGN.md`
5. `DEVELOPMENT.md`
6. `STATUS.md`

旧治理与真实设备历史材料已移出当前发布树，只保留私有归档。

## 11. 当前主要工程维护点

优先级：

1. 保持新文档和真实源码同步；
2. iOS 已按 UI、Policy、Materials、Presentation、Schedule 分区；后续聚焦仍较大的 `Home/HomeView.swift`、`RuntimeTaskStore.swift` 与 `storage.py`，不拆散状态/事务 owner；
3. 继续收敛 FastAPI/Pydantic 边界，避免两套 HTTP 语义；
4. commodity infrastructure 尽量迁成熟方案，但只在真实维护成本存在时迁；
5. 保住 Task Runtime / verification / recovery / Observation 等已经成立的产品语义；
6. 新功能优先补真实用户结果，而不是继续增加通用框架。

## 12. 当前不做

- 不整体迁 TCA；
- 不整体迁 Temporal/LangGraph；
- 不强迁官方 MCP SDK；
- 不接 DeepEval；
- 不一次性重写 Storage ORM；
- 不把 Observation 强行塞进 Task Planner；
- 不恢复旧 Auditor/Coordinator 文档体系作为活状态。
