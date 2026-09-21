# 花卷 / floweroll

花卷是一个 iOS 个人执行 Agent，**小卷**是其中的助手角色。

它将任务的持久状态和执行调度放在 Host，把手机作为可信的系统能力执行端与交互端。另有独立的观察模式，用于记录用户明确选择的声音和屏幕信息、整理纪要与问答。

## 核心架构

<p align="center">
  <img src="docs/assets/floweroll-architecture.svg" alt="Floweroll 核心架构：iPhone → Host Runtime → LangGraph Planner → Capability & Execution → Verification / Readback，并展示 SQLite、Mem0、模型、iOS 原生能力、外部 Provider、材料工具以及 retry / recovery / re-plan 闭环。" width="100%">
</p>

**主任务链路如上：LangGraph 负责 Planner 内部决策图；Floweroll Runtime 负责 Task / Action / Attempt、授权、verification、recovery 与 SQLite durable truth。Observation Mode 是独立 lifecycle，单独放在下节，不和 Task 状态机画在一张图里。**

## 两条真实工作链路

### Task Mode：一个任务怎样真正跑完

花卷不是把一整段聊天一直交给模型。任务先持久化，再逐步规划、执行、验证和恢复：

```text
用户在 iPhone 提交目标 / 附件 / 后续补充
        ↓
经过认证的 HTTPS
        ↓
FastAPI + Pydantic Host API
        ↓
SQLite 先持久化 Task / UserTurn / Thread
        ↓
RuntimeSupervisor 唤醒 TaskRuntime
        ↓
构造有界 Planner Context
  ├─ 当前 Task/Thread 真相
  ├─ 已验证 Observation / Artifact
  ├─ 必要的历史 referent
  ├─ Mem0 相关长期记忆
  └─ 当前相关的 semantic capabilities
        ↓
LangGraph Planner Graph
  ├─ Context Build / Evidence Compact
  ├─ Capability Selection / Discovery
  └─ Recovery Context
        ↓
OpenAI-compatible model call
        ↓
结构化 PlannerDecision
        ↓
Action 先持久化
        ↓
需要破坏性确认时：exact target / revision → binding-aware ACTION_INPUT
        ↓
用户确认后才创建 Attempt；无需确认的 Action 直接进入 Attempt
        ↓
CapabilityRegistry 解析 semantic capability
        ↓
Adapter / Source
  ├─ MCPExecutionWorker
  │    ├─ 高德 Amap MCP
  │    ├─ Exa Search MCP
  │    ├─ Context7 MCP（可选）
  │    └─ 环境配置的其他 MCP server
  ├─ FunctionExecutionWorker
  │    ├─ 飞猪 FlyAI managed CLI
  │    ├─ 高德 WebService
  │    ├─ public HTTP
  │    └─ Host 本地文件 / 图片 / 文档 / Mac helper
  └─ iPhone DeviceRuntimeWorker
       ├─ Calendar / Reminder / Contacts / Alarm
       ├─ Location / Notification
       └─ 其他 Apple 原生能力
        ↓
真实 Provider / 系统结果
        ↓
verification / readback / reconciliation
  ├─ 成功：保存 Observation / Artifact / Trace
  ├─ 可纠正：把错误交还 Planner 重规划
  ├─ 瞬时失败：按策略等待/重试
  └─ 结果不确定：先对账，禁止盲目重复副作用
        ↓
更新 durable TaskState
        ↓
仍有下一步 → 再进入 Planner
完成 / 需要用户 / 失败 / 取消 → 生成 read model / Timeline
        ↓
SSE / 普通读取同步回 iPhone
```

关键原则是：**Planner 负责决定下一步，但不拥有任务真相；Source 负责真实执行，但不能自己宣布整个 Task 完成。** Task 正确性最终由 durable state、验证结果和恢复逻辑共同保证。

### Observation Mode：陪用户看、听、记、整理

