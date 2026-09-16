import Foundation
import Observation


struct AlarmQueryArguments: Equatable, Sendable {
    let maxResults: Int

    static func parse(_ payload: [String: JSONValue]) -> AlarmQueryArguments? {
        guard Set(payload.keys).isSubset(of: ["max_results"]) else { return nil }
        guard let value = payload["max_results"] else {
            return AlarmQueryArguments(maxResults: 100)
        }
        guard case let .number(number) = value,
              number.isFinite,
              number.rounded() == number,
              (1...100).contains(Int(number))
        else { return nil }
        return AlarmQueryArguments(maxResults: Int(number))
    }
}


struct AlarmUpdateArguments: Equatable, Sendable {
    let alarmID: UUID
    let title: String
    let schedule: AlarmDesiredSchedule
    let sound: AlarmSoundChoice

    static func parse(_ payload: [String: JSONValue]) -> AlarmUpdateArguments? {
        guard Set(payload.keys) == Set(["alarm_id", "title", "schedule", "sound"]),
              let rawID = payload["alarm_id"]?.stringValue,
              let alarmID = UUID(uuidString: rawID)
        else { return nil }
        let createPayload: [String: JSONValue] = [
            "title": payload["title"] ?? .null,
            "schedule": payload["schedule"] ?? .null,
            "sound": payload["sound"] ?? .null,
        ]
        guard let desired = AlarmCreateArguments.parse(createPayload) else { return nil }
        return AlarmUpdateArguments(
            alarmID: alarmID,
            title: desired.title,
            schedule: desired.schedule,
            sound: desired.sound
        )
    }
}


struct AlarmUpdateReconciliationEvidence: Equatable, Sendable {
    let requestedScheduleMatchesNative: Bool
    let previousScheduleMatchesNative: Bool
    let titleMatchesOwnership: Bool
    let requestedScheduleMatchesOwnership: Bool
    let soundMatchesOwnership: Bool

    var isSemanticNoOp: Bool {
        titleMatchesOwnership
            && requestedScheduleMatchesOwnership
            && soundMatchesOwnership
    }
}


enum AlarmUpdateReconciliationDecision: Equatable, Sendable {
    case completed
    case definitelyNotStarted
    case stillUnknown(String)
}


func alarmUpdateReconciliationDecision(
    _ evidence: AlarmUpdateReconciliationEvidence
) -> AlarmUpdateReconciliationDecision {
    if evidence.requestedScheduleMatchesNative && !evidence.previousScheduleMatchesNative {
        return .completed
    }
    if evidence.previousScheduleMatchesNative && !evidence.requestedScheduleMatchesNative {
        return .definitelyNotStarted
    }
    if evidence.requestedScheduleMatchesNative,
       evidence.previousScheduleMatchesNative,
       evidence.isSemanticNoOp {
        return .completed
    }
    if evidence.requestedScheduleMatchesNative && evidence.previousScheduleMatchesNative {
        return .stillUnknown("alarm_update_native_schedule_matches_both_old_and_requested_configuration")
    }
    return .stillUnknown("alarm_update_native_state_ambiguous")
}


struct AlarmLifecycleArguments: Equatable, Sendable {
    let alarmID: UUID

    static func parse(_ payload: [String: JSONValue]) -> AlarmLifecycleArguments? {
        guard Set(payload.keys) == Set(["alarm_id"]),
              let raw = payload["alarm_id"]?.stringValue,
              let alarmID = UUID(uuidString: raw)
        else { return nil }
        return AlarmLifecycleArguments(alarmID: alarmID)
    }
}


private func managedAlarmTarget(
    alarmID: UUID,
    nativeStore: any AlarmNativeStore,
    ownershipStore: AlarmOwnershipStore
) async throws -> (ownership: AlarmOwnershipRecord, native: AlarmNativeRecord?)? {
    guard let ownership = await ownershipStore.record(alarmID: alarmID),
          ownership.lifecycle != .cancelled
    else { return nil }
    let native = try await nativeStore.alarms().first { $0.id == alarmID }
    let reconciled = try await ownershipStore.recordObservation(
        alarmID: alarmID,
        nativeState: native?.state,
        isMissing: native == nil
    )
    return (reconciled, native)
}


private func unmanagedTargetFailure(
    alarmID: UUID,
    nativeStore: any AlarmNativeStore,
    ownershipStore: AlarmOwnershipStore
) async -> DeviceExecutionResult {
    do {
        if try await nativeStore.alarms().contains(where: { $0.id == alarmID }),
           await ownershipStore.record(alarmID: alarmID) == nil
        {
            return alarmFailure(.foreignTarget, extra: ["alarm_id": .string(alarmID.uuidString)])
        }
    } catch {
        return alarmFailure(.readFailed, extra: ["alarm_id": .string(alarmID.uuidString)])
    }
    return alarmFailure(.unknownTarget, extra: ["alarm_id": .string(alarmID.uuidString)])
}


enum AlarmSettingsMutationReconciliationResult: Equatable, Sendable {
    case completed
    case definitelyNotStarted
    case ambiguous(String)
}


enum AlarmSettingsMutationReconciler {
    static func reconcilePending(
        nativeStore: any AlarmNativeStore,
        ownershipStore: AlarmOwnershipStore
    ) async throws -> [UUID: AlarmSettingsMutationReconciliationResult] {
        let native = try await nativeStore.alarms()
        let nativeByID = Dictionary(uniqueKeysWithValues: native.map { ($0.id, $0) })
        var results: [UUID: AlarmSettingsMutationReconciliationResult] = [:]
        for intent in await ownershipStore.pendingSettingsMutations() {
            results[intent.alarmID] = try await reconcile(
                intent: intent,
                native: nativeByID[intent.alarmID],
                ownershipStore: ownershipStore
            )
        }
        return results
    }

