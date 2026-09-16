import AVFAudio
import AVFoundation
import ContactsUI
import SwiftUI
import UserNotifications


private enum SettingsSimplePermissionState: Equatable {
    case notDetermined
    case allowed
    case provisional
    case denied
    case restricted
    case unknown

    var label: String {
        switch self {
        case .notDetermined: return "尚未请求"
        case .allowed: return "已允许"
        case .provisional: return "临时允许"
        case .denied: return "已拒绝"
        case .restricted: return "受系统限制"
        case .unknown: return "未知"
        }
    }

    var canRequest: Bool { self == .notDetermined }
    var canOpenSettings: Bool { self == .denied }
}

struct SettingsPermissionSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var locationPermission = LocationPermissionModel()
    @State private var reminderPermission = ReminderPermissionModel()
    @State private var calendarPermission = CalendarPermissionModel()
    @State private var contactsPermission = ContactsPermissionModel()
    @State private var showContactsAccessPicker = false
    @State private var alarmPermission = AlarmPermissionModel()
    @State private var microphonePermission: SettingsSimplePermissionState = .unknown
    @State private var cameraPermission: SettingsSimplePermissionState = .unknown
    @State private var notificationPermission: SettingsSimplePermissionState = .unknown
    @State private var requestingMicrophone = false
    @State private var requestingCamera = false
    @State private var requestingNotifications = false

    var body: some View {
        Section {
            permissionRow(
                title: "麦克风",
                icon: "mic",
                status: microphonePermission.label,
                actionTitle: simpleActionTitle(microphonePermission),
                isRequesting: requestingMicrophone
            ) {
                microphonePermission.canOpenSettings ? openSystemSettings() : requestMicrophone()
            }

            permissionRow(
                title: "相机",
                icon: "camera",
                status: cameraPermission.label,
                actionTitle: simpleActionTitle(cameraPermission),
                isRequesting: requestingCamera
            ) {
                cameraPermission.canOpenSettings ? openSystemSettings() : requestCamera()
            }

            permissionRow(
                title: "通知",
                icon: "bell",
                status: notificationPermission.label,
                actionTitle: simpleActionTitle(notificationPermission),
                isRequesting: requestingNotifications
            ) {
                notificationPermission.canOpenSettings ? openSystemSettings() : requestNotifications()
            }

            permissionRow(
                title: "定位",
                icon: "location",
                status: locationPermission.statusLabel,
                actionTitle: locationPermission.canRequestInApp
                    ? "请求权限"
                    : (locationPermission.canRequestBackgroundAccess
                        ? "允许后台"
                        : (locationPermission.canOpenSettings ? "系统设置" : nil)),
                isRequesting: locationPermission.isRequesting
            ) {
                if locationPermission.canOpenSettings {
                    locationPermission.openSystemSettings()
                } else if locationPermission.canRequestBackgroundAccess {
                    locationPermission.requestBackgroundAccess()
                } else {
                    locationPermission.requestWhenInUse()
                }
            }

            permissionRow(
                title: "提醒事项",
                icon: "checklist",
                status: reminderPermission.statusLabel,
                actionTitle: eventKitActionTitle(status: reminderPermission.statusLabel, allowed: reminderPermission.hasFullAccess),
                isRequesting: reminderPermission.isRequesting
            ) {
                if needsSystemSettings(reminderPermission.statusLabel) {
                    openSystemSettings()
                } else {
                    Task { @MainActor in await reminderPermission.requestFullAccess() }
                }
            }

            permissionRow(
                title: "日历",
                icon: "calendar",
                status: calendarPermission.statusLabel,
                actionTitle: eventKitActionTitle(status: calendarPermission.statusLabel, allowed: calendarPermission.hasFullAccess),
                isRequesting: calendarPermission.isRequesting
            ) {
                if needsSystemSettings(calendarPermission.statusLabel) {
                    openSystemSettings()
                } else {
                    Task { @MainActor in await calendarPermission.requestFullAccess() }
                }
            }

            permissionRow(
                title: "联系人",
                icon: "person.crop.circle",
                status: contactsPermission.statusLabel,
                actionTitle: contactsActionTitle,
                isRequesting: contactsPermission.isRequesting
            ) {
                switch contactsPermission.status {
                case .notDetermined:
                    Task { @MainActor in await contactsPermission.requestAccess() }
                case .limited:
                    showContactsAccessPicker = true
                case .denied:
                    openSystemSettings()
                case .authorized, .restricted, .unknown:
                    break
                }
            }

            permissionRow(
                title: "闹钟",
                icon: "alarm",
                status: alarmPermission.statusLabel,
                actionTitle: alarmPermission.isAuthorized ? nil : (alarmPermission.statusLabel == "已拒绝" ? "系统设置" : "请求权限"),
                isRequesting: alarmPermission.isRequesting
            ) {
                if alarmPermission.statusLabel == "已拒绝" {
                    openSystemSettings()
                } else {
                    Task { @MainActor in await alarmPermission.requestAuthorization() }
                }
            }

            if let message = firstPermissionError {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("权限")
        } footer: {
            Text("权限只在你点击时请求。联系人查找、创建和修改都不会在后台突然弹授权；“部分联系人”可在这里管理小卷能访问和修改的联系人。定位先申请“使用 App 时”；只有你明确点“允许后台”才会升级为“始终”。")
        }
        .task {
            // Permission reads are cheap but numerous. Defer them one turn so
            // entering Settings can render before native authorization state is
            // sampled and published.
            await Task.yield()
            refreshNativePermissionStates()
            await refreshNotificationPermission()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            refreshNativePermissionStates()
            Task { await refreshNotificationPermission() }
        }
        .contactAccessPicker(isPresented: $showContactsAccessPicker) { _ in
            contactsPermission.refresh()
        }
    }

    private var firstPermissionError: String? {
        locationPermission.errorMessage
            ?? reminderPermission.errorMessage
            ?? calendarPermission.errorMessage
            ?? contactsPermission.errorMessage
            ?? alarmPermission.errorMessage
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        icon: String,
        status: String,
        actionTitle: String?,
        isRequesting: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: icon)
            Spacer(minLength: 8)
            Text(status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let actionTitle {
                Button(isRequesting ? "请求中…" : actionTitle, action: action)
                    .buttonStyle(.borderless)
                    .disabled(isRequesting)
            }
        }
    }

    private func simpleActionTitle(_ state: SettingsSimplePermissionState) -> String? {
        if state.canRequest { return "请求权限" }
        if state.canOpenSettings { return "系统设置" }
        return nil
    }

    private func eventKitActionTitle(status: String, allowed: Bool) -> String? {
        if allowed { return nil }
        return needsSystemSettings(status) ? "系统设置" : "请求权限"
    }

    private var contactsActionTitle: String? {
        switch contactsPermission.status {
        case .notDetermined: return "请求权限"
        case .limited: return "管理"
        case .denied: return "系统设置"
        case .authorized, .restricted, .unknown: return nil
        }
    }

    private func needsSystemSettings(_ status: String) -> Bool {
        status == "已拒绝" || status == "受系统限制"
    }

    private func refreshNativePermissionStates() {
        microphonePermission = Self.microphoneState()
        cameraPermission = Self.cameraState()
        locationPermission.refresh()
        reminderPermission.refresh()
        calendarPermission.refresh()
        contactsPermission.refresh()
        alarmPermission.refresh()
    }

    private static func microphoneState() -> SettingsSimplePermissionState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .allowed
        case .denied: return .denied
        case .undetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    private static func cameraState() -> SettingsSimplePermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .allowed
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }

    private func requestMicrophone() {
        guard microphonePermission.canRequest, !requestingMicrophone else { return }
        requestingMicrophone = true
        Task { @MainActor in
            _ = await AVAudioApplication.requestRecordPermission()
            requestingMicrophone = false
            microphonePermission = Self.microphoneState()
        }
    }

    private func requestCamera() {
        guard cameraPermission.canRequest, !requestingCamera else { return }
        requestingCamera = true
        AVCaptureDevice.requestAccess(for: .video) { _ in
            Task { @MainActor in
                requestingCamera = false
                cameraPermission = Self.cameraState()
            }
        }
    }

    private func requestNotifications() {
        guard notificationPermission.canRequest, !requestingNotifications else { return }
        requestingNotifications = true
        Task { @MainActor in
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            requestingNotifications = false
            await refreshNotificationPermission()
        }
    }

    private func refreshNotificationPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: notificationPermission = .notDetermined
        case .denied: notificationPermission = .denied
        case .authorized: notificationPermission = .allowed
        case .provisional, .ephemeral: notificationPermission = .provisional
        @unknown default: notificationPermission = .unknown
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
