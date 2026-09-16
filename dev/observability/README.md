# 小卷开发观察台

本机主入口：`http://localhost:3034`。Langfuse：`http://localhost:3033`。

工作台在现有只读 sidecar 上展示系统拓扑、单任务执行记录和独立 Observation 会话。关闭浏览器、console 或 Langfuse 不会改变产品 Task/Observation 的状态，不执行模型、工具、重试或任何产品操作。

## 界面

- **任务 / 观察详情优先**：主页面先展示摘要、上下文和按实际开始时间排序的执行记录；时间未知的记录置后，顺序编号不冒充因果关系。
- **拓扑图（按需展开）**：稳定组件、当前源码声明的 HTTP 接口、CapabilitySpec 和 Planner Graph 放在主页面下方的折叠区域；需要时再展开系统拓扑或本次执行图。
- **任务摘要**：跨度、Planner、Action/Attempt、Work Unit、已报告 Token、模型耗时累计、重试。Token 缺失显示未记录；累计模型时长不是墙钟时间。
- **上下文速览 + 常驻请求检查器**：选择 Planner 后，右侧直接查看用户消息、Memory、System Prompt、完整 Context、工具集、原始请求、模型结果、决策与采纳和结构检查。执行记录中的 Planner / 模型步骤可直接切换当前 Planner，不弹覆盖层；上方摘要卡也直接切换右侧标签。重复选择当前调用不会清空已加载详情。请求检查器支持复制当前内容和放大查看；用户首条消息/后续 user turn 以及最终 wire request 中的 system/user message 都可单条复制。原始请求 JSON 不做前端截断，并明确区分完整采集与采集上限省略。
- **检查器**：节点源码文件/symbol、输入输出和关联记录；边的证据类型及两端记录。源码为当前工作区，不冒充历史运行进程。
- 导航、上下文可收起；拓扑默认折叠，不占主页面空间。专注模式有可见的退出按钮，也支持 Esc 或收起拓扑返回，保留当前任务选择。需要时可展开并进入“专注拓扑”。系统拓扑的手动节点位置保存在浏览器 localStorage；本次执行图按开始时间从左到右排列，不允许拖拽改变时间顺序。

布局由 React Flow 提供，ELK 在 Web Worker 中运行。页面不再与布局计算共用主线程。产品 Host、iOS 与 LangGraph 的职责不因界面改变。

## 图与证据的含义

**虚线是源码声明，实线是记录关联，不是自动抓到的所有函数调用。**

源码发现使用 Python AST，不导入或构造 HostApp，不启动其后台 worker。HTTP 路由、静态 CapabilitySpec 和 Graph 声明可自动出现，但不等于正在运行的 Host 已加载或能力 ready。未知动态表达式不能被假装解析；运行记录中出现但源码索引不认识的节点显示“未映射”。

全局调用数限定为最近 60 个任务；Planner 按唯一调用身份计数，工具按执行 Attempt 计数。没有采集的组件显示命中未知，不是零。源码存在或零命中都不能直接判定为死代码。

Task 的 Action 跨度可能包含排队、等待和核验。状态事件、按时间排序以及同属一个 Task，都不自动证明父子调用关系。图例、检查器及“证据范围”保留这种区别。

## 采集与持久化

```text
Task Runtime SQLite + 既有 Planner capture
                 ├─ 只读中文工作台
                 └─ 既有 OTel/Langfuse exporter

Observation SQLite + 新 Observation model snapshots
                 └─ 只读工作台，独立于 Task lifecycle

work-units.sqlite3 + 新 Work Unit attempt snapshots
                 └─ 真实状态、依赖、执行区间及同进程重叠证据
```

`host/floweroll_host/planner_capture.py` 继续使用已有的有界、best-effort 本机写入队列。Planner 历史目录及调用身份不变；新增 operation snapshots 放在：

```text
<snapshot_dir>/operations/observation/<session-id>/<capture-id>.json
<snapshot_dir>/operations/task/<task-id>/<capture-id>.json
```

观察模式在 worker 内绑定 session/runtime DB，再分别记录视觉、分段整理、最终整理和问答模型调用。记录适配器发送前的实际请求、System Prompt hash、响应、usage、计时与错误；`model_validated` 不代表 Session 已采纳该结果。Prompt 仍在既有产品源码，不为展示做行为无关的迁移。

Work Unit 在真正的执行入口记录开始/结束、独立 attempt owner、输入输出及 receipt 是否被接受。使用同一进程、同一父 Action 下的单调计时判断执行区间重叠；旧记录缺少计时时不推断串行/并行。没有修改 work-unit 数据表、claim/lease/finish 事务或重试语义。

**新增采集需要产品 Host 加载更新后的源码才会生效。仅重启 3034 不会热更新手机 Host。** 历史请求不能补录。默认只统计已存在的快照，完整传输/真机界面链路未采集处明确为空。

