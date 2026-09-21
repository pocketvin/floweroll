import Foundation
import XCTest
@testable import Floweroll


private final class FakeAlarmUpdateHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<[AlarmNativeRecord]>.Continuation] = [:]

    func stream() -> AsyncStream<[AlarmNativeRecord]> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations[id] = nil
                self?.lock.unlock()
            }
        }
    }

    func yield(_ records: [AlarmNativeRecord]) {
        lock.lock()
        let values = Array(continuations.values)
        lock.unlock()
        for continuation in values { continuation.yield(records) }
    }
}


private actor FakeAlarmNativeStore: AlarmNativeStore {
    private var authorization: AlarmAuthorizationStatus
    private var records: [UUID: AlarmNativeRecord]
    private var nextScheduleError: AlarmNativeStoreError?
    private var nextCancelError: AlarmNativeStoreError?
    private var nextPauseError: AlarmNativeStoreError?
    private var nextResumeError: AlarmNativeStoreError?
    private var readError: AlarmNativeStoreError?
    private var persistScheduledRecord = true
    private var rejectsExistingSchedule = false
    private var scheduleCalls = 0
    private var cancelCalls = 0
    private var pauseCalls = 0
    private var resumeCalls = 0
    nonisolated private let updatesHub = FakeAlarmUpdateHub()

    init(
        authorization: AlarmAuthorizationStatus = .authorized,
        records: [AlarmNativeRecord] = []
    ) {
        self.authorization = authorization
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    func authorizationStatus() async -> AlarmAuthorizationStatus { authorization }

    func alarms() async throws -> [AlarmNativeRecord] {
        if let readError { throw readError }
        return sortedRecords()
    }

    func schedule(_ request: AlarmNativeScheduleRequest) async throws -> AlarmNativeRecord {
        scheduleCalls += 1
        if rejectsExistingSchedule && records[request.id] != nil {
            throw AlarmNativeStoreError.nativeFailure("existing_native_id")
        }
        if let error = nextScheduleError {
            nextScheduleError = nil
            throw error
        }
        let schedule: AlarmNativeSchedule
        switch request.schedule.kind {
        case .fixed:
            schedule = .fixed(try XCTUnwrap(request.schedule.fireDate))
        case .weekly:
            schedule = .weekly(
                hour: try XCTUnwrap(request.schedule.hour),
                minute: try XCTUnwrap(request.schedule.minute),
                weekdays: try XCTUnwrap(request.schedule.weekdays)
            )
        }
        let record = AlarmNativeRecord(id: request.id, schedule: schedule, state: .scheduled)
        if persistScheduledRecord {
            records[request.id] = record
            emitUpdates()
        }
        return record
    }

    func cancel(id: UUID) async throws {
        cancelCalls += 1
        if let error = nextCancelError {
            nextCancelError = nil
            throw error
        }
        records[id] = nil
        emitUpdates()
    }

    func pause(id: UUID) async throws {
        pauseCalls += 1
        if let error = nextPauseError {
            nextPauseError = nil
            throw error
        }
        guard let record = records[id], record.state == .countdown else {
            throw AlarmNativeStoreError.nativeFailure("invalid_pause_state")
        }
        records[id] = AlarmNativeRecord(id: id, schedule: record.schedule, state: .paused)
        emitUpdates()
    }

    func resume(id: UUID) async throws {
        resumeCalls += 1
        if let error = nextResumeError {
            nextResumeError = nil
            throw error
        }
        guard let record = records[id], record.state == .paused else {
            throw AlarmNativeStoreError.nativeFailure("invalid_resume_state")
        }
        records[id] = AlarmNativeRecord(id: id, schedule: record.schedule, state: .countdown)
        emitUpdates()
    }

    nonisolated func alarmUpdates() -> AsyncStream<[AlarmNativeRecord]> { updatesHub.stream() }

    func setRejectExistingSchedule(_ value: Bool) { rejectsExistingSchedule = value }
    func setAuthorization(_ value: AlarmAuthorizationStatus) { authorization = value }

    func setRecord(_ record: AlarmNativeRecord?) {
        if let record { records[record.id] = record }
        emitUpdates()
    }

    func remove(id: UUID) {
        records[id] = nil
        emitUpdates()
    }

    func failNextSchedule(_ error: AlarmNativeStoreError) { nextScheduleError = error }
    func failNextCancel(_ error: AlarmNativeStoreError) { nextCancelError = error }
    func failNextPause(_ error: AlarmNativeStoreError) { nextPauseError = error }
    func failNextResume(_ error: AlarmNativeStoreError) { nextResumeError = error }
    func setPersistScheduledRecord(_ value: Bool) { persistScheduledRecord = value }
    func setReadError(_ error: AlarmNativeStoreError?) { readError = error }

    func counts() -> (schedule: Int, cancel: Int, pause: Int, resume: Int) {
        (scheduleCalls, cancelCalls, pauseCalls, resumeCalls)
    }

    private func sortedRecords() -> [AlarmNativeRecord] {
        records.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func emitUpdates() { updatesHub.yield(sortedRecords()) }
}



final class AlarmExecutorsTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alarm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func dispatch(
        actionType: String,
        payload: [String: JSONValue],
        key: String = UUID().uuidString,
        actionID: String = UUID().uuidString,
        attemptID: String = UUID().uuidString
    ) -> DeviceActionDispatch {
        DeviceActionDispatch(
            actionID: actionID,
            taskID: "00000000-0000-0000-0000-000000000001",
            actionType: actionType,
            payload: payload,
            status: "executing",
            runtimeActionStatus: "executing",
            idempotencyKey: key,
            attemptID: attemptID,
            attemptNumber: 1,
            attemptStatus: "IN_FLIGHT",
            dispatchDigest: "digest-\(attemptID)"
        )
    }

    private func fixedPayload(
        title: String = "起床",
        fireAt: String = "2030-01-02T07:00:00+08:00"
    ) -> [String: JSONValue] {
        ["title": .string(title), "fire_at": .string(fireAt)]
    }

    private func typedFixedPayload(
        title: String = "起床",
        fireAt: String = "2030-01-02T07:00:00+08:00",
        sound: String = "default"
    ) -> [String: JSONValue] {
        [
            "title": .string(title),
            "schedule": .object([
                "kind": .string("fixed"),
                "fire_at": .string(fireAt),
            ]),
            "sound": .string(sound),
        ]
    }

    private func weeklyPayload(
        title: String = "工作日",
        hour: Int = 7,
        minute: Int = 30,
        weekdays: [String] = ["monday", "wednesday", "friday"],
        sound: String = "default"
    ) -> [String: JSONValue] {
        [
            "title": .string(title),
            "schedule": .object([
                "kind": .string("weekly"),
                "hour": .number(Double(hour)),
                "minute": .number(Double(minute)),
                "weekdays": .array(weekdays.map(JSONValue.string)),
            ]),
            "sound": .string(sound),
        ]
    }

    func testOwnershipAcceptancePersistenceFailureDoesNotLeavePhantomOwner() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alarm-owner-create-write-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let ownership = try AlarmOwnershipStore(directoryURL: directory)
        let alarmID = UUID()
        let request = dispatch(
            actionType: "alarm.create",
            payload: fixedPayload(),
            key: "owner-create-write-failure",
            actionID: "owner-create-write-failure-action"
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        do {
            _ = try await ownership.recordAccepted(
                alarmID: alarmID,
                dispatch: request,
                title: "不应成为 phantom owner",
                schedule: .fixed(Date(timeIntervalSince1970: 1_900_000_000)),
                nativeState: .scheduled
            )
            XCTFail("unwritable ownership ledger must reject acceptance")
        } catch {}

        let recordAfterAcceptanceFailure = await ownership.record(alarmID: alarmID)
        XCTAssertNil(recordAfterAcceptanceFailure)
    }

    func testOwnershipCancelPersistenceFailureKeepsPriorOwnedState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alarm-owner-cancel-write-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let ownership = try AlarmOwnershipStore(directoryURL: directory)
        let alarmID = UUID()
        let request = dispatch(
            actionType: "alarm.create",
            payload: fixedPayload(),
            key: "owner-cancel-write-failure",
            actionID: "owner-cancel-write-failure-create"
        )
        _ = try await ownership.recordAccepted(
            alarmID: alarmID,
            dispatch: request,
            title: "仍应保持 owned",
            schedule: .fixed(Date(timeIntervalSince1970: 1_900_000_000)),
            nativeState: .scheduled
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        do {
            _ = try await ownership.markCancelled(
                alarmID: alarmID,
                actionID: "owner-cancel-write-failure-action"
            )
            XCTFail("unwritable ownership ledger must reject cancellation mutation")
        } catch {}

        let currentValue = await ownership.record(alarmID: alarmID)
        let current = try XCTUnwrap(currentValue)
        XCTAssertEqual(current.lifecycle, .accepted)
        XCTAssertNil(current.cancelledAt)
        XCTAssertNil(current.cancelledByActionID)
    }

    func testOwnershipSettingsPersistenceFailureDoesNotLeavePendingIntent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alarm-owner-settings-write-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let ownership = try AlarmOwnershipStore(directoryURL: directory)
        let alarmID = UUID()
        let request = dispatch(
            actionType: "alarm.create",
            payload: typedFixedPayload(),
            key: "owner-settings-write-failure",
            actionID: "owner-settings-write-failure-create"
        )
        _ = try await ownership.recordAccepted(
            alarmID: alarmID,
            dispatch: request,
            title: "原始闹钟",
            schedule: .fixed(Date(timeIntervalSince1970: 1_900_000_000)),
            nativeState: .scheduled
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        do {
            _ = try await ownership.beginSettingsMutation(
                alarmID: alarmID,
                mutationID: "owner-settings-write-failure-mutation",
                operation: .update,
                beforeNativeState: .scheduled,
                requestedTitle: "不应留在内存",
                requestedSchedule: .weekly(hour: 8, minute: 0, weekdays: [.monday]),
                requestedSound: .defaultSound
            )
            XCTFail("unwritable ownership ledger must reject settings mutation")
        } catch {}

        let currentValue = await ownership.record(alarmID: alarmID)
        let current = try XCTUnwrap(currentValue)
        XCTAssertNil(current.pendingSettingsMutation)
        XCTAssertEqual(current.title, "原始闹钟")
    }

    private func updatePayload(
        alarmID: UUID,
        title: String,
        hour: Int,
        minute: Int,
        weekdays: [String],
        sound: String = "default"
    ) -> [String: JSONValue] {
        var payload = weeklyPayload(
            title: title, hour: hour, minute: minute, weekdays: weekdays, sound: sound
        )
        payload["alarm_id"] = .string(alarmID.uuidString)
        return payload
    }

    private func number(_ value: JSONValue?) -> Double? {
        guard case let .number(number)? = value else { return nil }
        return number
    }

    private func journalEntry(_ dispatch: DeviceActionDispatch) -> DeviceActionJournalEntry {
        DeviceActionJournalEntry(
            attemptID: dispatch.attemptID,
            actionID: dispatch.actionID,
            idempotencyKey: dispatch.idempotencyKey,
            dispatchDigest: dispatch.dispatchDigest,
            state: .mayHaveStarted,
            success: nil,
            result: nil,
            error: nil,
            nativeCorrelationID: nil,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_010)
        )
    }

    func testLegacyFixedCreateSchedulesOncePersistsOwnershipAndSuppressesRetry() async throws {
        let folder = try directory()
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: folder)
        let executor = AlarmCreateExecutor(
            nativeStore: native,
            ownershipStore: ownership,
            usageDescriptionAvailable: { true }
        )
        let request = dispatch(
            actionType: "alarm.create",
            payload: fixedPayload(),
            key: "alarm-create-stable",
            actionID: "alarm-action"
        )

        let preflight = try await executor.preflight(request)
        XCTAssertNil(preflight)
        let first = try await executor.execute(request)
        XCTAssertTrue(first.success)
        XCTAssertEqual(first.output["fire_at"]?.stringValue, "2030-01-02T07:00:00+08:00")
        XCTAssertEqual(first.output["native_schedule_verified"]?.boolValue, true)
        let firstCounts = await native.counts()
        XCTAssertEqual(firstCounts.schedule, 1)

        let alarmID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(first.output["alarm_id"]?.stringValue)))
        let stored = await ownership.record(alarmID: alarmID)
        XCTAssertEqual(stored?.actionID, "alarm-action")
        XCTAssertEqual(stored?.lifecycle, .accepted)

        let reloaded = try AlarmOwnershipStore(directoryURL: folder)
        let reloadedRecord = await reloaded.record(alarmID: alarmID)
        XCTAssertEqual(reloadedRecord?.idempotencyKey, "alarm-create-stable")

        let replay = try await executor.execute(request)
        XCTAssertTrue(replay.success)
        XCTAssertEqual(replay.output["duplicate_suppressed"]?.boolValue, true)
        let retryCounts = await native.counts()
        XCTAssertEqual(retryCounts.schedule, 1)
    }

    func testFractionalFixedCreateSurvivesOwnershipReloadAndSuppressesRetry() async throws {
        let folder = try directory()
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: folder)
        let firstExecutor = AlarmCreateExecutor(
            nativeStore: native,
            ownershipStore: ownership,
            usageDescriptionAvailable: { true }
        )
        let request = dispatch(
            actionType: "alarm.create",
            payload: fixedPayload(fireAt: "2030-01-02T07:00:00.158+08:00"),
            key: "alarm-create-fractional-reload",
            actionID: "fractional-reload-action"
        )

        let first = try await firstExecutor.execute(request)
        XCTAssertTrue(first.success)
        let firstCounts = await native.counts()
        XCTAssertEqual(firstCounts.schedule, 1)

        let reloadedOwnership = try AlarmOwnershipStore(directoryURL: folder)
        let replayExecutor = AlarmCreateExecutor(
            nativeStore: native,
            ownershipStore: reloadedOwnership,
            usageDescriptionAvailable: { true }
        )
        let replay = try await replayExecutor.execute(request)

        XCTAssertTrue(replay.success)
        XCTAssertEqual(replay.output["duplicate_suppressed"]?.boolValue, true)
        XCTAssertEqual(replay.output["native_present"]?.boolValue, true)
        let retryCounts = await native.counts()
        XCTAssertEqual(retryCounts.schedule, 1)
    }

    func testDurableAcceptancePreventsRecreateWhenSystemAlarmLaterMissing() async throws {
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let executor = AlarmCreateExecutor(
            nativeStore: native,
            ownershipStore: ownership,
            usageDescriptionAvailable: { true }
        )
        let request = dispatch(
            actionType: "alarm.create",
            payload: fixedPayload(),
            key: "missing-after-accepted",
            actionID: "accepted-action"
        )
        let first = try await executor.execute(request)
        let alarmID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(first.output["alarm_id"]?.stringValue)))
        await native.remove(id: alarmID)

        let replay = try await executor.execute(request)
        XCTAssertTrue(replay.success)
        XCTAssertEqual(replay.output["native_present"]?.boolValue, false)
        XCTAssertEqual(replay.output["readback_source"]?.stringValue, "ownership_ledger")
        let replayCounts = await native.counts()
        XCTAssertEqual(replayCounts.schedule, 1, "retry must not silently recreate a previously accepted alarm")
        let missingOwnership = await ownership.record(alarmID: alarmID)
        XCTAssertEqual(missingOwnership?.lifecycle, .missing)
    }

    func testSameIdempotencyDifferentIntentFailsClosed() async throws {
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let executor = AlarmCreateExecutor(
            nativeStore: native,
            ownershipStore: ownership,
            usageDescriptionAvailable: { true }
        )
        let first = dispatch(
            actionType: "alarm.create",
            payload: fixedPayload(),
            key: "conflict-key",
            actionID: "action-one"
        )
        let firstResult = try await executor.execute(first)
        XCTAssertTrue(firstResult.success)

        let conflicting = dispatch(
            actionType: "alarm.create",
            payload: fixedPayload(title: "另一个闹钟"),
            key: "conflict-key",
            actionID: "action-two"
        )
        let failure = try await executor.preflight(conflicting)
        XCTAssertEqual(failure?.success, false)
        XCTAssertEqual(failure?.output["error_code"]?.stringValue, AlarmFailureCode.idempotencyConflict.rawValue)
        let firstCounts = await native.counts()
        XCTAssertEqual(firstCounts.schedule, 1)
    }

    func testTwoDistinctActionsCreateDistinctNativeIDs() async throws {
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let executor = AlarmCreateExecutor(
            nativeStore: native,
            ownershipStore: ownership,
            usageDescriptionAvailable: { true }
        )
        let one = dispatch(actionType: "alarm.create", payload: fixedPayload(), key: "key-one")
        let two = dispatch(
            actionType: "alarm.create",
            payload: fixedPayload(fireAt: "2030-01-02T08:00:00+08:00"),
            key: "key-two"
        )
        let resultOne = try await executor.execute(one)
        let resultTwo = try await executor.execute(two)
        XCTAssertNotEqual(resultOne.output["alarm_id"]?.stringValue, resultTwo.output["alarm_id"]?.stringValue)
        let distinctCounts = await native.counts()
        let distinctAlarms = try await native.alarms()
        XCTAssertEqual(distinctCounts.schedule, 2)
        XCTAssertEqual(distinctAlarms.count, 2)
    }

    func testPermissionStatesFailBeforeMutation() async throws {
        let native = FakeAlarmNativeStore(authorization: .notDetermined)
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let executor = AlarmCreateExecutor(
            nativeStore: native,
            ownershipStore: ownership,
            usageDescriptionAvailable: { true }
        )
        let request = dispatch(actionType: "alarm.create", payload: fixedPayload())

        var failure = try await executor.preflight(request)
        XCTAssertEqual(failure?.output["error_code"]?.stringValue, AlarmFailureCode.authorizationNotDetermined.rawValue)
        XCTAssertEqual(failure?.output["user_action"]?.stringValue, "request_alarm_authorization_in_foreground")

        await native.setAuthorization(.denied)
        failure = try await executor.preflight(request)
        XCTAssertEqual(failure?.output["error_code"]?.stringValue, AlarmFailureCode.authorizationDenied.rawValue)
        XCTAssertEqual(failure?.output["user_action"]?.stringValue, "open_app_settings_for_alarm_authorization")
        let mutationCounts = await native.counts()
        XCTAssertEqual(mutationCounts.schedule, 0)
    }

    func testMissingUsageDescriptionFailsBeforeMutation() async throws {
        let native = FakeAlarmNativeStore()
        let executor = AlarmCreateExecutor(
            nativeStore: native,
            ownershipStore: try AlarmOwnershipStore(directoryURL: try directory()),
            usageDescriptionAvailable: { false }
        )
        let failure = try await executor.preflight(
            dispatch(actionType: "alarm.create", payload: fixedPayload())
        )
        XCTAssertEqual(failure?.output["error_code"]?.stringValue, AlarmFailureCode.usageDescriptionMissing.rawValue)
        let mutationCounts = await native.counts()
        XCTAssertEqual(mutationCounts.schedule, 0)
    }


    func testNativeReadFailureMapsToDeterministicPreflightEnvelope() async throws {
        let native = FakeAlarmNativeStore()
        await native.setReadError(.nativeFailure("read-unavailable"))
        let executor = AlarmCreateExecutor(
            nativeStore: native,
            ownershipStore: try AlarmOwnershipStore(directoryURL: try directory()),
            usageDescriptionAvailable: { true }
        )
        let failure = try await executor.preflight(
            dispatch(actionType: "alarm.create", payload: fixedPayload())
        )
        XCTAssertEqual(failure?.success, false)
        XCTAssertEqual(failure?.output["error_code"]?.stringValue, AlarmFailureCode.readFailed.rawValue)
        let counts = await native.counts()
        XCTAssertEqual(counts.schedule, 0)
    }

    func testPostScheduleMissingReadbackStaysAmbiguousForCoordinatorReconciliation() async throws {
        let native = FakeAlarmNativeStore()
        await native.setPersistScheduledRecord(false)
        let executor = AlarmCreateExecutor(
            nativeStore: native,
            ownershipStore: try AlarmOwnershipStore(directoryURL: try directory()),
            usageDescriptionAvailable: { true }
        )
        do {
            _ = try await executor.execute(
                dispatch(actionType: "alarm.create", payload: fixedPayload())
            )
            XCTFail("missing native readback after schedule must not return definitive success/failure")
        } catch let error as AlarmNativeStoreError {
            XCTAssertEqual(
                error,
                .nativeFailure(AlarmFailureCode.readbackMissing.rawValue)
            )
        }
        let counts = await native.counts()
        XCTAssertEqual(counts.schedule, 1)
    }

    func testCancelNativeFailureRequiresReadbackBeforeRetry() async throws {
        let alarmID = UUID()
        let native = FakeAlarmNativeStore(records: [
            AlarmNativeRecord(
                id: alarmID,
                schedule: .fixed(Date(timeIntervalSince1970: 1_900_000_000)),
                state: .scheduled
            ),
        ])
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let createBinding = dispatch(
            actionType: "alarm.create",
            payload: fixedPayload(),
            key: "cancel-reconcile-owned",
            actionID: "cancel-reconcile-create"
        )
        _ = try await ownership.recordAccepted(
            alarmID: alarmID,
            dispatch: createBinding,
            title: "取消恢复",
            schedule: .fixed(Date(timeIntervalSince1970: 1_900_000_000)),
            nativeState: .scheduled
        )
        let executor = AlarmCancelExecutor(nativeStore: native, ownershipStore: ownership)
        let request = dispatch(
            actionType: "alarm.cancel",
            payload: ["alarm_id": .string(alarmID.uuidString)]
        )
        let preflight = try await executor.preflight(request)
        XCTAssertNil(preflight)
        await native.failNextCancel(.nativeFailure("cancel-interrupted"))
        do {
            _ = try await executor.execute(request)
            XCTFail("native cancel error after side-effect boundary must remain ambiguous")
        } catch let error as AlarmNativeStoreError {
            XCTAssertEqual(
                error,
                .nativeFailure(AlarmFailureCode.cancelFailed.rawValue)
            )
        }
        let reconciled = try await executor.reconcile(
            request,
            journalEntry: journalEntry(request)
        )
        XCTAssertEqual(reconciled, .definitelyNotStarted)
        let counts = await native.counts()
        XCTAssertEqual(counts.cancel, 1)
    }

    func testGenericScheduleFailureNormalizesAmbiguousReason() async throws {
        let native = FakeAlarmNativeStore()
        await native.failNextSchedule(.nativeFailure("opaque-system-error"))
        let executor = AlarmCreateExecutor(
            nativeStore: native,
            ownershipStore: try AlarmOwnershipStore(directoryURL: try directory()),
            usageDescriptionAvailable: { true }
        )
        do {
            _ = try await executor.execute(
                dispatch(actionType: "alarm.create", payload: fixedPayload())
            )
            XCTFail("generic schedule error after side-effect boundary must be ambiguous")
        } catch let error as AlarmNativeStoreError {
            XCTAssertEqual(
                error,
                .nativeFailure(AlarmFailureCode.nativeScheduleFailed.rawValue)
            )
        }
    }

    func testSystemLimitMapsToDeterministicFailureEnvelope() async throws {
        let native = FakeAlarmNativeStore()
        await native.failNextSchedule(.maximumLimitReached)
        let executor = AlarmCreateExecutor(
            nativeStore: native,
            ownershipStore: try AlarmOwnershipStore(directoryURL: try directory()),
            usageDescriptionAvailable: { true }
        )
        let result = try await executor.execute(
            dispatch(actionType: "alarm.create", payload: fixedPayload())
        )
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.output["error_code"]?.stringValue, AlarmFailureCode.maximumLimitReached.rawValue)
    }

    func testTypedWeeklyIsAcceptedAndUnsupportedRecurrenceRejected() {
        let weekly = AlarmCreateArguments.parse([
            "title": .string("工作日"),
            "schedule": .object([
                "kind": .string("weekly"),
                "hour": .number(7),
                "minute": .number(30),
                "weekdays": .array([.string("monday"), .string("wednesday"), .string("friday")]),
            ]),
        ])
        XCTAssertEqual(weekly?.schedule.kind, .weekly)
        XCTAssertEqual(weekly?.schedule.weekdays, [.monday, .wednesday, .friday])

        XCTAssertNil(AlarmCreateArguments.parse([
            "title": .string("每日"),
            "schedule": .object([
                "kind": .string("daily"),
                "hour": .number(7),
                "minute": .number(30),
            ]),
        ]))
        XCTAssertNil(AlarmCreateArguments.parse([
            "title": .string("重复星期"),
            "schedule": .object([
                "kind": .string("weekly"),
                "hour": .number(7),
                "minute": .number(30),
                "weekdays": .array([.string("monday"), .string("monday")]),
            ]),
        ]))
        XCTAssertNil(AlarmCreateArguments.parse([
            "title": .string("无时区"),
            "schedule": .object([
                "kind": .string("fixed"),
                "fire_at": .string("2030-01-02T07:00:00"),
            ]),
        ]))
    }

    func testCreateReconcileAdoptsMatchingNativeAfterCrash() async throws {
        let key = "crash-key"
        let alarmID = AlarmIdentity.stableAlarmID(for: key)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2030-01-01T23:00:00Z"))
        let native = FakeAlarmNativeStore(records: [
            AlarmNativeRecord(id: alarmID, schedule: .fixed(date), state: .scheduled),
        ])
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let executor = AlarmCreateExecutor(
            nativeStore: native,
            ownershipStore: ownership,
            usageDescriptionAvailable: { true }
        )
        let request = dispatch(
            actionType: "alarm.create",
            payload: fixedPayload(),
            key: key,
            actionID: "crash-action"
        )
        let outcome = try await executor.reconcile(request, journalEntry: journalEntry(request))
        guard case let .completed(result) = outcome else {
            return XCTFail("matching native alarm must reconcile completed")
        }
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output["reconciled"]?.boolValue, true)
        let reconciledOwnership = await ownership.record(alarmID: alarmID)
        let reconcileCounts = await native.counts()
        XCTAssertEqual(reconciledOwnership?.actionID, "crash-action")
        XCTAssertEqual(reconcileCounts.schedule, 0)
    }

    func testCreateReconcileMissingWithoutReceiptRemainsUnknown() async throws {
        let native = FakeAlarmNativeStore()
        let executor = AlarmCreateExecutor(
            nativeStore: native,
            ownershipStore: try AlarmOwnershipStore(directoryURL: try directory()),
            usageDescriptionAvailable: { true }
        )
        let request = dispatch(actionType: "alarm.create", payload: fixedPayload())
        let outcome = try await executor.reconcile(request, journalEntry: journalEntry(request))
        guard case let .stillUnknown(reason) = outcome else {
            return XCTFail("missing native state after mayHaveStarted must not be retried blindly")
        }
        XCTAssertEqual(reason, "alarm_create_native_state_absent_after_ambiguous_boundary")
    }

    func testCancelVerifiesAbsenceAndIsIdempotentForOwnedAlarm() async throws {
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let create = AlarmCreateExecutor(
            nativeStore: native,
            ownershipStore: ownership,
            usageDescriptionAvailable: { true }
        )
        let createRequest = dispatch(
            actionType: "alarm.create",
            payload: fixedPayload(),
            key: "cancel-owned-key",
            actionID: "create-owned"
        )
        let created = try await create.execute(createRequest)
        let alarmID = try XCTUnwrap(created.output["alarm_id"]?.stringValue)
        let cancel = AlarmCancelExecutor(nativeStore: native, ownershipStore: ownership)
        let cancelRequest = dispatch(
            actionType: "alarm.cancel",
            payload: ["alarm_id": .string(alarmID)],
            key: "cancel-action-key",
            actionID: "cancel-action"
        )

        let cancelPreflight = try await cancel.preflight(cancelRequest)
        XCTAssertNil(cancelPreflight)
        let first = try await cancel.execute(cancelRequest)
        XCTAssertTrue(first.success)
        XCTAssertEqual(first.output["verified_absent"]?.boolValue, true)
        let cancelCounts = await native.counts()
        XCTAssertEqual(cancelCounts.cancel, 1)

        let replay = try await cancel.execute(cancelRequest)
        XCTAssertTrue(replay.success)
        XCTAssertEqual(replay.output["duplicate_suppressed"]?.boolValue, true)
        let replayCancelCounts = await native.counts()
        XCTAssertEqual(replayCancelCounts.cancel, 1)
        let id = try XCTUnwrap(UUID(uuidString: alarmID))
        let cancelledOwnership = await ownership.record(alarmID: id)
        XCTAssertEqual(cancelledOwnership?.lifecycle, .cancelled)
    }

    func testCancelUnknownAbsentIDFailsClosed() async throws {
        let executor = AlarmCancelExecutor(
            nativeStore: FakeAlarmNativeStore(),
            ownershipStore: try AlarmOwnershipStore(directoryURL: try directory())
        )
        let failure = try await executor.preflight(
            dispatch(
                actionType: "alarm.cancel",
                payload: ["alarm_id": .string(UUID().uuidString)]
            )
        )
        XCTAssertEqual(failure?.output["error_code"]?.stringValue, AlarmFailureCode.unknownTarget.rawValue)
    }

    func testCancelReconcileUsesNativePresenceAsRetryProof() async throws {
        let alarmID = UUID()
        let native = FakeAlarmNativeStore(records: [
            AlarmNativeRecord(
                id: alarmID,
                schedule: .fixed(Date(timeIntervalSince1970: 1_900_000_000)),
                state: .scheduled
            ),
        ])
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let createBinding = dispatch(
            actionType: "alarm.create",
            payload: fixedPayload(),
            key: "cancel-reconcile-owned",
            actionID: "cancel-reconcile-create"
        )
        _ = try await ownership.recordAccepted(
            alarmID: alarmID,
            dispatch: createBinding,
            title: "取消恢复",
            schedule: .fixed(Date(timeIntervalSince1970: 1_900_000_000)),
            nativeState: .scheduled
        )
        let executor = AlarmCancelExecutor(nativeStore: native, ownershipStore: ownership)
        let request = dispatch(
            actionType: "alarm.cancel",
            payload: ["alarm_id": .string(alarmID.uuidString)]
        )

        var outcome = try await executor.reconcile(request, journalEntry: journalEntry(request))
        XCTAssertEqual(outcome, .definitelyNotStarted)

        await native.remove(id: alarmID)
        outcome = try await executor.reconcile(request, journalEntry: journalEntry(request))
        guard case let .completed(result) = outcome else {
            return XCTFail("native absence after admitted cancel must reconcile as desired-state complete")
        }
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output["verified_absent"]?.boolValue, true)
    }

    func testReadJoinsNativeTruthWithLedgerAndReportsSystemMissing() async throws {
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let create = AlarmCreateExecutor(
            nativeStore: native,
            ownershipStore: ownership,
            usageDescriptionAvailable: { true }
        )
        let createRequest = dispatch(
            actionType: "alarm.create",
            payload: fixedPayload(title: "读回测试"),
            key: "read-owned-key",
            actionID: "read-create"
        )
        let created = try await create.execute(createRequest)
        let alarmIDRaw = try XCTUnwrap(created.output["alarm_id"]?.stringValue)
        let alarmID = try XCTUnwrap(UUID(uuidString: alarmIDRaw))
        let read = AlarmReadExecutor(nativeStore: native, ownershipStore: ownership)
        let readRequest = dispatch(
            actionType: "alarm.read",
            payload: ["alarm_id": .string(alarmIDRaw)]
        )

        var result = try await read.execute(readRequest)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output["exists"]?.boolValue, true)
        XCTAssertEqual(result.output["title"]?.stringValue, "读回测试")
        XCTAssertEqual(result.output["title_source"]?.stringValue, "ownership_ledger")
        XCTAssertEqual(result.output["native_state"]?.stringValue, AlarmNativeState.scheduled.rawValue)

        await native.remove(id: alarmID)
        result = try await read.execute(readRequest)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output["exists"]?.boolValue, false)
        XCTAssertEqual(result.output["ownership_lifecycle"]?.stringValue, AlarmOwnershipLifecycle.missing.rawValue)
        let readMissingOwnership = await ownership.record(alarmID: alarmID)
        XCTAssertEqual(readMissingOwnership?.lifecycle, .missing)
    }

    func testReadUnknownTargetAndPermissionFailureAreDeterministic() async throws {
        let native = FakeAlarmNativeStore(authorization: .denied)
        let read = AlarmReadExecutor(
            nativeStore: native,
            ownershipStore: try AlarmOwnershipStore(directoryURL: try directory())
        )
        let request = dispatch(
            actionType: "alarm.read",
            payload: ["alarm_id": .string(UUID().uuidString)]
        )
        let preflightFailure = try await read.preflight(request)
        XCTAssertEqual(preflightFailure?.output["error_code"]?.stringValue, AlarmFailureCode.authorizationDenied.rawValue)

        await native.setAuthorization(.authorized)
        let executeFailure = try await read.execute(request)
        XCTAssertEqual(executeFailure.output["error_code"]?.stringValue, AlarmFailureCode.unknownTarget.rawValue)
    }

    func testReadRejectsForeignNativeAlarmAndUnavailableOwnershipLedger() async throws {
        let foreignID = UUID()
        let native = FakeAlarmNativeStore(records: [
            AlarmNativeRecord(
                id: foreignID,
                schedule: .fixed(Date(timeIntervalSince1970: 1_900_000_000)),
                state: .scheduled
            ),
        ])
        let request = dispatch(
            actionType: "alarm.read",
            payload: ["alarm_id": .string(foreignID.uuidString)]
        )

        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let foreignRead = AlarmReadExecutor(nativeStore: native, ownershipStore: ownership)
        let foreignPreflight = try await foreignRead.preflight(request)
        XCTAssertEqual(
            foreignPreflight?.output["error_code"]?.stringValue,
            AlarmFailureCode.foreignTarget.rawValue
        )
        let foreignResult = try await foreignRead.execute(request)
        XCTAssertFalse(foreignResult.success)
        XCTAssertEqual(
            foreignResult.output["error_code"]?.stringValue,
            AlarmFailureCode.foreignTarget.rawValue
        )
        XCTAssertNil(foreignResult.output["native_schedule"])

        let unavailableRead = AlarmReadExecutor(nativeStore: native, ownershipStore: nil)
        let unavailablePreflight = try await unavailableRead.preflight(request)
        XCTAssertEqual(
            unavailablePreflight?.output["error_code"]?.stringValue,
            AlarmFailureCode.ownershipStoreUnavailable.rawValue
        )
        let unavailableResult = try await unavailableRead.execute(request)
        XCTAssertFalse(unavailableResult.success)
        XCTAssertEqual(
            unavailableResult.output["error_code"]?.stringValue,
            AlarmFailureCode.ownershipStoreUnavailable.rawValue
        )
        XCTAssertNil(unavailableResult.output["native_schedule"])
    }

    func testBoundedEnumerationSeesTwoDistinctNativeAlarms() async throws {
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let create = AlarmCreateExecutor(
            nativeStore: native,
            ownershipStore: ownership,
            usageDescriptionAvailable: { true }
        )
        _ = try await create.execute(
            dispatch(actionType: "alarm.create", payload: fixedPayload(), key: "enum-one")
        )
        _ = try await create.execute(
            dispatch(
                actionType: "alarm.create",
                payload: fixedPayload(fireAt: "2030-01-02T09:00:00+08:00"),
                key: "enum-two"
            )
        )
        let snapshots = try await AlarmReadbackService.enumerate(
            nativeStore: native,
            ownershipStore: ownership,
            maxResults: 10
        )
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertTrue(snapshots.allSatisfy { $0.native != nil && $0.ownership != nil })
    }

    func testTypedFixedAndWeeklyCreateUseSupportedSoundAndReadback() async throws {
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let executor = AlarmCreateExecutor(nativeStore: native, ownershipStore: ownership, usageDescriptionAvailable: { true })

        let fixed = try await executor.execute(
            dispatch(actionType: "alarm.create", payload: typedFixedPayload(), key: "typed-fixed")
        )
        XCTAssertTrue(fixed.success)
        XCTAssertEqual(fixed.output["sound"]?.stringValue, "default")
        XCTAssertEqual(fixed.output["schedule"]?.objectValue?["kind"]?.stringValue, "fixed")

        let weekly = try await executor.execute(
            dispatch(actionType: "alarm.create", payload: weeklyPayload(), key: "typed-weekly")
        )
        XCTAssertTrue(weekly.success)
        XCTAssertEqual(weekly.output["sound"]?.stringValue, "default")
        XCTAssertEqual(weekly.output["schedule"]?.objectValue?["kind"]?.stringValue, "weekly")
        XCTAssertEqual(number(weekly.output["schedule"]?.objectValue?["hour"]), 7)
        let counts = await native.counts()
        XCTAssertEqual(counts.schedule, 2)
    }

    func testUnsupportedAlarmSoundFailsClosed() {
        XCTAssertNil(AlarmCreateArguments.parse(typedFixedPayload(sound: "unbundled-tone")))
        let alarmID = UUID()
        XCTAssertNil(AlarmUpdateArguments.parse(updatePayload(
            alarmID: alarmID,
            title: "新标题",
            hour: 8,
            minute: 15,
            weekdays: ["tuesday"],
            sound: "unbundled-tone"
        )))
    }

    func testAlarmQueryZeroAndManyReturnsOwnedOnly() async throws {
        let foreignID = UUID()
        let native = FakeAlarmNativeStore(records: [
            AlarmNativeRecord(id: foreignID, schedule: .fixed(Date(timeIntervalSince1970: 1_900_000_000)), state: .scheduled),
        ])
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let query = AlarmQueryExecutor(nativeStore: native, ownershipStore: ownership)
        var result = try await query.execute(dispatch(actionType: "alarm.query", payload: [:]))
        XCTAssertTrue(result.success)
        XCTAssertEqual(number(result.output["count"]), 0)

        let create = AlarmCreateExecutor(nativeStore: native, ownershipStore: ownership, usageDescriptionAvailable: { true })
        _ = try await create.execute(dispatch(actionType: "alarm.create", payload: typedFixedPayload(), key: "query-one"))
        _ = try await create.execute(dispatch(actionType: "alarm.create", payload: weeklyPayload(), key: "query-two"))
        result = try await query.execute(dispatch(actionType: "alarm.query", payload: ["max_results": .number(10)]))
        XCTAssertEqual(number(result.output["count"]), 2)
        let alarms = try XCTUnwrap(result.output["alarms"]?.arrayValue)
        let ids = Set(alarms.compactMap { $0.objectValue?["alarm_id"]?.stringValue })
        XCTAssertFalse(ids.contains(foreignID.uuidString))
        XCTAssertTrue(alarms.allSatisfy { $0.objectValue?["ownership_ledger_present"]?.boolValue == true })
    }

    func testSameIDUpdateChangesTitleTimeWeekdaysAndSuppressesReplay() async throws {
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let create = AlarmCreateExecutor(nativeStore: native, ownershipStore: ownership, usageDescriptionAvailable: { true })
        let created = try await create.execute(
            dispatch(actionType: "alarm.create", payload: weeklyPayload(), key: "update-create", actionID: "create-action")
        )
        let alarmID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created.output["alarm_id"]?.stringValue)))
        let update = AlarmUpdateExecutor(nativeStore: native, ownershipStore: ownership)
        let request = dispatch(
            actionType: "alarm.update",
            payload: updatePayload(alarmID: alarmID, title: "新的工作日", hour: 8, minute: 15, weekdays: ["tuesday", "thursday"]),
            key: "update-idempotency",
            actionID: "update-action"
        )
        let updatePreflight = try await update.preflight(request)
        XCTAssertNil(updatePreflight)
        let first = try await update.execute(request)
        XCTAssertTrue(first.success)
        XCTAssertEqual(first.output["alarm_id"]?.stringValue, alarmID.uuidString)
        XCTAssertEqual(first.output["same_alarm_id"]?.boolValue, true)
        XCTAssertEqual(first.output["title"]?.stringValue, "新的工作日")
        XCTAssertEqual(number(first.output["schedule"]?.objectValue?["hour"]), 8)
        let storedOptional = await ownership.record(alarmID: alarmID)
        let stored = try XCTUnwrap(storedOptional)
        XCTAssertEqual(stored.title, "新的工作日")
        XCTAssertEqual(stored.schedule.hour, 8)
        XCTAssertEqual(stored.schedule.minute, 15)
        XCTAssertEqual(stored.schedule.weekdays, [.tuesday, .thursday])
        XCTAssertEqual(stored.effectiveSound, .defaultSound)
        XCTAssertEqual(stored.lastMutationActionID, "update-action")

        let replay = try await update.execute(request)
        XCTAssertEqual(replay.output["duplicate_suppressed"]?.boolValue, true)
        let counts = await native.counts()
        XCTAssertEqual(counts.schedule, 2, "create + one same-ID reschedule; replay must not reschedule again")
    }

    func testUpdateReconcileAdoptsSameIDNativeScheduleWithoutResend() async throws {
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let create = AlarmCreateExecutor(nativeStore: native, ownershipStore: ownership, usageDescriptionAvailable: { true })
        let created = try await create.execute(
            dispatch(actionType: "alarm.create", payload: weeklyPayload(), key: "reconcile-update-create")
        )
        let alarmID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created.output["alarm_id"]?.stringValue)))
        let request = dispatch(
            actionType: "alarm.update",
            payload: updatePayload(alarmID: alarmID, title: "已改", hour: 9, minute: 5, weekdays: ["monday", "friday"]),
            key: "reconcile-update",
            actionID: "reconcile-update-action"
        )
        await native.setRecord(AlarmNativeRecord(
            id: alarmID,
            schedule: .weekly(hour: 9, minute: 5, weekdays: [.monday, .friday]),
            state: .scheduled
        ))
        let executor = AlarmUpdateExecutor(nativeStore: native, ownershipStore: ownership)
        let outcome = try await executor.reconcile(request, journalEntry: journalEntry(request))
        guard case let .completed(result) = outcome else { return XCTFail("same-ID readback must reconcile") }
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output["reconciled"]?.boolValue, true)
        let counts = await native.counts()
        XCTAssertEqual(counts.schedule, 1, "reconciliation must not resend after native effect already exists")
        let reconciledRecord = await ownership.record(alarmID: alarmID)
        XCTAssertEqual(reconciledRecord?.title, "已改")
    }

    func testUpdateReconcileOldScheduleStillPresentIsDefinitelyNotStarted() async throws {
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let create = AlarmCreateExecutor(nativeStore: native, ownershipStore: ownership, usageDescriptionAvailable: { true })
        let created = try await create.execute(
            dispatch(actionType: "alarm.create", payload: weeklyPayload(), key: "reconcile-old-create")
        )
        let alarmID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created.output["alarm_id"]?.stringValue)))
        let beforeOptional = await ownership.record(alarmID: alarmID)
        let before = try XCTUnwrap(beforeOptional)
        let request = dispatch(
            actionType: "alarm.update",
            payload: updatePayload(alarmID: alarmID, title: "新时间", hour: 9, minute: 5, weekdays: ["monday", "friday"]),
            key: "reconcile-old-update",
            actionID: "reconcile-old-update-action"
        )

        let executor = AlarmUpdateExecutor(nativeStore: native, ownershipStore: ownership)
        let outcome = try await executor.reconcile(request, journalEntry: journalEntry(request))
        XCTAssertEqual(outcome, .definitelyNotStarted)
        let recordOptional = await ownership.record(alarmID: alarmID)
        let record = try XCTUnwrap(recordOptional)
        XCTAssertEqual(record.title, "工作日")
        XCTAssertEqual(record.schedule.hour, 7)
        XCTAssertEqual(record.schedule.minute, 30)
        XCTAssertEqual(record.effectiveSound, before.effectiveSound)
        XCTAssertEqual(record.lastMutationActionID, before.lastMutationActionID)
    }

    func testUpdateReconcileTitleOnlyMayHaveStartedRemainsUnknown() async throws {
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let create = AlarmCreateExecutor(nativeStore: native, ownershipStore: ownership, usageDescriptionAvailable: { true })
        let created = try await create.execute(
            dispatch(actionType: "alarm.create", payload: weeklyPayload(), key: "reconcile-title-create")
        )
        let alarmID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created.output["alarm_id"]?.stringValue)))
        let request = dispatch(
            actionType: "alarm.update",
            payload: updatePayload(
                alarmID: alarmID,
                title: "仅修改标题",
                hour: 7,
                minute: 30,
                weekdays: ["monday", "wednesday", "friday"]
            ),
            key: "reconcile-title-update",
            actionID: "reconcile-title-update-action"
        )

        let executor = AlarmUpdateExecutor(nativeStore: native, ownershipStore: ownership)
        let outcome = try await executor.reconcile(request, journalEntry: journalEntry(request))
        guard case .stillUnknown = outcome else {
            return XCTFail("same-schedule title-only recovery must remain ambiguous")
        }
    }

    func testUpdateReconciliationPolicySoundOnlyMayHaveStartedRemainsUnknown() {
        let decision = alarmUpdateReconciliationDecision(
            AlarmUpdateReconciliationEvidence(
                requestedScheduleMatchesNative: true,
                previousScheduleMatchesNative: true,
                titleMatchesOwnership: true,
                requestedScheduleMatchesOwnership: true,
                soundMatchesOwnership: false
            )
        )

        XCTAssertEqual(
            decision,
            .stillUnknown(
                "alarm_update_native_schedule_matches_both_old_and_requested_configuration"
            )
        )
    }

    func testUpdateReconcileExactSemanticNoOpCompletes() async throws {
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let create = AlarmCreateExecutor(nativeStore: native, ownershipStore: ownership, usageDescriptionAvailable: { true })
        let created = try await create.execute(
            dispatch(actionType: "alarm.create", payload: weeklyPayload(), key: "reconcile-noop-create")
        )
        let alarmID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created.output["alarm_id"]?.stringValue)))
        let request = dispatch(
            actionType: "alarm.update",
            payload: updatePayload(
                alarmID: alarmID,
                title: "工作日",
                hour: 7,
                minute: 30,
                weekdays: ["friday", "monday", "wednesday"]
            ),
            key: "reconcile-noop-update",
            actionID: "reconcile-noop-update-action"
        )

        let executor = AlarmUpdateExecutor(nativeStore: native, ownershipStore: ownership)
        let outcome = try await executor.reconcile(request, journalEntry: journalEntry(request))
        guard case let .completed(result) = outcome else {
            return XCTFail("exact semantic no-op is safe to reconcile completed")
        }
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output["reconciled"]?.boolValue, true)
        let counts = await native.counts()
        XCTAssertEqual(counts.schedule, 1, "no-op reconciliation must not resend the native update")
    }

    func testUpdateReconcileAmbiguousPathDoesNotPromoteOwnershipConfiguration() async throws {
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let create = AlarmCreateExecutor(nativeStore: native, ownershipStore: ownership, usageDescriptionAvailable: { true })
        let created = try await create.execute(
            dispatch(actionType: "alarm.create", payload: weeklyPayload(), key: "reconcile-preserve-create")
        )
        let alarmID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created.output["alarm_id"]?.stringValue)))
        let beforeOptional = await ownership.record(alarmID: alarmID)
        let before = try XCTUnwrap(beforeOptional)
        let request = dispatch(
            actionType: "alarm.update",
            payload: updatePayload(
                alarmID: alarmID,
                title: "不能偷写的新标题",
                hour: 7,
                minute: 30,
                weekdays: ["monday", "wednesday", "friday"]
            ),
            key: "reconcile-preserve-update",
            actionID: "reconcile-preserve-update-action"
        )

        let executor = AlarmUpdateExecutor(nativeStore: native, ownershipStore: ownership)
        let outcome = try await executor.reconcile(request, journalEntry: journalEntry(request))
        guard case .stillUnknown = outcome else {
            return XCTFail("ambiguous same-schedule recovery must remain unknown")
        }
        let afterOptional = await ownership.record(alarmID: alarmID)
        let after = try XCTUnwrap(afterOptional)
        XCTAssertEqual(after.title, before.title)
        XCTAssertEqual(after.effectiveSound, before.effectiveSound)
        XCTAssertTrue(after.schedule.isSemanticallyEquivalent(to: before.schedule))
        XCTAssertEqual(after.lastMutationActionID, before.lastMutationActionID)
    }

    func testPauseAndResumeUseNativeLifecycleAndReadback() async throws {
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let create = AlarmCreateExecutor(nativeStore: native, ownershipStore: ownership, usageDescriptionAvailable: { true })
        let created = try await create.execute(dispatch(actionType: "alarm.create", payload: typedFixedPayload(), key: "lifecycle-create"))
        let alarmID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created.output["alarm_id"]?.stringValue)))
        let nativeRecordsBeforePause = try await native.alarms()
        let schedule = try XCTUnwrap(nativeRecordsBeforePause.first(where: { $0.id == alarmID })?.schedule)
        await native.setRecord(AlarmNativeRecord(id: alarmID, schedule: schedule, state: .countdown))

        let pause = AlarmPauseExecutor(nativeStore: native, ownershipStore: ownership)
        let pauseRequest = dispatch(actionType: "alarm.pause", payload: ["alarm_id": .string(alarmID.uuidString)], actionID: "pause-action")
        let pausePreflight = try await pause.preflight(pauseRequest)
        XCTAssertNil(pausePreflight)
        let paused = try await pause.execute(pauseRequest)
        XCTAssertEqual(paused.output["native_state"]?.stringValue, AlarmNativeState.paused.rawValue)

        let resume = AlarmResumeExecutor(nativeStore: native, ownershipStore: ownership)
        let resumeRequest = dispatch(actionType: "alarm.resume", payload: ["alarm_id": .string(alarmID.uuidString)], actionID: "resume-action")
        let resumePreflight = try await resume.preflight(resumeRequest)
        XCTAssertNil(resumePreflight)
        let resumed = try await resume.execute(resumeRequest)
        XCTAssertEqual(resumed.output["native_state"]?.stringValue, AlarmNativeState.countdown.rawValue)
        let counts = await native.counts()
        XCTAssertEqual(counts.pause, 1)
        XCTAssertEqual(counts.resume, 1)
        let lifecycleRecord = await ownership.record(alarmID: alarmID)
        XCTAssertEqual(lifecycleRecord?.lastNativeState, .countdown)
    }

    func testPauseResumeAndUpdateRejectInvalidNativeState() async throws {
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let create = AlarmCreateExecutor(nativeStore: native, ownershipStore: ownership, usageDescriptionAvailable: { true })
        let created = try await create.execute(dispatch(actionType: "alarm.create", payload: typedFixedPayload(), key: "invalid-state-create"))
        let alarmID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created.output["alarm_id"]?.stringValue)))
        let pause = AlarmPauseExecutor(nativeStore: native, ownershipStore: ownership)
        let resume = AlarmResumeExecutor(nativeStore: native, ownershipStore: ownership)
        let pauseFailure = try await pause.preflight(dispatch(actionType: "alarm.pause", payload: ["alarm_id": .string(alarmID.uuidString)]))
        let resumeFailure = try await resume.preflight(dispatch(actionType: "alarm.resume", payload: ["alarm_id": .string(alarmID.uuidString)]))
        XCTAssertEqual(pauseFailure?.output["error_code"]?.stringValue, AlarmFailureCode.invalidNativeState.rawValue)
        XCTAssertEqual(resumeFailure?.output["error_code"]?.stringValue, AlarmFailureCode.invalidNativeState.rawValue)
    }

    func testManagedMutationsRejectForeignAndMissingTargets() async throws {
        let foreignID = UUID()
        let native = FakeAlarmNativeStore(records: [
            AlarmNativeRecord(id: foreignID, schedule: .fixed(Date(timeIntervalSince1970: 1_900_000_000)), state: .scheduled),
        ])
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let cancel = AlarmCancelExecutor(nativeStore: native, ownershipStore: ownership)
        let foreignCancel = try await cancel.preflight(dispatch(actionType: "alarm.cancel", payload: ["alarm_id": .string(foreignID.uuidString)]))
        XCTAssertEqual(foreignCancel?.output["error_code"]?.stringValue, AlarmFailureCode.foreignTarget.rawValue)

        let update = AlarmUpdateExecutor(nativeStore: native, ownershipStore: ownership)
        let foreignUpdate = try await update.preflight(dispatch(
            actionType: "alarm.update",
            payload: updatePayload(alarmID: foreignID, title: "不能改", hour: 8, minute: 0, weekdays: ["monday"])
        ))
        XCTAssertEqual(foreignUpdate?.output["error_code"]?.stringValue, AlarmFailureCode.foreignTarget.rawValue)

        let missingID = UUID()
        let missing = try await cancel.preflight(dispatch(actionType: "alarm.cancel", payload: ["alarm_id": .string(missingID.uuidString)]))
        XCTAssertEqual(missing?.output["error_code"]?.stringValue, AlarmFailureCode.unknownTarget.rawValue)
    }

    func testManagementPermissionDeniedFailsBeforeMutation() async throws {
        let native = FakeAlarmNativeStore(authorization: .denied)
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let alarmID = UUID()
        let queryFailure = try await AlarmQueryExecutor(nativeStore: native, ownershipStore: ownership)
            .preflight(dispatch(actionType: "alarm.query", payload: [:]))
        let updateFailure = try await AlarmUpdateExecutor(nativeStore: native, ownershipStore: ownership)
            .preflight(dispatch(actionType: "alarm.update", payload: updatePayload(alarmID: alarmID, title: "x", hour: 8, minute: 0, weekdays: ["monday"])))
        let pauseFailure = try await AlarmPauseExecutor(nativeStore: native, ownershipStore: ownership)
            .preflight(dispatch(actionType: "alarm.pause", payload: ["alarm_id": .string(alarmID.uuidString)]))
        let resumeFailure = try await AlarmResumeExecutor(nativeStore: native, ownershipStore: ownership)
            .preflight(dispatch(actionType: "alarm.resume", payload: ["alarm_id": .string(alarmID.uuidString)]))
        for result in [queryFailure, updateFailure, pauseFailure, resumeFailure] {
            XCTAssertEqual(result?.output["error_code"]?.stringValue, AlarmFailureCode.authorizationDenied.rawValue)
        }
        let counts = await native.counts()
        XCTAssertEqual(counts.schedule, 0)
        XCTAssertEqual(counts.pause, 0)
        XCTAssertEqual(counts.resume, 0)
    }

    func testDaemonLedgerMismatchIsVisibleAndUpdateFailsClosed() async throws {
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let create = AlarmCreateExecutor(nativeStore: native, ownershipStore: ownership, usageDescriptionAvailable: { true })
        let created = try await create.execute(dispatch(actionType: "alarm.create", payload: weeklyPayload(), key: "mismatch-create"))
        let alarmID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created.output["alarm_id"]?.stringValue)))
        await native.remove(id: alarmID)

        let queried = try await AlarmQueryExecutor(nativeStore: native, ownershipStore: ownership)
            .execute(dispatch(actionType: "alarm.query", payload: [:]))
        let item = try XCTUnwrap(queried.output["alarms"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(item["native_present"]?.boolValue, false)
        XCTAssertEqual(item["ownership_lifecycle"]?.stringValue, AlarmOwnershipLifecycle.missing.rawValue)

        let failure = try await AlarmUpdateExecutor(nativeStore: native, ownershipStore: ownership)
            .preflight(dispatch(
                actionType: "alarm.update",
                payload: updatePayload(alarmID: alarmID, title: "不能静默重建", hour: 8, minute: 0, weekdays: ["monday"])
            ))
        XCTAssertEqual(failure?.output["error_code"]?.stringValue, AlarmFailureCode.readbackMissing.rawValue)
    }

    func testPendingSettingsMutationBlocksPlannerMutationsButRemainsQueryable() async throws {
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let create = AlarmCreateExecutor(nativeStore: native, ownershipStore: ownership, usageDescriptionAvailable: { true })
        let created = try await create.execute(
            dispatch(actionType: "alarm.create", payload: typedFixedPayload(), key: "pending-settings-gate-create")
        )
        let alarmID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created.output["alarm_id"]?.stringValue)))
        let nativeRecords = try await native.alarms()
        let current = try XCTUnwrap(nativeRecords.first(where: { $0.id == alarmID }))
        _ = try await ownership.beginSettingsMutation(
            alarmID: alarmID,
            mutationID: "settings.pending.gate",
            operation: .update,
            beforeNativeState: current.state,
            requestedTitle: "待确认",
            requestedSchedule: .weekly(hour: 8, minute: 0, weekdays: [.monday]),
            requestedSound: .defaultSound
        )

        let updateFailure = try await AlarmUpdateExecutor(nativeStore: native, ownershipStore: ownership).preflight(
            dispatch(
                actionType: "alarm.update",
                payload: updatePayload(alarmID: alarmID, title: "Planner 不应覆盖", hour: 9, minute: 0, weekdays: ["tuesday"])
            )
        )
        let pauseFailure = try await AlarmPauseExecutor(nativeStore: native, ownershipStore: ownership).preflight(
            dispatch(actionType: "alarm.pause", payload: ["alarm_id": .string(alarmID.uuidString)])
        )
        let resumeFailure = try await AlarmResumeExecutor(nativeStore: native, ownershipStore: ownership).preflight(
            dispatch(actionType: "alarm.resume", payload: ["alarm_id": .string(alarmID.uuidString)])
        )
        let cancelFailure = try await AlarmCancelExecutor(nativeStore: native, ownershipStore: ownership).preflight(
            dispatch(actionType: "alarm.cancel", payload: ["alarm_id": .string(alarmID.uuidString)])
        )
        for failure in [updateFailure, pauseFailure, resumeFailure, cancelFailure] {
            XCTAssertEqual(
                failure?.output["error_code"]?.stringValue,
                AlarmFailureCode.settingsMutationPending.rawValue
            )
        }

        let query = try await AlarmQueryExecutor(nativeStore: native, ownershipStore: ownership).execute(
            dispatch(actionType: "alarm.query", payload: [:])
        )
        let item = try XCTUnwrap(query.output["alarms"]?.arrayValue?.first?.objectValue)
        let mutation = try XCTUnwrap(item["settings_mutation"]?.objectValue)
        XCTAssertEqual(mutation["mutation_id"]?.stringValue, "settings.pending.gate")
        XCTAssertEqual(mutation["operation"]?.stringValue, AlarmSettingsMutationOperation.update.rawValue)
        XCTAssertEqual(mutation["state"]?.stringValue, AlarmSettingsMutationIntentState.pending.rawValue)
        let counts = await native.counts()
        XCTAssertEqual(counts.schedule, 1)
        XCTAssertEqual(counts.cancel, 0)
        XCTAssertEqual(counts.pause, 0)
        XCTAssertEqual(counts.resume, 0)
    }

    @MainActor
    func testSettingsUpdateCrashAfterNativeSuccessRepairsLedgerOnReopen() async throws {
        let dir = try directory()
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: dir)
        let create = AlarmCreateExecutor(nativeStore: native, ownershipStore: ownership, usageDescriptionAvailable: { true })
        let created = try await create.execute(
            dispatch(actionType: "alarm.create", payload: typedFixedPayload(title: "旧标题"), key: "settings-update-crash-create", actionID: "origin-create")
        )
        let alarmID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created.output["alarm_id"]?.stringValue)))
        let originValue = await ownership.record(alarmID: alarmID)
        let origin = try XCTUnwrap(originValue)
        let nativeBefore = try await native.alarms()
        let beforeNative = try XCTUnwrap(nativeBefore.first(where: { $0.id == alarmID }))
        let desired = AlarmDesiredSchedule.weekly(hour: 8, minute: 15, weekdays: [.tuesday, .thursday])
        let mutationID = "settings.manual.update.crash-window"
        _ = try await ownership.beginSettingsMutation(
            alarmID: alarmID,
            mutationID: mutationID,
            operation: .update,
            beforeNativeState: beforeNative.state,
            requestedTitle: "新标题",
            requestedSchedule: desired,
            requestedSound: .defaultSound
        )

        _ = try await native.schedule(
            AlarmNativeScheduleRequest(
                id: alarmID,
                title: "新标题",
                taskID: origin.taskID,
                actionID: mutationID,
                idempotencyKey: mutationID,
                schedule: desired,
                sound: .defaultSound
            )
        )
        // Simulate process loss here: native succeeded, ownership completion never ran.
        let reopened = try AlarmOwnershipStore(directoryURL: dir)
        let pendingBeforeRefresh = await reopened.record(alarmID: alarmID)?.pendingSettingsMutation
        XCTAssertEqual(pendingBeforeRefresh?.mutationID, mutationID)

        let model = AlarmManagementModel(nativeStore: native, ownershipStore: reopened)
        model.refresh()
        try await Task.sleep(for: .milliseconds(100))

        let repairedValue = await reopened.record(alarmID: alarmID)
        let repaired = try XCTUnwrap(repairedValue)
        XCTAssertEqual(repaired.alarmID, alarmID)
        XCTAssertEqual(repaired.actionID, origin.actionID, "create origin must stay immutable")
        XCTAssertEqual(repaired.title, "新标题")
        XCTAssertTrue(repaired.schedule.isSemanticallyEquivalent(to: desired))
        XCTAssertNil(repaired.pendingSettingsMutation)
        XCTAssertEqual(repaired.lastSettingsMutationOutcome?.resolution, .completed)
        XCTAssertEqual(repaired.lastMutationActionID, mutationID)
        XCTAssertEqual(model.alarms.first?.id, alarmID)
        XCTAssertEqual(model.alarms.first?.title, "新标题")
        XCTAssertTrue(model.alarms.first?.schedule.isSemanticallyEquivalent(to: desired) == true)
        XCTAssertNil(model.alarms.first?.mutationStatus)
        let counts = await native.counts()
        XCTAssertEqual(counts.schedule, 2, "reopen repair must not reschedule a second time")
    }

    @MainActor
    func testSettingsCancelCrashAfterNativeSuccessReopensAsDurablyCancelled() async throws {
        let dir = try directory()
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: dir)
        let create = AlarmCreateExecutor(nativeStore: native, ownershipStore: ownership, usageDescriptionAvailable: { true })
        let created = try await create.execute(
            dispatch(actionType: "alarm.create", payload: typedFixedPayload(), key: "settings-cancel-crash-create")
        )
        let alarmID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created.output["alarm_id"]?.stringValue)))
        let nativeBeforeCancel = try await native.alarms()
        let before = try XCTUnwrap(nativeBeforeCancel.first(where: { $0.id == alarmID }))
        let mutationID = "settings.manual.cancel.crash-window"
        _ = try await ownership.beginSettingsMutation(
            alarmID: alarmID, mutationID: mutationID, operation: .cancel, beforeNativeState: before.state
        )
        try await native.cancel(id: alarmID)

        let reopened = try AlarmOwnershipStore(directoryURL: dir)
        let model = AlarmManagementModel(nativeStore: native, ownershipStore: reopened)
        model.refresh()
        try await Task.sleep(for: .milliseconds(100))

        let repairedValue = await reopened.record(alarmID: alarmID)
        let repaired = try XCTUnwrap(repairedValue)
        XCTAssertEqual(repaired.lifecycle, .cancelled)
        XCTAssertNil(repaired.pendingSettingsMutation)
        XCTAssertEqual(repaired.lastSettingsMutationOutcome?.operation, .cancel)
        XCTAssertEqual(repaired.lastSettingsMutationOutcome?.resolution, .completed)
        XCTAssertTrue(model.alarms.isEmpty, "cancelled owned alarm must not reopen as stale/missing management row")
        let counts = await native.counts()
        XCTAssertEqual(counts.cancel, 1, "reconciliation must not repeat native cancel")
    }

    @MainActor
    func testSettingsPauseAndResumeCrashWindowsReconcileFromNativeState() async throws {
        let dir = try directory()
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: dir)
        let create = AlarmCreateExecutor(nativeStore: native, ownershipStore: ownership, usageDescriptionAvailable: { true })
        let created = try await create.execute(
            dispatch(actionType: "alarm.create", payload: typedFixedPayload(), key: "settings-lifecycle-crash-create")
        )
        let alarmID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created.output["alarm_id"]?.stringValue)))
        let nativeBeforeLifecycle = try await native.alarms()
        let original = try XCTUnwrap(nativeBeforeLifecycle.first(where: { $0.id == alarmID }))
        await native.setRecord(AlarmNativeRecord(id: alarmID, schedule: original.schedule, state: .countdown))

        let pauseID = "settings.manual.pause.crash-window"
        _ = try await ownership.beginSettingsMutation(
            alarmID: alarmID, mutationID: pauseID, operation: .pause, beforeNativeState: .countdown
        )
        try await native.pause(id: alarmID)
        let reopenedAfterPause = try AlarmOwnershipStore(directoryURL: dir)
        let pauseModel = AlarmManagementModel(nativeStore: native, ownershipStore: reopenedAfterPause)
        pauseModel.refresh()
        try await Task.sleep(for: .milliseconds(100))
        let pausedValue = await reopenedAfterPause.record(alarmID: alarmID)
        let paused = try XCTUnwrap(pausedValue)
        XCTAssertNil(paused.pendingSettingsMutation)
        XCTAssertEqual(paused.lastNativeState, .paused)
        XCTAssertEqual(paused.lastSettingsMutationOutcome?.operation, .pause)
        XCTAssertEqual(paused.lastSettingsMutationOutcome?.resolution, .completed)
        XCTAssertTrue(pauseModel.alarms.first?.canResume == true)

        let resumeID = "settings.manual.resume.crash-window"
        _ = try await reopenedAfterPause.beginSettingsMutation(
            alarmID: alarmID, mutationID: resumeID, operation: .resume, beforeNativeState: .paused
        )
        try await native.resume(id: alarmID)
        let reopenedAfterResume = try AlarmOwnershipStore(directoryURL: dir)
        let resumeModel = AlarmManagementModel(nativeStore: native, ownershipStore: reopenedAfterResume)
        resumeModel.refresh()
        try await Task.sleep(for: .milliseconds(100))
        let resumedValue = await reopenedAfterResume.record(alarmID: alarmID)
        let resumed = try XCTUnwrap(resumedValue)
        XCTAssertNil(resumed.pendingSettingsMutation)
        XCTAssertEqual(resumed.lastNativeState, .countdown)
        XCTAssertEqual(resumed.lastSettingsMutationOutcome?.operation, .resume)
        XCTAssertEqual(resumed.lastSettingsMutationOutcome?.resolution, .completed)
        XCTAssertTrue(resumeModel.alarms.first?.canPause == true)
        let counts = await native.counts()
        XCTAssertEqual(counts.pause, 1)
        XCTAssertEqual(counts.resume, 1)
    }

    @MainActor
    func testSettingsMutationReconciliationProvesNotStartedForKnownOldStates() async throws {
        let dir = try directory()
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: dir)
        let create = AlarmCreateExecutor(nativeStore: native, ownershipStore: ownership, usageDescriptionAvailable: { true })
        let created = try await create.execute(
            dispatch(actionType: "alarm.create", payload: typedFixedPayload(title: "原值"), key: "settings-not-started-create")
        )
        let alarmID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created.output["alarm_id"]?.stringValue)))
        let nativeBeforeNotStarted = try await native.alarms()
        let nativeRecord = try XCTUnwrap(nativeBeforeNotStarted.first(where: { $0.id == alarmID }))
        let desired = AlarmDesiredSchedule.weekly(hour: 9, minute: 0, weekdays: [.monday])
        _ = try await ownership.beginSettingsMutation(
            alarmID: alarmID, mutationID: "settings.update.not-started", operation: .update,
            beforeNativeState: nativeRecord.state, requestedTitle: "新值", requestedSchedule: desired, requestedSound: .defaultSound
        )
        // No native call: reopen must prove the old schedule is still authoritative.
        let reopened = try AlarmOwnershipStore(directoryURL: dir)
        let result = try await AlarmSettingsMutationReconciler.reconcile(
            alarmID: alarmID, nativeStore: native, ownershipStore: reopened
        )
        XCTAssertEqual(result, .definitelyNotStarted)
        let recordValue = await reopened.record(alarmID: alarmID)
        let record = try XCTUnwrap(recordValue)
        XCTAssertEqual(record.title, "原值")
        XCTAssertNil(record.pendingSettingsMutation)
        XCTAssertEqual(record.lastSettingsMutationOutcome?.resolution, .definitelyNotStarted)

        await native.setRecord(AlarmNativeRecord(id: alarmID, schedule: nativeRecord.schedule, state: .countdown))
        _ = try await reopened.beginSettingsMutation(
            alarmID: alarmID, mutationID: "settings.pause.not-started", operation: .pause, beforeNativeState: .countdown
        )
        let pauseNotStarted = try await AlarmSettingsMutationReconciler.reconcile(
            alarmID: alarmID, nativeStore: native, ownershipStore: reopened
        )
        XCTAssertEqual(pauseNotStarted, .definitelyNotStarted)
        await native.setRecord(AlarmNativeRecord(id: alarmID, schedule: nativeRecord.schedule, state: .paused))
        _ = try await reopened.beginSettingsMutation(
            alarmID: alarmID, mutationID: "settings.resume.not-started", operation: .resume, beforeNativeState: .paused
        )
        let resumeNotStarted = try await AlarmSettingsMutationReconciler.reconcile(
            alarmID: alarmID, nativeStore: native, ownershipStore: reopened
        )
        XCTAssertEqual(resumeNotStarted, .definitelyNotStarted)
        _ = try await reopened.beginSettingsMutation(
            alarmID: alarmID, mutationID: "settings.cancel.not-started", operation: .cancel, beforeNativeState: .paused
        )
        let cancelNotStarted = try await AlarmSettingsMutationReconciler.reconcile(
            alarmID: alarmID, nativeStore: native, ownershipStore: reopened
        )
        XCTAssertEqual(cancelNotStarted, .definitelyNotStarted)
    }

    @MainActor
    func testSettingsTitleOnlyUpdateCrashRemainsExplicitlyAmbiguous() async throws {
        let dir = try directory()
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: dir)
        let create = AlarmCreateExecutor(nativeStore: native, ownershipStore: ownership, usageDescriptionAvailable: { true })
        let created = try await create.execute(
            dispatch(actionType: "alarm.create", payload: typedFixedPayload(title: "旧标题"), key: "settings-ambiguous-create")
        )
        let alarmID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created.output["alarm_id"]?.stringValue)))
        let originValue = await ownership.record(alarmID: alarmID)
        let origin = try XCTUnwrap(originValue)
        let nativeBeforeAmbiguous = try await native.alarms()
        let currentNative = try XCTUnwrap(nativeBeforeAmbiguous.first(where: { $0.id == alarmID }))
        let mutationID = "settings.manual.update.title-only-crash"
        _ = try await ownership.beginSettingsMutation(
            alarmID: alarmID, mutationID: mutationID, operation: .update, beforeNativeState: currentNative.state,
            requestedTitle: "新标题", requestedSchedule: origin.schedule, requestedSound: .defaultSound
        )
        _ = try await native.schedule(
            AlarmNativeScheduleRequest(
                id: alarmID, title: "新标题", taskID: origin.taskID, actionID: mutationID,
                idempotencyKey: mutationID, schedule: origin.schedule, sound: .defaultSound
            )
        )
        // AlarmKit readback exposes id/schedule/state but not title/sound, so this crash is unknowable.
        let reopened = try AlarmOwnershipStore(directoryURL: dir)
        let model = AlarmManagementModel(nativeStore: native, ownershipStore: reopened)
        model.refresh()
        try await Task.sleep(for: .milliseconds(100))

        let unresolvedValue = await reopened.record(alarmID: alarmID)
        let unresolved = try XCTUnwrap(unresolvedValue)
        XCTAssertEqual(unresolved.title, "旧标题", "must not silently promote an unverified requested title")
        XCTAssertEqual(unresolved.pendingSettingsMutation?.mutationID, mutationID)
        XCTAssertEqual(unresolved.pendingSettingsMutation?.state, .ambiguous)
        XCTAssertEqual(unresolved.pendingSettingsMutation?.requestedTitle, "新标题")
        XCTAssertNil(unresolved.lastSettingsMutationOutcome)
        let modelAlarm = try XCTUnwrap(model.alarms.first)
        XCTAssertEqual(modelAlarm.mutationStatus?.operation, .update)
        XCTAssertEqual(modelAlarm.mutationStatus?.state, .ambiguous)
        XCTAssertTrue(modelAlarm.hasUnresolvedMutation)
        XCTAssertFalse(modelAlarm.canEdit)
        XCTAssertFalse(modelAlarm.canCancel)
    }

    @MainActor
    func testAlarmRingingUpdateChangesOnlyNativeAlarmTruthNotOriginTaskIdentity() async throws {
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let create = AlarmCreateExecutor(nativeStore: native, ownershipStore: ownership, usageDescriptionAvailable: { true })
        let created = try await create.execute(
            dispatch(
                actionType: "alarm.create",
                payload: typedFixedPayload(title: "响铃真相"),
                key: "ringing-origin-key",
                actionID: "ringing-origin-action"
            )
        )
        let alarmID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created.output["alarm_id"]?.stringValue)))
        let originValue = await ownership.record(alarmID: alarmID)
        let origin = try XCTUnwrap(originValue)
        let nativeBefore = try await native.alarms()
        let schedule = try XCTUnwrap(nativeBefore.first(where: { $0.id == alarmID })?.schedule)
        let model = AlarmManagementModel(nativeStore: native, ownershipStore: ownership)
        model.refresh()
        try await Task.sleep(for: .milliseconds(50))

        await native.setRecord(AlarmNativeRecord(id: alarmID, schedule: schedule, state: .alerting))
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(model.alarms.first?.state, .alerting)
        let afterValue = await ownership.record(alarmID: alarmID)
        let after = try XCTUnwrap(afterValue)
        XCTAssertEqual(after.taskID, origin.taskID)
        XCTAssertEqual(after.actionID, origin.actionID)
        XCTAssertEqual(after.idempotencyKey, origin.idempotencyKey)
        XCTAssertEqual(after.lifecycle, .accepted)
        XCTAssertEqual(after.lastNativeState, .alerting)
        let counts = await native.counts()
        XCTAssertEqual(counts.schedule, 1, "native alerting observation must never recreate/reschedule the old Task action")
        XCTAssertEqual(counts.cancel, 0)
        XCTAssertEqual(counts.pause, 0)
        XCTAssertEqual(counts.resume, 0)
    }

    @MainActor
    func testAlarmManagementModelChangesScheduledFixedAlarmToWeekly() async throws {
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let create = AlarmCreateExecutor(
            nativeStore: native,
            ownershipStore: ownership,
            usageDescriptionAvailable: { true }
        )
        let created = try await create.execute(
            dispatch(actionType: "alarm.create", payload: typedFixedPayload(), key: "settings-fixed-weekly-create")
        )
        let alarmID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created.output["alarm_id"]?.stringValue)))
        let model = AlarmManagementModel(nativeStore: native, ownershipStore: ownership)
        model.refresh()
        for _ in 0..<50 where model.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }

        let original = try XCTUnwrap(model.alarms.first(where: { $0.id == alarmID }))
        XCTAssertTrue(original.canEdit)
        let desired = AlarmDesiredSchedule.weekly(
            hour: 8,
            minute: 35,
            weekdays: [.monday, .wednesday, .friday]
        )
        model.update(original, title: "每周提醒", schedule: desired, sound: .defaultSound)
        for _ in 0..<80 where model.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertNil(model.errorMessage)
        let updated = try XCTUnwrap(model.alarms.first(where: { $0.id == alarmID }))
        XCTAssertEqual(updated.title, "每周提醒")
        XCTAssertTrue(updated.schedule.isSemanticallyEquivalent(to: desired))
        XCTAssertEqual(updated.state, .scheduled)
        XCTAssertTrue(updated.canEdit)
        let nativeRecords = try await native.alarms()
        let nativeReadback = try XCTUnwrap(nativeRecords.first(where: { $0.id == alarmID }))
        XCTAssertTrue(desired.matches(nativeReadback.schedule))
    }

    @MainActor
    func testAlarmManagementCanForgetMissingOwnedRecordWithoutNativeCancel() async throws {
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let create = AlarmCreateExecutor(
            nativeStore: native,
            ownershipStore: ownership,
            usageDescriptionAvailable: { true }
        )
        let created = try await create.execute(
            dispatch(actionType: "alarm.create", payload: typedFixedPayload(), key: "settings-missing-delete-create")
        )
        let alarmID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created.output["alarm_id"]?.stringValue)))
        await native.remove(id: alarmID)

        let model = AlarmManagementModel(nativeStore: native, ownershipStore: ownership)
        model.refresh()
        for _ in 0..<50 where model.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }

        let missing = try XCTUnwrap(model.alarms.first(where: { $0.id == alarmID }))
        XCTAssertFalse(missing.nativePresent)
        XCTAssertEqual(missing.lifecycle, .missing)
        XCTAssertEqual(missing.stateLabel, "已从系统移除")
        XCTAssertFalse(missing.canEdit)
        XCTAssertTrue(missing.canDeleteFromManagement)

        model.deleteFromManagement(missing)
        for _ in 0..<50 where model.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(model.alarms.isEmpty)
        let remainingOwnership = await ownership.record(alarmID: alarmID)
        XCTAssertNil(remainingOwnership)
        let counts = await native.counts()
        XCTAssertEqual(counts.schedule, 1)
        XCTAssertEqual(counts.cancel, 0, "forgetting an already-missing row must not issue another native cancel")
    }

    @MainActor
    func testAlarmManagementModelRefreshesFromAlarmUpdates() async throws {
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let create = AlarmCreateExecutor(nativeStore: native, ownershipStore: ownership, usageDescriptionAvailable: { true })
        let created = try await create.execute(dispatch(actionType: "alarm.create", payload: typedFixedPayload(), key: "model-updates-create"))
        let alarmID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created.output["alarm_id"]?.stringValue)))
        let model = AlarmManagementModel(nativeStore: native, ownershipStore: ownership)
        model.refresh()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.alarms.first?.id, alarmID)
        XCTAssertEqual(model.alarms.first?.state, .scheduled)

        let nativeRecordsForModel = try await native.alarms()
        let schedule = try XCTUnwrap(nativeRecordsForModel.first(where: { $0.id == alarmID })?.schedule)
        await native.setRecord(AlarmNativeRecord(id: alarmID, schedule: schedule, state: .countdown))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.alarms.first?.state, .countdown)
        XCTAssertTrue(model.alarms.first?.canPause == true)
    }

    func testDeviceWorkerSurfaceExposesCompleteAlarmManagementSet() async throws {
        let native = FakeAlarmNativeStore()
        let ownership = try AlarmOwnershipStore(directoryURL: try directory())
        let journal = try DeviceActionJournal(directoryURL: try directory())
        let worker = DeviceRuntimeWorker(
            journal: journal,
            executors: [
                AlarmQueryExecutor(nativeStore: native, ownershipStore: ownership),
                AlarmCreateExecutor(nativeStore: native, ownershipStore: ownership, usageDescriptionAvailable: { true }),
                AlarmUpdateExecutor(nativeStore: native, ownershipStore: ownership),
                AlarmPauseExecutor(nativeStore: native, ownershipStore: ownership),
                AlarmResumeExecutor(nativeStore: native, ownershipStore: ownership),
                AlarmCancelExecutor(nativeStore: native, ownershipStore: ownership),
                AlarmReadExecutor(nativeStore: native, ownershipStore: ownership),
            ]
        )
        for capability in ["alarm.query", "alarm.create", "alarm.update", "alarm.pause", "alarm.resume", "alarm.cancel", "alarm.read"] {
            let supported = await worker.supportsCapability(capability)
            XCTAssertTrue(supported, capability)
        }
    }

}