观察模式独立于任务执行：

```text
用户选择来源并授权
→ iOS 屏幕 / 麦克风 / 手机音频采集
→ 本机转写、OCR、来源区分与本地日志
→ Host ObservationService / 独立 SQLite
→ 分段总结、最终纪要、基于记录的问答
```

被观察的屏幕与语音只作为数据，不自动获得工具执行权限。

## 当前能力来源

Planner 看到的是稳定的 **semantic capability**，而不是 Provider 自己的 Tool 名。底层来源可以替换，但 Action / Attempt / verification / recovery 仍走同一套 Runtime。

| 来源 | 当前接法 | 暴露给 Planner 的例子 | 说明 |
| --- | --- | --- | --- |
| 高德地图 | **Amap MCP** | `geocode.resolve`、`weather.query`、`places.search`、`places.search_nearby`、`routes.walk`、`routes.drive`、`routes.transit`、`routes.distance` | 高德原始 `maps_*` Tool 不直接进入全局能力 namespace |
| 高德坐标转换 | 官方 **Amap WebService** | `coords.convert` | iPhone/GPS 的 WGS84 先转 GCJ-02，再进入高德附近搜索/路线链路 |
| 飞猪酒店 | **FlyAI managed CLI**（当前固定 `@fly-ai/flyai-cli 1.0.16`） | `travel.hotel.search` | 当前不是 MCP；只查询真实酒店候选、报价和飞猪/Fliggy 跳转链接，不代表已经预订 |
| 公网搜索 | **Exa MCP** | `web.search` | Provider discovery 失败时不向 Planner 假装能力 ready |
| 开发文档 | **Context7 MCP**（显式启用） | 文档查询 | 默认不强制启用 |
| 额外 MCP | 环境配置的 MCP catalog | discovery 后映射出的 semantic capability | 只有 discovery 成功且完成 semantic mapping 才进入 Registry |
| iPhone 原生 | EventKit / Contacts / AlarmKit / CoreLocation / Notifications 等 | `calendar.*`、`reminder.*`、`contacts.*`、`alarm.*`、`location.current` | 由 iPhone 执行并读回系统真实状态 |
| Host 本地能力 | Python / Apple Framework helper / bounded HTTP | PDF、OCR、图片、DOCX、文件、确定性计算等 | Planner 不获得任意 Shell |

### 高德 + 飞猪的一条真实组合链路

例如用户说：**“帮我找西湖附近明晚 500 元以内、评价好一点的酒店。”**

```text
用户目标
  ↓
TaskRuntime 把 travel.hotel.search / 地图能力放进有界工作集
  ↓
Planner 产生 travel.hotel.search
  ↓
FunctionToolAdapter → FunctionExecutionWorker
  ↓
FlyAIHotelTools → @fly-ai/flyai-cli search-hotel
  ↓
飞猪返回酒店候选 / 当前报价 / handoff URL
  ↓
Runtime 验证并保存结果
  ↓
如果需要证明“离西湖近”
  ↓
Planner 对 shortlist 调用高德 geocode / places / routes.distance
  ↓
MCPReadToolAdapter → MCPExecutionWorker → Amap MCP
  ↓
用真实 POI / 距离 / 路线结果独立核验
  ↓
Planner 汇总最终建议
  ↓
Timeline / Structured Result → iPhone
```

这里有两个刻意的边界：

- `max_price=500` 只是预算上限，代码不会因此自动变成“最低价优先”；普通酒店查询默认优先质量/口碑，只有用户明确说“最便宜”才使用 `price_asc`。
- FlyAI 的 `poi_name` / `distance_asc` 不能单独证明真实地理距离；需要高德路线或距离能力再次核对。

## 当前实现

Task / Action / Attempt / Observation / Trace 持久化，任务中途补充与取消，来源明确的能力发现，附件预上传、系统托管后台续传与断点对账，PDF/OCR、图片与 DOCX 处理，以及日历、提醒事项、联系人、闹钟、定位和本地通知的原生执行与核验。

