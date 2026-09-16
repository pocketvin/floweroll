# 花卷 / floweroll — 开发指南

更新：2026-09-15

这份文档是 Coding Agent 的默认施工入口。日常开发优先阅读本文件和任务相关的 `ARCHITECTURE.md / PRODUCT.md / CAPABILITIES.md / DESIGN.md / STATUS.md`，不要递归扫描 `docs/`。

## 1. 项目目录

```text
Floweroll/
├─ ios/          iPhone App、原生执行器、UI、系统入口
├─ host/         durable Runtime、Planner、Capability、HTTP、材料、Observation Host
├─ shared/       跨端协议/契约
├─ assets/       小卷角色/视觉资产
├─ scripts/      回归、构建、验收工具
├─ dev/          开发者可观测性等本地工具
├─ docs/         当前设计、开发与发布说明
├─ work/         构建、日志、开发 Runtime 数据
└─ outputs/      已验证交付物
```

不要为了目录整齐移动已有源码、依赖、构建目录或正在使用的运行数据。

## 2. 开工阅读

### 普通单点修改

读：

1. `AGENTS.md`
2. `docs/DEVELOPMENT.md`
3. 与任务直接相关的一份当前文档和源码

### 跨文件功能、重要故障、第三方集成、迁移、架构调整

先遵循宿主文件规则与项目开工流程。

先确认真实项目目录、dirty tree、目标调用链和验证方式，再修改。

## 3. 历史边界

历史派工、旧候选和实验材料不属于当前发布树。当前事实以源码和本次验证结果为准，不继承旧验收结论。

## 4. 工作区规则

当前仓库可能有大量未提交修改。

- 修改前执行 `git status --short`；
- 保留当前任务无关的 dirty changes；
- 不 `reset --hard`、不 clean、不为了方便 stash 掉其他工作；
- 不创建遗漏未提交内容的“干净 worktree”来冒充当前事实；
- 修改前读真实调用点，不靠旧文档猜；
- 未授权不 push、不发布、不生产部署。

任何密钥、Token、密码、证书不打印到聊天，不写普通日志，不进 Git。

未经用户针对性授权，不读取项目以外的私人目录。

## 5. Host 开发环境

- Python：项目 `.venv`，当前使用 `uv` 管理；
- 直接依赖：`host/requirements.txt`；可复现安装：`host/requirements.lock`（含哈希）；
- HTTP：FastAPI + Pydantic + Uvicorn；
- durable Task state：SQLite；
- 主入口：`host/run_host.py`。

安装已授权依赖优先：

```bash
uv venv .venv --python 3.12
uv pip install --python .venv/bin/python --require-hashes -r host/requirements.lock
cp .env.example .env
# 填写本地配置，启用 Planner 时需要模型 Key 与 MEM0_API_KEY。
scripts/run_host.sh
```

开发/评测工具不要默认塞进 product Host dependency；能放 `dev/` 独立环境就不要扩大运行时依赖面。

## 6. Host 结构

```text
host/floweroll_host/
├─ server.py              HostApp composition
├─ http_transport.py      Uvicorn lifecycle
├─ http_app.py            FastAPI composition/errors
├─ http_schemas.py        Pydantic wire contracts
├─ http_tasks.py
├─ http_interactions.py
├─ http_files.py
├─ http_observations.py
├─ http_developer.py
├─ storage.py
├─ task_runtime.py
├─ execution_runtime.py
├─ runtime_supervisor.py
├─ capability_registry.py
├─ task_assets.py
├─ task_material_tools.py
├─ observation_service.py
└─ ...
```

改 HTTP 时不要顺手改变 Runtime 产品语义；改 Runtime 时也不要顺手改 wire contract，除非任务本身就是协议升级。

## 7. 长后台执行与展示边界

长执行必须按入口选 owner：App 内 Home / Task Detail / Thread Detail 使用普通 `AppIntent` 做短 admission，并在前台用户动作内申请全局 `BGContinuedProcessingTask`；Action Button / Siri / Shortcut 等系统入口使用 `LongRunningIntent`。不要把两套 API 当互相 fallback，也不要让同一 Task 同时进入两套 owner。

当前 iOS 27 已有最小真实复现：App 内 `Button(intent:)` 调用 LongRunningIntent 时，`perform()` 可以进入，但 `performBackgroundTask()` 在 operation closure 开始前报 `PerformIntentError.noContext` / `LNContextErrorDomain 2004`，界面可能显示误导性的 `UnsupportedValueType`。零参数和单 String 参数均相同，因此不要通过改参数数量、JSON envelope 或捕获错误来伪装 App 内 LongRunning 已成立。

