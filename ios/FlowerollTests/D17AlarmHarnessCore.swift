import AlarmKit
import Foundation
import SwiftUI
import UIKit
#if canImport(Floweroll)
@testable import Floweroll
#endif
#if canImport(Darwin)
import Darwin
#endif

#if canImport(Floweroll)
private extension DeviceActionDispatch {
    init(
        actionID: String,
        taskID: String,
        actionType: String,
        payload: [String: JSONValue],
        idempotencyKey: String,
        attemptID: String
    ) {
        self.init(
            actionID: actionID,
            taskID: taskID,
            actionType: actionType,
            payload: payload,
            status: "READY",
            runtimeActionStatus: nil,
            idempotencyKey: idempotencyKey,
            attemptID: attemptID,
            attemptNumber: 1,
            attemptStatus: "READY",
            dispatchDigest: "d16-\(attemptID)"
        )
    }
}
#endif

private enum HarnessError: Error, CustomStringConvertible {
    case assertion(String)
    case preflight(String, [String: JSONValue])

    var description: String {
        switch self {
        case let .assertion(message):
            return message
        case let .preflight(error, output):
            return "preflight_failed:\(error):\(output)"
        }
    }
}

private struct D16Scenario: Codable {
    let runID: String
    let taskID: String
    let mainKey: String
    let countdownKey: String
    let ringKey: String
    let recoveryKey: String
    let mainAlarmID: UUID
    let countdownAlarmID: UUID
    let ringAlarmID: UUID
    let recoveryAlarmID: UUID
    let initialTitle: String
    let updatedTitle: String
    let initialFireAt: String
    let updatedFireAt: String
    let plannerRecoveryFireAt: String
    let settingsRecoveryFireAt: String
    var ringFireAt: String?
    let createdAt: Date
}

private struct D16CountdownMetadata: AlarmMetadata {
    let runID: String
    let taskID: String
    let actionID: String
}

#if !canImport(Floweroll)
@main
struct D16AlarmAcceptanceApp: App {
    @State private var displayText = "Floweroll D16 AlarmKit Acceptance"

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 14) {
                Image(systemName: "alarm.waves.left.and.right")
                    .font(.system(size: 42))
                Text("Floweroll Alarm D16")
                    .font(.headline)
                Text(displayText)
                    .font(.footnote.monospaced())
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .task {
                let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
                let command = arguments.first ?? "status"
                let invocationID = arguments.dropFirst().first
                displayText = "Running: \(command)"
                await D16Runner.run(command: command, invocationID: invocationID)
            }
        }
    }
}
#endif

@MainActor
enum D16Runner {
    private static let nativeStore = SystemAlarmNativeStore()
    private static let ringLeadTime: TimeInterval = 90
    private static let countdownDuration: TimeInterval = 10 * 60

    static func execute(command: String) async throws -> [String: JSONValue] {
        switch command {
        case "status": return try await status()
        case "request-auth": return try await requestAuthorization()
        case "core": return try await coreCreateUpdateQuery()
        case "planner-update-prepare": return try await plannerUpdatePrepare()
        case "planner-update-recover": return try await plannerUpdateRecover()
        case "ambiguous-title-prepare": return try await ambiguousTitlePrepare()
        case "ambiguous-title-recover": return try await ambiguousTitleRecover()
        case "settings-update-prepare": return try await settingsUpdatePrepare()
        case "settings-update-recover": return try await settingsUpdateRecover()
        case "countdown-pause-resume": return try await countdownPauseResume()
        case "cancel-main": return try await cancelMain()
        case "settings-cancel-prepare": return try await settingsCancelPrepare()
        case "settings-cancel-recover": return try await settingsCancelRecover()
        case "ring-prepare": return try await ringPrepare()
        case "ring-readback": return try await ringReadback()
        case "cleanup": return try await cleanup()
        case "purge-local":
            try purgeAllHarnessLocalState()
            return ["local_state_purged": .bool(true)]
        default:
            throw HarnessError.assertion("unknown_command:\(command)")
        }
    }

    static func run(command: String, invocationID: String? = nil) async {
        do {
            let result = try await execute(command: command)
            emitSuccess(command: command, invocationID: invocationID, result: result)
            terminateSoon(code: 0)
        } catch {
            var envelope: [String: JSONValue] = [
                "ok": .bool(false),
                "command": .string(command),
                "error": .string(String(describing: error)),
                "cleanup_required": .bool(true),
                "physical_final_acceptance": .string("NOT_RUN_OR_INCOMPLETE"),
                "identity": .object(identityJSON()),
                "timestamp": .string(iso8601(Date())),
            ]
            envelope["invocation_id"] = invocationID.map(JSONValue.string) ?? .null
            emit(envelope)
            terminateSoon(code: 2)
        }
    }

    private static func emitSuccess(command: String, invocationID: String?, result: [String: JSONValue]) {
        var envelope: [String: JSONValue] = [
            "ok": .bool(true),
            "command": .string(command),
            "result": .object(result),
            "identity": .object(identityJSON()),
            "timestamp": .string(iso8601(Date())),
        ]
        envelope["invocation_id"] = invocationID.map(JSONValue.string) ?? .null
        emit(envelope)
    }

    private static func status() async throws -> [String: JSONValue] {
        let authorization = await nativeStore.authorizationStatus()
        let native = try await nativeStore.alarms()
        let ownership = try makeOwnershipStore()
        return [
            "authorization_status": .string(authorization.rawValue),
            "native_current_client_count": .number(Double(native.count)),
            "native_current_client_alarms": .array(native.map(nativeJSON)),
            "ownership_record_count": .number(Double((await ownership.allRecords()).count)),
            "ownership_records": .array((await ownership.allRecords()).map(ownershipJSON)),
            "scenario_present": .bool(FileManager.default.fileExists(atPath: (try scenarioURL()).path)),
        ]
    }

    private static func requestAuthorization() async throws -> [String: JSONValue] {
        let before = await nativeStore.authorizationStatus()
        let model = AlarmPermissionModel()
        await model.requestAuthorization()
        model.refresh()
        let after = await nativeStore.authorizationStatus()
        return [
            "before": .string(before.rawValue),
            "after": .string(after.rawValue),
            "production_permission_model_status": .string(model.statusLabel),
            "production_permission_model_error": model.errorMessage.map(JSONValue.string) ?? .null,
        ]
    }

