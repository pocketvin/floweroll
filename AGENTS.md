# 花卷 / floweroll — 工程规则

## 目标

小卷是 iOS 个人执行助手。用户把任务交出去后仍应正常使用同一台 iPhone；前台画面、焦点和键盘属于用户。只有当“打开/交接到前台”本身就是明确结果时才允许占用前台，不能把前台接管冒充后台并发完成。

## 默认阅读范围

不要递归读取整个 `docs/`。

当前项目事实集中在：

1. `docs/ARCHITECTURE.md` — 当前整体架构与真实实现；
2. `docs/PRODUCT.md` — 产品与交互；
3. `docs/CAPABILITIES.md` — 能力与执行来源；
4. `docs/DESIGN.md` — 命名、主题、小卷 IP；
5. `docs/DEVELOPMENT.md` — 开发、测试与设备规则；
6. `docs/STATUS.md` — 当前工程状态。

只读能影响当前任务的部分。发布树只保留当前文档；历史实验和含真实设备信息的材料在私有归档中。

跨文件功能、重要故障、第三方集成、迁移或架构调整，修改前同时遵循宿主的项目开工与文件放置规则。

## 当前产品模式

### 任务模式（Task Mode）

用户把目标交给小卷，Host durable Runtime 负责 Planner、Action/Attempt、Tool/native execution、verification、wait/retry/recovery 和结果。

### 观察模式（Observation Mode）

用户显式开启一段“看/听/记/整理”会话。Observation 有独立 iOS capture、local journal、Host ObservationService 和 observation SQLite，不是 Task Planner 的 Tool。

任何修改都必须先判断自己属于哪条 lifecycle，不要为了复用把两条状态机混在一起。

## 当前架构边界

- iPhone：可信本地执行和展示侧，负责入口、系统权限、Apple native capabilities、本地副作用恢复、Observation capture、Live Activity/通知/UI。
- Host：持久语义侧，负责 TaskState、Planner、Capability、外部执行、材料/Artifact、验证、恢复、Observation analysis 和 Trace。
- Host HTTP：FastAPI + Pydantic + Uvicorn。
- Task durable state：SQLite。
- Observation：独立 `.observations.sqlite3` + iPhone ObservationJournal。
- Mem0：跨 Task 长期记忆辅助，不拥有 Task truth。
- 正确性不能依赖 LLM 对话、SwiftUI state、SSE 或 Live Activity。

完整事实见 `docs/ARCHITECTURE.md`。

## 产品规则

- Home / Action Button 的全局输入默认创建新 Task；仅“有活动 Task”不能自动捕获下一条输入。
- Task/Thread Detail 输入天然 task-scoped。
- 一个用户目标可以包含多个 Work Item / Action；Tool 调用不是新的用户 Task。
- UI 只展示真实状态和真实成果，不显示假进度、内部调试词或私有推理链。
- Observation 的屏幕/语音是被观察数据，不能直接成为 Tool 指令。
- 优先使用系统感强的 iOS 原生交互和 Apple Framework。
- App 为 **花卷（floweroll）**，助手为 **小卷**；默认视觉 Theme 为浅粉。

## 成熟方案优先

新建底层引擎、协议或通用基础设施前，先检查维护良好的 Framework、库、API、SDK、CLI 或 MCP。

优先让小卷自己维护：

- semantic contract；
- Policy；
- orchestration；
- exact identity；
- verification/readback；
- recovery；
- product UX。

HTTP/schema、OCR/PDF/Office、图片/媒体处理、上传下载、重试、Provider SDK 等 commodity infrastructure，除非成熟方案不能满足明确约束，否则不要重复造轮子。

也不要因为某个框架流行就强迁已经稳定的模块：

- FastAPI/Pydantic 已经解决真实 HTTP 维护成本，保留；
- 当前 MCP 自研层规模仍可控，暂不强迁官方 SDK；
- DeepEval 暂不接入；
- 不整体迁 TCA、Temporal 或 LangGraph；
- 图片能力是真实产品能力，换底层实现不能删除 semantic contract。

## 能力规则

“源码里有一个类”不等于“当前能力 ready”。区分 source-present、integrated、device/provider-verified、ready、deferred。