- Host durable Runtime 始终拥有 Task truth；BGCPT expiration、LongRunning timeout / interruption 都不等于 Task failed。
- BGCPT ownership 使用独立的 `continuedTaskIDs / continuedOutboxIDs`；通用 `trackedTaskIDs` 只表示 durable recovery eligibility。不要让 BGCPT 从通用 tracking 自动收编 system-entry Task。
- 系统入口 continuation 接手一个 BGCPT Task 前，先移除该 taskID 的 BGCPT ownership，再建立 LongRunning owner；durable recovery tracking 保留。
- BGCPT 必须从真实前台用户动作申请。UIKit `beginBackgroundTask` 仅用于 scheduler admission 的短桥接，不是长期执行方案。
- BGProcessing 是补偿恢复，不是固定间隔调度器。重复刷新先查系统排队请求，不能不断重设 earliestBeginDate。
- 数据传输使用 background URLSession file upload，按 Host offset 和 SHA / receipt 续传验收，不新增附件展示 owner。
- 后台窗口到期只结束对应系统 lease / Swift 等待者；用户主动移除附件才显式取消系统传输。发送取消必须先撤销 outbox 重试资格，再核对可能已发生的 Host admission。
- 不用高频假进度或动画刷新冒充持续业务进展。需要用户权限 / 确认的步骤停在真实交互边界，不能伪装后台完成。
- APNs 远程更新仍暂缓；当前不启用 Push entitlement，不增加 token 注册、provider 或 `.p8` 配置代码。

构建和自动测试不能证明无限后台运行。真机验收必须把 App 内 BGCPT 与系统入口 LongRunningIntent 分开测，并关联 submission/event ID、Host Task/Action/Attempt、BGCPT/LongRunning 系统窗口日志、附件 offset/SHA。旧 BGCPT 30–55 秒观测只能证明旧构建曾被系统回收，不能作为新实现时长承诺；工程目标始终是“durable + 自动恢复”，不是进程无限常驻。

## 附件传输的故障定位

先关联同一附件的系统上传任务、Host `Upload-Offset` 和最终 receipt，不能只看 UI 进度或 `/health`。上传中 Host 应持续保存收到的前缀；网络中断后从 durable offset 继续，不重新发送已确认内容。`didSendBodyData` 仅表示传输进度，不能提前生成 `.uploaded`。

真机验收要记录切到后台的时间、随后多次 Host offset 与最终 SHA，并确保没有调试器保持 App 运行。只能证明“后台收到一部分”时，不写成整份文件后台上传完成。TLS 错误、公网隧道 5xx、普通 HTTP 上传失败均应独立归因；连健康检查不能代替多 MB 传输验证。

若公网出现 `503 / ERR_NGROK_3004`，先与 ngrok agent 的同时间日志关联。该错误不能直接判为 Host 业务失败；本机出现过上传期间 agent 心跳超时、自行拆除隧道的情况。仅在确认此因果链后，通过项目专用配置覆盖 `agent.heartbeat_tolerance`（当前本机为 90 秒，心跳间隔仍为 10 秒），并重新验证完整文件传输；这不会提升实际网络带宽，也不应取消 App 或请求的有限超时。

检查隧道的真实进程 owner。若由 launchd 的 `KeepAlive` 托管，应更新并重启同一服务，不要只终止 PID 后再手动启动第二份 agent。项目覆盖文件放在忽略的 `work/local-runtime/`，原始账户配置与 Token 不复制进源码；公网地址、Host 端口和 iPhone 配对保持不变。

自动回归已覆盖真实 socket 分段送入、请求未结束时 prefix 落盘、主动断连接后的最后缓冲保留、按原身份续传及完整暂存后恢复发布。临时限速代理与合成测试文件仅用于验收，结束后清理，不写入日常 Host 启动配置。

## 8. Host 回归

```bash
scripts/verify_host_regression.sh core
scripts/verify_host_regression.sh presentation
scripts/verify_host_regression.sh capabilities
scripts/verify_host_regression.sh materials
scripts/verify_host_regression.sh full
```

`full` 是集成收尾 gate。Host 树仍在并行变化时，完整回归不能作为稳定 snapshot 证据。

Planner 已迁入 LangGraph；`host.tests.test_planner_graph` 包含真实 StateGraph 调用、上下文投影、单次 HTTP、Runtime 持久退避/重启、预算、过期输入拦截、并发隔离及隐私开关回归，纳入 `core` 和 `full`。独立运行：`PYTHONPATH=host .venv/bin/python -m unittest host.tests.test_planner_graph`。

查看节点执行使用 Planner → Metrics → `graph_steps`；`/v1/developer/observability/status` 的 `planner` 描述当前已加载的引擎。该接口仍需原有 Host 认证和开发者 Header。不要为了看到 Graph 而默认打开外部 LangSmith tracing。离线回放只能证明图路由、请求体变化及契约，不代表真实模型生成质量、供应商时延或 iPhone 端副作用已验收。


## 9. iOS 环境

- Xcode 27：通过 `DEVELOPER_DIR` 或 `xcode-select` 选择；签名 Team 放在未跟踪的 `ios/Config/Local.xcconfig`。
- 平台：iOS only
- 真机：通过本地 `FLOWEROLL_DEVICE_UDID` 指定。
- `CODE_SIGN_STYLE=Automatic`

禁止使用 `-allowProvisioningUpdates`。

