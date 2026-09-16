import AlarmKit
import Foundation
import Observation


struct AlarmCreateArguments: Equatable, Sendable {
    let title: String
    let schedule: AlarmDesiredSchedule
    let requestedFireAt: String?
    let sound: AlarmSoundChoice

    static func parse(_ payload: [String: JSONValue]) -> AlarmCreateArguments? {
        let keys = Set(payload.keys)
        if keys == Set(["title", "fire_at"]) || keys == Set(["title", "fire_at", "sound"]) {
            guard let title = canonicalTitle(payload["title"]),
                  let fireAt = payload["fire_at"]?.stringValue,
                  hasExplicitTimeZone(fireAt),
                  let fireDate = parseISO8601(fireAt)
            else { return nil }
            guard let sound = parseSound(payload["sound"]) else { return nil }
            return AlarmCreateArguments(
                title: title,
                schedule: .fixed(fireDate),
                requestedFireAt: fireAt,
                sound: sound
            )
        }

        guard keys == Set(["title", "schedule"]) || keys == Set(["title", "schedule", "sound"]),
              let title = canonicalTitle(payload["title"]),
              let sound = parseSound(payload["sound"]),
              let scheduleObject = payload["schedule"]?.objectValue,
              let kind = scheduleObject["kind"]?.stringValue
        else { return nil }

        switch kind {
        case AlarmScheduleKind.fixed.rawValue:
            guard Set(scheduleObject.keys) == Set(["kind", "fire_at"]),
                  let fireAt = scheduleObject["fire_at"]?.stringValue,
                  hasExplicitTimeZone(fireAt),
                  let fireDate = parseISO8601(fireAt)
            else { return nil }
            return AlarmCreateArguments(
                title: title,
                schedule: .fixed(fireDate),
                requestedFireAt: fireAt,
                sound: sound
            )

        case AlarmScheduleKind.weekly.rawValue:
            guard Set(scheduleObject.keys) == Set(["kind", "hour", "minute", "weekdays"]),
                  let hour = integer(scheduleObject["hour"]),
                  (0...23).contains(hour),
                  let minute = integer(scheduleObject["minute"]),
                  (0...59).contains(minute),
                  let weekdayValues = scheduleObject["weekdays"]?.arrayValue,
                  !weekdayValues.isEmpty,
                  weekdayValues.count <= 7
            else { return nil }
            let weekdays = weekdayValues.compactMap { value -> AlarmWeekday? in
                guard let raw = value.stringValue else { return nil }
                return AlarmWeekday(rawValue: raw)
            }
            guard weekdays.count == weekdayValues.count,
                  Set(weekdays).count == weekdays.count
            else { return nil }
            return AlarmCreateArguments(
                title: title,
                schedule: .weekly(hour: hour, minute: minute, weekdays: weekdays),
                requestedFireAt: nil,
                sound: sound
            )

        default:
            return nil
        }
    }

    static func parseSound(_ value: JSONValue?) -> AlarmSoundChoice? {
        guard let value else { return .defaultSound }
        guard let raw = value.stringValue else { return nil }
        return AlarmSoundChoice(rawValue: raw)
    }

    static func canonicalTitle(_ value: JSONValue?) -> String? {
        guard let title = value?.stringValue,
              !title.isEmpty,
              title.count <= 160,
              title == title.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return title
    }

    static func integer(_ value: JSONValue?) -> Int? {
        guard case let .number(number)? = value,
              number.isFinite,
              number.rounded() == number,
              number >= Double(Int.min),
              number <= Double(Int.max)
        else { return nil }
        return Int(number)
    }

    static func hasExplicitTimeZone(_ raw: String) -> Bool {
        raw.range(
            of: #"(?:Z|[+-][0-9]{2}:[0-9]{2})$"#,
            options: .regularExpression
        ) != nil
    }

    static func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let normal = ISO8601DateFormatter()
        normal.formatOptions = [.withInternetDateTime]
        return normal.date(from: raw)
    }
}


