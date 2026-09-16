import CryptoKit
import Foundation
import UserNotifications


enum NotifyUserAuthorizationState: String, Codable, Equatable, Sendable {
    case authorized
    case denied
    case notDetermined = "not_determined"
    case provisional
    case ephemeral
    case unknown
}


enum NotifyUserPresentationState: String, Codable, Equatable, Sendable {
    case delivered
    case pending
    case acceptedUnobserved = "accepted_unobserved"
}


struct NotifyUserArguments: Equatable, Sendable {
    let title: String
    let body: String
    let attentionLevel: String

    static func parse(_ payload: [String: JSONValue]) -> NotifyUserArguments? {
        guard Set(payload.keys) == Set(["title", "body", "attention_level"]),
              let title = payload["title"]?.stringValue,
              let body = payload["body"]?.stringValue,
              let attention = payload["attention_level"]?.stringValue,
              !title.isEmpty, title == title.trimmingCharacters(in: .whitespacesAndNewlines), title.count <= 120,
              !body.isEmpty, body == body.trimmingCharacters(in: .whitespacesAndNewlines), body.count <= 600,
              attention == "IMPORTANT" || attention == "USER_REQUIRED"
        else { return nil }
        return NotifyUserArguments(title: title, body: body, attentionLevel: attention)
    }
}


struct NotifyUserSystemRequest: Equatable, Sendable {
    let notificationID: String
    let title: String
    let body: String
    let attentionLevel: String
    let taskID: String
    let actionID: String
}


struct NotifyUserSystemRecord: Equatable, Sendable {
    let notificationID: String
    let taskID: String
    let actionID: String
    let presentationState: NotifyUserPresentationState
}


protocol LocalNotificationClient: Sendable {
    func authorizationStatus() async -> NotifyUserAuthorizationState
    func add(_ request: NotifyUserSystemRequest) async throws
    func read(notificationID: String) async -> NotifyUserSystemRecord?
}


actor SystemLocalNotificationClient: LocalNotificationClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> NotifyUserAuthorizationState {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        @unknown default: return .unknown
        }
    }

    func add(_ request: NotifyUserSystemRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.threadIdentifier = NotifyUserConstants.threadIdentifier
        content.categoryIdentifier = NotifyUserConstants.categoryIdentifier
        content.interruptionLevel = .active
        content.userInfo = [
            "capability": NotifyUserConstants.capabilityID,
            "notification_id": request.notificationID,
            "task_id": request.taskID,
            "action_id": request.actionID,
        ]
        try await center.add(
            UNNotificationRequest(
                identifier: request.notificationID,
                content: content,
                trigger: nil
            )
        )
    }

    func read(notificationID: String) async -> NotifyUserSystemRecord? {
        if let delivered = await deliveredRecord(notificationID: notificationID) {
            return delivered
        }
        return await pendingRecord(notificationID: notificationID)
    }

    private func pendingRecord(notificationID: String) async -> NotifyUserSystemRecord? {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                let record = requests
                    .first(where: { $0.identifier == notificationID })
                    .flatMap { Self.record(request: $0, state: .pending) }
                continuation.resume(returning: record)
            }
        }
    }

    private func deliveredRecord(notificationID: String) async -> NotifyUserSystemRecord? {
        await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notifications in
                let record = notifications
                    .first(where: { $0.request.identifier == notificationID })
                    .flatMap { Self.record(request: $0.request, state: .delivered) }
                continuation.resume(returning: record)
            }
        }
    }

    nonisolated private static func record(
        request: UNNotificationRequest,
        state: NotifyUserPresentationState
    ) -> NotifyUserSystemRecord? {
        let info = request.content.userInfo
        guard info["capability"] as? String == NotifyUserConstants.capabilityID,
              info["notification_id"] as? String == request.identifier,
              let taskID = info["task_id"] as? String,
              let actionID = info["action_id"] as? String,
              !taskID.isEmpty, !actionID.isEmpty
        else { return nil }
        return NotifyUserSystemRecord(
            notificationID: request.identifier,
            taskID: taskID,
            actionID: actionID,
            presentationState: state
        )
    }
}