    private static func coreCreateUpdateQuery() async throws -> [String: JSONValue] {
        try await requireAuthorized()
        let baselineNative = try await nativeStore.alarms()
        guard baselineNative.isEmpty else {
            throw HarnessError.assertion("unexpected_existing_d16_client_alarms:\(baselineNative.count)")
        }
        let ownershipStore = try makeOwnershipStore()
        guard await ownershipStore.allRecords().isEmpty else {
            throw HarnessError.assertion("unexpected_existing_d16_ownership_records")
        }

        let runID = UUID().uuidString.lowercased()
        let taskID = "d16.task.\(runID)"
        let mainKey = "floweroll-d16-main-\(runID)"
        let countdownKey = "floweroll-d16-countdown-\(runID)"
        let ringKey = "floweroll-d16-ring-\(runID)"
        let recoveryKey = "floweroll-d16-recovery-\(runID)"
        let now = Date()
        let scenario = D16Scenario(
            runID: runID,
            taskID: taskID,
            mainKey: mainKey,
            countdownKey: countdownKey,
            ringKey: ringKey,
            recoveryKey: recoveryKey,
            mainAlarmID: AlarmIdentity.stableAlarmID(for: mainKey),
            countdownAlarmID: AlarmIdentity.stableAlarmID(for: countdownKey),
            ringAlarmID: AlarmIdentity.stableAlarmID(for: ringKey),
            recoveryAlarmID: AlarmIdentity.stableAlarmID(for: recoveryKey),
            initialTitle: "Floweroll D16 主闹钟",
            updatedTitle: "Floweroll D16 已更新",
            initialFireAt: iso8601(now.addingTimeInterval(45 * 60)),
            updatedFireAt: iso8601(now.addingTimeInterval(50 * 60)),
            plannerRecoveryFireAt: iso8601(now.addingTimeInterval(55 * 60)),
            settingsRecoveryFireAt: iso8601(now.addingTimeInterval(60 * 60)),
            ringFireAt: nil,
            createdAt: now
        )
        try saveScenario(scenario)

        let create = AlarmCreateExecutor(nativeStore: nativeStore, ownershipStore: ownershipStore, usageDescriptionAvailable: { true })
        let update = AlarmUpdateExecutor(nativeStore: nativeStore, ownershipStore: ownershipStore)
        let read = AlarmReadExecutor(nativeStore: nativeStore, ownershipStore: ownershipStore)
        let query = AlarmQueryExecutor(nativeStore: nativeStore, ownershipStore: ownershipStore)

        let createRequest = createDispatch(
            scenario: scenario,
            actionSuffix: "main",
            alarmID: scenario.mainAlarmID,
            key: scenario.mainKey,
            title: scenario.initialTitle,
            fireAt: scenario.initialFireAt
        )
        try await requirePreflightClear(create, dispatch: createRequest)
        let createResult = try await create.execute(createRequest)
        try requireSuccess(createResult, label: "alarm.create")
        guard createResult.output["alarm_id"]?.stringValue == scenario.mainAlarmID.uuidString,
              createResult.nativeCorrelationID == scenario.mainAlarmID.uuidString
        else { throw HarnessError.assertion("create_stable_alarm_id_mismatch") }
        let ownershipAfterCreate = try XCTLike.unwrap(
            await ownershipStore.record(alarmID: scenario.mainAlarmID),
            "main_ownership_missing_after_create"
        )

        let beforeUpdate = try requireNative(alarmID: scenario.mainAlarmID, in: try await nativeStore.alarms())
        let updateRequest = updateDispatch(
            scenario: scenario,
            suffix: "core",
            title: scenario.updatedTitle,
            fireAt: scenario.updatedFireAt
        )
        try await requirePreflightClear(update, dispatch: updateRequest)
        let updateResult = try await update.execute(updateRequest)
        try requireSuccess(updateResult, label: "alarm.update")
        let afterUpdate = try requireNative(alarmID: scenario.mainAlarmID, in: try await nativeStore.alarms())
        guard beforeUpdate.id == afterUpdate.id,
              afterUpdate.id == scenario.mainAlarmID,
              updateResult.output["same_alarm_id"]?.boolValue == true,
              desiredFixed(scenario.updatedFireAt).matches(afterUpdate.schedule)
        else { throw HarnessError.assertion("same_id_update_contract_failed") }

        let readResult = try await read.execute(readDispatch(scenario: scenario, suffix: "core", alarmID: scenario.mainAlarmID))
        try requireSuccess(readResult, label: "alarm.read")
        guard readResult.output["alarm_id"]?.stringValue == scenario.mainAlarmID.uuidString,
              readResult.output["exists"]?.boolValue == true,
              readResult.output["native_state"]?.stringValue == AlarmNativeState.scheduled.rawValue
        else { throw HarnessError.assertion("readback_same_id_state_failed") }

        let queryResult = try await query.execute(queryDispatch(scenario: scenario, suffix: "core"))
        try requireSuccess(queryResult, label: "alarm.query")
        guard queryContainsAlarm(queryResult, alarmID: scenario.mainAlarmID) else {
            throw HarnessError.assertion("query_missing_same_alarm_id")
        }

        let ownership = try XCTLike.unwrap(await ownershipStore.record(alarmID: scenario.mainAlarmID), "main_ownership_missing")
        return [
            "run_id": .string(scenario.runID),
            "task_id": .string(scenario.taskID),
            "alarm_id": .string(scenario.mainAlarmID.uuidString),
            "stable_alarm_id": .bool(true),
            "create_action_id": .string(createRequest.actionID),
            "update_action_id": .string(updateRequest.actionID),
            "before_update_native": nativeJSON(beforeUpdate),
            "after_update_native": nativeJSON(afterUpdate),
            "same_native_id_before_after": .bool(beforeUpdate.id == afterUpdate.id),
            "create_result": resultJSON(createResult),
            "ownership_after_create": ownershipJSON(ownershipAfterCreate),
            "update_result": resultJSON(updateResult),
            "read_result": resultJSON(readResult),
            "query_result": resultJSON(queryResult),
            "ownership_after_update": ownershipJSON(ownership),
            "expected_transition": .string("scheduled(old schedule) -> scheduled(new schedule), same alarm_id"),
        ]
    }

    private static func plannerUpdatePrepare() async throws -> [String: JSONValue] {
        let scenario = try loadScenario()
        let ownershipStore = try makeOwnershipStore()
        let beforeOwnership = try XCTLike.unwrap(await ownershipStore.record(alarmID: scenario.mainAlarmID), "main_ownership_missing")
        let beforeNative = try requireNative(alarmID: scenario.mainAlarmID, in: try await nativeStore.alarms())
        guard beforeNative.state == .scheduled else { throw HarnessError.assertion("planner_prepare_requires_scheduled") }

        let request = plannerRecoveryDispatch(scenario)
        let requested = desiredFixed(scenario.plannerRecoveryFireAt)
        _ = try await nativeStore.schedule(
            AlarmNativeScheduleRequest(
                id: scenario.mainAlarmID,
                title: "Floweroll D16 Planner 恢复",
                taskID: request.taskID,
                actionID: request.actionID,
                idempotencyKey: request.idempotencyKey,
                schedule: requested,
                sound: .defaultSound
            )
        )
        let afterNative = try requireNative(alarmID: scenario.mainAlarmID, in: try await nativeStore.alarms())
        let afterOwnership = try XCTLike.unwrap(await ownershipStore.record(alarmID: scenario.mainAlarmID), "ownership_lost_after_native_side_effect")
        guard afterNative.id == beforeNative.id,
              requested.matches(afterNative.schedule),
              !afterOwnership.schedule.isSemanticallyEquivalent(to: requested),
              afterOwnership.title == beforeOwnership.title
        else { throw HarnessError.assertion("planner_prepare_did_not_leave_may_have_started_window") }

        return recoveryPrepareResult(
            scenario: scenario,
            request: request,
            beforeNative: beforeNative,
            afterNative: afterNative,
            beforeOwnership: beforeOwnership,
            afterOwnership: afterOwnership,
            expected: "new native schedule exists; durable ownership still old; exit before reconcile"
        )
    }

