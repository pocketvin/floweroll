# Host — 小卷的持久执行侧

Host 是小卷的持久语义大脑。iPhone 可以随时退出前台或重新连接，但 Task 正确性、Planner 状态、Action/Attempt、验证结果和恢复逻辑不能依赖 SwiftUI 页面或一条持续连接。

## 当前结构

```text
FastAPI / Pydantic / Uvicorn
        ↓
HostApp
        ↓
TaskRuntime / TransitionEngine
        ↓
Planner + CapabilityRegistry
        ↓
ExecutionRuntime
   ├─ Function / HTTP / CLI
   ├─ MCP
   └─ iPhone native action
        ↓
verification / reconciliation
        ↓
Observation / Artifact / Trace / Timeline
        ↓
SQLite durable state
```

### HTTP 层

当前 HTTP 路径已经使用 **FastAPI + Pydantic 2 + Uvicorn**：

- `http_app.py`：FastAPI 组合；
- `http_schemas.py`：wire request/response 模型；
- `http_tasks.py`、`http_files.py`、`http_interactions.py` 等：分域路由；
- `http_transport.py`：Uvicorn 生命周期；
- `server.py`：保留 `HostApp` 组合与兼容 `create_server()` 入口。

迁移目标只是替换 HTTP 基础设施，不改变 TaskRuntime、Planner、Storage、Capability 和 iOS wire contract 的产品语义。

### 持久状态

当前使用 SQLite 保存 Task、Action、Attempt、Observation、Trace、Timeline、交互请求等状态。Storage 仍是高维护区域，后续优先做职责拆分，不在一次改动里同时更换 ORM、schema 和业务语义。

### Planner 与 Memory

Planner 使用严格结构化决策契约。Mem0 是跨 Task 的辅助长期记忆层，不替代 SQLite durable TaskState，也不把历史全部常驻注入 Context。

### 能力层（Capability）

Host 通过统一 `CapabilityRegistry` 向 Planner 暴露 semantic capability。执行来源可以是：

- 本地确定性 Function；
- 受控 HTTP/API；
- MCP；
- managed CLI；
- Mac 原生 Framework helper；
- iPhone 原生 executor。

来源类型不改变 Action/Attempt/verification/recovery 的统一语义。

当前能力边界以 `../docs/CAPABILITIES.md` 和实际 Registry 源码为准，不在本 README 维护一份会过期的 Provider readiness 表。

## Python 环境

项目 Host 使用 Python 3.12。直接依赖在 `host/requirements.txt`，可复现安装使用带哈希的 `host/requirements.lock`。

```bash
cd "$(git rev-parse --show-toplevel)"
uv venv .venv --python 3.12
uv pip install --python .venv/bin/python --require-hashes -r host/requirements.lock
```

运行：

```bash
cd "$(git rev-parse --show-toplevel)"
cp .env.example .env
# 编辑本地 .env；启用 Planner 时同时配置 MEM0_API_KEY。
scripts/run_host.sh
```

默认：

- endpoint：`http://127.0.0.1:8765`
- SQLite：`work/floweroll-v1.sqlite3`
- Host workspace：`work/host-capabilities`

启动脚本读取本地 `.env`；直接执行 Python 入口不会自动加载它。密钥必须来自环境变量、Keychain 或已有受控配置读取路径，不写入仓库或普通日志。

## 测试

按改动范围优先使用项目回归入口：

```bash
scripts/verify_host_regression.sh core
scripts/verify_host_regression.sh presentation
scripts/verify_host_regression.sh capabilities
scripts/verify_host_regression.sh materials
scripts/verify_host_regression.sh full
```

也可以运行完整 unittest：

```bash
PYTHONPATH=host .venv/bin/python -m unittest discover -s host/tests -p 'test_*.py' -v
```

不要在 README 写死“当前一共有多少项测试”；测试数量会随源码变化，当前结果应以本次实际运行输出为准。

## 材料与文件

任务文件、上传、生成物和处理回执由 `TaskAssetStore` / material subsystem 管理。大文件保存在文件系统，SQLite 保存 identity、绑定、manifest、work unit 等持久元数据。

普通图片处理、DOCX、扫描/OCR 等是产品能力，不是 UI/Rive 构建脚本。未来可以把通用底层实现替换成成熟库，但要保留 Task lineage、semantic contract、verification 和 Artifact 语义。

## MCP 与 CLI

当前自研 MCP 层规模可控，暂不因“标准化”强迁官方 SDK。只有 transport、协议兼容、升级维护成为真实成本时再迁。

managed CLI 必须使用固定 argv、`shell=False`、有界结构化输出，不向 Planner 暴露任意 Shell。

## 可观测性

Planner capture、Runtime Trace 和 developer observability 用于定位 Prompt / Context / Planning / Tool / Runtime 问题。它们是开发观察层，不是第二套 Task 真相。

开发说明见 `../docs/DEVELOPMENT.md`；当前架构见 `../docs/ARCHITECTURE.md`。
