import CoreLocation
import Foundation
import UIKit


struct LocationCurrentSample: Sendable, Equatable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let timestamp: Date
}

enum LocationCurrentVerification: Sendable, Equatable {
    case accepted(ageMilliseconds: Double)
    case temporarilyUnavailable(String)
    case unknown(String)
}

enum LocationCurrentVerifier {
    static let maximumAge: TimeInterval = 60
    static let futureTolerance: TimeInterval = 5
    static let maximumHorizontalAccuracy: CLLocationAccuracy = 10_000

    static func verify(
        _ sample: LocationCurrentSample,
        receivedAt: Date
    ) -> LocationCurrentVerification {
        guard sample.latitude.isFinite,
              sample.longitude.isFinite,
              sample.horizontalAccuracy.isFinite,
              CLLocationCoordinate2DIsValid(
                CLLocationCoordinate2D(latitude: sample.latitude, longitude: sample.longitude)
              ) else {
            return .temporarilyUnavailable("定位坐标无效。")
        }
        guard sample.horizontalAccuracy >= 0,
              sample.horizontalAccuracy <= maximumHorizontalAccuracy else {
            return .temporarilyUnavailable("本次定位精度异常，未把它当作当前位置。")
        }
        let age = receivedAt.timeIntervalSince(sample.timestamp)
        guard age >= -futureTolerance else {
            return .unknown("定位时间明显晚于设备当前时间，无法确认当前位置。")
        }
        guard age <= maximumAge else {
            return .temporarilyUnavailable("系统只返回了过旧的位置，本次没有把它当作当前位置。")
        }
        return .accepted(ageMilliseconds: max(0, age * 1_000))
    }
}

enum LocationOneShotResult: Sendable {
    case location(
        LocationCurrentSample,
        authorizationStatus: CLAuthorizationStatus,
        accuracyAuthorization: CLAccuracyAuthorization
    )
    case failure(
        code: Int,
        authorizationStatus: CLAuthorizationStatus,
        accuracyAuthorization: CLAccuracyAuthorization
    )
    case timeout(
        authorizationStatus: CLAuthorizationStatus,
        accuracyAuthorization: CLAccuracyAuthorization
    )
    case cancelled
}

private struct LocationEnvironmentSnapshot: Sendable {
    let isForeground: Bool
    let servicesEnabled: Bool
    let authorizationStatus: CLAuthorizationStatus
    let accuracyAuthorization: CLAccuracyAuthorization
}

struct LocationCurrentEnvironmentFailure: Sendable, Equatable {
    let status: String
    let reason: String
    let reasonCode: String?
    let userAction: String?
}

enum LocationCurrentAuthorizationScope: Sendable, Equatable {
    case notDetermined
    case restricted
    case denied
    case whenInUse
    case always
    case unknown
}

enum LocationCurrentEnvironmentPolicy {
    static func failure(
        isForeground: Bool,
        servicesEnabled: Bool,
        authorization: LocationCurrentAuthorizationScope
    ) -> LocationCurrentEnvironmentFailure? {
        guard servicesEnabled else {
            return LocationCurrentEnvironmentFailure(
                status: "SERVICES_DISABLED",
                reason: "系统定位服务当前已关闭。",
                reasonCode: nil,
                userAction: nil
            )
        }

        switch authorization {
        case .always:
            // A user-started background task already owns the execution window.
            // Always authorization lets this one-shot read start during that
            // window without turning location into continuous tracking.
            return nil
        case .whenInUse:
            guard isForeground else {
                return LocationCurrentEnvironmentFailure(
                    status: "PERMISSION_REQUIRED",
                    reason: "后台读取当前位置需要你先允许小卷在后台使用定位。之后只会在明确需要当前位置的任务里读取一次。",
                    reasonCode: "location_background_authorization_required",
                    userAction: "request_always_authorization_in_foreground"
                )
            }
            return nil
        case .notDetermined:
            return LocationCurrentEnvironmentFailure(
                status: "PERMISSION_REQUIRED",
                reason: "小卷还没有定位权限，请先在花卷设置里允许定位。",
                reasonCode: "location_authorization_required",
                userAction: "request_location_authorization_in_foreground"
            )
        case .denied:
            return LocationCurrentEnvironmentFailure(
                status: "DENIED",
                reason: "定位权限已被拒绝，请到系统设置里允许小卷访问位置。",
                reasonCode: "location_authorization_denied",
                userAction: "open_location_settings"
            )
        case .restricted:
            return LocationCurrentEnvironmentFailure(
                status: "DENIED",
                reason: "这台 iPhone 的定位权限受到系统限制。",
                reasonCode: "location_authorization_restricted",
                userAction: nil
            )
        case .unknown:
            return LocationCurrentEnvironmentFailure(
                status: "UNKNOWN",
                reason: "系统返回了未知的定位授权状态。",
                reasonCode: "location_authorization_unknown",
                userAction: nil
            )
        }
    }
}