    private static func plannerUpdateRecover() async throws -> [String: JSONValue] {
        let scenario = try loadScenario()
        let ownershipStore = try makeOwnershipStore()
        let request = plannerRecoveryDispatch(scenario)
        let executor = AlarmUpdateExecutor(nativeStore: nativeStore, ownershipStore: ownershipStore)
        let beforeNative = try requireNative(alarmID: scenario.mainAlarmID, in: try await nativeStore.alarms())
        let beforeOwnership = try XCTLike.unwrap(await ownershipStore.record(alarmID: scenario.mainAlarmID), "ownership_missing_before_reconcile")
        let outcome = try await executor.reconcile(request, journalEntry: journalEntry(request))
        guard case let .completed(result) = outcome, result.success else {
            throw HarnessError.assertion("planner_same_id_reconcile_not_completed:\(outcome)")
        }
        let afterNative = try requireNative(alarmID: scenario.mainAlarmID, in: try await nativeStore.alarms())
        let afterOwnership = try XCTLike.unwrap(await ownershipStore.record(alarmID: scenario.mainAlarmID), "ownership_missing_after_reconcile")
        let expected = desiredFixed(scenario.plannerRecoveryFireAt)
        guard afterNative.id == scenario.mainAlarmID,
              expected.matches(afterNative.schedule),
              afterOwnership.schedule.isSemanticallyEquivalent(to: expected),
              afterOwnership.title == "Floweroll D16 Planner 恢复"
        else { throw HarnessError.assertion("planner_same_id_reconcile_truth_mismatch") }
        return [
            "run_id": .string(scenario.runID),
            "task_id": .string(request.taskID),
            "action_id": .string(request.actionID),
            "alarm_id": .string(scenario.mainAlarmID.uuidString),
            "before_native": nativeJSON(beforeNative),
            "after_native": nativeJSON(afterNative),
            "before_ownership": ownershipJSON(beforeOwnership),
            "after_ownership": ownershipJSON(afterOwnership),
            "reconciliation": reconciliationJSON(outcome),
            "expected_transition": .string("may-have-started changed-schedule -> completed; same alarm_id ownership repaired"),
        ]
    }

    private static func ambiguousTitlePrepare() async throws -> [String: JSONValue] {
        let scenario = try loadScenario()
        let ownershipStore = try makeOwnershipStore()
        let ownership = try XCTLike.unwrap(await ownershipStore.record(alarmID: scenario.mainAlarmID), "ownership_missing_before_ambiguous_title")
        let beforeNative = try requireNative(alarmID: scenario.mainAlarmID, in: try await nativeStore.alarms())
        let request = ambiguousTitleDispatch(scenario, schedule: ownership.schedule)
        _ = try await nativeStore.schedule(
            AlarmNativeScheduleRequest(
                id: scenario.mainAlarmID,
                title: "Floweroll D16 不可读标题",
                taskID: request.taskID,
                actionID: request.actionID,
                idempotencyKey: request.idempotencyKey,
                schedule: ownership.schedule,
                sound: ownership.effectiveSound
            )
        )
        let afterNative = try requireNative(alarmID: scenario.mainAlarmID, in: try await nativeStore.alarms())
        let afterOwnership = try XCTLike.unwrap(await ownershipStore.record(alarmID: scenario.mainAlarmID), "ownership_missing_after_ambiguous_prepare")
        guard ownership.schedule.matches(afterNative.schedule),
              afterOwnership.title == ownership.title,
              afterOwnership.effectiveSound == ownership.effectiveSound
        else { throw HarnessError.assertion("ambiguous_title_prepare_overwrote_durable_ownership") }
        return recoveryPrepareResult(
            scenario: scenario,
            request: request,
            beforeNative: beforeNative,
            afterNative: afterNative,
            beforeOwnership: ownership,
            afterOwnership: afterOwnership,
            expected: "native schedule matches old+requested; title changed across opaque AlarmKit boundary; exit before reconcile"
        )
    }

    private static func ambiguousTitleRecover() async throws -> [String: JSONValue] {
        let scenario = try loadScenario()
        let ownershipStore = try makeOwnershipStore()
        let beforeOwnership = try XCTLike.unwrap(await ownershipStore.record(alarmID: scenario.mainAlarmID), "ownership_missing_before_ambiguous_recover")
        let request = ambiguousTitleDispatch(scenario, schedule: beforeOwnership.schedule)
        let executor = AlarmUpdateExecutor(nativeStore: nativeStore, ownershipStore: ownershipStore)
        let outcome = try await executor.reconcile(request, journalEntry: journalEntry(request))
        guard case let .stillUnknown(reason) = outcome else {
            throw HarnessError.assertion("title_only_may_have_started_must_remain_unknown:\(outcome)")
        }
        let afterOwnership = try XCTLike.unwrap(await ownershipStore.record(alarmID: scenario.mainAlarmID), "ownership_missing_after_ambiguous_recover")
        guard afterOwnership.title == beforeOwnership.title,
              afterOwnership.effectiveSound == beforeOwnership.effectiveSound,
              afterOwnership.schedule.isSemanticallyEquivalent(to: beforeOwnership.schedule)
        else { throw HarnessError.assertion("ambiguous_reconcile_promoted_unreadable_fields") }
        return [
            "run_id": .string(scenario.runID),
            "task_id": .string(request.taskID),
            "action_id": .string(request.actionID),
            "alarm_id": .string(scenario.mainAlarmID.uuidString),
            "reconciliation": reconciliationJSON(outcome),
            "reason": reason.map(JSONValue.string) ?? .null,
            "ownership_before": ownershipJSON(beforeOwnership),
            "ownership_after": ownershipJSON(afterOwnership),
            "title_preserved": .bool(afterOwnership.title == beforeOwnership.title),
            "sound_preserved": .bool(afterOwnership.effectiveSound == beforeOwnership.effectiveSound),
            "sound_physical_note": .string("Production supports only default sound; D16 does not invent an unsupported sound variant. D15 deterministic sound-only reconciliation remains the source-level proof."),
            "expected_transition": .string("same schedule + unreadable title/sound evidence -> stillUnknown; durable ownership not promoted"),
        ]
    }

