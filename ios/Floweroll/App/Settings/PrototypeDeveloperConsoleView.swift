import AVFAudio
import AVFoundation
import ContactsUI
import SwiftUI
import UserNotifications


private struct PrototypeDeveloperConsoleView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var locationPermission = LocationPermissionModel()
    @State private var permissionText = "未检查"
    @State private var statusText = "待命"
    @State private var lastError: String?

    var body: some View {
        Form {
            Section("Floweroll / 小卷") {
                LabeledContent("当前状态", value: statusText)
                LabeledContent("麦克风权限", value: permissionText)
                Text("保留旧开发期控制能力；这里不是正式产品页面。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("首次准备") {
                Button("请求麦克风权限") {
                    Task {
                        let granted = await AVAudioApplication.requestRecordPermission()
                        permissionText = granted ? "已允许" : "未允许"
                    }
                }

                LabeledContent("定位权限", value: locationPermission.statusLabel)
                if locationPermission.canRequestInApp {
                    Button {
                        locationPermission.requestWhenInUse()
                    } label: {
                        Label(
                            locationPermission.isRequesting ? "正在请求定位权限…" : "请求定位权限",
                            systemImage: "location.fill"
                        )
                    }
                    .disabled(locationPermission.isRequesting)
                } else if locationPermission.canRequestBackgroundAccess {
                    Button {
                        locationPermission.requestBackgroundAccess()
                    } label: {
                        Label(
                            locationPermission.isRequesting ? "正在请求后台定位…" : "允许后台定位",
                            systemImage: "location.circle.fill"
                        )
                    }
                    .disabled(locationPermission.isRequesting)
                } else if locationPermission.canOpenSettings {
                    Button {
                        locationPermission.openSystemSettings()
                    } label: {
                        Label("打开系统设置开启定位", systemImage: "gearshape")
                    }
                }

                if let message = locationPermission.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("后台定位只用于你明确交代且确实需要当前位置的任务；每次只读取当前结果，不持续跟踪、不保存位置历史。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("录音验证") {
                Button("前台开始监听") {
                    run {
                        try await AudioCaptureService.shared.start()
                        statusText = "Listening"
                    }
                }

                Button("停止监听") {
                    run {
                        AudioCaptureService.shared.stop()
                        statusText = "已停止监听"
                    }
                }
            }

            if let lastError {
                Section("最近错误") {
                    Text(lastError)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("开发工具")
        .task {
            refreshPermission()
            locationPermission.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                locationPermission.refresh()
            }
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                lastError = nil
                try await operation()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func refreshPermission() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            permissionText = "已允许"
        case .denied:
            permissionText = "已拒绝"
        case .undetermined:
            permissionText = "尚未请求"
        @unknown default:
            permissionText = "未知"
        }
    }
}