    static func reconcile(
        alarmID: UUID,
        nativeStore: any AlarmNativeStore,
        ownershipStore: AlarmOwnershipStore
    ) async throws -> AlarmSettingsMutationReconciliationResult? {
        guard let intent = await ownershipStore.record(alarmID: alarmID)?.pendingSettingsMutation else {
            return nil
        }
        let native = try await nativeStore.alarms().first { $0.id == alarmID }
        return try await reconcile(intent: intent, native: native, ownershipStore: ownershipStore)
    }

    private static func reconcile(
        intent: AlarmSettingsMutationIntent,
        native: AlarmNativeRecord?,
        ownershipStore: AlarmOwnershipStore
    ) async throws -> AlarmSettingsMutationReconciliationResult {
        switch intent.operation {
        case .update:
            guard let requestedTitle = intent.requestedTitle,
                  let requestedSchedule = intent.requestedSchedule,
                  let requestedSound = intent.requestedSound
            else {
                return try await ambiguous(
                    intent, native: native, detail: "update_intent_missing_requested_fields", ownershipStore: ownershipStore
                )
            }
            guard let native else {
                return try await ambiguous(
                    intent, native: nil, detail: "update_native_alarm_missing", ownershipStore: ownershipStore
                )
            }
            let desiredMatches = requestedSchedule.matches(native.schedule)
            let beforeMatches = intent.beforeSchedule.matches(native.schedule)
            let semanticNoOp = intent.beforeTitle == requestedTitle
                && intent.beforeSchedule.isSemanticallyEquivalent(to: requestedSchedule)
                && intent.beforeSound == requestedSound

            if desiredMatches && !beforeMatches {
                _ = try await ownershipStore.completeSettingsUpdate(
                    alarmID: intent.alarmID,
                    mutationID: intent.mutationID,
                    nativeState: native.state
                )
                return .completed
            }
            if beforeMatches && !desiredMatches {
                _ = try await ownershipStore.resolveSettingsMutationNotStarted(
                    alarmID: intent.alarmID,
                    mutationID: intent.mutationID,
                    nativeState: native.state,
                    detail: "native_still_matches_known_old_schedule"
                )
                return .definitelyNotStarted
            }
            if desiredMatches && beforeMatches && semanticNoOp {
                _ = try await ownershipStore.completeSettingsUpdate(
                    alarmID: intent.alarmID,
                    mutationID: intent.mutationID,
                    nativeState: native.state
                )
                return .completed
            }
            let detail = desiredMatches && beforeMatches
                ? "native_schedule_matches_both_old_and_requested_configuration"
                : "native_schedule_matches_neither_old_nor_requested_configuration"
            return try await ambiguous(intent, native: native, detail: detail, ownershipStore: ownershipStore)

        case .cancel:
            if native == nil {
                _ = try await ownershipStore.completeSettingsCancel(
                    alarmID: intent.alarmID,
                    mutationID: intent.mutationID
                )
                return .completed
            }
            _ = try await ownershipStore.resolveSettingsMutationNotStarted(
                alarmID: intent.alarmID,
                mutationID: intent.mutationID,
                nativeState: native?.state,
                detail: "native_alarm_still_present_after_cancel_intent"
            )
            return .definitelyNotStarted

        case .pause:
            guard let native else {
                return try await ambiguous(
                    intent, native: nil, detail: "pause_native_alarm_missing", ownershipStore: ownershipStore
                )
            }
            if native.state == .paused {
                _ = try await ownershipStore.completeSettingsLifecycle(
                    alarmID: intent.alarmID,
                    mutationID: intent.mutationID,
                    nativeState: native.state
                )
                return .completed
            }
            if native.state == .countdown {
                _ = try await ownershipStore.resolveSettingsMutationNotStarted(
                    alarmID: intent.alarmID,
                    mutationID: intent.mutationID,
                    nativeState: native.state,
                    detail: "native_still_countdown_after_pause_intent"
                )
                return .definitelyNotStarted
            }
            return try await ambiguous(
                intent, native: native, detail: "pause_native_state_ambiguous_\(native.state.rawValue)", ownershipStore: ownershipStore
            )

        case .resume:
            guard let native else {
                return try await ambiguous(
                    intent, native: nil, detail: "resume_native_alarm_missing", ownershipStore: ownershipStore
                )
            }
            if native.state == .countdown || native.state == .scheduled {
                _ = try await ownershipStore.completeSettingsLifecycle(
                    alarmID: intent.alarmID,
                    mutationID: intent.mutationID,
                    nativeState: native.state
                )
                return .completed
            }
            if native.state == .paused {
                _ = try await ownershipStore.resolveSettingsMutationNotStarted(
                    alarmID: intent.alarmID,
                    mutationID: intent.mutationID,
                    nativeState: native.state,
                    detail: "native_still_paused_after_resume_intent"
                )
                return .definitelyNotStarted
            }
            return try await ambiguous(
                intent, native: native, detail: "resume_native_state_ambiguous_\(native.state.rawValue)", ownershipStore: ownershipStore
            )
        }
    }