    private static func settingsUpdatePrepare() async throws -> [String: JSONValue] {
        let scenario = try loadScenario()
        let ownershipStore = try makeOwnershipStore()
        let beforeOwnership = try XCTLike.unwrap(await ownershipStore.record(alarmID: scenario.mainAlarmID), "ownership_missing_before_settings_update")
        let beforeNative = try requireNative(alarmID: scenario.mainAlarmID, in: try await nativeStore.alarms())
        guard beforeNative.state == .scheduled else { throw HarnessError.assertion("settings_update_prepare_requires_scheduled") }
        let mutationID = settingsUpdateMutationID(scenario)
        let requestedSchedule = desiredFixed(scenario.settingsRecoveryFireAt)
        _ = try await ownershipStore.beginSettingsMutation(
            alarmID: scenario.mainAlarmID,
            mutationID: mutationID,
            operation: .update,
            beforeNativeState: beforeNative.state,
            requestedTitle: "Floweroll D16 Settings 恢复",
            requestedSchedule: requestedSchedule,
            requestedSound: .defaultSound
        )
        _ = try await nativeStore.schedule(
            AlarmNativeScheduleRequest(
                id: scenario.mainAlarmID,
                title: "Floweroll D16 Settings 恢复",
                taskID: beforeOwnership.taskID,
                actionID: mutationID,
                idempotencyKey: mutationID,
                schedule: requestedSchedule,
                sound: .defaultSound
            )
        )
        let afterNative = try requireNative(alarmID: scenario.mainAlarmID, in: try await nativeStore.alarms())
        let afterOwnership = try XCTLike.unwrap(await ownershipStore.record(alarmID: scenario.mainAlarmID), "ownership_missing_after_settings_prepare")
        guard afterOwnership.pendingSettingsMutation?.mutationID == mutationID,
              requestedSchedule.matches(afterNative.schedule),
              !afterOwnership.schedule.isSemanticallyEquivalent(to: requestedSchedule)
        else { throw HarnessError.assertion("settings_update_prepare_window_not_durable") }
        return [
            "run_id": .string(scenario.runID),
            "alarm_id": .string(scenario.mainAlarmID.uuidString),
            "mutation_id": .string(mutationID),
            "before_native": nativeJSON(beforeNative),
            "after_native": nativeJSON(afterNative),
            "ownership_before": ownershipJSON(beforeOwnership),
            "ownership_after_native_before_reconcile": ownershipJSON(afterOwnership),
            "process_exit_required": .bool(true),
            "expected_transition": .string("durable Settings update intent -> native new schedule -> process exit before ownership completion"),
        ]
    }

    private static func settingsUpdateRecover() async throws -> [String: JSONValue] {
        let scenario = try loadScenario()
        let ownershipStore = try makeOwnershipStore()
        let beforeOwnership = try XCTLike.unwrap(await ownershipStore.record(alarmID: scenario.mainAlarmID), "ownership_missing_before_settings_recover")
        let resolution = try await AlarmSettingsMutationReconciler.reconcile(
            alarmID: scenario.mainAlarmID,
            nativeStore: nativeStore,
            ownershipStore: ownershipStore
        )
        guard resolution == .completed else {
            throw HarnessError.assertion("settings_update_recovery_not_completed:\(String(describing: resolution))")
        }
        let afterOwnership = try XCTLike.unwrap(await ownershipStore.record(alarmID: scenario.mainAlarmID), "ownership_missing_after_settings_recover")
        let afterNative = try requireNative(alarmID: scenario.mainAlarmID, in: try await nativeStore.alarms())
        let expected = desiredFixed(scenario.settingsRecoveryFireAt)
        guard afterOwnership.pendingSettingsMutation == nil,
              afterOwnership.schedule.isSemanticallyEquivalent(to: expected),
              afterOwnership.title == "Floweroll D16 Settings 恢复",
              expected.matches(afterNative.schedule),
              afterNative.id == scenario.mainAlarmID
        else { throw HarnessError.assertion("settings_update_recovery_truth_mismatch") }
        return [
            "run_id": .string(scenario.runID),
            "alarm_id": .string(scenario.mainAlarmID.uuidString),
            "mutation_id": .string(settingsUpdateMutationID(scenario)),
            "resolution": settingsResolutionJSON(resolution),
            "ownership_before": ownershipJSON(beforeOwnership),
            "ownership_after": ownershipJSON(afterOwnership),
            "native_after": nativeJSON(afterNative),
            "expected_transition": .string("pending Settings update journal -> completed; same-ID native and durable desired truth converge"),
        ]
    }

    private static func countdownPauseResume() async throws -> [String: JSONValue] {
        let scenario = try loadScenario()
        let ownershipStore = try makeOwnershipStore()
        let create = AlarmCreateExecutor(nativeStore: nativeStore, ownershipStore: ownershipStore, usageDescriptionAvailable: { true })
        let pause = AlarmPauseExecutor(nativeStore: nativeStore, ownershipStore: ownershipStore)
        let resume = AlarmResumeExecutor(nativeStore: nativeStore, ownershipStore: ownershipStore)
        let cancel = AlarmCancelExecutor(nativeStore: nativeStore, ownershipStore: ownershipStore)
        let fireAt = iso8601(Date().addingTimeInterval(countdownDuration))
        let createRequest = createDispatch(
            scenario: scenario,
            actionSuffix: "countdown",
            alarmID: scenario.countdownAlarmID,
            key: scenario.countdownKey,
            title: "Floweroll D16 Countdown Fixture",
            fireAt: fireAt
        )
        try await requirePreflightClear(create, dispatch: createRequest)
        let created = try await create.execute(createRequest)
        try requireSuccess(created, label: "countdown_fixture_create")

        // Test-only fixture: switch the already Floweroll-owned same ID into a real AlarmKit timer.
        // Production Alarm semantics are not changed. This is solely to exercise production
        // pause/resume against genuine Alarm.State.countdown / .paused on a physical device.
        let beforeFixture = try requireNative(alarmID: scenario.countdownAlarmID, in: try await nativeStore.alarms())
        let configured = try await scheduleNativeCountdownFixture(
            id: scenario.countdownAlarmID,
            scenario: scenario,
            actionID: "d16.fixture.countdown.\(scenario.runID)"
        )
        guard configured.id == scenario.countdownAlarmID else {
            throw HarnessError.assertion("countdown_fixture_changed_native_id")
        }
        let countdownNative = try await waitForNativeState(alarmID: scenario.countdownAlarmID, state: .countdown, timeout: 3.0)

        let pauseRequest = lifecycleDispatch(scenario: scenario, suffix: "pause", alarmID: scenario.countdownAlarmID, actionType: "alarm.pause")
        try await requirePreflightClear(pause, dispatch: pauseRequest)
        let pauseResult = try await pause.execute(pauseRequest)
        try requireSuccess(pauseResult, label: "alarm.pause")
        let pausedNative = try await waitForNativeState(alarmID: scenario.countdownAlarmID, state: .paused, timeout: 3.0)

        let resumeRequest = lifecycleDispatch(scenario: scenario, suffix: "resume", alarmID: scenario.countdownAlarmID, actionType: "alarm.resume")
        try await requirePreflightClear(resume, dispatch: resumeRequest)
        let resumeResult = try await resume.execute(resumeRequest)
        try requireSuccess(resumeResult, label: "alarm.resume")
        let resumedNative = try await waitForNativeState(alarmID: scenario.countdownAlarmID, state: .countdown, timeout: 3.0)

        let cancelRequest = cancelDispatch(scenario: scenario, suffix: "countdown", alarmID: scenario.countdownAlarmID)
        try await requirePreflightClear(cancel, dispatch: cancelRequest)
        let cancelResult = try await cancel.execute(cancelRequest)
        try requireSuccess(cancelResult, label: "countdown_fixture_cancel")
        let cancelledOwnership = try XCTLike.unwrap(await ownershipStore.record(alarmID: scenario.countdownAlarmID), "countdown_ownership_missing_after_cancel")
        guard !(try await nativeStore.alarms()).contains(where: { $0.id == scenario.countdownAlarmID }),
              cancelledOwnership.lifecycle == .cancelled
        else { throw HarnessError.assertion("countdown_fixture_cleanup_failed") }

        return [
            "run_id": .string(scenario.runID),
            "task_id": .string(scenario.taskID),
            "alarm_id": .string(scenario.countdownAlarmID.uuidString),
            "fixture_kind": .string("test_only_alarmkit_timer_configuration"),
            "production_semantics_modified": .bool(false),
            "before_fixture_native": nativeJSON(beforeFixture),
            "countdown_native": nativeJSON(countdownNative),
            "pause_action_id": .string(pauseRequest.actionID),
            "pause_result": resultJSON(pauseResult),
            "paused_native": nativeJSON(pausedNative),
            "resume_action_id": .string(resumeRequest.actionID),
            "resume_result": resultJSON(resumeResult),
            "resumed_native": nativeJSON(resumedNative),
            "cancel_result": resultJSON(cancelResult),
            "ownership_after_cleanup": ownershipJSON(cancelledOwnership),
            "expected_transition": .string("AlarmKit countdown -> pause -> paused -> resume -> countdown"),
        ]
    }