@MainActor
final class CoreLocationOneShotClient: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<LocationOneShotResult, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false
    private var cancellationRequested = false

    override init() {
        super.init()
        manager.delegate = self
    }

    fileprivate static func environment() -> LocationEnvironmentSnapshot {
        let manager = CLLocationManager()
        return LocationEnvironmentSnapshot(
            isForeground: UIApplication.shared.applicationState == .active,
            servicesEnabled: CLLocationManager.locationServicesEnabled(),
            authorizationStatus: manager.authorizationStatus,
            accuracyAuthorization: manager.accuracyAuthorization
        )
    }

    func request(timeoutSeconds: TimeInterval) async -> LocationOneShotResult {
        manager.desiredAccuracy = manager.accuracyAuthorization == .reducedAccuracy
            ? kCLLocationAccuracyReduced
            : kCLLocationAccuracyHundredMeters
        // Do not enable allowsBackgroundLocationUpdates here. Floweroll asks for
        // one fresh location inside its existing user-started background
        // execution window; Core Location must not become a second long-lived
        // background owner.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled || cancellationRequested {
                    finish(.cancelled)
                    return
                }
                manager.requestLocation()
                timeoutTask = Task { @MainActor [weak self] in
                    let nanos = UInt64(max(0, timeoutSeconds) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanos)
                    guard !Task.isCancelled else { return }
                    self?.finish(
                        .timeout(
                            authorizationStatus: self?.manager.authorizationStatus ?? .notDetermined,
                            accuracyAuthorization: self?.manager.accuracyAuthorization ?? .reducedAccuracy
                        )
                    )
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancel()
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.max(by: { $0.timestamp < $1.timestamp }) else {
            finish(
                .failure(
                    code: CLError.locationUnknown.rawValue,
                    authorizationStatus: manager.authorizationStatus,
                    accuracyAuthorization: manager.accuracyAuthorization
                )
            )
            return
        }
        finish(
            .location(
                LocationCurrentSample(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    horizontalAccuracy: location.horizontalAccuracy,
                    timestamp: location.timestamp
                ),
                authorizationStatus: manager.authorizationStatus,
                accuracyAuthorization: manager.accuracyAuthorization
            )
        )
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let nsError = error as NSError
        finish(
            .failure(
                code: nsError.domain == kCLErrorDomain ? nsError.code : Int.min,
                authorizationStatus: manager.authorizationStatus,
                accuracyAuthorization: manager.accuracyAuthorization
            )
        )
    }

    private func cancel() {
        cancellationRequested = true
        guard continuation != nil else { return }
        finish(.cancelled)
    }

    private func finish(_ result: LocationOneShotResult) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        manager.stopUpdatingLocation()
        manager.delegate = nil
        let pending = continuation
        continuation = nil
        pending?.resume(returning: result)
    }
}