配置沿用 `work/observability/config.json`：`runtime_db`、`snapshot_dir`、`mode` 和保留/容量限制。`work_units_db` 必须显式指定并与当前 Runtime 身份核对，不按同名文件猜测。当前保留模式、密钥处理和来源边界沿用既有实现；正文只在 `local_full` 模式提供。大请求超过快照容量会明确标记省略，不把截断内容当完整请求。

Exporter 的本地保留清理同时覆盖旧 Planner 和新 operation snapshots；原有已结束 generation 的幂等导出方式保持不变。Observation 模型快照暂不自动复制到 Langfuse。没有新增数据库服务器或图数据库。

## 启动和构建

所有命令在项目目录内执行，正式源码在 `dev/observability/`，日志/临时构建在项目 `work/`。

```sh
uv venv work/observability/venv --python 3.12
uv pip install --python work/observability/venv/bin/python --require-hashes -r dev/observability/requirements.lock
(cd dev/observability/web && npm ci && npm run build)
PYTHONPATH=host:. python3 scripts/floweroll_observability.py serve
```

产物位于 `dev/observability/web/dist/`，由原来的 `console.py` 在 3034 提供。开发依赖位于 `work/observability/venv`，不安装进产品 Host 环境。

现有 Langfuse 生命周期和导出命令不变：

```sh
python3 scripts/floweroll_observability.py status
python3 scripts/floweroll_observability.py watch
```

不要为恢复开发台去重启手机 Host 或隧道。3034 只在 loopback 服务；主界面与 API 同源。iOS 原来的 Agent 调试页和 paired Host Developer API 保留。

## 只读 API

保留旧 Task、Planner call 和 Observation detail API；新增：

```text
GET /api/topology
GET /api/tasks/{task_id}/path
GET /api/observations/{session_id}/path
GET /api/observations/{session_id}/calls/{capture_id}
GET /api/components/{url-encoded-component-id}
```

客户端沿用 `X-Floweroll-Console: 1`。不存在任务 mutation、Tool execute、强制完成或模型调用 API。模型正文按单次调用读取，不塞进全局拓扑。

## 验证

```sh
PYTHONPATH=host:. FLOWEROLL_OBSERVABILITY_CONFIG=/dev/null \
  .venv/bin/python -m unittest host.tests.test_planner_capture \
  host.tests.test_observation_service host.tests.test_work_units host.tests.test_operation_capture

PYTHONPATH=host:. FLOWEROLL_OBSERVABILITY_CONFIG=/dev/null \
  work/observability/venv/bin/python -m unittest \
  dev.observability.test_console dev.observability.test_observability \
  dev.observability.test_observation_projection dev.observability.test_namespace \
  dev.observability.test_topology dev.observability.test_operation_projection

cd dev/observability/web
npm run build
npm run test:e2e
```

每个命令块从项目根目录执行。浏览器用例由 Playwright 启动独立的 3044 测试服务，所有 `/api/` 回应使用固定夹具，不依赖个人 Task ID、运行数据库、3034 服务或模型 Key。未覆盖的 API 和写请求会使测试失败。需要本机安装 Chrome；可通过 `OBSERVATORY_BROWSER_CHANNEL` 选择其他已安装的 Playwright channel。

截图与 JSON 结果统一进入 `work/observability-browser/`。`npm run build` 同时检查产品源码、测试代码和配置；`dist/` 只在本机生成，不进入源码发布包。

浏览器测试证明展示和交互契约，不冒充真实模型或 iPhone 全链路验收；Python 侧的只读 SQLite、命名空间隔离和投影测试仍单独运行。

浏览器测试使用单独的无头 Chrome，不接管用户正在浏览的窗口。覆盖：导航折叠、Task/Observation 切换、上下文展开、源码检查器、搜索、拖拽保持、小窗口画布空间、按模型调用查看真实 Prompt/Response。

Host 采集测试使用被替换的供应商响应及真实本机工作项执行器，不消费付费 API。包括：请求字节一致、并发会话隔离、失败不重试、磁盘采集故障不影响业务、工作项并行计时、已完成工作项不重放。

## 当前限制

- 当前源码拓扑不是已部署构建快照；没有完整 Build Diff 或全仓库静态调用图。
- 尚未完成 iOS → Host → iOS 全链 Trace。不能把 Host 收到回执等同于 Home/Inbox/灵动岛已更新。
- 原生 Action 可展示 Host 侧 dispatch/attempt/result 记录；缺失的设备内部事件不补造。
- Observation 旧记录没有完整模型请求、usage 或时间；不会根据纪要数量推断模型调用量。
- 完整运行图有读取/显示上限，截取情况会标注；零命中不代表无用代码。
- 没有自动改 Prompt、运行模型、评估事实质量、删除代码或修复状态功能。