App 内用户启动的长任务由 `BGContinuedProcessingTask` 持有 execution/presentation window；Action Button / Siri / Shortcut 等系统入口使用 `LongRunningIntent`；附件字节传输独立交给 background `URLSession`，`BGProcessingTask` 只做机会式恢复。三个通道都不能替代 Host durable truth。

Planner 支持 OpenAI-compatible 接口，并对复杂任务做有界 evidence compaction、capability discovery 收敛与 provider-specific reasoning 配置；Kimi K3 的逐步 Planner 默认使用低 reasoning effort，避免把一次“下一步决策”变成长时间生成。Mem0 用作辅助长期记忆，不替代任务数据库。

需要 destructive side effect 的 capability 由真实 Adapter 声明 `predispatch_confirmation`：Planner 只规划语义 Action，ExecutionRuntime 在创建 Attempt 前生成绑定 exact identity / revision 的 `ACTION_INPUT`。开发者工具可以查看真实请求上下文、能力选择、Provider/Tool、响应、验证结果与耗时。

## 技术栈与工程选择

花卷尽量把**产品语义、状态机、verification/recovery**留在自己的代码里，把 HTTP、Schema、Memory、系统能力等通用基础设施交给成熟框架。

### Host / Agent Runtime

| 技术 | 当前作用 |
| --- | --- |
| **Python 3.12** | Host Runtime、Planner orchestration、Capability、材料处理与 Provider 集成 |
| **FastAPI 0.141.1** | Host HTTP API、路由、错误边界和 OpenAPI；旧手写 HTTP routing 已不是主路径 |
| **Pydantic 2.13.5** | 主要 request/response 与 wire contract 校验，避免大量手写 JSON guard |
| **Uvicorn 0.53.0** | FastAPI 的实际 serving / lifecycle |
| **SQLite** | Task / Action / Attempt / Observation / Trace / Timeline 等 durable truth；不是普通 UI cache |
| **Mem0 2.0.20** | 跨 Task 长期记忆辅助；只把相关 memory 投影进 Planner Context，不拥有 Task truth |
| **HTTPX 0.28.1** | Mem0 等受控 HTTP client 路径 |
| **LangGraph 1.2.11** | **Planner 内部的真实 `StateGraph` orchestration**：Memory、Context Build、Evidence Compact、Capability Selection、模型调用、恢复分支与契约校验；不拥有 Task durable truth |
| **自研 Execution Runtime** | Action/Attempt、幂等、retry/wait、UNKNOWN reconciliation、verification/readback |
| **MCP + managed CLI + bounded HTTP** | 统一接入高德、Exa、Context7、飞猪及额外 Provider，同时保持 semantic capability namespace |

这里采用的是**“LangGraph 管 Planner，Floweroll Runtime 管 durable execution”**：Planner 已真实迁入 LangGraph `StateGraph`，但 Task / Action / Attempt、授权、verification、recovery 和 SQLite durable truth 仍由现有 Runtime 拥有。没有把整套 Runtime 再迁进 Temporal、LangGraph 或 TCA，避免产生第二套状态机。

### iOS / Apple 平台

| 技术 | 当前作用 |
| --- | --- |
| **Swift 6 + SwiftUI + Observation** | App Shell、Home、Tasks、Settings、Observable state 与严格并发模型 |
| **ActivityKit + WidgetKit** | Live Activity / Dynamic Island；当前冻结为本地 ActivityKit 方案 |
| **AlarmKit** | 小卷原生闹钟 create/query/update/pause/resume/cancel 与系统状态读回 |
| **EventKit** | Calendar / Reminder 读取、写入、更新、删除和 readback |
| **Contacts / ContactsUI** | 联系人查询、创建、修改及权限边界 |
| **CoreLocation** | 一次性当前位置与权限状态；不把定位历史当默认产品数据 |
| **UserNotifications + BackgroundTasks** | 用户可见通知、`BGContinuedProcessingTask` 长执行窗口与 `BGProcessingTask` 补偿恢复 |
| **AppIntents** | Action Button / 系统入口，把自然语言任务送入同一 durable Runtime |
| **CryptoKit + Security/Keychain** | hash/identity、Host pairing token 和本地 secret storage |

