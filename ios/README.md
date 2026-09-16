# 花卷 iOS

使用 `Floweroll.xcodeproj` / `Floweroll` Scheme。App 展示名称为“花卷”，助手角色为“小卷”。

`Floweroll/App` 包含 Home、Tasks、Settings、材料、原生执行、系统入口和观察模式；`Floweroll/Shared` 包含主题相关共享资源与 ActivityAttributes；`Floweroll/LiveActivity` 是实时活动扩展；`FlowerollTests` 为 XCTest。

当前 Home 使用 sprite 与独立眼睛，统一入口为 `FlowerollPresentationView`。项目中保留的 Rive 资源有独立契约测试，不应把“引入 Rive”描述成当前 Home 的实际渲染方式。

## 构建与签名

先配置 `DEVELOPER_DIR` / `xcode-select` 指向 Xcode 27。复制 `Config/Local.xcconfig.example` 为 `Config/Local.xcconfig` 并填写自己的 Team；本地签名文件禁止提交。

```bash
cd /path/to/floweroll
scripts/verify_ios_regression.sh build
scripts/verify_ios_regression.sh unit
```

App 代码按 `Shell/Home/Tasks/Settings/Schedule/Developer` 分区；客户端的 Policy、Materials 和 Presentation 保持在 `RuntimeClient` 对应子目录。`ContentView` 只组合界面，`RuntimeTaskStore` 仍是唯一前台状态 owner。

`project.yml` 和 `.xcodeproj` 必须保持一致。测试脚本使用模拟器租约，不覆盖其他任务。可通过 `IOS_SIMULATOR_ID` 显式选择设备；真实设备标识由 `FLOWEROLL_DEVICE_UDID` 提供。

当前最低部署目标为 iOS 27.0（以 `project.yml` 和 Xcode 工程为准），完整观察模式也需要 iOS 27；真实系统能力须另做真机验收。实时活动只保留本地方案，不启用 Push Notifications capability。

详见 `../docs/DEVELOPMENT.md` 与 `../docs/ARCHITECTURE.md`。