    private static func ambiguous(
        _ intent: AlarmSettingsMutationIntent,
        native: AlarmNativeRecord?,
        detail: String,
        ownershipStore: AlarmOwnershipStore
    ) async throws -> AlarmSettingsMutationReconciliationResult {
        _ = try await ownershipStore.markSettingsMutationAmbiguous(
            alarmID: intent.alarmID,
            mutationID: intent.mutationID,
            nativeState: native?.state,
            detail: detail
        )
        return .ambiguous(detail)
    }
}


func alarmNativeScheduleJSON(_ schedule: AlarmNativeSchedule?) -> JSONValue {
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


func alarmManagedSnapshotJSON(_ snapshot: AlarmReadbackSnapshot) -> JSONValue {
    var value: [String: JSONValue] = [
        "alarm_id": .string(snapshot.alarmID.uuidString),
        "native_present": .bool(snapshot.native != nil),
        "ownership_ledger_present": .bool(snapshot.ownership != nil),
        "ownership_source": .string(snapshot.ownershipSource),
    ]
    if let native = snapshot.native {
        value["state"] = .string(native.state.rawValue)
        value["native_schedule"] = alarmNativeScheduleJSON(native.schedule)
    } else {
        value["state"] = .string("missing")
        value["native_schedule"] = .null
    }
    if let ownership = snapshot.ownership {
        value["title"] = .string(ownership.title)
        value["desired_schedule"] = ownership.schedule.jsonValue
        value["sound"] = .string(ownership.effectiveSound.rawValue)
        value["ownership_lifecycle"] = .string(ownership.lifecycle.rawValue)
        value["source_task_id"] = .string(ownership.taskID)
        value["source_action_id"] = .string(ownership.actionID)
        if let pending = ownership.pendingSettingsMutation {
            var mutation: [String: JSONValue] = [
                "mutation_id": .string(pending.mutationID),
                "operation": .string(pending.operation.rawValue),
                "state": .string(pending.state.rawValue),
            ]
            if let detail = pending.detail { mutation["detail"] = .string(detail) }
            value["settings_mutation"] = .object(mutation)
        }
    }
    return .object(value)
}


actor AlarmQueryExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID = "alarm.query"

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
        guard AlarmQueryArguments.parse(dispatch.payload) != nil else {
            return alarmFailure(.invalidArguments)
        }
        guard ownershipStore != nil else { return alarmFailure(.ownershipStoreUnavailable) }
        if let permission = alarmPermissionFailure(await nativeStore.authorizationStatus()) {
            return permission
        }
        return nil
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        guard let arguments = AlarmQueryArguments.parse(dispatch.payload) else {
            return alarmFailure(.invalidArguments)
        }
        guard let ownershipStore else { return alarmFailure(.ownershipStoreUnavailable) }
        do {
            let snapshots = try await AlarmReadbackService.enumerateOwned(
                nativeStore: nativeStore,
                ownershipStore: ownershipStore,
                maxResults: arguments.maxResults
            )
            return .success([
                "alarms": .array(snapshots.map(alarmManagedSnapshotJSON)),
                "count": .number(Double(snapshots.count)),
                "verified": .bool(true),
                "readback_source": .string("alarm_manager_and_ownership_ledger"),
                "ownership_scope": .string("floweroll_owned_only"),
            ])
        } catch {
            return alarmFailure(.queryFailed)
        }
    }

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        .completed(try await execute(dispatch))
    }
}