### 观察、媒体与材料

| 技术 | 当前作用 |
| --- | --- |
| **ScreenCaptureKit** | iOS 27 观察模式的屏幕/系统音频采集 |
| **SpeechAnalyzer / SpeechTranscriber** | 设备侧实时语音转写 |
| **Vision** | OCR 与屏幕文字识别 |
| **AVFoundation / AVFAudio** | 麦克风、音频流和格式处理 |
| **PDFKit** | PDF 预览与部分材料读取 |
| **PhotosUI / Photos** | PhotosPicker 与经过用户动作确认的照片保存 |
| **QuickLook** | 文件/Artifact 原生预览 |
| **CoreImage / ImageIO** | 图片处理、编码、扫描增强等底层媒体路径 |
| **RiveRuntime 6.24.0** | 小卷 IP 的动画资源/runtime 契约；当前 Home idle/listening 主体仍以 approved sprite 为实际 owner |

### 可观测性与质量门禁

产品 Host 不依赖可观测性平台才能执行任务。开发观察层是**隔离 sidecar**：

- **Langfuse 4.15.2 + OpenTelemetry / OTLP**：消费现有 Planner capture / Runtime Trace，查看真实 Prompt、Context、Tool、Provider 响应和耗时；不成为第二套 Task truth；
- **本机 Observation 面板**：直接只读独立 Observation SQLite，查看来源证据、screen/transcript 时间线、屏幕理解、Checkpoint/Final Summary 和分析错误；原始截图永不通过观察台 API 返回；
- **XCTest + Python `unittest`**：确定性回归与 contract 测试；
- **Gitleaks**：公开源码和 Git 历史 secret 扫描，并带阳性/阴性控制；
- **Pillow**：开发期视觉资源 hash / alpha / 图层重组校验，不进入生产 Host；
- **uv + hash-locked requirements**：Python 3.12 环境与可复现依赖安装；
- **XcodeGen `project.yml`**：声明 iOS target / dependency / build settings，并与提交的 `.xcodeproj` 保持一致。

## 快速开始：Host

完整能力当前以 **macOS + Python 3.12** 为基线；OCR、PDF 和部分图片处理使用 Apple Framework，不能把 Linux 上的有限测试当成完整能力验证。

```bash
cd /path/to/floweroll
uv venv .venv --python 3.12
uv pip install --python .venv/bin/python --require-hashes -r host/requirements.lock
cp .env.example .env
# 在本机编辑 .env，配置 Host 配对 token、Planner 地址、模型 Key 与 MEM0_API_KEY。
scripts/run_host.sh
```

默认监听 `127.0.0.1:8765`。真实 iPhone 通过你控制的 HTTPS 入口连接，设置中填入同一个 Host token。不要直接将无认证的 loopback 服务暴露到互联网。

外部能力按当前真实来源分别就绪：

- 高德 MCP / WebService：配置 `AMAP_MAPS_API_KEY`（也可由 Host 的 macOS Keychain secret store 提供）；
- 飞猪酒店：配置 `FLYAI_API_KEY`，并确保官方 `@fly-ai/flyai-cli` **1.0.16** 可用；默认查找项目私有 provider-cli 目录和 `PATH`，也可用 `FLOWEROLL_FLYAI_CLI` 指向固定可执行文件；
- Context7：设置 `FLOWEROLL_ENABLE_CONTEXT7=1` 后才主动注册；
- 额外 MCP：通过 `FLOWEROLL_MCP_SERVERS_JSON` 配置，只有 discovery 与 semantic mapping 成功后才会进入 Registry。

