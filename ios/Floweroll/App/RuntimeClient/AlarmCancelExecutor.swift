import Foundation


struct AlarmCancelArguments: Equatable, Sendable {
    let alarmID: UUID

    static func parse(_ payload: [String: JSONValue]) -> AlarmCancelArguments? {
        guard Set(payload.keys) == Set(["alarm_id"]),
              let raw = payload["alarm_id"]?.stringValue,
              let alarmID = UUID(uuidString: raw)
        else { return nil }
        return AlarmCancelArguments(alarmID: alarmID)
    }
}


actor AlarmCancelExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID = "alarm.cancel"

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
        guard let arguments = AlarmCancelArguments.parse(dispatch.payload) else {
            return alarmFailure(.invalidArguments)
        }
        guard ownershipStore != nil else {
            return alarmFailure(.ownershipStoreUnavailable)
        }
        if let permission = alarmPermissionFailure(await nativeStore.authorizationStatus()) {
            return permission
        }
        guard let ownershipStore else {
            return alarmFailure(.ownershipStoreUnavailable)
        }
        do {
            guard let ownership = await ownershipStore.record(alarmID: arguments.alarmID) else {
                let nativeExists = try await nativeStore.alarms().contains { $0.id == arguments.alarmID }
                return alarmFailure(
                    nativeExists ? .foreignTarget : .unknownTarget,
                    extra: ["alarm_id": .string(arguments.alarmID.uuidString)]
                )
            }
            guard ownership.pendingSettingsMutation == nil else {
                return alarmFailure(
                    .settingsMutationPending,
                    extra: ["alarm_id": .string(arguments.alarmID.uuidString)]
                )
            }
        } catch {
            return alarmFailure(.readFailed)
        }
        return nil
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        guard let arguments = AlarmCancelArguments.parse(dispatch.payload) else {
            return alarmFailure(.invalidArguments)
        }
        guard let ownershipStore else {
            return alarmFailure(.ownershipStoreUnavailable)
        }
        guard let ownership = await ownershipStore.record(alarmID: arguments.alarmID) else {
            let nativeExists = try await nativeStore.alarms().contains { $0.id == arguments.alarmID }
            return alarmFailure(
                nativeExists ? .foreignTarget : .unknownTarget,
                extra: ["alarm_id": .string(arguments.alarmID.uuidString)]
            )
        }
        guard ownership.pendingSettingsMutation == nil else {
            return alarmFailure(
                .settingsMutationPending,
                extra: ["alarm_id": .string(arguments.alarmID.uuidString)]
            )
        }
        let beforeNative = try await nativeStore.alarms().first { $0.id == arguments.alarmID }
        if ownership.lifecycle == .cancelled, beforeNative == nil {
            return Self.successResult(
                alarmID: arguments.alarmID,
                nativeWasPresent: false,
                ownershipVerified: true,
                duplicateSuppressed: true,
                reconciled: false
            )
        }
        if beforeNative != nil {
            do {
                try await nativeStore.cancel(id: arguments.alarmID)
            } catch {
                throw AlarmNativeStoreError.nativeFailure(AlarmFailureCode.cancelFailed.rawValue)
            }
        }

        let stillPresent = try await nativeStore.alarms().contains {
            $0.id == arguments.alarmID
        }
        guard !stillPresent else {
            return alarmFailure(
                .stillPresentAfterCancel,
                extra: ["alarm_id": .string(arguments.alarmID.uuidString)]
            )
        }
        if await ownershipStore.record(alarmID: arguments.alarmID) != nil {
            _ = try await ownershipStore.markCancelled(
                alarmID: arguments.alarmID,
                taskID: dispatch.taskID,
                actionID: dispatch.actionID
            )
        }
        return Self.successResult(
            alarmID: arguments.alarmID,
            nativeWasPresent: beforeNative != nil,
            ownershipVerified: true,
            duplicateSuppressed: beforeNative == nil,
            reconciled: false
        )
    }

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        guard let arguments = AlarmCancelArguments.parse(dispatch.payload) else {
            return .completed(alarmFailure(.invalidArguments))
        }
        guard let ownershipStore else {
            return .stillUnknown(AlarmFailureCode.ownershipStoreUnavailable.rawValue)
        }
        let authorization = await nativeStore.authorizationStatus()
        guard authorization == .authorized else {
            return .stillUnknown(Self.authorizationReconciliationReason(authorization))
        }

        guard let ownership = await ownershipStore.record(alarmID: arguments.alarmID) else {
            return .stillUnknown(AlarmFailureCode.ownershipStoreUnavailable.rawValue)
        }
        guard ownership.pendingSettingsMutation == nil else {
            return .stillUnknown(AlarmFailureCode.settingsMutationPending.rawValue)
        }
        let snapshot = try await AlarmReadbackService.read(
            alarmID: arguments.alarmID,
            nativeStore: nativeStore,
            ownershipStore: ownershipStore
        )
        if snapshot?.native != nil {
            // Native presence proves the desired cancel effect is not complete.
            // It is safe for DeviceExecutionCoordinator to retry the same cancel.
            return .definitelyNotStarted
        }
        if await ownershipStore.record(alarmID: arguments.alarmID) != nil {
            _ = try await ownershipStore.markCancelled(
                alarmID: arguments.alarmID,
                taskID: dispatch.taskID,
                actionID: dispatch.actionID,
                now: journalEntry.updatedAt
            )
        }
        // Preflight admitted an exact Floweroll-owned target before mayHaveStarted.
        // Absence now is authoritative desired-state evidence for that same owner.
        return .completed(
            Self.successResult(
                alarmID: arguments.alarmID,
                nativeWasPresent: false,
                ownershipVerified: snapshot?.ownership != nil,
                duplicateSuppressed: false,
                reconciled: true
            )
        )
    }

    private static func successResult(
        alarmID: UUID,
        nativeWasPresent: Bool,
        ownershipVerified: Bool,
        duplicateSuppressed: Bool,
        reconciled: Bool
    ) -> DeviceExecutionResult {
        .success(
            [
                "alarm_id": .string(alarmID.uuidString),
                "cancelled": .bool(true),
                "verified_absent": .bool(true),
                "native_was_present": .bool(nativeWasPresent),
                "ownership_ledger_verified": .bool(ownershipVerified),
                "readback_source": .string("alarm_manager_absence"),
                "duplicate_suppressed": .bool(duplicateSuppressed),
                "reconciled": .bool(reconciled),
            ],
            nativeCorrelationID: alarmID.uuidString
        )
    }

    private static func authorizationReconciliationReason(
        _ status: AlarmAuthorizationStatus
    ) -> String {
        switch status {
        case .authorized: return ""
        case .notDetermined: return AlarmFailureCode.authorizationNotDetermined.rawValue
        case .denied: return AlarmFailureCode.authorizationDenied.rawValue
        case .unknown: return AlarmFailureCode.authorizationUnknown.rawValue
        }
    }
}