    private static func cancelMain() async throws -> [String: JSONValue] {
        let scenario = try loadScenario()
        let ownershipStore = try makeOwnershipStore()
        let cancel = AlarmCancelExecutor(nativeStore: nativeStore, ownershipStore: ownershipStore)
        let beforeNative = try requireNative(alarmID: scenario.mainAlarmID, in: try await nativeStore.alarms())
        let request = cancelDispatch(scenario: scenario, suffix: "main", alarmID: scenario.mainAlarmID)
        try await requirePreflightClear(cancel, dispatch: request)
        let result = try await cancel.execute(request)
        try requireSuccess(result, label: "alarm.cancel")
        let afterNative = try await nativeStore.alarms().first(where: { $0.id == scenario.mainAlarmID })
        let ownership = try XCTLike.unwrap(await ownershipStore.record(alarmID: scenario.mainAlarmID), "main_ownership_missing_after_cancel")
        guard afterNative == nil,
              result.output["verified_absent"]?.boolValue == true,
              ownership.lifecycle == .cancelled
        else { throw HarnessError.assertion("cancel_absence_or_durable_cancel_failed") }
        return [
            "run_id": .string(scenario.runID),
            "task_id": .string(request.taskID),
            "action_id": .string(request.actionID),
            "alarm_id": .string(scenario.mainAlarmID.uuidString),
            "before_native": nativeJSON(beforeNative),
            "after_native": .null,
            "result": resultJSON(result),
            "ownership_after": ownershipJSON(ownership),
            "expected_transition": .string("native present -> absent; ownership accepted -> cancelled"),
        ]
    }

    private static func settingsCancelPrepare() async throws -> [String: JSONValue] {
        let scenario = try loadScenario()
        let ownershipStore = try makeOwnershipStore()
        let create = AlarmCreateExecutor(nativeStore: nativeStore, ownershipStore: ownershipStore, usageDescriptionAvailable: { true })
        let fireAt = iso8601(Date().addingTimeInterval(30 * 60))
        let createRequest = createDispatch(
            scenario: scenario,
            actionSuffix: "recovery",
            alarmID: scenario.recoveryAlarmID,
            key: scenario.recoveryKey,
            title: "Floweroll D16 Cancel Recovery",
            fireAt: fireAt
        )
        try await requirePreflightClear(create, dispatch: createRequest)
        let created = try await create.execute(createRequest)
        try requireSuccess(created, label: "cancel_recovery_create")
        let beforeNative = try requireNative(alarmID: scenario.recoveryAlarmID, in: try await nativeStore.alarms())
        let mutationID = settingsCancelMutationID(scenario)
        _ = try await ownershipStore.beginSettingsMutation(
            alarmID: scenario.recoveryAlarmID,
            mutationID: mutationID,
            operation: .cancel,
            beforeNativeState: beforeNative.state
        )
        try await nativeStore.cancel(id: scenario.recoveryAlarmID)
        guard !(try await nativeStore.alarms()).contains(where: { $0.id == scenario.recoveryAlarmID }) else {
            throw HarnessError.assertion("cancel_recovery_native_still_present")
        }
        let ownership = try XCTLike.unwrap(await ownershipStore.record(alarmID: scenario.recoveryAlarmID), "recovery_ownership_missing")
        guard ownership.pendingSettingsMutation?.mutationID == mutationID,
              ownership.lifecycle != .cancelled
        else { throw HarnessError.assertion("cancel_recovery_durable_intent_missing") }
        return [
            "run_id": .string(scenario.runID),
            "alarm_id": .string(scenario.recoveryAlarmID.uuidString),
            "mutation_id": .string(mutationID),
            "before_native": nativeJSON(beforeNative),
            "after_native": .null,
            "ownership_after_native_before_reconcile": ownershipJSON(ownership),
            "process_exit_required": .bool(true),
            "expected_transition": .string("durable Settings cancel intent -> native absence -> process exit before ownership completion"),
        ]
    }

    private static func settingsCancelRecover() async throws -> [String: JSONValue] {
        let scenario = try loadScenario()
        let ownershipStore = try makeOwnershipStore()
        let before = try XCTLike.unwrap(await ownershipStore.record(alarmID: scenario.recoveryAlarmID), "recovery_ownership_missing_before_reconcile")
        let resolution = try await AlarmSettingsMutationReconciler.reconcile(
            alarmID: scenario.recoveryAlarmID,
            nativeStore: nativeStore,
            ownershipStore: ownershipStore
        )
        guard resolution == .completed else {
            throw HarnessError.assertion("settings_cancel_recovery_not_completed:\(String(describing: resolution))")
        }
        let after = try XCTLike.unwrap(await ownershipStore.record(alarmID: scenario.recoveryAlarmID), "recovery_ownership_missing_after_reconcile")
        guard after.lifecycle == .cancelled,
              after.pendingSettingsMutation == nil,
              !(try await nativeStore.alarms()).contains(where: { $0.id == scenario.recoveryAlarmID })
        else { throw HarnessError.assertion("settings_cancel_recovery_truth_mismatch") }
        return [
            "run_id": .string(scenario.runID),
            "alarm_id": .string(scenario.recoveryAlarmID.uuidString),
            "mutation_id": .string(settingsCancelMutationID(scenario)),
            "resolution": settingsResolutionJSON(resolution),
            "ownership_before": ownershipJSON(before),
            "ownership_after": ownershipJSON(after),
            "native_after": .null,
            "expected_transition": .string("pending Settings cancel journal + native absence -> durable cancelled"),
        ]
    }