actor AlarmUpdateExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID = "alarm.update"

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
        guard let arguments = AlarmUpdateArguments.parse(dispatch.payload) else {
            return alarmFailure(.invalidArguments)
        }
        guard let ownershipStore else { return alarmFailure(.ownershipStoreUnavailable) }
        if let permission = alarmPermissionFailure(await nativeStore.authorizationStatus()) {
            return permission
        }
        guard let target = try await managedAlarmTarget(
            alarmID: arguments.alarmID,
            nativeStore: nativeStore,
            ownershipStore: ownershipStore
        ) else {
            return await unmanagedTargetFailure(
                alarmID: arguments.alarmID,
                nativeStore: nativeStore,
                ownershipStore: ownershipStore
            )
        }
        guard target.ownership.pendingSettingsMutation == nil else {
            return alarmFailure(
                .settingsMutationPending,
                extra: ["alarm_id": .string(arguments.alarmID.uuidString)]
            )
        }
        guard let native = target.native else {
            return alarmFailure(.readbackMissing, extra: ["alarm_id": .string(arguments.alarmID.uuidString)])
        }
        guard native.state == .scheduled else {
            return alarmFailure(
                .invalidNativeState,
                extra: [
                    "alarm_id": .string(arguments.alarmID.uuidString),
                    "native_state": .string(native.state.rawValue),
                    "required_state": .string(AlarmNativeState.scheduled.rawValue),
                ]
            )
        }
        return nil
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        guard let arguments = AlarmUpdateArguments.parse(dispatch.payload) else {
            return alarmFailure(.invalidArguments)
        }
        guard let ownershipStore else { return alarmFailure(.ownershipStoreUnavailable) }
        guard let before = try await managedAlarmTarget(
            alarmID: arguments.alarmID,
            nativeStore: nativeStore,
            ownershipStore: ownershipStore
        ) else {
            return await unmanagedTargetFailure(
                alarmID: arguments.alarmID,
                nativeStore: nativeStore,
                ownershipStore: ownershipStore
            )
        }
        guard before.ownership.pendingSettingsMutation == nil else {
            return alarmFailure(
                .settingsMutationPending,
                extra: ["alarm_id": .string(arguments.alarmID.uuidString)]
            )
        }
        guard let beforeNative = before.native else {
            return alarmFailure(.readbackMissing, extra: ["alarm_id": .string(arguments.alarmID.uuidString)])
        }
        guard beforeNative.state == .scheduled else {
            return alarmFailure(.invalidNativeState, extra: ["native_state": .string(beforeNative.state.rawValue)])
        }

        if before.ownership.lastMutationActionID == dispatch.actionID,
           before.ownership.title == arguments.title,
           before.ownership.schedule.isSemanticallyEquivalent(to: arguments.schedule),
           before.ownership.effectiveSound == arguments.sound,
           arguments.schedule.matches(beforeNative.schedule)
        {
            return Self.successResult(
                dispatch: dispatch,
                arguments: arguments,
                native: beforeNative,
                duplicateSuppressed: true,
                reconciled: false
            )
        }

        do {
            _ = try await nativeStore.schedule(
                AlarmNativeScheduleRequest(
                    id: arguments.alarmID,
                    title: arguments.title,
                    taskID: dispatch.taskID,
                    actionID: dispatch.actionID,
                    idempotencyKey: dispatch.idempotencyKey,
                    schedule: arguments.schedule,
                    sound: arguments.sound
                )
            )
        } catch {
            throw AlarmNativeStoreError.nativeFailure(AlarmFailureCode.updateFailed.rawValue)
        }
        guard let saved = try await nativeStore.alarms().first(where: { $0.id == arguments.alarmID }) else {
            throw AlarmNativeStoreError.nativeFailure(AlarmFailureCode.readbackMissing.rawValue)
        }
        guard arguments.schedule.matches(saved.schedule) else {
            return alarmFailure(.readbackMismatch, extra: ["alarm_id": .string(arguments.alarmID.uuidString)])
        }
        _ = try await ownershipStore.recordUpdated(
            alarmID: arguments.alarmID,
            taskID: dispatch.taskID,
            actionID: dispatch.actionID,
            title: arguments.title,
            schedule: arguments.schedule,
            sound: arguments.sound,
            nativeState: saved.state
        )
        return Self.successResult(
            dispatch: dispatch,
            arguments: arguments,
            native: saved,
            duplicateSuppressed: false,
            reconciled: false
        )
    }

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        guard let arguments = AlarmUpdateArguments.parse(dispatch.payload) else {
            return .completed(alarmFailure(.invalidArguments))
        }
        guard let ownershipStore else {
            return .stillUnknown(AlarmFailureCode.ownershipStoreUnavailable.rawValue)
        }
        guard await nativeStore.authorizationStatus() == .authorized else {
            return .stillUnknown(AlarmFailureCode.authorizationUnknown.rawValue)
        }
        guard let target = try await managedAlarmTarget(
            alarmID: arguments.alarmID,
            nativeStore: nativeStore,
            ownershipStore: ownershipStore
        ), let native = target.native else {
            return .stillUnknown(AlarmFailureCode.readbackMissing.rawValue)
        }
        guard target.ownership.pendingSettingsMutation == nil else {
            return .stillUnknown(AlarmFailureCode.settingsMutationPending.rawValue)
        }

        let decision = alarmUpdateReconciliationDecision(
            AlarmUpdateReconciliationEvidence(
                requestedScheduleMatchesNative: arguments.schedule.matches(native.schedule),
                previousScheduleMatchesNative: target.ownership.schedule.matches(native.schedule),
                titleMatchesOwnership: target.ownership.title == arguments.title,
                requestedScheduleMatchesOwnership: target.ownership.schedule.isSemanticallyEquivalent(
                    to: arguments.schedule
                ),
                soundMatchesOwnership: target.ownership.effectiveSound == arguments.sound
            )
        )

        switch decision {
        case .completed:
            _ = try await ownershipStore.recordUpdated(
                alarmID: arguments.alarmID,
                taskID: dispatch.taskID,
                actionID: dispatch.actionID,
                title: arguments.title,
                schedule: arguments.schedule,
                sound: arguments.sound,
                nativeState: native.state,
                now: journalEntry.updatedAt
            )
            return .completed(
                Self.successResult(
                    dispatch: dispatch,
                    arguments: arguments,
                    native: native,
                    duplicateSuppressed: true,
                    reconciled: true
                )
            )

        case .definitelyNotStarted:
            return .definitelyNotStarted

        case let .stillUnknown(reason):
            return .stillUnknown(reason)
        }
    }

    private static func successResult(
        dispatch: DeviceActionDispatch,
        arguments: AlarmUpdateArguments,
        native: AlarmNativeRecord,
        duplicateSuppressed: Bool,
        reconciled: Bool
    ) -> DeviceExecutionResult {
        .success([
            "alarm_id": .string(arguments.alarmID.uuidString),
            "same_alarm_id": .bool(native.id == arguments.alarmID),
            "updated": .bool(true),
            "verified": .bool(true),
            "native_schedule_verified": .bool(arguments.schedule.matches(native.schedule)),
            "native_state": .string(native.state.rawValue),
            "title": .string(arguments.title),
            "schedule": arguments.schedule.jsonValue,
            "sound": .string(arguments.sound.rawValue),
            "idempotency_marker": .string(dispatch.idempotencyKey),
            "duplicate_suppressed": .bool(duplicateSuppressed),
            "reconciled": .bool(reconciled),
        ], nativeCorrelationID: arguments.alarmID.uuidString)
    }
}