actor LocationCurrentExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID = "location.current"
    private static let requestTimeoutSeconds: TimeInterval = 15

    func preflight(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult? {
        guard dispatch.payload.isEmpty else {
            return Self.failure(
                status: "UNKNOWN",
                reason: "location.current 不接受模型提供的位置参数。",
                dispatch: dispatch,
                authorizationStatus: .notDetermined,
                accuracyAuthorization: .reducedAccuracy
            )
        }
        let environment = await CoreLocationOneShotClient.environment()
        return Self.environmentFailure(environment, dispatch: dispatch)
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        let environment = await CoreLocationOneShotClient.environment()
        if let failure = Self.environmentFailure(environment, dispatch: dispatch) {
            return failure
        }

        let client = await CoreLocationOneShotClient()
        let result = await client.request(timeoutSeconds: Self.requestTimeoutSeconds)
        let receivedAt = Date()

        switch result {
        case let .location(sample, authorizationStatus, accuracyAuthorization):
            switch LocationCurrentVerifier.verify(sample, receivedAt: receivedAt) {
            case let .accepted(ageMilliseconds):
                return .success(
                    [
                        "status": .string("COMPLETED"),
                        "location_observation_id": .string(UUID().uuidString),
                        "request_id": .string(dispatch.attemptID),
                        "task_id": .string(dispatch.taskID),
                        "action_id": .string(dispatch.actionID),
                        "attempt_id": .string(dispatch.attemptID),
                        "latitude": .number(sample.latitude),
                        "longitude": .number(sample.longitude),
                        "horizontal_accuracy_m": .number(sample.horizontalAccuracy),
                        "timestamp": .string(Self.iso8601(sample.timestamp)),
                        "received_at": .string(Self.iso8601(receivedAt)),
                        "age_ms": .number(ageMilliseconds),
                        "authorization_status": .string(Self.authorizationLabel(authorizationStatus)),
                        "accuracy_authorization": .string(Self.accuracyLabel(accuracyAuthorization)),
                        "coordinate_reference": .string("WGS84"),
                        "freshness_verified": .bool(true),
                        "validity_verified": .bool(true),
                        "privacy_class": .string("precise_location"),
                    ],
                    nativeCorrelationID: dispatch.attemptID
                )
            case let .temporarilyUnavailable(reason):
                return Self.failure(
                    status: "TEMPORARILY_UNAVAILABLE",
                    reason: reason,
                    dispatch: dispatch,
                    authorizationStatus: authorizationStatus,
                    accuracyAuthorization: accuracyAuthorization
                )
            case let .unknown(reason):
                return Self.failure(
                    status: "UNKNOWN",
                    reason: reason,
                    dispatch: dispatch,
                    authorizationStatus: authorizationStatus,
                    accuracyAuthorization: accuracyAuthorization
                )
            }

        case let .failure(code, authorizationStatus, accuracyAuthorization):
            if code == CLError.denied.rawValue {
                let refreshed = await CoreLocationOneShotClient.environment()
                return Self.environmentFailure(refreshed, dispatch: dispatch)
                    ?? Self.failure(
                        status: "DENIED",
                        reason: "系统拒绝了这次定位请求。",
                        dispatch: dispatch,
                        authorizationStatus: authorizationStatus,
                        accuracyAuthorization: accuracyAuthorization
                    )
            }
            if code == CLError.locationUnknown.rawValue || code == CLError.network.rawValue {
                return Self.failure(
                    status: "TEMPORARILY_UNAVAILABLE",
                    reason: "系统暂时无法取得足够可靠的当前位置。",
                    dispatch: dispatch,
                    authorizationStatus: authorizationStatus,
                    accuracyAuthorization: accuracyAuthorization
                )
            }
            return Self.failure(
                status: "UNKNOWN",
                reason: "Core Location 返回了无法分类的定位错误。",
                dispatch: dispatch,
                authorizationStatus: authorizationStatus,
                accuracyAuthorization: accuracyAuthorization
            )

        case .cancelled:
            throw CancellationError()

        case let .timeout(authorizationStatus, accuracyAuthorization):
            return Self.failure(
                status: "TIMEOUT",
                reason: "15 秒内没有取得可用的当前位置。",
                dispatch: dispatch,
                authorizationStatus: authorizationStatus,
                accuracyAuthorization: accuracyAuthorization
            )
        }
    }

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        .stillUnknown("location.current 是一次性当前状态读取；无法在丢失结果后盲目重读并冒充同一次观察。")
    }

    private static func environmentFailure(
        _ environment: LocationEnvironmentSnapshot,
        dispatch: DeviceActionDispatch
    ) -> DeviceExecutionResult? {
        guard let policyFailure = LocationCurrentEnvironmentPolicy.failure(
            isForeground: environment.isForeground,
            servicesEnabled: environment.servicesEnabled,
            authorization: .from(environment.authorizationStatus)
        ) else { return nil }
        return failure(
            status: policyFailure.status,
            reason: policyFailure.reason,
            reasonCode: policyFailure.reasonCode,
            userAction: policyFailure.userAction,
            dispatch: dispatch,
            authorizationStatus: environment.authorizationStatus,
            accuracyAuthorization: environment.accuracyAuthorization
        )
    }

    private static func failure(
        status: String,
        reason: String,
        reasonCode: String? = nil,
        userAction: String? = nil,
        dispatch: DeviceActionDispatch,
        authorizationStatus: CLAuthorizationStatus,
        accuracyAuthorization: CLAccuracyAuthorization
    ) -> DeviceExecutionResult {
        .failure(
            reason,
            output: [
                "status": .string(status),
                "request_id": .string(dispatch.attemptID),
                "task_id": .string(dispatch.taskID),
                "action_id": .string(dispatch.actionID),
                "attempt_id": .string(dispatch.attemptID),
                "authorization_status": .string(authorizationLabel(authorizationStatus)),
                "accuracy_authorization": .string(accuracyLabel(accuracyAuthorization)),
                "reason": .string(reason),
                "privacy_class": .string("precise_location"),
            ].merging(
                (reasonCode.map { ["reason_code": .string($0)] } ?? [:])
                    .merging(
                        userAction.map { ["user_action": .string($0)] } ?? [:],
                        uniquingKeysWith: { current, _ in current }
                    ),
                uniquingKeysWith: { current, _ in current }
            ),
            nativeCorrelationID: dispatch.attemptID
        )
    }

    private static func authorizationLabel(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown"
        }
    }

    private static func accuracyLabel(_ status: CLAccuracyAuthorization) -> String {
        switch status {
        case .fullAccuracy: return "fullAccuracy"
        case .reducedAccuracy: return "reducedAccuracy"
        @unknown default: return "unknown"
        }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private extension LocationCurrentAuthorizationScope {
    static func from(_ status: CLAuthorizationStatus) -> Self {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedWhenInUse: return .whenInUse
        case .authorizedAlways: return .always
        @unknown default: return .unknown
        }
    }
}