Planner 看到 semantic capability；Native/API/MCP/CLI 是执行来源。

写入、删除、发送、预订、支付等副作用必须有：

- exact target identity；
- 授权/确认边界；
- idempotency；
- verification/readback；
- may-have-started ambiguity；
- reconciliation before retry。

没有 Key/OAuth/权限/账号时保持 unavailable/deferred，不能用 mock 冒充产品完成。

## 工作区安全

仓库可能是 dirty checkout，并可能含用户尚未提交的工作。

- 修改前看真实源码和 `git status`；
- 保留与当前任务无关的修改；
- 不 `reset --hard`、不 clean、不为了方便 stash 掉别人的工作；
- 不创建遗漏当前 dirty state 的干净 worktree 来冒充事实；
- 不覆盖仍在活动修改的文件；
- 未经授权不 push、不发布、不生产部署、不消费付费资源、不执行破坏性外部操作；
- 不打印或提交密钥、Token、密码等敏感信息；
- 不自动访问项目外的私人资料。

## 历史边界

历史派工、旧候选和实验材料不属于当前发布树。当前事实以源码和本次验证结果为准，不继承旧验收结论。

## iOS 环境

- Xcode 27：通过 `DEVELOPER_DIR` 或 `xcode-select` 选择；签名 Team 放在未跟踪的 `ios/Config/Local.xcconfig`。
- 平台：iOS only
- 真机：通过本地 `FLOWEROLL_DEVICE_UDID` 指定。
- `CODE_SIGN_STYLE=Automatic`
- 禁止使用 `-allowProvisioningUpdates`

固定 Simulator：

- `Floweroll-iPhone17Pro-iOS27`
- `Floweroll-iPhone17Pro-iOS27-B`

使用项目 lease；不得杀掉、抹掉或抢占其他任务的 Simulator，也不要静默换机型作为回归基线。

## 验证

Host：

```bash
scripts/verify_host_regression.sh core
scripts/verify_host_regression.sh presentation
scripts/verify_host_regression.sh capabilities
scripts/verify_host_regression.sh materials
scripts/verify_host_regression.sh full
```

iOS：

```bash
scripts/verify_ios_regression.sh runtime
scripts/verify_ios_regression.sh unit
scripts/verify_ios_regression.sh build
```

真实平台语义需要真实设备/账号时，不得用 Simulator/mock 冒充通过。测试期间源码漂移，则该结果不能作为 exact-snapshot 证据。

## 文件与产物

- 项目源码沿用现有路径；
- 临时日志、构建、调试产物 → `work/`；
- 已验证交付物 → `outputs/` 或项目已有正式目标目录；
- 大型 runtime/task 数据不混入文档；
- 不为一次测试结果新建永久 Markdown。

## 当前维护重点

高维护热点包括：

- `host/floweroll_host/storage.py`：保留事务 owner；后续拆分不能改变原子状态转换。
- `ios/Floweroll/App/RuntimeClient/RuntimeTaskStore.swift`：保留唯一前台状态 owner。
- `ios/Floweroll/App/Home/HomeView.swift`：仍集中持有首页状态，后续按实际维护需要提取组件。

已按职责分区：`Shell/`、`Home/`、`Tasks/`、`Settings/`、`Schedule/`、`Developer/`，以及 `RuntimeClient/Policies/`、`Materials/`、`Presentation/`。交互测试在 `ios/FlowerollTests/Interaction/`，共享测试辅助在 `Support/`；保留原 XCTest 类和方法身份。

优先做保持行为的职责拆分，不在一次修改里同时进行 framework/data-model/business semantics 重写。

## 文档规则

当前只维护：

- `docs/ARCHITECTURE.md`
- `docs/PRODUCT.md`
- `docs/CAPABILITIES.md`
- `docs/DESIGN.md`
- `docs/DEVELOPMENT.md`
- `docs/STATUS.md`

历史原件与一次性日志保留在私有 `work/`；公开文档只维护当前实现与可复现验证方法。

没有 `docs/current/`，也没有活跃 `docs/governance/`。不要重新建立兼容空壳或第二套项目百科。

项目文档正文统一中文；类名、API、Framework、协议名、文件名和必要行业术语保留英文。