private enum AlarmLifecycleOperation: String, Sendable {
    case pause
    case resume

    var capabilityID: String { "alarm.\(rawValue)" }
}


private actor AlarmLifecycleExecutorCore {
    let operation: AlarmLifecycleOperation
    let nativeStore: any AlarmNativeStore
    let ownershipStore: AlarmOwnershipStore?

    init(
        operation: AlarmLifecycleOperation,
        nativeStore: any AlarmNativeStore,
        ownershipStore: AlarmOwnershipStore?
    ) {
        self.operation = operation
        self.nativeStore = nativeStore
        self.ownershipStore = ownershipStore
    }

    func preflight(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult? {
        guard let arguments = AlarmLifecycleArguments.parse(dispatch.payload) else {
            return alarmFailure(.invalidArguments)
        }
        guard let ownershipStore else { return alarmFailure(.ownershipStoreUnavailable) }
        if let permission = alarmPermissionFailure(await nativeStore.authorizationStatus()) {
            return permission
        }
        guard let target = try await managedAlarmTarget(
            alarmID: arguments.alarmID,
            nativeStore: nativeStore,
            ownershipStore: ownershipStore
        ) else {
            return await unmanagedTargetFailure(
                alarmID: arguments.alarmID,
                nativeStore: nativeStore,
                ownershipStore: ownershipStore
            )
        }
        guard target.ownership.pendingSettingsMutation == nil else {
            return alarmFailure(
                .settingsMutationPending,
                extra: ["alarm_id": .string(arguments.alarmID.uuidString)]
            )
        }
        guard let native = target.native else {
            return alarmFailure(.readbackMissing, extra: ["alarm_id": .string(arguments.alarmID.uuidString)])
        }
        switch operation {
        case .pause:
            guard native.state == .countdown || native.state == .paused else {
                return alarmFailure(.invalidNativeState, extra: ["native_state": .string(native.state.rawValue)])
            }
        case .resume:
            guard native.state == .paused else {
                return alarmFailure(.invalidNativeState, extra: ["native_state": .string(native.state.rawValue)])
            }
        }
        return nil
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        guard let arguments = AlarmLifecycleArguments.parse(dispatch.payload) else {
            return alarmFailure(.invalidArguments)
        }
        guard let ownershipStore else { return alarmFailure(.ownershipStoreUnavailable) }
        guard let target = try await managedAlarmTarget(
            alarmID: arguments.alarmID,
            nativeStore: nativeStore,
            ownershipStore: ownershipStore
        ) else {
            return await unmanagedTargetFailure(
                alarmID: arguments.alarmID,
                nativeStore: nativeStore,
                ownershipStore: ownershipStore
            )
        }
        guard target.ownership.pendingSettingsMutation == nil else {
            return alarmFailure(
                .settingsMutationPending,
                extra: ["alarm_id": .string(arguments.alarmID.uuidString)]
            )
        }
        guard let before = target.native else {
            return alarmFailure(.readbackMissing, extra: ["alarm_id": .string(arguments.alarmID.uuidString)])
        }

        if operation == .pause, before.state == .paused {
            return Self.result(
                operation: operation,
                alarmID: arguments.alarmID,
                state: .paused,
                duplicateSuppressed: true,
                reconciled: false
            )
        }

        do {
            switch operation {
            case .pause:
                guard before.state == .countdown else {
                    return alarmFailure(.invalidNativeState, extra: ["native_state": .string(before.state.rawValue)])
                }
                try await nativeStore.pause(id: arguments.alarmID)
            case .resume:
                guard before.state == .paused else {
                    return alarmFailure(.invalidNativeState, extra: ["native_state": .string(before.state.rawValue)])
                }
                try await nativeStore.resume(id: arguments.alarmID)
            }
        } catch {
            throw AlarmNativeStoreError.nativeFailure(
                operation == .pause ? AlarmFailureCode.pauseFailed.rawValue : AlarmFailureCode.resumeFailed.rawValue
            )
        }

        guard let after = try await nativeStore.alarms().first(where: { $0.id == arguments.alarmID }) else {
            throw AlarmNativeStoreError.nativeFailure(AlarmFailureCode.readbackMissing.rawValue)
        }
        let verified: Bool
        switch operation {
        case .pause: verified = after.state == .paused
        case .resume: verified = after.state == .countdown || after.state == .scheduled
        }
        guard verified else {
            return alarmFailure(
                .readbackMismatch,
                extra: [
                    "alarm_id": .string(arguments.alarmID.uuidString),
                    "native_state": .string(after.state.rawValue),
                ]
            )
        }
        _ = try await ownershipStore.recordNativeState(
            alarmID: arguments.alarmID,
            taskID: dispatch.taskID,
            actionID: dispatch.actionID,
            nativeState: after.state
        )
        return Self.result(
            operation: operation,
            alarmID: arguments.alarmID,
            state: after.state,
            duplicateSuppressed: false,
            reconciled: false
        )
    }

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        guard let arguments = AlarmLifecycleArguments.parse(dispatch.payload) else {
            return .completed(alarmFailure(.invalidArguments))
        }
        guard let ownershipStore else {
            return .stillUnknown(AlarmFailureCode.ownershipStoreUnavailable.rawValue)
        }
        guard let target = try await managedAlarmTarget(
            alarmID: arguments.alarmID,
            nativeStore: nativeStore,
            ownershipStore: ownershipStore
        ), let native = target.native else {
            return .stillUnknown(AlarmFailureCode.readbackMissing.rawValue)
        }
        guard target.ownership.pendingSettingsMutation == nil else {
            return .stillUnknown(AlarmFailureCode.settingsMutationPending.rawValue)
        }
        switch operation {
        case .pause:
            if native.state == .paused {
                _ = try await ownershipStore.recordNativeState(
                    alarmID: arguments.alarmID,
                    taskID: dispatch.taskID,
                    actionID: dispatch.actionID,
                    nativeState: native.state,
                    now: journalEntry.updatedAt
                )
                return .completed(Self.result(operation: operation, alarmID: arguments.alarmID, state: native.state, duplicateSuppressed: true, reconciled: true))
            }
            if native.state == .countdown { return .definitelyNotStarted }
        case .resume:
            if native.state == .countdown || native.state == .scheduled {
                _ = try await ownershipStore.recordNativeState(
                    alarmID: arguments.alarmID,
                    taskID: dispatch.taskID,
                    actionID: dispatch.actionID,
                    nativeState: native.state,
                    now: journalEntry.updatedAt
                )
                return .completed(Self.result(operation: operation, alarmID: arguments.alarmID, state: native.state, duplicateSuppressed: true, reconciled: true))
            }
            if native.state == .paused { return .definitelyNotStarted }
        }
        return .stillUnknown("alarm_\(operation.rawValue)_native_state_ambiguous")
    }

    private static func result(
        operation: AlarmLifecycleOperation,
        alarmID: UUID,
        state: AlarmNativeState,
        duplicateSuppressed: Bool,
        reconciled: Bool
    ) -> DeviceExecutionResult {
        .success([
            "alarm_id": .string(alarmID.uuidString),
            "operation": .string(operation.rawValue),
            "verified": .bool(true),
            "native_state": .string(state.rawValue),
            "duplicate_suppressed": .bool(duplicateSuppressed),
            "reconciled": .bool(reconciled),
        ], nativeCorrelationID: alarmID.uuidString)
    }
}