enum NotifyUserConstants {
    static let capabilityID = "notify.user"
    static let categoryIdentifier = "floweroll.notify.user"
    static let threadIdentifier = "floweroll.tasks"

    static func stableNotificationID(idempotencyKey: String) -> String {
        let digest = SHA256.hash(data: Data(idempotencyKey.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "floweroll.notify.\(hex.prefix(32))"
    }
}


struct NotifyUserAcceptanceReceipt: Codable, Equatable, Sendable {
    let notificationID: String
    let taskID: String
    let actionID: String
    let idempotencyKey: String
    let acceptedAt: Date
    var completesTask: Bool? = nil
}


enum NotifyUserAcceptanceStoreError: Error, Equatable {
    case identityConflict
}


actor NotifyUserAcceptanceStore {
    private struct Snapshot: Codable {
        var receipts: [NotifyUserAcceptanceReceipt]
    }

    static let shared: NotifyUserAcceptanceStore? = try? NotifyUserAcceptanceStore()

    private let fileURL: URL
    private var receipts: [String: NotifyUserAcceptanceReceipt]

    init(directoryURL: URL? = nil) throws {
        let directory = try directoryURL ?? Self.defaultDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("notify-user-acceptance.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder.floweroll.decode(Snapshot.self, from: data)
            receipts = Dictionary(uniqueKeysWithValues: snapshot.receipts.map { ($0.notificationID, $0) })
        } else {
            receipts = [:]
        }
    }

    func receipt(notificationID: String) -> NotifyUserAcceptanceReceipt? {
        receipts[notificationID]
    }

    func record(_ receipt: NotifyUserAcceptanceReceipt) throws {
        if let existing = receipts[receipt.notificationID] {
            guard existing.taskID == receipt.taskID,
                  existing.actionID == receipt.actionID,
                  existing.idempotencyKey == receipt.idempotencyKey
            else { throw NotifyUserAcceptanceStoreError.identityConflict }
            return
        }
        receipts[receipt.notificationID] = receipt
        try persist()
    }

    func hasAcceptedNotification(taskID: String) -> Bool {
        receipts.values.contains { $0.taskID == taskID }
    }

    func hasAcceptedTerminalNotification(taskID: String) -> Bool {
        receipts.values.contains { $0.taskID == taskID && $0.completesTask == true }
    }

    private func persist() throws {
        let snapshot = Snapshot(
            receipts: receipts.values.sorted { $0.notificationID < $1.notificationID }
        )
        try JSONEncoder.floweroll.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    private static func defaultDirectoryURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("Floweroll", isDirectory: true)
            .appendingPathComponent("RuntimeClient", isDirectory: true)
    }
}


actor NotifyUserExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID = NotifyUserConstants.capabilityID

    private let client: any LocalNotificationClient
    private let acceptanceStore: NotifyUserAcceptanceStore?

    init(
        client: any LocalNotificationClient = SystemLocalNotificationClient(),
        acceptanceStore: NotifyUserAcceptanceStore? = NotifyUserAcceptanceStore.shared
    ) {
        self.client = client
        self.acceptanceStore = acceptanceStore
    }

    func preflight(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult? {
        guard acceptanceStore != nil else {
            return .failure(
                "notify_user_acceptance_store_unavailable",
                output: ["error_code": .string("notify_user_acceptance_store_unavailable")]
            )
        }
        guard NotifyUserArguments.parse(dispatch.payload) != nil else {
            return .failure(
                "notify_user_invalid_arguments",
                output: ["error_code": .string("notify_user_invalid_arguments")]
            )
        }
        let authorization = await client.authorizationStatus()
        switch authorization {
        case .authorized:
            return nil
        case .denied:
            return permissionFailure(
                code: "notifications_authorization_denied",
                status: authorization
            )
        case .notDetermined:
            return permissionFailure(
                code: "notifications_authorization_not_determined",
                status: authorization
            )
        case .provisional, .ephemeral, .unknown:
            return permissionFailure(
                code: "notifications_authorization_insufficient",
                status: authorization
            )
        }
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        guard let arguments = NotifyUserArguments.parse(dispatch.payload) else {
            return .failure(
                "notify_user_invalid_arguments",
                output: ["error_code": .string("notify_user_invalid_arguments")]
            )
        }
        let notificationID = NotifyUserConstants.stableNotificationID(
            idempotencyKey: dispatch.idempotencyKey
        )
        guard let acceptanceStore else {
            return .failure(
                "notify_user_acceptance_store_unavailable",
                output: ["error_code": .string("notify_user_acceptance_store_unavailable")]
            )
        }
        if let receipt = await acceptanceStore.receipt(notificationID: notificationID) {
            guard receiptMatches(receipt, dispatch: dispatch) else {
                return .failure("notify_user_acceptance_identity_conflict")
            }
            return await successResult(
                dispatch: dispatch,
                notificationID: notificationID,
                reconciled: false,
                duplicateSuppressed: true
            )
        }

        try await client.add(
            NotifyUserSystemRequest(
                notificationID: notificationID,
                title: arguments.title,
                body: arguments.body,
                attentionLevel: arguments.attentionLevel,
                taskID: dispatch.taskID,
                actionID: dispatch.actionID
            )
        )
        // This is the capability-level may-have-started recovery anchor. It is
        // deliberately persisted before a success result can leave the executor.
        var receipt = NotifyUserAcceptanceReceipt(
            notificationID: notificationID,
            taskID: dispatch.taskID,
            actionID: dispatch.actionID,
            idempotencyKey: dispatch.idempotencyKey,
            acceptedAt: Date()
        )
        receipt.completesTask = dispatch.onVerified == "COMPLETE"
        try await acceptanceStore.record(receipt)
        return await successResult(
            dispatch: dispatch,
            notificationID: notificationID,
            reconciled: false,
            duplicateSuppressed: false
        )
    }

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        let notificationID = NotifyUserConstants.stableNotificationID(
            idempotencyKey: dispatch.idempotencyKey
        )
        guard let acceptanceStore else {
            return .stillUnknown("notify_user_acceptance_store_unavailable")
        }
        if let receipt = await acceptanceStore.receipt(notificationID: notificationID) {
            guard receiptMatches(receipt, dispatch: dispatch) else {
                return .stillUnknown("notify_user_acceptance_identity_conflict")
            }
            return .completed(
                await successResult(
                    dispatch: dispatch,
                    notificationID: notificationID,
                    reconciled: true,
                    duplicateSuppressed: true
                )
            )
        }

        if let record = await client.read(notificationID: notificationID) {
            guard record.taskID == dispatch.taskID, record.actionID == dispatch.actionID else {
                return .stillUnknown("notify_user_readback_correlation_mismatch")
            }
            var receipt = NotifyUserAcceptanceReceipt(
                notificationID: notificationID,
                taskID: dispatch.taskID,
                actionID: dispatch.actionID,
                idempotencyKey: dispatch.idempotencyKey,
                acceptedAt: journalEntry.updatedAt
            )
            receipt.completesTask = dispatch.onVerified == "COMPLETE"
            try await acceptanceStore.record(receipt)
            return .completed(
                result(
                    dispatch: dispatch,
                    notificationID: notificationID,
                    presentationState: record.presentationState,
                    readbackSource: record.presentationState.rawValue,
                    reconciled: true,
                    duplicateSuppressed: true
                )
            )
        }

        // After DeviceActionJournal.mayHaveStarted, an empty system query is
        // not evidence that the user never received or dismissed the request.
        return .stillUnknown("notify_user_acceptance_not_observable")
    }

    private func successResult(
        dispatch: DeviceActionDispatch,
        notificationID: String,
        reconciled: Bool,
        duplicateSuppressed: Bool
    ) async -> DeviceExecutionResult {
        if let record = await client.read(notificationID: notificationID),
           record.taskID == dispatch.taskID,
           record.actionID == dispatch.actionID {
            return result(
                dispatch: dispatch,
                notificationID: notificationID,
                presentationState: record.presentationState,
                readbackSource: record.presentationState.rawValue,
                reconciled: reconciled,
                duplicateSuppressed: duplicateSuppressed
            )
        }
        return result(
            dispatch: dispatch,
            notificationID: notificationID,
            presentationState: .acceptedUnobserved,
            readbackSource: "acceptance_receipt",
            reconciled: reconciled,
            duplicateSuppressed: duplicateSuppressed
        )
    }

    private func result(
        dispatch: DeviceActionDispatch,
        notificationID: String,
        presentationState: NotifyUserPresentationState,
        readbackSource: String,
        reconciled: Bool,
        duplicateSuppressed: Bool
    ) -> DeviceExecutionResult {
        .success(
            [
                "notification_id": .string(notificationID),
                "task_id": .string(dispatch.taskID),
                "action_id": .string(dispatch.actionID),
                "system_accepted": .bool(true),
                "correlation_verified": .bool(true),
                "authorization_status": .string(NotifyUserAuthorizationState.authorized.rawValue),
                "presentation_state": .string(presentationState.rawValue),
                "durable_acceptance_receipt": .bool(true),
                "reconciled": .bool(reconciled),
                "readback_source": .string(readbackSource),
                "duplicate_suppressed": .bool(duplicateSuppressed),
            ],
            nativeCorrelationID: notificationID
        )
    }

    private func permissionFailure(
        code: String,
        status: NotifyUserAuthorizationState
    ) -> DeviceExecutionResult {
        .failure(
            code,
            output: [
                "error_code": .string(code),
                "authorization_status": .string(status.rawValue),
            ]
        )
    }

    private func receiptMatches(
        _ receipt: NotifyUserAcceptanceReceipt,
        dispatch: DeviceActionDispatch
    ) -> Bool {
        receipt.taskID == dispatch.taskID
            && receipt.actionID == dispatch.actionID
            && receipt.idempotencyKey == dispatch.idempotencyKey
    }
}


struct NotifyUserRoute: Codable, Equatable, Sendable {
    let taskID: String
    let actionID: String
    let notificationID: String

