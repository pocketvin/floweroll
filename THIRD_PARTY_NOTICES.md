# 第三方组件与素材

依赖安装遵循各自的上游许可与服务条款；本项目的品牌声明不覆盖第三方权利。以下为直接依赖摘要，不将它冒充完整法律审计或 SBOM。完整解析版本与哈希见 requirements.lock。

| 组件 | 固定版本 | 安装包元数据中的许可 |
| --- | --- | --- |
| mem0ai | 2.0.20 | Apache-2.0 |
| fastapi | 0.141.1 | MIT |
| pydantic | 2.13.5 | MIT |
| uvicorn | 0.53.0 | BSD-3-Clause |
| httpx | 0.28.1 | BSD License |
| Pillow | 12.3.0 | MIT-CMU |
| langgraph | 1.2.11 | MIT |
| react / react-dom（开发观察台） | 19.3.0 | MIT |
| @xyflow/react（开发观察台） | 12.11.6 | MIT |
| elkjs（开发观察台布局） | 0.12.0 | EPL-2.0 OR GPL-3.0-or-later |
| vite（开发构建） | 8.3.0 | MIT |
| @playwright/test（浏览器验收） | 1.63.0 | Apache-2.0 |

RiveRuntime 6.24.0 通过 `ios/Packages/RiveRuntime/Package.swift` 引用官方发布的二进制与固定 checksum；本地 manifest 不包含 SDK 源码。上游：https://github.com/rive-app/rive-ios/tree/6.24.0 。

开发观察台是单独环境：Langfuse、OpenTelemetry 与 jsonschema 的版本在 `dev/observability/requirements.txt`；Docker 服务按 `compose.yaml` 上游镜像及许可运行。它们不被复制到发布快照，也不属于 Host 的基础 Python 环境。

文档扫描测试的第三方照片来源与 MIT 原文保留在 `host/tests/fixtures/document_quality/real_camera/SOURCES.md` 和同目录 `LICENSE-*` 文件中。其作者归属不得被品牌改名覆盖。

`host/tests/fixtures/docx` 等项目自制 fixture 不是用户的私人文件；真实任务材料、截图、转写和凭据只保留在私人运行目录。

Gitleaks 是外部开发校验工具。下载脚本固定官方 release 与 SHA-256，不将扫描器可执行文件纳入 Git。上游：https://github.com/gitleaks/gitleaks 。