    private static func ringPrepare() async throws -> [String: JSONValue] {
        var scenario = try loadScenario()
        let ownershipStore = try makeOwnershipStore()
        let create = AlarmCreateExecutor(nativeStore: nativeStore, ownershipStore: ownershipStore, usageDescriptionAvailable: { true })
        let fireDate = Date().addingTimeInterval(ringLeadTime)
        let fireAt = iso8601(fireDate)
        scenario.ringFireAt = fireAt
        try saveScenario(scenario)
        let request = createDispatch(
            scenario: scenario,
            actionSuffix: "ring",
            alarmID: scenario.ringAlarmID,
            key: scenario.ringKey,
            title: "Floweroll D16 Near-time Ring",
            fireAt: fireAt
        )
        try await requirePreflightClear(create, dispatch: request)
        let result = try await create.execute(request)
        try requireSuccess(result, label: "ring_create")
        let native = try requireNative(alarmID: scenario.ringAlarmID, in: try await nativeStore.alarms())
        guard native.state == .scheduled,
              desiredFixed(fireAt).matches(native.schedule)
        else { throw HarnessError.assertion("ring_prepare_readback_mismatch") }
        return [
            "run_id": .string(scenario.runID),
            "task_id": .string(request.taskID),
            "action_id": .string(request.actionID),
            "alarm_id": .string(scenario.ringAlarmID.uuidString),
            "expected_fire_at": .string(fireAt),
            "native_after_schedule": nativeJSON(native),
            "result": resultJSON(result),
            "user_observation_slots": .object([
                "audible_ring_heard": .null,
                "system_alarm_ui_seen": .null,
                "observed_at": .null,
                "lock_screen_or_foreground_context": .null,
                "notes": .null,
                "screenshot_or_recording_path": .null,
            ]),
            "expected_transition": .string("scheduled -> real AlarmKit alerting/system alarm presentation at expected_fire_at"),
            "physical_execution_note": .string("Do not mark PASS until a human observation records the real ring and system UI."),
        ]
    }

    private static func ringReadback() async throws -> [String: JSONValue] {
        let scenario = try loadScenario()
        guard let expectedFireAt = scenario.ringFireAt else {
            throw HarnessError.assertion("ring_prepare_not_run")
        }
        let ownershipStore = try makeOwnershipStore()
        let native = try await nativeStore.alarms().first(where: { $0.id == scenario.ringAlarmID })
        let ownership = await ownershipStore.record(alarmID: scenario.ringAlarmID)
        return [
            "run_id": .string(scenario.runID),
            "task_id": .string(scenario.taskID),
            "alarm_id": .string(scenario.ringAlarmID.uuidString),
            "expected_fire_at": .string(expectedFireAt),
            "observed_at": .string(iso8601(Date())),
            "native_readback": native.map(nativeJSON) ?? .null,
            "ownership_readback": ownership.map(ownershipJSON) ?? .null,
            "user_observation_slots": .object([
                "audible_ring_heard": .null,
                "system_alarm_ui_seen": .null,
                "system_ui_state_text": .null,
                "observed_at": .null,
                "notes": .null,
                "screenshot_or_recording_path": .null,
            ]),
            "expected_transition": .string("near-time schedule must produce actual ring; readback is supporting evidence, not a substitute for human system-UI/audio observation"),
        ]
    }

    private static func cleanup() async throws -> [String: JSONValue] {
        let current = try await nativeStore.alarms()
        guard let scenario = try? loadScenario() else {
            let safe = current.isEmpty
            if safe { try purgeAllHarnessLocalState() }
            return [
                "scenario_present": .bool(false),
                "native_current_client_count": .number(Double(current.count)),
                "safe_to_claim_cleanup": .bool(safe),
                "local_state_purged": .bool(safe),
            ]
        }
        let knownIDs = Set([
            scenario.mainAlarmID,
            scenario.countdownAlarmID,
            scenario.ringAlarmID,
            scenario.recoveryAlarmID,
        ])
        let knownBefore = current.filter { knownIDs.contains($0.id) }
        for record in knownBefore {
            try await nativeStore.cancel(id: record.id)
        }
        let after = try await nativeStore.alarms()
        let knownRemaining = after.filter { knownIDs.contains($0.id) }
        guard knownRemaining.isEmpty else {
            throw HarnessError.assertion("cleanup_left_known_native_alarms:\(knownRemaining.count)")
        }
        let result: [String: JSONValue] = [
            "run_id": .string(scenario.runID),
            "known_alarm_ids": .array(knownIDs.sorted { $0.uuidString < $1.uuidString }.map { .string($0.uuidString) }),
            "known_present_before_cleanup": .array(knownBefore.map(nativeJSON)),
            "known_remaining_after_cleanup": .array(knownRemaining.map(nativeJSON)),
            "native_current_client_count_after_cleanup": .number(Double(after.count)),
            "all_known_native_alarms_removed": .bool(true),
            "cleanup_timestamp": .string(iso8601(Date())),
        ]
        try purgeAllHarnessLocalState()
        return result.merging(["local_state_purged": .bool(true)]) { _, new in new }
    }

