# GitHub 发布

## 发布边界

使用经过验证的当前工作区导出新快照，不直接公开本机开发历史。公开树包括 iOS、Host、跨端协议、当前资源、测试、脚本和现行文档，不包含历史派工、个人设备验收资料、运行数据、密钥或 `.git` 历史。

本机旧开发历史和迁移备份只用于恢复。公开快照不是第二个长期开发分支：后续仍在主工程开发，重新导出验证后再更新发布仓库。

## 本地检查与导出

```bash
cd /path/to/floweroll
python3 scripts/verify_repository.py
.venv/bin/python scripts/verify_floweroll_ip.py
scripts/verify_host_regression.sh full
scripts/verify_ios_regression.sh unit
scripts/verify_ios_regression.sh build
python3 scripts/export_public_snapshot.py --output outputs/floweroll-source
```

导出器对明确的源码目录做 allowlist，拒绝符号链接、保留字与危险产物，输出文件 SHA-256 清单并检查导出期间源码未漂移。它不自动 commit、创建远端或 push。

公开前对源码快照和准备发布的 Git 历史分别运行 Gitleaks。封装入口先验证已知测试样本能够被检出、无密钥样本不被误报，再接受扫描结果；失败或超时不能显示为通过。测试样本动态生成在忽略目录里，不是真实凭据。

```bash
python3 scripts/fetch_gitleaks.py
python3 scripts/verify_secrets.py --mode source
# 在已经初始化并提交的发布仓库内检查实际 Git 历史：
python3 scripts/verify_secrets.py --mode git
```

Gitleaks 输出经过脱敏；命名/路径门禁不冒充完整秘密扫描。SHA-256 清单对所有公开源文件建立身份，验证结果必须对应这一份快照，不能在测试后混入未验证修改。

## 许可与个人配置

当前原始代码未指定开源许可证，`LICENSE` 保持保留权利状态；所有者必须明确选择 MIT、Apache-2.0 或其他条款，才能称为开源发布。小卷品牌素材须单独决定授权，第三方 fixture 的原许可不能删除。

App 的 Team、真机 UDID、Host token、模型 Key 和观测数据都不在公开树中。将 `ios/Config/Local.xcconfig.example` 与 `.env.example` 复制成本地配置，不提交填写后的文件。

## CI

自动 CI 负责源码命名/路径检查、确定性 Host 回归、资源检查与 Gitleaks；不能证明真机权限和系统行为。iOS 27 检查只通过手动触发的可信自托管工作流运行，不在任意外部 PR 上执行带设备权限的代码。尚未在远端运行的 workflow 不标成 CI 通过。

## 新 App 身份

花卷使用新的 Bundle ID。不能把旧身份的描述文件硬套给新 App，也不能声称仅改目录即可迁移 iPhone Keychain、系统闹钟和 App 容器。安装与数据接续须在有效签名后单独核验。

已有任务数据库、材料、系统对象不因为发布准备而清空；无法自动迁移的私人状态必须保留并明确说明。核心 task_id / action_id / attempt_id、文件哈希和执行回执不做批量品牌替换。
