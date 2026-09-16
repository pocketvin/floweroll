import Foundation


struct AlarmReadArguments: Equatable, Sendable {
    let alarmID: UUID

    static func parse(_ payload: [String: JSONValue]) -> AlarmReadArguments? {
        guard Set(payload.keys) == Set(["alarm_id"]),
              let raw = payload["alarm_id"]?.stringValue,
              let alarmID = UUID(uuidString: raw)
        else { return nil }
        return AlarmReadArguments(alarmID: alarmID)
    }
}


actor AlarmReadExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID = "alarm.read"

    private let nativeStore: any AlarmNativeStore
    private let ownershipStore: AlarmOwnershipStore?

    init(
        nativeStore: any AlarmNativeStore = SystemAlarmNativeStore(),
        ownershipStore: AlarmOwnershipStore? = AlarmOwnershipStore.shared
    ) {
        self.nativeStore = nativeStore
        self.ownershipStore = ownershipStore
    }

    func preflight(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult? {
        guard AlarmReadArguments.parse(dispatch.payload) != nil else {
            return alarmFailure(.invalidArguments)
        }
        if let permission = alarmPermissionFailure(await nativeStore.authorizationStatus()) {
            return permission
        }
        return nil
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        guard let arguments = AlarmReadArguments.parse(dispatch.payload) else {
            return alarmFailure(.invalidArguments)
        }
        do {
            guard let snapshot = try await AlarmReadbackService.read(
                alarmID: arguments.alarmID,
                nativeStore: nativeStore,
                ownershipStore: ownershipStore
            ) else {
                return alarmFailure(
                    .unknownTarget,
                    extra: ["alarm_id": .string(arguments.alarmID.uuidString)]
                )
            }
            return Self.result(snapshot)
        } catch {
            return alarmFailure(
                .readFailed,
                extra: ["alarm_id": .string(arguments.alarmID.uuidString)]
            )
        }
    }

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        guard let arguments = AlarmReadArguments.parse(dispatch.payload) else {
            return .completed(alarmFailure(.invalidArguments))
        }
        let authorization = await nativeStore.authorizationStatus()
        guard authorization == .authorized else {
            return .completed(
                alarmPermissionFailure(authorization)
                    ?? alarmFailure(.authorizationUnknown)
            )
        }
        do {
            guard let snapshot = try await AlarmReadbackService.read(
                alarmID: arguments.alarmID,
                nativeStore: nativeStore,
                ownershipStore: ownershipStore
            ) else {
                return .completed(
                    alarmFailure(
                        .unknownTarget,
                        extra: ["alarm_id": .string(arguments.alarmID.uuidString)]
                    )
                )
            }
            return .completed(Self.result(snapshot, reconciled: true))
        } catch {
            return .completed(
                alarmFailure(
                    .readFailed,
                    extra: ["alarm_id": .string(arguments.alarmID.uuidString)]
                )
            )
        }
    }

    private static func result(
        _ snapshot: AlarmReadbackSnapshot,
        reconciled: Bool = false
    ) -> DeviceExecutionResult {
        var output: [String: JSONValue] = [
            "alarm_id": .string(snapshot.alarmID.uuidString),
            "exists": .bool(snapshot.native != nil),
            "current_client_owned": .bool(snapshot.native != nil),
            "ownership_ledger_present": .bool(snapshot.ownership != nil),
            "ownership_source": .string(snapshot.ownershipSource),
            "readback_source": .string("alarm_manager_and_ownership_ledger"),
            "reconciled": .bool(reconciled),
        ]

        if let native = snapshot.native {
            output["native_state"] = .string(native.state.rawValue)
            output["native_schedule"] = Self.nativeScheduleJSON(native.schedule)
        }
        if let ownership = snapshot.ownership {
            output["title"] = .string(ownership.title)
            output["title_source"] = .string("ownership_ledger")
            output["task_id"] = .string(ownership.taskID)
            output["action_id"] = .string(ownership.actionID)
            output["desired_schedule"] = ownership.schedule.jsonValue
            output["sound"] = .string(ownership.effectiveSound.rawValue)
            output["ownership_lifecycle"] = .string(ownership.lifecycle.rawValue)
        }

        return .success(output, nativeCorrelationID: snapshot.alarmID.uuidString)
    }

    private static func nativeScheduleJSON(_ schedule: AlarmNativeSchedule?) -> JSONValue {
        guard let schedule else { return .null }
        switch schedule {
        case let .fixed(date):
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return .object([
                "kind": .string("fixed"),
                "fire_at": .string(formatter.string(from: date)),
                "timezone_semantics": .string("absolute_instant"),
            ])
        case let .weekly(hour, minute, weekdays):
            return .object([
                "kind": .string("weekly"),
                "hour": .number(Double(hour)),
                "minute": .number(Double(minute)),
                "weekdays": .array(weekdays.map { .string($0.rawValue) }),
                "timezone_semantics": .string("device_current_timezone"),
            ])
        case let .relativeOnce(hour, minute):
            return .object([
                "kind": .string("relative_once"),
                "hour": .number(Double(hour)),
                "minute": .number(Double(minute)),
                "timezone_semantics": .string("device_current_timezone"),
            ])
        case .unsupported:
            return .object(["kind": .string("unsupported_native_schedule")])
        }
    }
}