    private static func scheduleNativeCountdownFixture(
        id: UUID,
        scenario: D16Scenario,
        actionID: String
    ) async throws -> Alarm {
        let alertTitle = LocalizedStringResource(String.LocalizationValue("D16 Countdown Alert"))
        let countdownTitle = LocalizedStringResource(String.LocalizationValue("D16 Countdown Running"))
        let pausedTitle = LocalizedStringResource(String.LocalizationValue("D16 Countdown Paused"))
        let pauseButton = AlarmButton(text: "暂停", textColor: .white, systemImageName: "pause.fill")
        let resumeButton = AlarmButton(text: "继续", textColor: .white, systemImageName: "play.fill")
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: alertTitle)
        } else {
            let stop = AlarmButton(text: "停止", textColor: .white, systemImageName: "stop.fill")
            alert = AlarmPresentation.Alert(title: alertTitle, stopButton: stop)
        }
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(
                alert: alert,
                countdown: AlarmPresentation.Countdown(title: countdownTitle, pauseButton: pauseButton),
                paused: AlarmPresentation.Paused(title: pausedTitle, resumeButton: resumeButton)
            ),
            metadata: D16CountdownMetadata(runID: scenario.runID, taskID: scenario.taskID, actionID: actionID),
            tintColor: .blue
        )
        let configuration = AlarmManager.AlarmConfiguration<D16CountdownMetadata>.timer(
            duration: countdownDuration,
            attributes: attributes,
            sound: .default
        )
        return try await AlarmManager.shared.schedule(id: id, configuration: configuration)
    }

    private static func waitForNativeState(
        alarmID: UUID,
        state: AlarmNativeState,
        timeout: TimeInterval
    ) async throws -> AlarmNativeRecord {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let record = try await nativeStore.alarms().first(where: { $0.id == alarmID }), record.state == state {
                return record
            }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        let last = try await nativeStore.alarms().first(where: { $0.id == alarmID })
        throw HarnessError.assertion("native_state_timeout_expected_\(state.rawValue)_actual_\(last?.state.rawValue ?? "missing")")
    }

    private static func requireAuthorized() async throws {
        let authorization = await nativeStore.authorizationStatus()
        guard authorization == .authorized else {
            throw HarnessError.assertion("authorization_not_authorized:\(authorization.rawValue)")
        }
    }

    private static func requirePreflightClear(
        _ executor: any DeviceCapabilityExecutor,
        dispatch: DeviceActionDispatch
    ) async throws {
        if let failure = try await executor.preflight(dispatch) {
            throw HarnessError.preflight(failure.error ?? "unknown", failure.output)
        }
    }

    private static func requireSuccess(_ result: DeviceExecutionResult, label: String) throws {
        guard result.success else {
            throw HarnessError.assertion("\(label)_failed:\(result.error ?? "unknown")")
        }
    }

    private static func requireNative(alarmID: UUID, in records: [AlarmNativeRecord]) throws -> AlarmNativeRecord {
        try XCTLike.unwrap(records.first(where: { $0.id == alarmID }), "native_alarm_missing_\(alarmID.uuidString)")
    }

    private static func desiredFixed(_ fireAt: String) -> AlarmDesiredSchedule {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: fireAt) else {
            preconditionFailure("D16 generated invalid fixed instant")
        }
        return .fixed(date)
    }

    private static func typedFixedPayload(title: String, fireAt: String) -> [String: JSONValue] {
        [
            "title": .string(title),
            "schedule": .object([
                "kind": .string("fixed"),
                "fire_at": .string(fireAt),
            ]),
            "sound": .string("default"),
        ]
    }

    private static func createDispatch(
        scenario: D16Scenario,
        actionSuffix: String,
        alarmID: UUID,
        key: String,
        title: String,
        fireAt: String
    ) -> DeviceActionDispatch {
        let payload = typedFixedPayload(title: title, fireAt: fireAt)
        // alarm.create derives the same stable ID from idempotency_key. This assertion lives at
        // the call sites so the harness never passes a hidden random native identifier.
        precondition(AlarmIdentity.stableAlarmID(for: key) == alarmID)
        return DeviceActionDispatch(
            actionID: "d16.create.\(actionSuffix).\(scenario.runID)",
            taskID: scenario.taskID,
            actionType: "alarm.create",
            payload: payload,
            idempotencyKey: key,
            attemptID: "d16.create.\(actionSuffix).attempt.\(scenario.runID)"
        )
    }

    private static func updateDispatch(
        scenario: D16Scenario,
        suffix: String,
        title: String,
        fireAt: String
    ) -> DeviceActionDispatch {
        var payload = typedFixedPayload(title: title, fireAt: fireAt)
        payload["alarm_id"] = .string(scenario.mainAlarmID.uuidString)
        return DeviceActionDispatch(
            actionID: "d16.update.\(suffix).\(scenario.runID)",
            taskID: scenario.taskID,
            actionType: "alarm.update",
            payload: payload,
            idempotencyKey: "d16.update.\(suffix).\(scenario.runID)",
            attemptID: "d16.update.\(suffix).attempt.\(scenario.runID)"
        )
    }

    private static func plannerRecoveryDispatch(_ scenario: D16Scenario) -> DeviceActionDispatch {
        updateDispatch(
            scenario: scenario,
            suffix: "planner-recovery",
            title: "Floweroll D16 Planner 恢复",
            fireAt: scenario.plannerRecoveryFireAt
        )
    }

    private static func ambiguousTitleDispatch(
        _ scenario: D16Scenario,
        schedule: AlarmDesiredSchedule
    ) -> DeviceActionDispatch {
        let fireAt = iso8601(schedule.fireDate ?? Date.distantFuture)
        return updateDispatch(
            scenario: scenario,
            suffix: "ambiguous-title",
            title: "Floweroll D16 不可读标题",
            fireAt: fireAt
        )
    }

    private static func queryDispatch(scenario: D16Scenario, suffix: String) -> DeviceActionDispatch {
        DeviceActionDispatch(
            actionID: "d16.query.\(suffix).\(scenario.runID)",
            taskID: scenario.taskID,
            actionType: "alarm.query",
            payload: ["max_results": .number(100)],
            idempotencyKey: "d16.query.\(suffix).\(scenario.runID)",
            attemptID: "d16.query.\(suffix).attempt.\(scenario.runID)"
        )
    }

    private static func readDispatch(scenario: D16Scenario, suffix: String, alarmID: UUID) -> DeviceActionDispatch {
        DeviceActionDispatch(
            actionID: "d16.read.\(suffix).\(scenario.runID)",
            taskID: scenario.taskID,
            actionType: "alarm.read",
            payload: ["alarm_id": .string(alarmID.uuidString)],
            idempotencyKey: "d16.read.\(suffix).\(scenario.runID)",
            attemptID: "d16.read.\(suffix).attempt.\(scenario.runID)"
        )
    }

    private static func lifecycleDispatch(
        scenario: D16Scenario,
        suffix: String,
        alarmID: UUID,
        actionType: String
    ) -> DeviceActionDispatch {
        DeviceActionDispatch(
            actionID: "d16.\(suffix).\(scenario.runID)",
            taskID: scenario.taskID,
            actionType: actionType,
            payload: ["alarm_id": .string(alarmID.uuidString)],
            idempotencyKey: "d16.\(suffix).\(scenario.runID)",
            attemptID: "d16.\(suffix).attempt.\(scenario.runID)"
        )
    }

    private static func cancelDispatch(scenario: D16Scenario, suffix: String, alarmID: UUID) -> DeviceActionDispatch {
        lifecycleDispatch(scenario: scenario, suffix: "cancel.\(suffix)", alarmID: alarmID, actionType: "alarm.cancel")
    }

    private static func settingsUpdateMutationID(_ scenario: D16Scenario) -> String {
        "settings.d16.update.\(scenario.runID)"
    }

    private static func settingsCancelMutationID(_ scenario: D16Scenario) -> String {
        "settings.d16.cancel.\(scenario.runID)"
    }

    private static func journalEntry(_ dispatch: DeviceActionDispatch) -> DeviceActionJournalEntry {
        let now = Date()
        return DeviceActionJournalEntry(
            attemptID: dispatch.attemptID,
            actionID: dispatch.actionID,
            idempotencyKey: dispatch.idempotencyKey,
            dispatchDigest: dispatch.dispatchDigest,
            state: .mayHaveStarted,
            success: nil,
            result: nil,
            error: nil,
            nativeCorrelationID: nil,
            createdAt: now.addingTimeInterval(-1),
            updatedAt: now
        )
    }

    private static func queryContainsAlarm(_ result: DeviceExecutionResult, alarmID: UUID) -> Bool {
        guard let alarms = result.output["alarms"]?.arrayValue else { return false }
        return alarms.contains { $0.objectValue?["alarm_id"]?.stringValue == alarmID.uuidString }
    }

    private static func recoveryPrepareResult(
        scenario: D16Scenario,
        request: DeviceActionDispatch,
        beforeNative: AlarmNativeRecord,
        afterNative: AlarmNativeRecord,
        beforeOwnership: AlarmOwnershipRecord,
        afterOwnership: AlarmOwnershipRecord,
        expected: String
    ) -> [String: JSONValue] {
        [
            "run_id": .string(scenario.runID),
            "task_id": .string(request.taskID),
            "action_id": .string(request.actionID),
            "attempt_id": .string(request.attemptID),
            "idempotency_key": .string(request.idempotencyKey),
            "alarm_id": .string(scenario.mainAlarmID.uuidString),
            "before_native": nativeJSON(beforeNative),
            "after_native": nativeJSON(afterNative),
            "before_ownership": ownershipJSON(beforeOwnership),
            "after_ownership": ownershipJSON(afterOwnership),
            "process_exit_required": .bool(true),
            "expected_transition": .string(expected),
        ]
    }

    private static func resultJSON(_ result: DeviceExecutionResult) -> JSONValue {
        .object([
            "success": .bool(result.success),
            "error": result.error.map(JSONValue.string) ?? .null,
            "native_correlation_id": result.nativeCorrelationID.map(JSONValue.string) ?? .null,
            "output": .object(result.output),
        ])
    }

    private static func reconciliationJSON(_ result: DeviceReconciliationResult) -> JSONValue {
        switch result {
        case let .completed(execution):
            return .object(["kind": .string("completed"), "execution": resultJSON(execution)])
        case .definitelyNotStarted:
            return .object(["kind": .string("definitely_not_started")])
        case let .stillUnknown(reason):
            return .object([
                "kind": .string("still_unknown"),
                "reason": reason.map(JSONValue.string) ?? .null,
            ])
        }
    }

    private static func settingsResolutionJSON(_ result: AlarmSettingsMutationReconciliationResult?) -> JSONValue {
        guard let result else { return .null }
        switch result {
        case .completed: return .string("completed")
        case .definitelyNotStarted: return .string("definitely_not_started")
        case let .ambiguous(reason): return .object(["kind": .string("ambiguous"), "reason": .string(reason)])
        }
    }

    private static func nativeJSON(_ record: AlarmNativeRecord) -> JSONValue {
        .object([
            "alarm_id": .string(record.id.uuidString),
            "state": .string(record.state.rawValue),
            "schedule": nativeScheduleJSON(record.schedule),
            "observed_at": .string(iso8601(Date())),
        ])
    }

    private static func nativeScheduleJSON(_ schedule: AlarmNativeSchedule?) -> JSONValue {
        guard let schedule else { return .null }
        switch schedule {
        case let .fixed(date):
            return .object([
                "kind": .string("fixed"),
                "fire_at": .string(iso8601(date)),
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
            return .object(["kind": .string("unsupported")])
        }
    }

    private static func ownershipJSON(_ record: AlarmOwnershipRecord) -> JSONValue {
        var object: [String: JSONValue] = [
            "alarm_id": .string(record.alarmID.uuidString),
            "task_id": .string(record.taskID),
            "create_action_id": .string(record.actionID),
            "idempotency_key": .string(record.idempotencyKey),
            "title": .string(record.title),
            "schedule": record.schedule.jsonValue,
            "sound": .string(record.effectiveSound.rawValue),
            "lifecycle": .string(record.lifecycle.rawValue),
            "accepted_at": .string(iso8601(record.acceptedAt)),
            "last_native_state": record.lastNativeState.map { .string($0.rawValue) } ?? .null,
            "last_observed_at": .string(iso8601(record.lastObservedAt)),
            "last_mutation_at": record.lastMutationAt.map { .string(iso8601($0)) } ?? .null,
            "last_mutation_task_id": record.lastMutationTaskID.map(JSONValue.string) ?? .null,
            "last_mutation_action_id": record.lastMutationActionID.map(JSONValue.string) ?? .null,
            "cancelled_at": record.cancelledAt.map { .string(iso8601($0)) } ?? .null,
            "cancelled_by_action_id": record.cancelledByActionID.map(JSONValue.string) ?? .null,
        ]
        if let pending = record.pendingSettingsMutation {
            object["pending_settings_mutation"] = .object([
                "mutation_id": .string(pending.mutationID),
                "operation": .string(pending.operation.rawValue),
                "state": .string(pending.state.rawValue),
                "created_at": .string(iso8601(pending.createdAt)),
                "last_observed_native_state": pending.lastObservedNativeState.map { .string($0.rawValue) } ?? .null,
                "last_observed_at": pending.lastObservedAt.map { .string(iso8601($0)) } ?? .null,
                "detail": pending.detail.map(JSONValue.string) ?? .null,
            ])
        } else {
            object["pending_settings_mutation"] = .null
        }
        if let outcome = record.lastSettingsMutationOutcome {
            object["last_settings_mutation_outcome"] = .object([
                "mutation_id": .string(outcome.mutationID),
                "operation": .string(outcome.operation.rawValue),
                "resolution": .string(outcome.resolution.rawValue),
                "resolved_at": .string(iso8601(outcome.resolvedAt)),
                "detail": outcome.detail.map(JSONValue.string) ?? .null,
            ])
        } else {
            object["last_settings_mutation_outcome"] = .null
        }
        return .object(object)
    }

    private static func identityJSON() -> [String: JSONValue] {
        let bundle = Bundle.main
        return [
            "bundle_id": .string(bundle.bundleIdentifier ?? "unknown"),
            "version": .string(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"),
            "build": .string(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"),
            "device_name": .string(UIDevice.current.name),
            "device_model": .string(UIDevice.current.model),
            "system_name": .string(UIDevice.current.systemName),
            "system_version": .string(UIDevice.current.systemVersion),
            "process_id": .number(Double(ProcessInfo.processInfo.processIdentifier)),
        ]
    }

    private static func makeOwnershipStore() throws -> AlarmOwnershipStore {
        try AlarmOwnershipStore(directoryURL: ownershipDirectoryURL())
    }

    private static func ownershipDirectoryURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("D16AlarmAcceptance", isDirectory: true)
            .appendingPathComponent("Ownership", isDirectory: true)
    }

    private static func scenarioURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("D16AlarmAcceptance", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("scenario.json")
    }

    private static func saveScenario(_ scenario: D16Scenario) throws {
        try JSONEncoder.floweroll.encode(scenario).write(to: scenarioURL(), options: .atomic)
    }

    private static func loadScenario() throws -> D16Scenario {
        try JSONDecoder.floweroll.decode(D16Scenario.self, from: Data(contentsOf: scenarioURL()))
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func emit(_ object: [String: JSONValue]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(object)) ?? Data("{\"ok\":false,\"error\":\"encode_failed\"}".utf8)
        if let url = try? evidenceURL() {
            try? data.write(to: url, options: .atomic)
        }
        FileHandle.standardOutput.write(Data("D16_RESULT ".utf8))
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        fflush(stdout)
    }

    private static func evidenceURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("D16AlarmAcceptance", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("last-result.json")
    }

    private static func purgeAllHarnessLocalState() throws {
        let manager = FileManager.default
        let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("D16AlarmAcceptance", isDirectory: true)
        if manager.fileExists(atPath: support.path) { try manager.removeItem(at: support) }
        let documents = try manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("D16AlarmAcceptance", isDirectory: true)
        if manager.fileExists(atPath: documents.path) { try manager.removeItem(at: documents) }
    }

    private static func terminateSoon(code: Int32) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            exit(code)
        }
    }
}

private enum XCTLike {
    static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw HarnessError.assertion(message) }
        return value
    }
}