    static func parse(
        categoryIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> NotifyUserRoute? {
        guard categoryIdentifier == NotifyUserConstants.categoryIdentifier,
              userInfo["capability"] as? String == NotifyUserConstants.capabilityID,
              let taskID = userInfo["task_id"] as? String,
              UUID(uuidString: taskID) != nil,
              let actionID = userInfo["action_id"] as? String,
              !actionID.isEmpty,
              let notificationID = userInfo["notification_id"] as? String,
              notificationID.hasPrefix("floweroll.notify.")
        else { return nil }
        return NotifyUserRoute(
            taskID: taskID,
            actionID: actionID,
            notificationID: notificationID
        )
    }
}


extension Notification.Name {
    static let flowerollNotifyUserRouteAvailable = Notification.Name(
        "floweroll.notify.user.route.available"
    )
}


final class NotifyUserRouteStore: @unchecked Sendable {
    static let shared = NotifyUserRouteStore()
    private let key = "floweroll.notify.user.pendingRoute"
    private let lock = NSLock()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(_ route: NotifyUserRoute) {
        lock.lock()
        let data = try? JSONEncoder().encode(route)
        if let data { defaults.set(data, forKey: key) }
        lock.unlock()
        guard data != nil else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .flowerollNotifyUserRouteAvailable, object: nil)
        }
    }

    func peek() -> NotifyUserRoute? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(NotifyUserRoute.self, from: data)
    }

    func consume() -> NotifyUserRoute? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: key),
              let route = try? JSONDecoder().decode(NotifyUserRoute.self, from: data)
        else { return nil }
        defaults.removeObject(forKey: key)
        return route
    }
}