没有有效模型、Key、CLI、OAuth 或 Provider discovery 时，对应能力会保持 unavailable/deferred，不用 mock 冒充成功；配置变量说明见 [开发指南](docs/DEVELOPMENT.md)。

## iOS

工程：`ios/Floweroll.xcodeproj`，Scheme：`Floweroll`。

当前 `ios/project.yml` 与 Xcode 工程的最低部署目标均为 iOS 27.0，全量编译使用 Xcode 27；此候选不宣称支持安装到 iOS 26。签名配置与设备标识不写入公开工程。

```bash
cd /path/to/floweroll
cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig
# 填入自己的 DEVELOPMENT_TEAM，在 Xcode 中配置对应 App / 扩展的签名。
scripts/verify_ios_regression.sh build
```

App identity 为 `com.maxenceyu.floweroll`，实时活动扩展为 `.liveactivity`。其他开发者需要在工程与 `ios/project.yml` 中使用自己可签名的 Bundle ID。

## 验证

```bash
cd /path/to/floweroll
uv pip install --python .venv/bin/python --require-hashes -r dev/requirements.lock
python3 scripts/verify_repository.py
python3 scripts/fetch_gitleaks.py
python3 scripts/verify_secrets.py
.venv/bin/python scripts/verify_floweroll_ip.py
scripts/verify_host_regression.sh full
scripts/verify_ios_regression.sh runtime
scripts/verify_ios_regression.sh unit
scripts/verify_ios_regression.sh build
```

Host 回归使用确定性测试，不要求真实模型 Key。资源检查同时检查 PNG 身份、透明通道和图层重组；XCTest 另验证 Rive 文件仍能按已定义的 artboard/state machine 加载。

## 明确边界

灵动岛目前冻结在本地 ActivityKit 方案，不具备 Host → APNs 的远程更新链路。后台挂起时不能保证动画或状态持续刷新，动画停止不能被解释为任务失败。

原生权限、后台调度、AlarmKit、系统音频和屏幕捕获仍须在真实设备上验证。当前开发候选已对 AlarmKit 配置替换/读回、提醒 create→query→remove→query、取消恢复和复杂 Task 后台闭环做过真机验收，但这不等于所有设备、系统调度时机或权限状态都自动成立；编译成功和单元测试通过仍不能替代目标设备验收。

## 目录与文档

| 目录 | 内容 |
| --- | --- |
| `ios/` | App、原生执行器、观察采集、Live Activity、XCTest |
| `host/` | 持久运行时、模型/工具适配、材料与观察服务 |
| `shared/` | 跨端契约 |
| `assets/floweroll/` | 小卷视觉资源与校验清单 |
| `scripts/` | 启动、测试、资源校验与发布快照工具 |
| `dev/` | 可选的本机观察台与开发依赖 |
| `docs/` | 当前架构、产品、能力、设计、开发及发布说明 |

[架构](docs/ARCHITECTURE.md) · [产品](docs/PRODUCT.md) · [能力](docs/CAPABILITIES.md) · [设计](docs/DESIGN.md) · [开发](docs/DEVELOPMENT.md) · [发布](docs/PUBLICATION.md)

## 数据与许可

任务、联系人、日程、截图、转写、完整 Prompt 和 API 凭据都不应进入 Git。默认忽略运行数据与本地配置。观察模式使用前应取得被记录者的同意，第三方 AI/Memory 服务的数据边界见 [隐私说明](docs/PRIVACY.md)。

当前是发布候选源码，**尚未指定开源许可证**，不宣称 MIT 或 Apache-2.0 授权。原始代码与小卷品牌资产的授权须由所有者在公开前决定；第三方素材继续遵循随附许可，见 `LICENSE`、`ASSETS-LICENSE.md` 和 `THIRD_PARTY_NOTICES.md`。
