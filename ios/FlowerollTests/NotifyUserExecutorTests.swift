import XCTest
@testable import Floweroll


private actor FakeLocalNotificationClient: LocalNotificationClient {
    private var status: NotifyUserAuthorizationState
    private var added: [NotifyUserSystemRequest] = []
    private var records: [String: NotifyUserSystemRecord] = [:]
    private let recordOnAdd: Bool

    init(
        status: NotifyUserAuthorizationState = .authorized,
        recordOnAdd: Bool = true
    ) {
        self.status = status
        self.recordOnAdd = recordOnAdd
    }

    func authorizationStatus() async -> NotifyUserAuthorizationState { status }

    func add(_ request: NotifyUserSystemRequest) async throws {
        added.append(request)
        if recordOnAdd {
            records[request.notificationID] = NotifyUserSystemRecord(
                notificationID: request.notificationID,
                taskID: request.taskID,
                actionID: request.actionID,
                presentationState: .pending
            )
        }
    }

    func read(notificationID: String) async -> NotifyUserSystemRecord? {
        records[notificationID]
    }

    func setAuthorization(_ value: NotifyUserAuthorizationState) {
        status = value
    }

    func setRecord(_ value: NotifyUserSystemRecord?) {
        if let value {
            records[value.notificationID] = value
        }
    }

    func addCount() -> Int { added.count }
    func requests() -> [NotifyUserSystemRequest] { added }
}