固定 Simulator 池：

- `Floweroll-iPhone17Pro-iOS27`
- `Floweroll-iPhone17Pro-iOS27-B`

使用项目 lease；不要杀掉、抹掉、抢占别人的 Simulator，也不要静默换另一个机型作为回归基线。

## 10. iOS 回归

```bash
scripts/verify_ios_regression.sh runtime
scripts/verify_ios_regression.sh unit
scripts/verify_ios_regression.sh build
```

脚本会检查测试期间 Swift/project 是否漂移；source drift 的测试不能作为稳定证据。

以下类型通常需要真实设备才能最终证明：

- AlarmKit；
- Contacts/Photos/Files 权限与真实系统对象；
- Location 权限行为；
- Background execution；
- Live Activity / Dynamic Island；
- ScreenCaptureKit Observation；
- 系统共享和设备音频。

## 11. Observation 开发

Observation Mode 是独立产品 Runtime，不应为了复用 Task 架构而硬塞进 `TaskRuntime`。

相关文件：

```text
ios/Floweroll/App/Observation/
├─ ObservationModels.swift
├─ ObservationCapture.swift
├─ ObservationController.swift
└─ ObservationView.swift

host/floweroll_host/
├─ observation_service.py
└─ http_observations.py
```

开发时要保持：

- explicit consent；
- source 分离；
- 不自动恢复 capture；
- raw evidence 与 AI summary 分离；
- screen/audio 内容只能是数据，不能变成 Tool 指令；
- Host unreachable 时本机 evidence 不丢；
- delete 必须防 late replay 复活；
- 不保存完整录音/视频。

## 12. 成熟方案优先

新增底层能力前先找：

1. Apple Framework / 官方 SDK；
2. 成熟 Python/Swift 库；
3. 官方 API / MCP / CLI；
4. 最后才是自研基础设施。

小卷真正需要自己掌握的是：

- product semantics；
- policy；
- orchestration；
- exact identity；
- verification/readback；
- recovery；
- 用户体验。

已有模块稳定且维护成本不高时，不为了“看起来更现代”强迁框架。

## 13. 不做顺手大改

- FastAPI 改动不同时迁 Storage ORM；
- Storage 拆分不同时改 schema/business semantics；
- 图片底层换库不改变 `image.inspect/image.transform` contract；
- UI 性能修复不顺手改变 Task lifecycle；
- Observation 修复不把它合并进普通 Task Planner；
- Provider adapter 修复不扩大授权范围。

## 14. 当前高维护文件

重点关注：

- `host/floweroll_host/storage.py`：保留事务 owner；后续拆分不能改变原子状态转换。
- `ios/Floweroll/App/RuntimeClient/RuntimeTaskStore.swift`：保留唯一前台状态 owner。
- `ios/Floweroll/App/Home/HomeView.swift`：仍集中持有首页状态，后续按实际维护需要提取组件。

已按职责分区：`Shell/`、`Home/`、`Tasks/`、`Settings/`、`Schedule/`、`Developer/`，以及 `RuntimeClient/Policies/`、`Materials/`、`Presentation/`。交互测试在 `ios/FlowerollTests/Interaction/`，共享测试辅助在 `Support/`；保留原 XCTest 类和方法身份。

目标是职责清楚和可验证，不是机械追求每个文件低于某个行数。

## 15. 测试选择

- parser/schema/helper → focused unit；
- Host Runtime/Storage/Capability → focused + 对应 Host regression；
- iOS state/policy → focused XCTest + runtime；
- 大范围 iOS → unit/build；
- 原生副作用 → deterministic + 必要的 Simulator/real device；
- 跨层 contract → 从真实入口走到真实 readback；
- Observation capture → iOS 27 真机才可证明完整平台行为。

Mock 只能证明代码 contract，不能冒充真实设备/Provider 成功。

## 16. 观察与评测

当前已经有：

- Runtime Trace；
- Planner capture；
- developer observability：Task/Planner trace + 独立 Observation SQLite 只读面板；
- routing corpus；
- Host/iOS regression；
- 历史 acceptance evidence。

暂不接 DeepEval。以后若增加 LLM Judge，让它消费现有 Trace，不取代 unittest/XCTest，也不再造第二套 Runtime truth。

## 17. 文档规则

当前核心文档：

- `docs/ARCHITECTURE.md`
- `docs/PRODUCT.md`
- `docs/CAPABILITIES.md`
- `docs/DESIGN.md`
- `docs/DEVELOPMENT.md`
- `docs/STATUS.md`

没有 `docs/current/`，也没有活跃 `docs/governance/`。

一次性原始日志放在忽略的 `work/`；发布文档只记可复现结论，不复制私人历史。

不要为了“理解项目”递归读取 history/research/evidence。

## 18. 收尾

完成工程任务时说明：

- 改了什么；
- 为什么；
- 跑了什么验证；
- 哪些平台行为仍未真实验证。

不要把未验证写成通过，也不要为一次测试新增永久项目手册。