actor AlarmPauseExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID = "alarm.pause"
    private let core: AlarmLifecycleExecutorCore
    init(nativeStore: any AlarmNativeStore = SystemAlarmNativeStore(), ownershipStore: AlarmOwnershipStore? = AlarmOwnershipStore.shared) {
        core = AlarmLifecycleExecutorCore(operation: .pause, nativeStore: nativeStore, ownershipStore: ownershipStore)
    }
    func preflight(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult? { try await core.preflight(dispatch) }
    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult { try await core.execute(dispatch) }
    func reconcile(_ dispatch: DeviceActionDispatch, journalEntry: DeviceActionJournalEntry) async throws -> DeviceReconciliationResult { try await core.reconcile(dispatch, journalEntry: journalEntry) }
}


actor AlarmResumeExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID = "alarm.resume"
    private let core: AlarmLifecycleExecutorCore
    init(nativeStore: any AlarmNativeStore = SystemAlarmNativeStore(), ownershipStore: AlarmOwnershipStore? = AlarmOwnershipStore.shared) {
        core = AlarmLifecycleExecutorCore(operation: .resume, nativeStore: nativeStore, ownershipStore: ownershipStore)
    }
    func preflight(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult? { try await core.preflight(dispatch) }
    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult { try await core.execute(dispatch) }
    func reconcile(_ dispatch: DeviceActionDispatch, journalEntry: DeviceActionJournalEntry) async throws -> DeviceReconciliationResult { try await core.reconcile(dispatch, journalEntry: journalEntry) }
}


struct AlarmSettingsMutationStatus: Equatable, Sendable {
    let mutationID: String
    let operation: AlarmSettingsMutationOperation
    let state: AlarmSettingsMutationIntentState
    let detail: String?

    init(_ intent: AlarmSettingsMutationIntent) {
        mutationID = intent.mutationID
        operation = intent.operation
        state = intent.state
        detail = intent.detail
    }
}


struct FlowerollAlarmRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let schedule: AlarmDesiredSchedule
    let sound: AlarmSoundChoice
    let state: AlarmNativeState?
    let nativePresent: Bool
    let lifecycle: AlarmOwnershipLifecycle
    let mutationStatus: AlarmSettingsMutationStatus?
    let lastMutationOutcome: AlarmSettingsMutationOutcome?

    var fireDate: Date? { schedule.fireDate }
    var hasUnresolvedMutation: Bool { mutationStatus != nil }
    var canEdit: Bool { !hasUnresolvedMutation && nativePresent && state == .scheduled }
    var canPause: Bool { !hasUnresolvedMutation && nativePresent && state == .countdown }
    var canResume: Bool { !hasUnresolvedMutation && nativePresent && state == .paused }
    var canCancel: Bool { !hasUnresolvedMutation && nativePresent && lifecycle != .cancelled }
    var canDeleteFromManagement: Bool {
        !hasUnresolvedMutation
            && (canCancel || (!nativePresent && lifecycle == .missing))
    }

    var stateLabel: String {
        guard nativePresent, let state else { return "已从系统移除" }
        switch state {
        case .scheduled: return "已计划"
        case .countdown: return "倒计时中"
        case .paused: return "已暂停"
        case .alerting: return "正在响铃"
        case .unknown: return "未知"
        }
    }
}