actor AlarmCreateExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID = "alarm.create"

    private let nativeStore: any AlarmNativeStore
    private let ownershipStore: AlarmOwnershipStore?
    private let usageDescriptionAvailable: @Sendable () -> Bool

    init(
        nativeStore: any AlarmNativeStore = SystemAlarmNativeStore(),
        ownershipStore: AlarmOwnershipStore? = AlarmOwnershipStore.shared,
        usageDescriptionAvailable: @escaping @Sendable () -> Bool = {
            guard let value = Bundle.main.object(
                forInfoDictionaryKey: "NSAlarmKitUsageDescription"
            ) as? String else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    ) {
        self.nativeStore = nativeStore
        self.ownershipStore = ownershipStore
        self.usageDescriptionAvailable = usageDescriptionAvailable
    }

    func preflight(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult? {
        guard ownershipStore != nil else {
            return alarmFailure(.ownershipStoreUnavailable)
        }
        guard usageDescriptionAvailable() else {
            return alarmFailure(.usageDescriptionMissing)
        }
        guard let arguments = AlarmCreateArguments.parse(dispatch.payload) else {
            return alarmFailure(.invalidArguments)
        }
        if let permission = alarmPermissionFailure(await nativeStore.authorizationStatus()) {
            return permission
        }

        let alarmID = AlarmIdentity.stableAlarmID(for: dispatch.idempotencyKey)
        if let ownership = await ownershipStore?.record(alarmID: alarmID),
           !Self.ownershipMatches(
                ownership,
                dispatch: dispatch,
                arguments: arguments
           ) {
            return alarmFailure(
                .idempotencyConflict,
                extra: ["alarm_id": .string(alarmID.uuidString)]
            )
        }

        do {
            if let native = try await nativeStore.alarms().first(where: { $0.id == alarmID }),
               !arguments.schedule.matches(native.schedule) {
                return alarmFailure(
                    .nativeIDConflict,
                    extra: ["alarm_id": .string(alarmID.uuidString)]
                )
            }
        } catch {
            return alarmFailure(.readFailed)
        }
        return nil
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        guard let arguments = AlarmCreateArguments.parse(dispatch.payload) else {
            return alarmFailure(.invalidArguments)
        }
        guard let ownershipStore else {
            return alarmFailure(.ownershipStoreUnavailable)
        }
        let alarmID = AlarmIdentity.stableAlarmID(for: dispatch.idempotencyKey)

        if let ownership = await ownershipStore.record(alarmID: alarmID) {
            guard Self.ownershipMatches(
                ownership,
                dispatch: dispatch,
                arguments: arguments
            ) else {
                return alarmFailure(
                    .idempotencyConflict,
                    extra: ["alarm_id": .string(alarmID.uuidString)]
                )
            }
            let native = try await nativeRecord(id: alarmID)
            if let native, !arguments.schedule.matches(native.schedule) {
                return alarmFailure(
                    .readbackMismatch,
                    extra: ["alarm_id": .string(alarmID.uuidString)]
                )
            }
            _ = try await ownershipStore.recordObservation(
                alarmID: alarmID,
                nativeState: native?.state,
                isMissing: native == nil
            )
            return Self.successResult(
                dispatch: dispatch,
                arguments: arguments,
                alarmID: alarmID,
                native: native,
                readbackSource: native == nil ? "ownership_ledger" : "alarm_manager",
                duplicateSuppressed: true,
                reconciled: false
            )
        }

        if let existing = try await nativeRecord(id: alarmID) {
            guard arguments.schedule.matches(existing.schedule) else {
                return alarmFailure(
                    .nativeIDConflict,
                    extra: ["alarm_id": .string(alarmID.uuidString)]
                )
            }
            _ = try await ownershipStore.recordAccepted(
                alarmID: alarmID,
                dispatch: dispatch,
                title: arguments.title,
                schedule: arguments.schedule,
                sound: arguments.sound,
                nativeState: existing.state
            )
            return Self.successResult(
                dispatch: dispatch,
                arguments: arguments,
                alarmID: alarmID,
                native: existing,
                readbackSource: "alarm_manager_migrated",
                duplicateSuppressed: true,
                reconciled: false
            )
        }

        do {
            _ = try await nativeStore.schedule(
                AlarmNativeScheduleRequest(
                    id: alarmID,
                    title: arguments.title,
                    taskID: dispatch.taskID,
                    actionID: dispatch.actionID,
                    idempotencyKey: dispatch.idempotencyKey,
                    schedule: arguments.schedule,
                    sound: arguments.sound
                )
            )
        } catch AlarmNativeStoreError.maximumLimitReached {
            return alarmFailure(.maximumLimitReached)
        } catch AlarmNativeStoreError.unsupportedSchedule {
            return alarmFailure(.invalidArguments)
        } catch {
            throw AlarmNativeStoreError.nativeFailure(
                AlarmFailureCode.nativeScheduleFailed.rawValue
            )
        }

        guard let saved = try await nativeRecord(id: alarmID) else {
            // Once schedule() was invoked, absence is not strong enough to prove
            // no side effect occurred. Throw so DeviceActionJournal preserves
            // mayHaveStarted and forces reconciliation instead of blind retry.
            throw AlarmNativeStoreError.nativeFailure(
                AlarmFailureCode.readbackMissing.rawValue
            )
        }
        guard arguments.schedule.matches(saved.schedule) else {
            return alarmFailure(
                .readbackMismatch,
                extra: ["alarm_id": .string(alarmID.uuidString)]
            )
        }
        _ = try await ownershipStore.recordAccepted(
            alarmID: alarmID,
            dispatch: dispatch,
            title: arguments.title,
            schedule: arguments.schedule,
            sound: arguments.sound,
            nativeState: saved.state
        )
        return Self.successResult(
            dispatch: dispatch,
            arguments: arguments,
            alarmID: alarmID,
            native: saved,
            readbackSource: "alarm_manager",
            duplicateSuppressed: false,
            reconciled: false
        )
    }

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        guard let arguments = AlarmCreateArguments.parse(dispatch.payload) else {
            return .completed(alarmFailure(.invalidArguments))
        }
        guard let ownershipStore else {
            return .stillUnknown(AlarmFailureCode.ownershipStoreUnavailable.rawValue)
        }
        let authorization = await nativeStore.authorizationStatus()
        guard authorization == .authorized else {
            return .stillUnknown(Self.authorizationReconciliationReason(authorization))
        }

        let alarmID = AlarmIdentity.stableAlarmID(for: dispatch.idempotencyKey)
        if let ownership = await ownershipStore.record(alarmID: alarmID) {
            guard Self.ownershipMatches(
                ownership,
                dispatch: dispatch,
                arguments: arguments
            ) else {
                return .stillUnknown(AlarmFailureCode.idempotencyConflict.rawValue)
            }
            let native = try await nativeRecord(id: alarmID)
            if let native, !arguments.schedule.matches(native.schedule) {
                return .completed(
                    alarmFailure(
                        .readbackMismatch,
                        extra: ["alarm_id": .string(alarmID.uuidString)]
                    )
                )
            }
            _ = try await ownershipStore.recordObservation(
                alarmID: alarmID,
                nativeState: native?.state,
                isMissing: native == nil
            )
            return .completed(
                Self.successResult(
                    dispatch: dispatch,
                    arguments: arguments,
                    alarmID: alarmID,
                    native: native,
                    readbackSource: native == nil ? "ownership_ledger" : "alarm_manager",
                    duplicateSuppressed: true,
                    reconciled: true
                )
            )
        }

        if let native = try await nativeRecord(id: alarmID) {
            guard arguments.schedule.matches(native.schedule) else {
                return .completed(
                    alarmFailure(
                        .readbackMismatch,
                        extra: ["alarm_id": .string(alarmID.uuidString)]
                    )
                )
            }
            _ = try await ownershipStore.recordAccepted(
                alarmID: alarmID,
                dispatch: dispatch,
                title: arguments.title,
                schedule: arguments.schedule,
                sound: arguments.sound,
                nativeState: native.state,
                acceptedAt: journalEntry.updatedAt
            )
            return .completed(
                Self.successResult(
                    dispatch: dispatch,
                    arguments: arguments,
                    alarmID: alarmID,
                    native: native,
                    readbackSource: "alarm_manager_reconciled",
                    duplicateSuppressed: true,
                    reconciled: true
                )
            )
        }

        // D04's cautious conclusion survives independent review: after the
        // native side-effect boundary, one empty query is not enough to prove
        // schedule() never took effect (the alarm may also have fired/stopped).
        return .stillUnknown("alarm_create_native_state_absent_after_ambiguous_boundary")
    }

    private func nativeRecord(id: UUID) async throws -> AlarmNativeRecord? {
        try await nativeStore.alarms().first { $0.id == id }
    }

    private static func ownershipMatches(
        _ ownership: AlarmOwnershipRecord,
        dispatch: DeviceActionDispatch,
        arguments: AlarmCreateArguments
    ) -> Bool {
        ownership.taskID == dispatch.taskID
            && ownership.actionID == dispatch.actionID
            && ownership.idempotencyKey == dispatch.idempotencyKey
            && ownership.title == arguments.title
            && ownership.schedule.isSemanticallyEquivalent(to: arguments.schedule)
            && ownership.effectiveSound == arguments.sound
    }

    private static func successResult(
        dispatch: DeviceActionDispatch,
        arguments: AlarmCreateArguments,
        alarmID: UUID,
        native: AlarmNativeRecord?,
        readbackSource: String,
        duplicateSuppressed: Bool,
        reconciled: Bool
    ) -> DeviceExecutionResult {
        var output: [String: JSONValue] = [
            "alarm_id": .string(alarmID.uuidString),
            "idempotency_marker": .string(dispatch.idempotencyKey),
            "verified": .bool(true),
            "ownership_verified": .bool(true),
            "durable_acceptance_receipt": .bool(true),
            "native_present": .bool(native != nil),
            "native_schedule_verified": .bool(
                native.map { arguments.schedule.matches($0.schedule) } ?? false
            ),
            "readback_source": .string(readbackSource),
            "correlation_source": .string("ownership_ledger"),
            "duplicate_suppressed": .bool(duplicateSuppressed),
            "reconciled": .bool(reconciled),
            "schedule": arguments.schedule.jsonValue,
            "title": .string(arguments.title),
            "sound": .string(arguments.sound.rawValue),
        ]
        if let requestedFireAt = arguments.requestedFireAt {
            // Kept for the currently registered Host alarm.create adapter.
            output["fire_at"] = .string(requestedFireAt)
        }
        if let native {
            output["native_state"] = .string(native.state.rawValue)
        }
        return .success(output, nativeCorrelationID: alarmID.uuidString)
    }

    private static func authorizationReconciliationReason(
        _ status: AlarmAuthorizationStatus
    ) -> String {
        switch status {
        case .authorized:
            return ""
        case .notDetermined:
            return AlarmFailureCode.authorizationNotDetermined.rawValue
        case .denied:
            return AlarmFailureCode.authorizationDenied.rawValue
        case .unknown:
            return AlarmFailureCode.authorizationUnknown.rawValue
        }
    }
}


@MainActor
@Observable
final class AlarmPermissionModel {
    private(set) var status = AlarmManager.shared.authorizationState
    private(set) var isRequesting = false
    private(set) var errorMessage: String?

    var isAuthorized: Bool {
        status == .authorized
    }

    var statusLabel: String {
        switch status {
        case .authorized: return "已允许"
        case .notDetermined: return "尚未请求"
        case .denied: return "已拒绝"
        @unknown default: return "未知"
        }
    }

    func refresh() {
        status = AlarmManager.shared.authorizationState
    }

    func requestAuthorization() async {
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        do {
            status = try await AlarmManager.shared.requestAuthorization()
            errorMessage = status == .authorized ? nil : "没有获得闹钟访问权限。"
        } catch {
            refresh()
            errorMessage = "闹钟授权失败：\(error.localizedDescription)"
        }
    }
}