final class NotifyUserExecutorTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    private func directory(_ label: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notify-user-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func dispatch(
        taskID: String = UUID().uuidString,
        actionID: String = UUID().uuidString,
        idempotencyKey: String = UUID().uuidString,
        payload: [String: JSONValue]? = nil,
        onVerified: String? = "COMPLETE"
    ) -> DeviceActionDispatch {
        var value = DeviceActionDispatch(
            actionID: actionID,
            taskID: taskID,
            actionType: "notify.user",
            payload: payload ?? [
                "title": .string("需要你确认"),
                "body": .string("候选已经准备好，请回来选择。"),
                "attention_level": .string("USER_REQUIRED"),
            ],
            status: "dispatched",
            runtimeActionStatus: "executing",
            idempotencyKey: idempotencyKey,
            attemptID: UUID().uuidString,
            attemptNumber: 1,
            attemptStatus: "IN_FLIGHT",
            dispatchDigest: UUID().uuidString
        )
        value.onVerified = onVerified
        return value
    }

    private func journalEntry(for dispatch: DeviceActionDispatch) -> DeviceActionJournalEntry {
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
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private func string(_ result: DeviceExecutionResult, _ key: String) -> String? {
        result.output[key]?.stringValue
    }

    private func bool(_ result: DeviceExecutionResult, _ key: String) -> Bool? {
        result.output[key]?.boolValue
    }

    private func assertAddCount(
        _ expected: Int,
        client: FakeLocalNotificationClient,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let actual = await client.addCount()
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    func testNotificationIDMatchesHostCrossLanguageVector() {
        XCTAssertEqual(
            NotifyUserConstants.stableNotificationID(idempotencyKey: "notify-vector-1"), // gitleaks:allow -- public deterministic cross-language test vector
            "floweroll.notify.a3d9a18f914b430699394b54f94d7023"
        )
    }

    func testAuthorizationPreflightIsDeterministicAndNeverPrompts() async throws {
        for (status, expectedCode) in [
            (NotifyUserAuthorizationState.denied, "notifications_authorization_denied"),
            (.notDetermined, "notifications_authorization_not_determined"),
            (.provisional, "notifications_authorization_insufficient"),
            (.ephemeral, "notifications_authorization_insufficient"),
            (.unknown, "notifications_authorization_insufficient"),
        ] {
            let client = FakeLocalNotificationClient(status: status)
            let store = try NotifyUserAcceptanceStore(directoryURL: directory(status.rawValue))
            let executor = NotifyUserExecutor(client: client, acceptanceStore: store)
            let value = try await executor.preflight(dispatch())
            let failure = try XCTUnwrap(value)
            XCTAssertFalse(failure.success)
            XCTAssertEqual(failure.error, expectedCode)
            XCTAssertEqual(string(failure, "error_code"), expectedCode)
            await assertAddCount(0, client: client)
        }

        let authorizedClient = FakeLocalNotificationClient(status: .authorized)
        let authorizedStore = try NotifyUserAcceptanceStore(directoryURL: directory("authorized"))
        let authorizedExecutor = NotifyUserExecutor(
            client: authorizedClient,
            acceptanceStore: authorizedStore
        )
        let authorizedPreflight = try await authorizedExecutor.preflight(dispatch())
        XCTAssertNil(authorizedPreflight)
        await assertAddCount(0, client: authorizedClient)
    }

    func testUnavailableAcceptanceStoreFailsOnlyNotifyBeforeSystemBoundary() async throws {
        let client = FakeLocalNotificationClient()
        let executor = NotifyUserExecutor(client: client, acceptanceStore: nil)
        let value = try await executor.preflight(dispatch())
        let failure = try XCTUnwrap(value)
        XCTAssertFalse(failure.success)
        XCTAssertEqual(failure.error, "notify_user_acceptance_store_unavailable")
        XCTAssertEqual(string(failure, "error_code"), "notify_user_acceptance_store_unavailable")
        await assertAddCount(0, client: client)
    }

    func testInvalidArgumentsFailBeforeNotificationBoundary() async throws {
        let client = FakeLocalNotificationClient()
        let store = try NotifyUserAcceptanceStore(directoryURL: directory())
        let executor = NotifyUserExecutor(client: client, acceptanceStore: store)
        let request = dispatch(payload: [
            "title": .string("标题"),
            "body": .string("正文"),
            "attention_level": .string("CRITICAL"),
        ])
        let preflight = try await executor.preflight(request)
        let failure = try XCTUnwrap(preflight)
        XCTAssertFalse(failure.success)
        XCTAssertEqual(failure.error, "notify_user_invalid_arguments")
        await assertAddCount(0, client: client)
    }

    func testAuthorizedExecutionPersistsAcceptanceAndReturnsCorrelatedPendingReadback() async throws {
        let client = FakeLocalNotificationClient(recordOnAdd: true)
        let store = try NotifyUserAcceptanceStore(directoryURL: directory())
        let executor = NotifyUserExecutor(client: client, acceptanceStore: store)
        let request = dispatch(idempotencyKey: "notify-idempotency-1") // gitleaks:allow -- synthetic idempotency fixture, not an API credential

        let result = try await executor.execute(request)

        XCTAssertTrue(result.success)
        await assertAddCount(1, client: client)
        let notificationID = NotifyUserConstants.stableNotificationID(
            idempotencyKey: request.idempotencyKey
        )
        let receipt = await store.receipt(notificationID: notificationID)
        XCTAssertEqual(receipt?.taskID, request.taskID)
        XCTAssertEqual(receipt?.actionID, request.actionID)
        XCTAssertEqual(string(result, "notification_id"), notificationID)
        XCTAssertEqual(string(result, "task_id"), request.taskID)
        XCTAssertEqual(string(result, "action_id"), request.actionID)
        XCTAssertEqual(string(result, "authorization_status"), "authorized")
        XCTAssertEqual(string(result, "presentation_state"), "pending")
        XCTAssertEqual(string(result, "readback_source"), "pending")
        XCTAssertEqual(bool(result, "durable_acceptance_receipt"), true)
        XCTAssertEqual(bool(result, "correlation_verified"), true)
        XCTAssertEqual(bool(result, "reconciled"), false)
        XCTAssertEqual(bool(result, "duplicate_suppressed"), false)
    }

    func testAcceptanceWithoutImmediateSystemReadbackIsNotOverclaimedAsDelivered() async throws {
        let client = FakeLocalNotificationClient(recordOnAdd: false)
        let store = try NotifyUserAcceptanceStore(directoryURL: directory())
        let executor = NotifyUserExecutor(client: client, acceptanceStore: store)
        let result = try await executor.execute(dispatch(idempotencyKey: "unobserved"))

        XCTAssertTrue(result.success)
        XCTAssertEqual(string(result, "presentation_state"), "accepted_unobserved")
        XCTAssertEqual(string(result, "readback_source"), "acceptance_receipt")
        XCTAssertNil(result.output["human_read"])
    }

    func testSameActionIdempotencyIsSuppressedButTwoActionsInOneTaskRemainDistinct() async throws {
        let client = FakeLocalNotificationClient()
        let store = try NotifyUserAcceptanceStore(directoryURL: directory())
        let executor = NotifyUserExecutor(client: client, acceptanceStore: store)
        let taskID = UUID().uuidString
        let first = dispatch(
            taskID: taskID,
            actionID: UUID().uuidString,
            idempotencyKey: "same-action-key"
        )
        let replay = first
        let second = dispatch(
            taskID: taskID,
            actionID: UUID().uuidString,
            idempotencyKey: "different-action-key"
        )

        let firstResult = try await executor.execute(first)
        let replayResult = try await executor.execute(replay)
        let secondResult = try await executor.execute(second)

        XCTAssertTrue(firstResult.success)
        XCTAssertTrue(replayResult.success)
        XCTAssertTrue(secondResult.success)
        await assertAddCount(2, client: client)
        XCTAssertEqual(bool(replayResult, "duplicate_suppressed"), true)
        XCTAssertNotEqual(
            string(firstResult, "notification_id"),
            string(secondResult, "notification_id")
        )
        XCTAssertEqual(string(firstResult, "task_id"), string(secondResult, "task_id"))
        XCTAssertNotEqual(string(firstResult, "action_id"), string(secondResult, "action_id"))
    }

    func testReconcileUsesDurableReceiptWithoutResending() async throws {
        let client = FakeLocalNotificationClient(recordOnAdd: false)
        let store = try NotifyUserAcceptanceStore(directoryURL: directory())
        let executor = NotifyUserExecutor(client: client, acceptanceStore: store)
        let request = dispatch(idempotencyKey: "reconcile-receipt")
        _ = try await executor.execute(request)
        await assertAddCount(1, client: client)

        let reconciled = try await executor.reconcile(
            request,
            journalEntry: journalEntry(for: request)
        )
        guard case let .completed(result) = reconciled else {
            return XCTFail("durable acceptance receipt should reconcile as completed")
        }
        XCTAssertTrue(result.success)
        await assertAddCount(1, client: client)
        XCTAssertEqual(bool(result, "reconciled"), true)
        XCTAssertEqual(bool(result, "duplicate_suppressed"), true)
        XCTAssertEqual(string(result, "presentation_state"), "accepted_unobserved")
    }

    func testReconcileCanRecoverFromPendingOrDeliveredSystemReadbackWithoutReceipt() async throws {
        for state in [NotifyUserPresentationState.pending, .delivered] {
            let client = FakeLocalNotificationClient(recordOnAdd: false)
            let store = try NotifyUserAcceptanceStore(directoryURL: directory(state.rawValue))
            let executor = NotifyUserExecutor(client: client, acceptanceStore: store)
            let request = dispatch(idempotencyKey: "readback-\(state.rawValue)")
            let notificationID = NotifyUserConstants.stableNotificationID(
                idempotencyKey: request.idempotencyKey
            )
            await client.setRecord(
                NotifyUserSystemRecord(
                    notificationID: notificationID,
                    taskID: request.taskID,
                    actionID: request.actionID,
                    presentationState: state
                )
            )

            let reconciled = try await executor.reconcile(
                request,
                journalEntry: journalEntry(for: request)
            )
            guard case let .completed(result) = reconciled else {
                return XCTFail("system readback should reconstruct acceptance receipt")
            }
            XCTAssertTrue(result.success)
            XCTAssertEqual(string(result, "presentation_state"), state.rawValue)
            XCTAssertEqual(string(result, "readback_source"), state.rawValue)
            let reconstructed = await store.receipt(notificationID: notificationID)
            XCTAssertNotNil(reconstructed)
            await assertAddCount(0, client: client)
        }
    }

    func testReconcileWithoutReceiptOrSystemReadbackStaysUnknownAndDoesNotResend() async throws {
        let client = FakeLocalNotificationClient(recordOnAdd: false)
        let store = try NotifyUserAcceptanceStore(directoryURL: directory())
        let executor = NotifyUserExecutor(client: client, acceptanceStore: store)
        let request = dispatch(idempotencyKey: "unknown-after-boundary")

        let value = try await executor.reconcile(
            request,
            journalEntry: journalEntry(for: request)
        )
        guard case let .stillUnknown(reason) = value else {
            return XCTFail("absence after may-have-started must stay unknown")
        }
        XCTAssertEqual(reason, "notify_user_acceptance_not_observable")
        await assertAddCount(0, client: client)
    }

    func testAcceptanceStoreRejectsNotificationIdentityCollision() async throws {
        let store = try NotifyUserAcceptanceStore(directoryURL: directory())
        let first = NotifyUserAcceptanceReceipt(
            notificationID: "floweroll.notify.collision",
            taskID: UUID().uuidString,
            actionID: UUID().uuidString,
            idempotencyKey: "same-key",
            acceptedAt: Date()
        )
        try await store.record(first)
        let second = NotifyUserAcceptanceReceipt(
            notificationID: first.notificationID,
            taskID: first.taskID,
            actionID: UUID().uuidString,
            idempotencyKey: first.idempotencyKey,
            acceptedAt: Date()
        )
        do {
            try await store.record(second)
            XCTFail("identity collision must fail closed")
        } catch let error as NotifyUserAcceptanceStoreError {
            XCTAssertEqual(error, .identityConflict)
        }
    }

    func testOwnedTapRouteCarriesTaskAndActionAndRejectsUnownedOrMalformedPayload() throws {
        let taskID = UUID().uuidString
        let actionID = UUID().uuidString
        let notificationID = NotifyUserConstants.stableNotificationID(idempotencyKey: "route")
        let info: [AnyHashable: Any] = [
            "capability": "notify.user",
            "notification_id": notificationID,
            "task_id": taskID,
            "action_id": actionID,
        ]
        let route = try XCTUnwrap(
            NotifyUserRoute.parse(
                categoryIdentifier: NotifyUserConstants.categoryIdentifier,
                userInfo: info
            )
        )
        XCTAssertEqual(route.taskID, taskID)
        XCTAssertEqual(route.actionID, actionID)
        XCTAssertNil(
            NotifyUserRoute.parse(categoryIdentifier: "other.category", userInfo: info)
        )
        var malformed = info
        malformed["task_id"] = "not-a-task-uuid"
        XCTAssertNil(
            NotifyUserRoute.parse(
                categoryIdentifier: NotifyUserConstants.categoryIdentifier,
                userInfo: malformed
            )
        )
    }

    func testRouteStoreSurvivesColdLaunchUntilConsumed() throws {
        let suite = "NotifyUserRouteStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstStore = NotifyUserRouteStore(defaults: defaults)
        let route = NotifyUserRoute(
            taskID: UUID().uuidString,
            actionID: UUID().uuidString,
            notificationID: NotifyUserConstants.stableNotificationID(idempotencyKey: "cold-launch")
        )
        firstStore.record(route)

        let relaunchedStore = NotifyUserRouteStore(defaults: defaults)
        XCTAssertEqual(relaunchedStore.peek(), route)
        XCTAssertEqual(relaunchedStore.consume(), route)
        XCTAssertNil(relaunchedStore.peek())
    }

    func testDeviceRuntimeWorkerProductionSetIncludesNotifyUser() async throws {
        guard let worker = DeviceRuntimeWorker.shared else {
            return XCTFail("production DeviceRuntimeWorker should initialize")
        }
        let supportsNotify = await worker.supportsCapability("notify.user")
        XCTAssertTrue(supportsNotify)
    }

    func testOnlyAcceptedCompleteNotifySuppressesSeparateTerminalNotificationPolicy() async throws {
        let store = try NotifyUserAcceptanceStore(directoryURL: directory())
        let taskID = UUID().uuidString
        let before = await store.hasAcceptedTerminalNotification(taskID: taskID)
        XCTAssertFalse(before)

        var midTask = NotifyUserAcceptanceReceipt(
            notificationID: NotifyUserConstants.stableNotificationID(idempotencyKey: "mid-task"),
            taskID: taskID,
            actionID: UUID().uuidString,
            idempotencyKey: "mid-task",
            acceptedAt: Date()
        )
        midTask.completesTask = false
        try await store.record(midTask)
        let afterMidTask = await store.hasAcceptedTerminalNotification(taskID: taskID)
        XCTAssertFalse(afterMidTask)

        var terminal = NotifyUserAcceptanceReceipt(
            notificationID: NotifyUserConstants.stableNotificationID(idempotencyKey: "terminal-separation"),
            taskID: taskID,
            actionID: UUID().uuidString,
            idempotencyKey: "terminal-separation",
            acceptedAt: Date()
        )
        terminal.completesTask = true
        try await store.record(terminal)
        let afterTerminal = await store.hasAcceptedTerminalNotification(taskID: taskID)
        XCTAssertTrue(afterTerminal)
    }
}
