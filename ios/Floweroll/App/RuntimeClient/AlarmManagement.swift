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
        if intent.operation == .update, intent.replacementPhase != nil {
            guard let title = intent.requestedTitle, let schedule = intent.requestedSchedule,
                  let sound = intent.requestedSound,
                  let owner = await ownershipStore.record(alarmID: intent.alarmID)
            else { return .ambiguous("replacement_intent_invalid") }
            let request = AlarmNativeScheduleRequest(id: intent.alarmID, title: title, taskID: owner.taskID,
                actionID: intent.mutationID, idempotencyKey: intent.mutationID, schedule: schedule, sound: sound)
            switch try await AlarmConfigurationReplacement.reconcile(
                request: request, nativeSnapshot: native,
                ownershipStore: ownershipStore, stopRequested: false
            ) {
            case .settled(.updated): return .completed
            case let .settled(.failed(reason, _)): return .ambiguous(reason)
            case .resume: return .ambiguous("replacement_pending_recovery")
            case let .unknown(reason): return .ambiguous(reason)
            }
        }
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

    init(nativeStore: any AlarmNativeStore = SystemAlarmNativeStore(),
         ownershipStore: AlarmOwnershipStore? = AlarmOwnershipStore.shared) {
        self.nativeStore = nativeStore
        self.ownershipStore = ownershipStore
    }

    private func nativeRequest(_ dispatch: DeviceActionDispatch, _ args: AlarmUpdateArguments) -> AlarmNativeScheduleRequest {
        AlarmNativeScheduleRequest(id: args.alarmID, title: args.title, taskID: dispatch.taskID,
                                   actionID: dispatch.actionID, idempotencyKey: dispatch.idempotencyKey,
                                   schedule: args.schedule, sound: args.sound)
    }

    func preflight(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult? {
        guard let args = AlarmUpdateArguments.parse(dispatch.payload) else { return alarmFailure(.invalidArguments) }
        guard let ownershipStore else { return alarmFailure(.ownershipStoreUnavailable) }
        if let permission = alarmPermissionFailure(await nativeStore.authorizationStatus()) { return permission }
        guard let owner = await ownershipStore.record(alarmID: args.alarmID), owner.lifecycle != .cancelled else {
            return await unmanagedTargetFailure(alarmID: args.alarmID, nativeStore: nativeStore, ownershipStore: ownershipStore)
        }
        if let pending = owner.pendingSettingsMutation {
            guard pending.mutationID == dispatch.actionID, pending.operation == .update,
                  pending.replacementPhase != nil,
                  pending.requestedTitle == args.title, pending.requestedSound == args.sound,
                  pending.requestedSchedule?.isSemanticallyEquivalent(to: args.schedule) == true
            else { return alarmFailure(.settingsMutationPending) }
            return nil
        }
        guard let native = try await nativeStore.alarms().first(where: { $0.id == args.alarmID }) else {
            return alarmFailure(.readbackMissing)
        }
        guard native.state == .scheduled else { return alarmFailure(.invalidNativeState) }
        return nil
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        guard let args = AlarmUpdateArguments.parse(dispatch.payload) else { return alarmFailure(.invalidArguments) }
        guard let ownershipStore else { return alarmFailure(.ownershipStoreUnavailable) }
        if let failure = try await preflight(dispatch) { return failure }
        if let owner = await ownershipStore.record(alarmID: args.alarmID),
           owner.pendingSettingsMutation == nil,
           owner.lastMutationActionID == dispatch.actionID,
           owner.title == args.title, owner.effectiveSound == args.sound,
           owner.schedule.isSemanticallyEquivalent(to: args.schedule),
           let native = try await nativeStore.alarms().first(where: { $0.id == args.alarmID }),
           args.schedule.matches(native.schedule) {
            return Self.successResult(dispatch: dispatch, arguments: args, native: native,
                                      duplicateSuppressed: true, reconciled: false)
        }
        let result = try await AlarmConfigurationReplacement.execute(
            request: nativeRequest(dispatch, args), nativeStore: nativeStore, ownershipStore: ownershipStore
        )
        return resultForReplacement(result, dispatch: dispatch, arguments: args, reconciled: false)
    }

    func reconcile(_ dispatch: DeviceActionDispatch, journalEntry: DeviceActionJournalEntry) async throws -> DeviceReconciliationResult {
        guard let args = AlarmUpdateArguments.parse(dispatch.payload) else { return .completed(alarmFailure(.invalidArguments)) }
        guard let ownershipStore else { return .stillUnknown(AlarmFailureCode.ownershipStoreUnavailable.rawValue) }
        guard await nativeStore.authorizationStatus() == .authorized else { return .stillUnknown(AlarmFailureCode.authorizationUnknown.rawValue) }
        guard let owner = await ownershipStore.record(alarmID: args.alarmID) else {
            return .stillUnknown(AlarmFailureCode.readbackMissing.rawValue)
        }
        let native = try await nativeStore.alarms().first { $0.id == args.alarmID }

        // A trusted exact-ID cancellation receipt plus native absence means the
        // old update is superseded, not that it "never started". Deliver a
        // settled failure; Host's pending cancellation can then finish safely.
        if owner.lifecycle == .cancelled, native == nil,
           let cancelledAt = owner.cancelledAt, cancelledAt >= journalEntry.createdAt,
           let cancellationID = owner.cancelledByActionID,
           !cancellationID.isEmpty, owner.lastMutationActionID == cancellationID {
            return .completed(.failure("目标闹钟已被取消，先前修改已停止。", output: [
                "error_code": .string("alarm_update_superseded_by_cancel"),
                "alarm_id": .string(args.alarmID.uuidString),
                "native_absence_verified": .bool(true), "cancellation_receipt": .string(cancellationID)
            ]))
        }
        guard owner.lifecycle != .cancelled else { return .stillUnknown("alarm_cancel_receipt_or_native_state_unresolved") }
        if let pending = owner.pendingSettingsMutation {
            guard pending.mutationID == dispatch.actionID, pending.replacementPhase != nil else {
                return .stillUnknown(AlarmFailureCode.settingsMutationPending.rawValue)
            }
            let recovery = try await AlarmConfigurationReplacement.reconcile(
                request: nativeRequest(dispatch, args), nativeStore: nativeStore,
                ownershipStore: ownershipStore, stopRequested: dispatch.reconciliationOnly == true
            )
            switch recovery {
            case let .settled(result):
                return .completed(resultForReplacement(result, dispatch: dispatch, arguments: args, reconciled: true))
            case .resume:
                return .resumeAuthorizedOperation
            case let .unknown(reason):
                return .stillUnknown(reason)
            }
        }
        if let outcome = owner.lastSettingsMutationOutcome,
           outcome.mutationID == dispatch.actionID, outcome.resolution == .failed {
            return .completed(.failure(outcome.detail ?? "闹钟修改未完成。", output: [
                "error_code": .string(AlarmFailureCode.updateFailed.rawValue),
                "original_restored": .bool(native != nil), "alarm_id": .string(args.alarmID.uuidString)
            ]))
        }
        guard let native else { return .stillUnknown(AlarmFailureCode.readbackMissing.rawValue) }
        // Installed legacy attempts have no replacement journal. Preserve the
        // conservative old readback behavior, but their next execution uses the
        // new transaction instead of repeated schedule(existing ID).
        let decision = alarmUpdateReconciliationDecision(AlarmUpdateReconciliationEvidence(
            requestedScheduleMatchesNative: args.schedule.matches(native.schedule),
            previousScheduleMatchesNative: owner.schedule.matches(native.schedule),
            titleMatchesOwnership: owner.title == args.title,
            requestedScheduleMatchesOwnership: owner.schedule.isSemanticallyEquivalent(to: args.schedule),
            soundMatchesOwnership: owner.effectiveSound == args.sound
        ))
        switch decision {
        case .completed:
            _ = try await ownershipStore.recordUpdated(alarmID: args.alarmID, taskID: dispatch.taskID,
                actionID: dispatch.actionID, title: args.title, schedule: args.schedule, sound: args.sound,
                nativeState: native.state, now: journalEntry.updatedAt)
            return .completed(Self.successResult(dispatch: dispatch, arguments: args, native: native,
                                                duplicateSuppressed: true, reconciled: true))
        case .definitelyNotStarted: return .definitelyNotStarted
        case let .stillUnknown(reason): return .stillUnknown(reason)
        }
    }

    private func resultForReplacement(_ result: AlarmReplacementResult, dispatch: DeviceActionDispatch,
                                      arguments: AlarmUpdateArguments, reconciled: Bool) -> DeviceExecutionResult {
        switch result {
        case let .updated(native):
            return Self.successResult(dispatch: dispatch, arguments: arguments, native: native,
                                      duplicateSuppressed: reconciled, reconciled: reconciled)
        case let .failed(reason, originalRestored):
            return .failure(reason, output: ["error_code": .string(AlarmFailureCode.updateFailed.rawValue),
                "original_restored": .bool(originalRestored), "alarm_id": .string(arguments.alarmID.uuidString)])
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
        if lastMutationOutcome?.resolution == .failed {
            return nativePresent ? "修改未完成，原闹钟已保留" : "修改未完成，闹钟已移除"
        }
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
                let result = try await AlarmConfigurationReplacement.execute(
                    request: AlarmNativeScheduleRequest(
                        id: alarm.id, title: title, taskID: ownership.taskID,
                        actionID: durableMutationID, idempotencyKey: durableMutationID,
                        schedule: schedule, sound: sound
                    ), nativeStore: nativeStore, ownershipStore: ownershipStore
                )
                if case let .failed(reason, _) = result {
                    await load()
                    errorMessage = reason
                    return
                }
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


// MARK: - Durable AlarmKit configuration replacement

private actor AlarmReplacementExecutionGate {
    static let shared = AlarmReplacementExecutionGate()
    private var active = Set<UUID>()
    func acquire(_ id: UUID) -> Bool { active.insert(id).inserted }
    func release(_ id: UUID) { active.remove(id) }
    func contains(_ id: UUID) -> Bool { active.contains(id) }
}

enum AlarmReplacementResult: Equatable, Sendable {
    case updated(AlarmNativeRecord)
    case failed(reason: String, originalRestored: Bool)
}

enum AlarmReplacementRecovery: Equatable, Sendable {
    case settled(AlarmReplacementResult)
    case resume
    case unknown(String)
}

/// AlarmKit exposes cancel and schedule, not an atomic configuration update.
/// Keep the product/native ID, but only schedule after exact-ID absence has
/// been read back. The durable intent fences settings vs Task execution and
/// retains the original configuration for rollback across process loss.
enum AlarmConfigurationReplacement {
    static func execute(
        request: AlarmNativeScheduleRequest,
        nativeStore: any AlarmNativeStore,
        ownershipStore: AlarmOwnershipStore
    ) async throws -> AlarmReplacementResult {
        guard await AlarmReplacementExecutionGate.shared.acquire(request.id) else {
            throw AlarmNativeStoreError.nativeFailure("alarm_replacement_already_executing")
        }
        do {
            let result = try await executeOwned(request: request, nativeStore: nativeStore, ownershipStore: ownershipStore)
            await AlarmReplacementExecutionGate.shared.release(request.id)
            return result
        } catch {
            await AlarmReplacementExecutionGate.shared.release(request.id)
            throw error
        }
    }

    private static func executeOwned(
        request: AlarmNativeScheduleRequest,
        nativeStore: any AlarmNativeStore,
        ownershipStore: AlarmOwnershipStore
    ) async throws -> AlarmReplacementResult {
        guard await nativeStore.authorizationStatus() == .authorized else {
            throw AlarmNativeStoreError.nativeFailure(AlarmFailureCode.authorizationDenied.rawValue)
        }
        guard let owner = await ownershipStore.record(alarmID: request.id), owner.lifecycle != .cancelled else {
            return .failed(reason: "目标闹钟已经取消，不会重新创建。", originalRestored: false)
        }
        if let pending = owner.pendingSettingsMutation {
            guard matches(pending, request) else { throw AlarmOwnershipStoreError.settingsMutationAlreadyPending }
        } else {
            guard let before = try await nativeStore.alarms().first(where: { $0.id == request.id }),
                  before.state == .scheduled, owner.schedule.matches(before.schedule)
            else { throw AlarmNativeStoreError.nativeFailure(AlarmFailureCode.readbackMismatch.rawValue) }
            _ = try await ownershipStore.beginSettingsMutation(
                alarmID: request.id, mutationID: request.actionID, operation: .update,
                beforeNativeState: before.state, requestedTitle: request.title,
                requestedSchedule: request.schedule, requestedSound: request.sound
            )
        }
        if await ownershipStore.record(alarmID: request.id)?.pendingSettingsMutation?.replacementPhase == nil {
            _ = try await ownershipStore.advanceReplacement(
                alarmID: request.id, mutationID: request.actionID, phase: .removingOriginal
            )
        }

        // Each transition is durable before its next native side effect. A
        // single invocation normally traverses removal, replacement, readback.
        for _ in 0..<5 {
            try Task.checkCancellation()
            guard let current = await ownershipStore.record(alarmID: request.id),
                  current.lifecycle != .cancelled,
                  let intent = current.pendingSettingsMutation, matches(intent, request),
                  let phase = intent.replacementPhase
            else { throw AlarmOwnershipStoreError.settingsMutationIdentityConflict }
            let native = try await nativeStore.alarms().first { $0.id == request.id }
            switch phase {
            case .removingOriginal:
                if let native {
                    guard intent.beforeSchedule.matches(native.schedule), native.state == .scheduled else {
                        throw AlarmNativeStoreError.nativeFailure("alarm_replacement_original_changed")
                    }
                    do { try await nativeStore.cancel(id: request.id) }
                    catch {
                        let after = try await nativeStore.alarms().first { $0.id == request.id }
                        if let after, intent.beforeSchedule.matches(after.schedule) {
                            return try await fail(request, native: after, reason: "无法取消旧配置，原闹钟已保留。", store: ownershipStore)
                        }
                        if after != nil { throw error }
                        // A lost cancellation ACK is recoverable via exact absence.
                    }
                }
                guard !(try await nativeStore.alarms().contains { $0.id == request.id }) else {
                    throw AlarmNativeStoreError.nativeFailure(AlarmFailureCode.stillPresentAfterCancel.rawValue)
                }
                _ = try await ownershipStore.advanceReplacement(
                    alarmID: request.id, mutationID: request.actionID, phase: .schedulingReplacement
                )

            case .schedulingReplacement:
                if let native {
                    guard request.schedule.matches(native.schedule) else {
                        throw AlarmNativeStoreError.nativeFailure("alarm_replacement_target_changed")
                    }
                    return try await complete(request, native: native, store: ownershipStore)
                }
                if (intent.replacementAttempts ?? 0) >= 3 {
                    _ = try await ownershipStore.advanceReplacement(
                        alarmID: request.id, mutationID: request.actionID, phase: .restoringOriginal
                    )
                    continue
                }
                _ = try await ownershipStore.advanceReplacement(
                    alarmID: request.id, mutationID: request.actionID, phase: .schedulingReplacement, countAttempt: true
                )
                do { _ = try await nativeStore.schedule(request) }
                catch {
                    let after = try await nativeStore.alarms().first { $0.id == request.id }
                    if let after, request.schedule.matches(after.schedule) {
                        return try await complete(request, native: after, store: ownershipStore)
                    }
                    if after != nil { throw error }
                    // A definitive empty readback allows rollback, not a second
                    // create against an uncertain/existing native object.
                    _ = try await ownershipStore.advanceReplacement(
                        alarmID: request.id, mutationID: request.actionID, phase: .restoringOriginal
                    )
                    continue
                }
                guard let saved = try await nativeStore.alarms().first(where: { $0.id == request.id }),
                      request.schedule.matches(saved.schedule)
                else {
                    _ = try await ownershipStore.advanceReplacement(
                        alarmID: request.id, mutationID: request.actionID, phase: .restoringOriginal
                    )
                    continue
                }
                return try await complete(request, native: saved, store: ownershipStore)

            case .restoringOriginal:
                if let native {
                    guard intent.beforeSchedule.matches(native.schedule) else {
                        throw AlarmNativeStoreError.nativeFailure("alarm_rollback_native_state_ambiguous")
                    }
                    return try await fail(request, native: native, reason: "新配置未写入，已恢复原闹钟。", store: ownershipStore)
                }
                if (intent.replacementAttempts ?? 0) >= 3 {
                    return try await fail(request, native: nil,
                        reason: "闹钟修改失败且原配置未能恢复；该闹钟当前不存在，请重新设置。", store: ownershipStore)
                }
                _ = try await ownershipStore.advanceReplacement(
                    alarmID: request.id, mutationID: request.actionID, phase: .restoringOriginal, countAttempt: true
                )
                let original = AlarmNativeScheduleRequest(
                    id: request.id, title: intent.beforeTitle, taskID: request.taskID,
                    actionID: request.actionID, idempotencyKey: request.idempotencyKey,
                    schedule: intent.beforeSchedule, sound: intent.beforeSound
                )
                do { _ = try await nativeStore.schedule(original) }
                catch {
                    if let restored = try await nativeStore.alarms().first(where: { $0.id == request.id }),
                       intent.beforeSchedule.matches(restored.schedule) {
                        return try await fail(request, native: restored, reason: "新配置未写入，已恢复原闹钟。", store: ownershipStore)
                    }
                    throw error // durable rollback phase is retried within its bound.
                }
                guard let restored = try await nativeStore.alarms().first(where: { $0.id == request.id }),
                      intent.beforeSchedule.matches(restored.schedule)
                else { throw AlarmNativeStoreError.nativeFailure("alarm_rollback_readback_missing") }
                return try await fail(request, native: restored, reason: "新配置未写入，已恢复原闹钟。", store: ownershipStore)
            }
        }
        throw AlarmNativeStoreError.nativeFailure("alarm_replacement_transition_bound")
    }

    static func reconcile(
        request: AlarmNativeScheduleRequest, nativeStore: any AlarmNativeStore,
        ownershipStore: AlarmOwnershipStore, stopRequested: Bool
    ) async throws -> AlarmReplacementRecovery {
        let snapshot = try await nativeStore.alarms().first { $0.id == request.id }
        return try await reconcile(request: request,
            nativeSnapshot: snapshot,
            ownershipStore: ownershipStore, stopRequested: stopRequested)
    }

    static func reconcile(
        request: AlarmNativeScheduleRequest, nativeSnapshot: AlarmNativeRecord?,
        ownershipStore: AlarmOwnershipStore, stopRequested: Bool
    ) async throws -> AlarmReplacementRecovery {
        guard !(await AlarmReplacementExecutionGate.shared.contains(request.id)) else {
            return .unknown("alarm_replacement_currently_executing")
        }
        guard let owner = await ownershipStore.record(alarmID: request.id),
              let intent = owner.pendingSettingsMutation, matches(intent, request),
              let phase = intent.replacementPhase
        else { return .unknown("alarm_replacement_intent_missing") }
        let native = nativeSnapshot
        if phase == .schedulingReplacement, let native, request.schedule.matches(native.schedule) {
            return .settled(try await complete(request, native: native, store: ownershipStore))
        }
        if phase == .restoringOriginal, let native, intent.beforeSchedule.matches(native.schedule) {
            return .settled(try await fail(request, native: native, reason: "新配置未写入，已恢复原闹钟。", store: ownershipStore))
        }
        if stopRequested {
            if native == nil {
                return .settled(try await fail(request, native: nil,
                    reason: "已停止修改；原闹钟已在更改过程中移除，不会自动重建。", store: ownershipStore))
            }
            if phase == .removingOriginal, let native, intent.beforeSchedule.matches(native.schedule) {
                return .settled(try await fail(request, native: native, reason: "已停止修改，原闹钟保持不变。", store: ownershipStore))
            }
            return .unknown("alarm_stop_replacement_native_state_ambiguous")
        }
        if native == nil || (phase == .removingOriginal && intent.beforeSchedule.matches(native?.schedule)) {
            return .resume
        }
        return .unknown("alarm_replacement_native_state_ambiguous")
    }

    static func recoverManualUpdates(
        nativeStore: any AlarmNativeStore = SystemAlarmNativeStore(),
        ownershipStore: AlarmOwnershipStore? = AlarmOwnershipStore.shared
    ) async {
        guard let ownershipStore, await nativeStore.authorizationStatus() == .authorized else { return }
        for intent in await ownershipStore.pendingSettingsMutations()
        where intent.replacementPhase != nil && intent.mutationID.hasPrefix("settings.manual.update.") {
            guard !Task.isCancelled,
                  let owner = await ownershipStore.record(alarmID: intent.alarmID),
                  let title = intent.requestedTitle, let schedule = intent.requestedSchedule,
                  let sound = intent.requestedSound else { continue }
            let request = AlarmNativeScheduleRequest(
                id: intent.alarmID, title: title, taskID: owner.taskID,
                actionID: intent.mutationID, idempotencyKey: intent.mutationID,
                schedule: schedule, sound: sound
            )
            _ = try? await execute(request: request, nativeStore: nativeStore, ownershipStore: ownershipStore)
        }
    }

    private static func matches(_ intent: AlarmSettingsMutationIntent, _ request: AlarmNativeScheduleRequest) -> Bool {
        intent.mutationID == request.actionID && intent.operation == .update && intent.alarmID == request.id
            && intent.requestedTitle == request.title && intent.requestedSound == request.sound
            && intent.requestedSchedule?.isSemanticallyEquivalent(to: request.schedule) == true
    }

    private static func complete(_ request: AlarmNativeScheduleRequest, native: AlarmNativeRecord,
                                 store: AlarmOwnershipStore) async throws -> AlarmReplacementResult {
        _ = try await store.completeSettingsUpdate(alarmID: request.id, mutationID: request.actionID, nativeState: native.state)
        return .updated(native)
    }

    private static func fail(_ request: AlarmNativeScheduleRequest, native: AlarmNativeRecord?, reason: String,
                             store: AlarmOwnershipStore) async throws -> AlarmReplacementResult {
        _ = try await store.finishReplacementFailure(
            alarmID: request.id, mutationID: request.actionID, nativeState: native?.state, detail: reason
        )
        return .failed(reason: reason, originalRestored: native != nil)
    }
}