@MainActor
@Observable
final class AlarmManagementModel {
    private(set) var alarms: [FlowerollAlarmRecord] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let nativeStore: any AlarmNativeStore
    private let ownershipStore: AlarmOwnershipStore?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    init(
        nativeStore: any AlarmNativeStore = SystemAlarmNativeStore(),
        ownershipStore: AlarmOwnershipStore? = AlarmOwnershipStore.shared
    ) {
        self.nativeStore = nativeStore
        self.ownershipStore = ownershipStore
        startObservingAlarmUpdates()
    }

    deinit { updatesTask?.cancel() }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task { @MainActor [weak self] in await self?.load() }
    }

    func update(
        _ alarm: FlowerollAlarmRecord,
        title: String,
        schedule: AlarmDesiredSchedule,
        sound: AlarmSoundChoice
    ) {
        guard !isLoading, alarm.canEdit else { return }
        guard AlarmCreateArguments.canonicalTitle(.string(title)) != nil, schedule.isValid else {
            errorMessage = "修改闹钟失败：标题或时间设置无效"
            return
        }
        isLoading = true
        Task { @MainActor [weak self] in
            guard let self, let ownershipStore else { return }
            var durableIntentPersisted = false
            do {
                guard let ownership = await ownershipStore.record(alarmID: alarm.id),
                      ownership.lifecycle != .cancelled,
                      ownership.pendingSettingsMutation == nil
                else {
                    throw AlarmNativeStoreError.nativeFailure(AlarmFailureCode.unknownTarget.rawValue)
                }
                guard let currentNative = try await nativeStore.alarms().first(where: { $0.id == alarm.id }) else {
                    throw AlarmNativeStoreError.nativeFailure(AlarmFailureCode.readbackMissing.rawValue)
                }
                guard currentNative.state == .scheduled else {
                    throw AlarmNativeStoreError.nativeFailure(AlarmFailureCode.invalidNativeState.rawValue)
                }
                let durableMutationID = "settings.manual.update.\(UUID().uuidString)"
                _ = try await ownershipStore.beginSettingsMutation(
                    alarmID: alarm.id,
                    mutationID: durableMutationID,
                    operation: .update,
                    beforeNativeState: currentNative.state,
                    requestedTitle: title,
                    requestedSchedule: schedule,
                    requestedSound: sound
                )
                durableIntentPersisted = true
                _ = try await nativeStore.schedule(
                    AlarmNativeScheduleRequest(
                        id: alarm.id,
                        title: title,
                        taskID: ownership.taskID,
                        actionID: durableMutationID,
                        idempotencyKey: durableMutationID,
                        schedule: schedule,
                        sound: sound
                    )
                )
                guard let readback = try await nativeStore.alarms().first(where: { $0.id == alarm.id }),
                      schedule.matches(readback.schedule)
                else { throw AlarmNativeStoreError.nativeFailure(AlarmFailureCode.readbackMismatch.rawValue) }
                _ = try await ownershipStore.completeSettingsUpdate(
                    alarmID: alarm.id,
                    mutationID: durableMutationID,
                    nativeState: readback.state
                )
                await load()
            } catch {
                let resolution = durableIntentPersisted
                    ? try? await AlarmSettingsMutationReconciler.reconcile(
                        alarmID: alarm.id, nativeStore: nativeStore, ownershipStore: ownershipStore
                    )
                    : nil
                await load()
                if resolution == .completed { return }
                if case .ambiguous = resolution {
                    errorMessage = nil
                    return
                }
                errorMessage = "修改闹钟失败：\(error.localizedDescription)"
            }
        }
    }

    func pause(_ alarm: FlowerollAlarmRecord) { mutateLifecycle(alarm, operation: .pause) }
    func resume(_ alarm: FlowerollAlarmRecord) { mutateLifecycle(alarm, operation: .resume) }

    func cancel(_ alarm: FlowerollAlarmRecord) {
        guard !isLoading, alarm.canCancel else { return }
        isLoading = true
        Task { @MainActor [weak self] in
            guard let self, let ownershipStore else { return }
            var durableIntentPersisted = false
            do {
                guard let currentNative = try await nativeStore.alarms().first(where: { $0.id == alarm.id }) else {
                    throw AlarmNativeStoreError.nativeFailure(AlarmFailureCode.readbackMissing.rawValue)
                }
                let mutationID = "settings.manual.cancel.\(UUID().uuidString)"
                _ = try await ownershipStore.beginSettingsMutation(
                    alarmID: alarm.id,
                    mutationID: mutationID,
                    operation: .cancel,
                    beforeNativeState: currentNative.state
                )
                durableIntentPersisted = true
                try await nativeStore.cancel(id: alarm.id)
                guard !(try await nativeStore.alarms().contains { $0.id == alarm.id }) else {
                    throw AlarmNativeStoreError.nativeFailure(AlarmFailureCode.stillPresentAfterCancel.rawValue)
                }
                _ = try await ownershipStore.completeSettingsCancel(
                    alarmID: alarm.id,
                    mutationID: mutationID
                )
                await load()
            } catch {
                let resolution = durableIntentPersisted
                    ? try? await AlarmSettingsMutationReconciler.reconcile(
                        alarmID: alarm.id, nativeStore: nativeStore, ownershipStore: ownershipStore
                    )
                    : nil
                await load()
                if resolution == .completed { return }
                if case .ambiguous = resolution {
                    errorMessage = nil
                    return
                }
                errorMessage = "取消闹钟失败：\(error.localizedDescription)"
            }
        }
    }

    func deleteFromManagement(_ alarm: FlowerollAlarmRecord) {
        guard !isLoading, alarm.canDeleteFromManagement else { return }
        if alarm.nativePresent {
            cancel(alarm)
            return
        }
        guard alarm.lifecycle == .missing else { return }
        guard let ownershipStore else {
            errorMessage = "删除闹钟记录失败：本地归属记录不可用"
            return
        }
        isLoading = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await ownershipStore.removeMissingRecord(alarmID: alarm.id)
                await load()
            } catch {
                await load()
                errorMessage = "删除闹钟记录失败：\(error.localizedDescription)"
            }
        }
    }

    private func mutateLifecycle(_ alarm: FlowerollAlarmRecord, operation: AlarmLifecycleOperation) {
        guard !isLoading else { return }
        guard (operation == .pause && alarm.canPause) || (operation == .resume && alarm.canResume) else { return }
        isLoading = true
        Task { @MainActor [weak self] in
            guard let self, let ownershipStore else { return }
            var durableIntentPersisted = false
            do {
                guard let currentNative = try await nativeStore.alarms().first(where: { $0.id == alarm.id }) else {
                    throw AlarmNativeStoreError.nativeFailure(AlarmFailureCode.readbackMissing.rawValue)
                }
                let expectedStateIsValid = operation == .pause
                    ? currentNative.state == .countdown
                    : currentNative.state == .paused
                guard expectedStateIsValid else {
                    throw AlarmNativeStoreError.nativeFailure(AlarmFailureCode.invalidNativeState.rawValue)
                }
                let settingsOperation: AlarmSettingsMutationOperation = operation == .pause ? .pause : .resume
                let mutationID = "settings.manual.\(operation.rawValue).\(UUID().uuidString)"
                _ = try await ownershipStore.beginSettingsMutation(
                    alarmID: alarm.id,
                    mutationID: mutationID,
                    operation: settingsOperation,
                    beforeNativeState: currentNative.state
                )
                durableIntentPersisted = true
                switch operation {
                case .pause: try await nativeStore.pause(id: alarm.id)
                case .resume: try await nativeStore.resume(id: alarm.id)
                }
                guard let readback = try await nativeStore.alarms().first(where: { $0.id == alarm.id }) else {
                    throw AlarmNativeStoreError.nativeFailure(AlarmFailureCode.readbackMissing.rawValue)
                }
                let valid = operation == .pause
                    ? readback.state == .paused
                    : (readback.state == .countdown || readback.state == .scheduled)
                guard valid else { throw AlarmNativeStoreError.nativeFailure(AlarmFailureCode.readbackMismatch.rawValue) }
                _ = try await ownershipStore.completeSettingsLifecycle(
                    alarmID: alarm.id,
                    mutationID: mutationID,
                    nativeState: readback.state
                )
                await load()
            } catch {
                let resolution = durableIntentPersisted
                    ? try? await AlarmSettingsMutationReconciler.reconcile(
                        alarmID: alarm.id, nativeStore: nativeStore, ownershipStore: ownershipStore
                    )
                    : nil
                await load()
                if resolution == .completed { return }
                if case .ambiguous = resolution {
                    errorMessage = nil
                    return
                }
                errorMessage = operation == .pause
                    ? "暂停闹钟失败：\(error.localizedDescription)"
                    : "恢复闹钟失败：\(error.localizedDescription)"
            }
        }
    }

    private func startObservingAlarmUpdates() {
        let updates = nativeStore.alarmUpdates()
        updatesTask = Task { @MainActor [weak self] in
            for await _ in updates {
                guard !Task.isCancelled else { return }
                guard let self, !self.isLoading else { continue }
                await self.load(resetLoading: false)
            }
        }
    }

    private func load(resetLoading: Bool = true) async {
        defer { if resetLoading { isLoading = false } }
        guard await nativeStore.authorizationStatus() == .authorized else {
            alarms = []
            errorMessage = nil
            return
        }
        guard let ownershipStore else {
            alarms = []
            errorMessage = "读取小卷闹钟失败：本地归属记录不可用"
            return
        }
        do {
            _ = try await AlarmSettingsMutationReconciler.reconcilePending(
                nativeStore: nativeStore,
                ownershipStore: ownershipStore
            )
            let snapshots = try await AlarmReadbackService.enumerateOwned(
                nativeStore: nativeStore,
                ownershipStore: ownershipStore
            )
            alarms = snapshots.compactMap { snapshot in
                guard let ownership = snapshot.ownership else { return nil }
                return FlowerollAlarmRecord(
                    id: snapshot.alarmID,
                    title: ownership.title,
                    schedule: ownership.schedule,
                    sound: ownership.effectiveSound,
                    state: snapshot.native?.state,
                    nativePresent: snapshot.native != nil,
                    lifecycle: ownership.lifecycle,
                    mutationStatus: ownership.pendingSettingsMutation.map(AlarmSettingsMutationStatus.init),
                    lastMutationOutcome: ownership.lastSettingsMutationOutcome
                )
            }
            .sorted { lhs, rhs in
                switch (lhs.fireDate, rhs.fireDate) {
                case let (a?, b?): return a < b
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.id.uuidString < rhs.id.uuidString
                }
            }
            errorMessage = nil
        } catch {
            alarms = []
            errorMessage = "读取小卷闹钟失败：\(error.localizedDescription)"
        }
    }
}
