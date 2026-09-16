import Combine
import CoreLocation
import UIKit


@MainActor
final class LocationPermissionModel: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var status: CLAuthorizationStatus
    @Published private(set) var accuracyAuthorization: CLAccuracyAuthorization
    @Published private(set) var isRequesting = false
    @Published private(set) var errorMessage: String?

    private let manager: CLLocationManager

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        self.status = manager.authorizationStatus
        self.accuracyAuthorization = manager.accuracyAuthorization
        super.init()
        manager.delegate = self
    }

    var isAuthorized: Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    var hasBackgroundAccess: Bool {
        status == .authorizedAlways
    }

    var canRequestBackgroundAccess: Bool {
        status == .authorizedWhenInUse
    }

    var canRequestInApp: Bool {
        status == .notDetermined
    }

    var canOpenSettings: Bool {
        status == .denied
    }

    var statusLabel: String {
        switch status {
        case .notDetermined:
            return "尚未请求"
        case .restricted:
            return "受系统限制"
        case .denied:
            return "已拒绝"
        case .authorizedAlways:
            return accuracyAuthorization == .fullAccuracy ? "已允许后台（精确位置）" : "已允许后台（大概位置）"
        case .authorizedWhenInUse:
            return accuracyAuthorization == .fullAccuracy ? "仅使用 App 时（精确位置）" : "仅使用 App 时（大概位置）"
        @unknown default:
            return "未知"
        }
    }

    func refresh() {
        status = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        if status != .notDetermined {
            isRequesting = false
        }
    }

    func requestWhenInUse() {
        refresh()
        guard status == .notDetermined else { return }
        guard UIApplication.shared.applicationState == .active else {
            errorMessage = "请在小卷处于前台时请求定位权限。"
            return
        }
        isRequesting = true
        errorMessage = nil
        manager.requestWhenInUseAuthorization()
    }

    func requestBackgroundAccess() {
        refresh()
        guard status == .authorizedWhenInUse else {
            if status == .notDetermined { requestWhenInUse() }
            return
        }
        guard UIApplication.shared.applicationState == .active else {
            errorMessage = "请在小卷处于前台时升级后台定位权限。"
            return
        }
        isRequesting = true
        errorMessage = nil
        manager.requestAlwaysAuthorization()

        // Keeping "使用 App 时" may not change authorization and therefore
        // isn't guaranteed to trigger a delegate callback. Refresh once after
        // the system prompt has had a chance to settle so the settings row does
        // not remain stuck in a requesting state.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.refresh()
            self?.isRequesting = false
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            errorMessage = "无法打开系统设置。"
            return
        }
        UIApplication.shared.open(url)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refresh()
        if status == .denied {
            errorMessage = "定位权限已拒绝；需要时可从系统设置重新允许。"
        } else if status == .restricted {
            errorMessage = "定位权限受到系统限制。"
        } else if hasBackgroundAccess {
            errorMessage = nil
        }
    }
}