extension AlarmExecutorsTests {
    private func replacementFixture() async throws -> (FakeAlarmNativeStore, AlarmOwnershipStore, DeviceActionDispatch, UUID, URL) {
        let dir = try directory()
        let native = FakeAlarmNativeStore()
        await native.setRejectExistingSchedule(true)
        let store = try AlarmOwnershipStore(directoryURL: dir)
        let result = try await AlarmCreateExecutor(nativeStore: native, ownershipStore: store, usageDescriptionAvailable: { true })
            .execute(dispatch(actionType: "alarm.create", payload: weeklyPayload(), key: UUID().uuidString))
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(result.output["alarm_id"]?.stringValue)))
        let update = dispatch(actionType: "alarm.update",
            payload: updatePayload(alarmID: id, title: "更新后的闹钟", hour: 9, minute: 5, weekdays: ["tuesday"]),
            key: UUID().uuidString, actionID: UUID().uuidString)
        return (native, store, update, id, dir)
    }

    private func persistReplacement(_ request: DeviceActionDispatch, id: UUID,
                                    store: AlarmOwnershipStore, phase: AlarmReplacementPhase) async throws {
        let args = try XCTUnwrap(AlarmUpdateArguments.parse(request.payload))
        _ = try await store.beginSettingsMutation(alarmID: id, mutationID: request.actionID, operation: .update,
            beforeNativeState: .scheduled, requestedTitle: args.title,
            requestedSchedule: args.schedule, requestedSound: args.sound)
        _ = try await store.advanceReplacement(alarmID: id, mutationID: request.actionID, phase: phase)
    }

    func testUpdateCancelsAndVerifiesAbsenceBeforeSchedulingSameNativeID() async throws {
        let (native, store, request, id, _) = try await replacementFixture()
        let result = try await AlarmUpdateExecutor(nativeStore: native, ownershipStore: store).execute(request)
        XCTAssertTrue(result.success)
        let counts = await native.counts()
        XCTAssertEqual(counts.cancel, 1)
        XCTAssertEqual(counts.schedule, 2)
        let owner = await store.record(alarmID: id)
        XCTAssertEqual(owner?.schedule.hour, 9)
        XCTAssertNil(owner?.pendingSettingsMutation)
        XCTAssertEqual(owner?.lastSettingsMutationOutcome?.resolution, .completed)
    }

    func testReplacementScheduleFailureRestoresOldAlarmAndReportsFailure() async throws {
        let (native, store, request, id, _) = try await replacementFixture()
        await native.failNextSchedule(.nativeFailure("injected_configuration_failure"))
        let result = try await AlarmUpdateExecutor(nativeStore: native, ownershipStore: store).execute(request)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.output["original_restored"]?.boolValue, true)
        let owner = await store.record(alarmID: id)
        XCTAssertEqual(owner?.schedule.hour, 7)
        XCTAssertEqual(owner?.lifecycle, .accepted)
        XCTAssertNil(owner?.pendingSettingsMutation)
        XCTAssertEqual(owner?.lastSettingsMutationOutcome?.resolution, .failed)
        let records = try await native.alarms()
        XCTAssertTrue(owner?.schedule.matches(records.first?.schedule) == true)
    }

    func testReplacementCrashAfterOldRemovalResumesWithoutLyingNotStarted() async throws {
        let (native, store, request, id, dir) = try await replacementFixture()
        try await persistReplacement(request, id: id, store: store, phase: .schedulingReplacement)
        await native.remove(id: id)
        let reopened = try AlarmOwnershipStore(directoryURL: dir)
        let executor = AlarmUpdateExecutor(nativeStore: native, ownershipStore: reopened)
        let recovery = try await executor.reconcile(request, journalEntry: journalEntry(request))
        XCTAssertEqual(recovery, .resumeAuthorizedOperation)
        let before = await native.counts()
        XCTAssertEqual(before.schedule, 1, "Read-only reconciliation cannot schedule")
        let result = try await executor.execute(request)
        XCTAssertTrue(result.success)
        let after = await native.counts()
        XCTAssertEqual(after.schedule, 2)
        XCTAssertEqual(after.cancel, 0, "Already-absent original is not cancelled twice")
    }

    func testStoppingPartialReplacementDoesNotRecreateAnyAlarm() async throws {
        let (native, store, original, id, _) = try await replacementFixture()
        try await persistReplacement(original, id: id, store: store, phase: .schedulingReplacement)
        await native.remove(id: id)
        var stopped = original
        stopped.reconciliationOnly = true
        let outcome = try await AlarmUpdateExecutor(nativeStore: native, ownershipStore: store)
            .reconcile(stopped, journalEntry: journalEntry(stopped))
        guard case let .completed(result) = outcome else { return XCTFail("Stopped partial update must settle, not resume") }
        XCTAssertFalse(result.success)
        let counts = await native.counts()
        XCTAssertEqual(counts.schedule, 1)
        let owner = await store.record(alarmID: id)
        XCTAssertNil(owner?.pendingSettingsMutation)
        XCTAssertEqual(owner?.lifecycle, .missing)
    }

    func testTrustedManualCancellationSettlesLegacyUpdateWithoutResurrection() async throws {
        let (native, store, original, id, _) = try await replacementFixture()
        let entry = journalEntry(original)
        let cancelledAt = entry.createdAt.addingTimeInterval(1)
        _ = try await store.beginSettingsMutation(alarmID: id, mutationID: "settings.manual.cancel.test",
                                                 operation: .cancel, beforeNativeState: .scheduled)
        try await native.cancel(id: id)
        _ = try await store.completeSettingsCancel(alarmID: id, mutationID: "settings.manual.cancel.test", now: cancelledAt)
        var stopped = original
        stopped.reconciliationOnly = true
        let outcome = try await AlarmUpdateExecutor(nativeStore: native, ownershipStore: store).reconcile(stopped, journalEntry: entry)
        guard case let .completed(result) = outcome else { return XCTFail("Trusted exact cancellation must settle") }
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.output["native_absence_verified"]?.boolValue, true)
        XCTAssertEqual(result.output["error_code"]?.stringValue, "alarm_update_superseded_by_cancel")
        let counts = await native.counts()
        XCTAssertEqual(counts.schedule, 1)
    }

    func testMissingNativeWithoutTrustedCancellationReceiptRemainsUnknown() async throws {
        let (native, store, request, id, _) = try await replacementFixture()
        await native.remove(id: id)
        let outcome = try await AlarmUpdateExecutor(nativeStore: native, ownershipStore: store)
            .reconcile(request, journalEntry: journalEntry(request))
        guard case .stillUnknown = outcome else { return XCTFail("Absence alone cannot prove no earlier effect") }
        let counts = await native.counts()
        XCTAssertEqual(counts.schedule, 1)
    }

    func testRollbackPhaseSurvivesRelaunchAndRestoresOriginalOnly() async throws {
        let (native, store, request, id, dir) = try await replacementFixture()
        try await persistReplacement(request, id: id, store: store, phase: .restoringOriginal)
        await native.remove(id: id)
        let reopened = try AlarmOwnershipStore(directoryURL: dir)
        let executor = AlarmUpdateExecutor(nativeStore: native, ownershipStore: reopened)
        let outcome = try await executor.reconcile(request, journalEntry: journalEntry(request))
        XCTAssertEqual(outcome, .resumeAuthorizedOperation)
        let result = try await executor.execute(request)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.output["original_restored"]?.boolValue, true)
        let owner = await reopened.record(alarmID: id)
        XCTAssertEqual(owner?.schedule.hour, 7)
        XCTAssertNil(owner?.pendingSettingsMutation)
    }

    func testNativeExecutionRetryCountPersistsAndMutationWriteFailureIsTransactional() async throws {
        let dir = try directory()
        let journal = try DeviceActionJournal(directoryURL: dir)
        let request = dispatch(actionType: "device.probe", payload: [:])
        _ = try await journal.prepare(request)
        _ = try await journal.markMayHaveStarted(attemptID: request.attemptID)
        _ = try await journal.markDefinitelyNotStarted(attemptID: request.attemptID)
        _ = try await journal.markMayHaveStarted(attemptID: request.attemptID)
        let reopened = try DeviceActionJournal(directoryURL: dir)
        let persisted = await reopened.entry(attemptID: request.attemptID)
        XCTAssertEqual(persisted?.executionCount, 2)
        let url = dir.appendingPathComponent("device-action-journal.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        do {
            _ = try await reopened.markDefinitelyNotStarted(attemptID: request.attemptID)
            XCTFail("Expected persistence failure")
        } catch {}
        let after = await reopened.entry(attemptID: request.attemptID)
        XCTAssertEqual(after?.state, .mayHaveStarted)
        XCTAssertEqual(after?.executionCount, 2)
    }
}
