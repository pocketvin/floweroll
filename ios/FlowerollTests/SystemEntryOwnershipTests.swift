import CryptoKit
import Foundation
import XCTest
@testable import Floweroll


private final class SystemEntryViewSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var views: [HostTaskView]
    private var index = 0

    init(_ views: [HostTaskView]) {
        self.views = views
    }

    func next() -> HostTaskView {
        lock.lock()
        defer { lock.unlock() }
        precondition(!views.isEmpty)
        let view = views[min(index, views.count - 1)]
        index += 1
        return view
    }
}


private final class SystemEntryURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var handler: ((URLRequest) throws -> (Int, Data))?
    private static let lock = NSLock()

    static func install(_ newHandler: @escaping (URLRequest) throws -> (Int, Data)) {
        lock.lock()
        handler = newHandler
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    private static func currentHandler() -> ((URLRequest) throws -> (Int, Data))? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.currentHandler() else {
                throw URLError(.resourceUnavailable)
            }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}


private struct SystemEntryRecordedRequest {
    let request: URLRequest
    let body: Data?
}

private final class SystemEntryRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [SystemEntryRecordedRequest] = []

    func append(_ request: URLRequest) {
        let recorded = SystemEntryRecordedRequest(
            request: request,
            body: Self.readBody(from: request)
        )
        lock.lock()
        requests.append(recorded)
        lock.unlock()
    }

    func snapshot() -> [SystemEntryRecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else if count == 0 {
                return data
            } else {
                return nil
            }
        }
    }
}


private final class SystemEntryProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SystemEntryRuntimeProgressUpdate] = []

    func append(_ value: SystemEntryRuntimeProgressUpdate) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [SystemEntryRuntimeProgressUpdate] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}


final class SystemEntryOwnershipTests: XCTestCase {
    override func tearDown() {
        SystemEntryURLProtocol.reset()
        super.tearDown()
    }

    func testActionButtonUsesLongRunningIntentAsSystemExecutionOwner() throws {
        let sourceURL = try ProductSourceFiles.iosRoot()
            .appendingPathComponent("Floweroll/App/FlowerollIntents.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("struct CaptureHouTaskIntent: LongRunningIntent, CancellableIntent"))
        XCTAssertTrue(source.contains("performBackgroundTask"))
        XCTAssertTrue(source.contains("owner: .systemLongRunningIntent"))
        XCTAssertFalse(source.contains("BGContinuedProcessingTaskRequest"))
    }

    func testHomeUsesInAppAppIntentAndBGCPTExecutionOwner() throws {
        let appRoot = try ProductSourceFiles.iosRoot().appendingPathComponent("Floweroll/App")
        let home = try String(contentsOf: appRoot.appendingPathComponent("Home/HomeView.swift"), encoding: .utf8)
        let intents = try String(contentsOf: appRoot.appendingPathComponent("FlowerollIntents.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("Button(intent: homeInAppIntent)"))
        XCTAssertTrue(intents.contains("struct HomeHouTaskIntent: AppIntent"))
        XCTAssertFalse(intents.contains("struct HomeHouTaskIntent: LongRunningIntent"))
        XCTAssertTrue(intents.contains("beginUserInitiatedOutboxContinuation("))
        XCTAssertTrue(intents.contains("submitUserInitiatedContinuation("))
        XCTAssertTrue(intents.contains("executePreparedHomeInput("))
    }

    func testTaskScopedResumeSurfacesUseInAppAppIntentAndBGCPT() throws {
        let appRoot = try ProductSourceFiles.iosRoot().appendingPathComponent("Floweroll/App")
        let intents = try String(
            contentsOf: appRoot.appendingPathComponent("FlowerollIntents.swift"),
            encoding: .utf8
        )
        let taskDetail = try String(
            contentsOf: appRoot.appendingPathComponent("RuntimeClient/Presentation/RuntimeTaskDetailView.swift"),
            encoding: .utf8
        )
        let episodeCard = try String(
            contentsOf: appRoot.appendingPathComponent("RuntimeClient/Presentation/RuntimeEpisodeInteractionViews.swift"),
            encoding: .utf8
        )
        let homeEpisode = try String(
            contentsOf: appRoot.appendingPathComponent("Home/HomeThreadEpisodeView.swift"),
            encoding: .utf8
        )
        let threadDetail = try String(
            contentsOf: appRoot.appendingPathComponent("RuntimeClient/Presentation/RuntimeThreadDetailView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(intents.contains("struct TaskScopedHouIntent: AppIntent"))
        XCTAssertTrue(intents.contains("struct ThreadFollowUpHouIntent: AppIntent"))
        XCTAssertFalse(intents.contains("struct TaskScopedHouIntent: LongRunningIntent"))
        XCTAssertFalse(intents.contains("struct ThreadFollowUpHouIntent: LongRunningIntent"))
        XCTAssertTrue(intents.contains("performTaskScopedOperation("))
        XCTAssertTrue(intents.contains("submitInAppFollowUp("))
        XCTAssertTrue(intents.contains("submitUserInitiatedContinuation("))

        XCTAssertTrue(taskDetail.contains("TaskScopedHouIntent.userTurn("))
        XCTAssertTrue(taskDetail.contains("TaskScopedHouIntent.clarificationOption("))
        XCTAssertTrue(taskDetail.contains("TaskScopedHouIntent.actionInput("))
        XCTAssertTrue(episodeCard.contains("TaskScopedHouIntent.clarificationOption("))
        XCTAssertTrue(episodeCard.contains("TaskScopedHouIntent.actionInput("))
        XCTAssertTrue(homeEpisode.contains("TaskScopedHouIntent.clarificationOption("))
        XCTAssertTrue(homeEpisode.contains("TaskScopedHouIntent.actionInput("))
        XCTAssertTrue(threadDetail.contains("TaskScopedHouIntent.userTurn("))
        XCTAssertTrue(threadDetail.contains("ThreadFollowUpHouIntent("))
    }

    @MainActor
    func testTaskScopedUserTurnKeepsExactEventIDThroughPersistFirstOutbox() async throws {
        let suite = "SystemEntryOwnershipTests.task-scoped-turn.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floweroll-task-scoped-turn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pendingStore = try PendingSubmissionStore(directoryURL: directory)
        let recorder = SystemEntryRequestRecorder()
        SystemEntryURLProtocol.install { request in
            recorder.append(request)
            return (202, Data("{}".utf8))
        }

        let coordinator = SystemEntryRuntimeCoordinator(
            defaults: defaults,
            pendingStore: pendingStore,
            deviceWorker: nil,
            session: Self.session()
        )
        try await coordinator.performTaskScopedOperation(
            taskID: "task-scoped",
            eventID: "event-scoped-123",
            operation: .userTurn(text: "继续整理这份材料")
        )

        let recorded = try XCTUnwrap(recorder.snapshot().first(where: {
            $0.request.url?.path == "/v1/tasks/task-scoped/turns"
        }))
        let body = try XCTUnwrap(recorded.body)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["event_id"] as? String, "event-scoped-123")
        let content = try XCTUnwrap(json["content"] as? [String: Any])
        XCTAssertEqual(content["text"] as? String, "继续整理这份材料")
        let pendingAfterAck = await pendingStore.pendingUserTurns()
        XCTAssertTrue(pendingAfterAck.isEmpty)
    }

    @MainActor
    func testExistingSystemOwnerAttachmentTurnIsAdmittedBeforeHomeSendReturns() async throws {
        let suite = "SystemEntryOwnershipTests.existing-owner-attachment-turn.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floweroll-existing-owner-attachment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pendingStore = try PendingSubmissionStore(directoryURL: directory)

        let bytes = Data("existing-owner-attachment-turn".utf8)
        let attachmentID = "existingowner" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let storedName = attachmentID + ".txt"
        let sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let attachment = PendingAttachment(
            id: attachmentID,
            name: "补充材料.txt",
            mediaType: "text/plain",
            sizeBytes: bytes.count,
            sha256: sha256,
            storedName: storedName
        )
        let durableURL = try attachment.fileURL()
        let cacheURL = try attachment.acceptedCacheURL()
        try bytes.write(to: durableURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: durableURL)
            try? FileManager.default.removeItem(at: cacheURL)
        }

        let receipt = TaskMaterialFile(
            id: attachment.id,
            name: attachment.name,
            mediaType: attachment.mediaType,
            sizeBytes: attachment.sizeBytes,
            sha256: attachment.sha256,
            category: "input",
            metadata: [:]
        )
        let recorder = SystemEntryRequestRecorder()
        SystemEntryURLProtocol.install { request in
            recorder.append(request)
            if request.httpMethod == "GET",
               request.url?.path == "/v1/files/\(attachment.id)" {
                return (200, try JSONEncoder.floweroll.encode(receipt))
            }
            if request.httpMethod == "POST",
               request.url?.path == "/v1/tasks/task-active/turns" {
                return (202, Data("{}".utf8))
            }
            return (404, Data())
        }

        let coordinator = SystemEntryRuntimeCoordinator(
            defaults: defaults,
            pendingStore: pendingStore,
            deviceWorker: nil,
            session: Self.session()
        )
        let prepared = SystemEntryPreparedHomeInput(
            normalizedText: "补充这份材料",
            target: .currentTask(
                taskID: "task-active",
                threadID: "thread-active",
                operation: .userTurn(text: "补充这份材料")
            )
        )
        let route = try await coordinator.enqueuePreparedHomeInputWithoutNewExecutionWindow(
            prepared,
            submissionID: "event-existing-owner-attachment",
            attachments: [attachment]
        )

        XCTAssertEqual(route.taskID, "task-active")
        XCTAssertEqual(route.kind, .userTurn)
        XCTAssertFalse(route.ownsExecutionWindow)
        let pendingAfterReturn = await pendingStore.pendingUserTurns()
        XCTAssertTrue(
            pendingAfterReturn.isEmpty,
            "Home Send must not return while the exact durable turn is still waiting for a later recovery window"
        )

        let turnRequest = try XCTUnwrap(recorder.snapshot().first(where: {
            $0.request.httpMethod == "POST" && $0.request.url?.path == "/v1/tasks/task-active/turns"
        }))
        let body = try XCTUnwrap(turnRequest.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["event_id"] as? String, "event-existing-owner-attachment")
        let content = try XCTUnwrap(json["content"] as? [String: Any])
        XCTAssertEqual(content["text"] as? String, "补充这份材料")
        XCTAssertEqual(content["attachment_ids"] as? [String], [attachment.id])
    }

    @MainActor
    func testExistingSystemOwnerAttachmentFailureKeepsExactPendingTurnForRecovery() async throws {
        let suite = "SystemEntryOwnershipTests.existing-owner-attachment-failure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floweroll-existing-owner-attachment-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pendingStore = try PendingSubmissionStore(directoryURL: directory)

        let bytes = Data("existing-owner-recovery".utf8)
        let attachmentID = "existingfailure" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let attachment = PendingAttachment(
            id: attachmentID,
            name: "待恢复材料.txt",
            mediaType: "text/plain",
            sizeBytes: bytes.count,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            storedName: attachmentID + ".txt"
        )
        let durableURL = try attachment.fileURL()
        try bytes.write(to: durableURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: durableURL) }

        SystemEntryURLProtocol.install { _ in
            throw URLError(.notConnectedToInternet)
        }
        let coordinator = SystemEntryRuntimeCoordinator(
            defaults: defaults,
            pendingStore: pendingStore,
            deviceWorker: nil,
            session: Self.session()
        )
        let prepared = SystemEntryPreparedHomeInput(
            normalizedText: "网络断了也保留这条补充",
            target: .currentTask(
                taskID: "task-active-failure",
                threadID: "thread-active-failure",
                operation: .userTurn(text: "网络断了也保留这条补充")
            )
        )

        do {
            _ = try await coordinator.enqueuePreparedHomeInputWithoutNewExecutionWindow(
                prepared,
                submissionID: "event-existing-owner-failure",
                attachments: [attachment]
            )
            XCTFail("network failure must surface to the current send")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }

        let pending = await pendingStore.pendingUserTurns()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.eventID, "event-existing-owner-failure")
        XCTAssertEqual(pending.first?.taskID, "task-active-failure")
        XCTAssertEqual(pending.first?.attachments, [attachment])
    }

    @MainActor
    func testThreadFollowUpKeepsSubmissionAndParentIdentity() async throws {
        let suite = "SystemEntryOwnershipTests.thread-follow-up.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floweroll-thread-follow-up-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pendingStore = try PendingSubmissionStore(directoryURL: directory)
        let recorder = SystemEntryRequestRecorder()
        let acceptedTask = HostTask(
            taskID: "task-follow-up",
            submissionID: "follow-up-123",
            threadID: "thread-parent",
            parentTaskID: "task-parent",
            goal: "继续整理下一轮",
            status: "active",
            currentStep: 0,
            idempotentReplay: false,
            createdAt: "2026-09-16T01:00:00Z",
            updatedAt: "2026-09-16T01:00:00Z"
        )
        SystemEntryURLProtocol.install { request in
            recorder.append(request)
            if request.url?.path == "/v1/tasks" {
                return (201, try JSONEncoder.floweroll.encode(acceptedTask))
            }
            return (404, Data())
        }

        let coordinator = SystemEntryRuntimeCoordinator(
            defaults: defaults,
            pendingStore: pendingStore,
            deviceWorker: nil,
            session: Self.session()
        )
        let task = try await coordinator.submitInAppFollowUp(
            parentTaskID: "task-parent",
            text: "继续整理下一轮",
            submissionID: "follow-up-123"
        )
        XCTAssertEqual(task, acceptedTask)

        let recorded = try XCTUnwrap(recorder.snapshot().first(where: {
            $0.request.url?.path == "/v1/tasks" && $0.request.httpMethod == "POST"
        }))
        let body = try XCTUnwrap(recorded.body)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["submission_id"] as? String, "follow-up-123")
        XCTAssertEqual(json["parent_task_id"] as? String, "task-parent")
        XCTAssertEqual(json["invocation_source"] as? String, "ios_thread_in_app")
        let pendingAfterAck = await pendingStore.pending()
        XCTAssertTrue(pendingAfterAck.isEmpty)

    }

    func testProductionControllerSplitsInAppBGCPTFromDurableRecoveryTracking() throws {
        let appRoot = try ProductSourceFiles.iosRoot().appendingPathComponent("Floweroll/App")
        let controller = try String(
            contentsOf: appRoot.appendingPathComponent("RuntimeClient/DeviceBackgroundExecutionController.swift"),
            encoding: .utf8
        )
        let info = try String(contentsOf: appRoot.appendingPathComponent("Info.plist"), encoding: .utf8)
        XCTAssertTrue(controller.contains("BGContinuedProcessingTaskRequest"))
        XCTAssertTrue(controller.contains("BGContinuedProcessingTask"))
        XCTAssertTrue(controller.contains("registerGlobalHandler"))
        XCTAssertTrue(controller.contains("handleGlobal("))
        XCTAssertTrue(controller.contains("trackedTaskIDsKey"))
        XCTAssertTrue(controller.contains("continuedTaskIDsKey"))
        XCTAssertTrue(controller.contains("continuedOutboxIDsKey"))
        XCTAssertTrue(controller.contains("runInAppContinuedPass()"))
        XCTAssertTrue(controller.contains("for taskID in continuedTaskIDs()"))
        XCTAssertTrue(controller.contains("handoffInAppTaskToSystemLongRunning"))
        XCTAssertTrue(controller.contains("untrackContinuedTask(normalized)"))
        XCTAssertTrue(controller.contains("global_handler_expired_completed_successfully"))
        XCTAssertTrue(controller.contains("backgroundTask.setTaskCompleted(success: true)"))
        XCTAssertTrue(info.contains("com.maxenceyu.floweroll.runtime.continued.*"))
        XCTAssertTrue(info.contains("com.maxenceyu.floweroll.runtime.recovery"))
    }

    func testOrphanedContinuedTaskTrackingIsRemovedWithoutTouchingTrackedTasks() {
        XCTAssertEqual(
            ContinuedTaskTrackingReconciliationPolicy.orphanedContinuedTaskIDs(
                trackedTaskIDs: ["active", "tracked-only"],
                continuedTaskIDs: ["active", "stale-terminal"]
            ),
            ["stale-terminal"]
        )
    }

    func testPersistFirstInAppSendRequestsBGCPTBeforeSlowWork() throws {
        let appRoot = try ProductSourceFiles.iosRoot().appendingPathComponent("Floweroll/App")
        let store = try String(
            contentsOf: appRoot.appendingPathComponent("RuntimeClient/RuntimeTaskStore.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: appRoot.appendingPathComponent("RuntimeClient/DeviceBackgroundExecutionController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(store.contains("beginUserInitiatedOutboxContinuation("))
        XCTAssertTrue(store.contains("finishUserInitiatedOutboxContinuation("))
        XCTAssertTrue(store.contains("submitUserInitiatedContinuation(taskID: taskID, goal: goal)"))
        XCTAssertTrue(controller.contains("UIApplication.shared.beginBackgroundTask("))
        XCTAssertTrue(controller.contains("BGContinuedProcessingTaskRequest("))
        XCTAssertTrue(controller.contains("BGProcessingTaskRequest(identifier: Self.recoveryIdentifier)"))
    }

    func testRecoveryRequestPolicyNeverReplacesAlreadyPendingOpportunity() {
        let identifier = "com.maxenceyu.floweroll.runtime.recovery"
        XCTAssertTrue(BackgroundRecoveryRequestPolicy.shouldSubmit(
            identifier: identifier,
            pendingIdentifiers: []
        ))
        XCTAssertFalse(BackgroundRecoveryRequestPolicy.shouldSubmit(
            identifier: identifier,
            pendingIdentifiers: [identifier]
        ))
    }

    func testBackgroundCompletionGateClaimsOnlyOnce() {
        let gate = BackgroundCompletionGate()
        XCTAssertTrue(gate.claim())
        XCTAssertFalse(gate.claim())
        XCTAssertFalse(gate.claim())
    }

    func testTaskScopedContinuationReservationIsReferenceCounted() {
        var ledger = TaskScopedContinuationReservationLedger()
        XCTAssertFalse(ledger.contains(taskID: "task-1"))

        ledger.reserve(taskID: "task-1")
        ledger.reserve(taskID: "task-1")
        XCTAssertTrue(ledger.contains(taskID: "task-1"))
        XCTAssertEqual(ledger.count(taskID: "task-1"), 2)

        XCTAssertEqual(ledger.release(taskID: "task-1"), 1)
        XCTAssertTrue(ledger.contains(taskID: "task-1"))
        XCTAssertEqual(ledger.release(taskID: "task-1"), 0)
        XCTAssertFalse(ledger.contains(taskID: "task-1"))
    }

    func testTaskScopedReservationOnlyHoldsStaleNeedsUserTruth() {
        XCTAssertTrue(ContinuedTaskStableStatePolicy.shouldHoldForTaskScopedMutation(
            state: RuntimeTaskStateDimensions(
                status: "waiting",
                hasRawPendingInteraction: true
            ),
            hasTaskScopedMutationReservation: true
        ))
        XCTAssertTrue(ContinuedTaskStableStatePolicy.shouldHoldForTaskScopedMutation(
            state: RuntimeTaskStateDimensions(status: "needs_user"),
            hasTaskScopedMutationReservation: true
        ))
        XCTAssertFalse(ContinuedTaskStableStatePolicy.shouldHoldForTaskScopedMutation(
            state: RuntimeTaskStateDimensions(
                status: "waiting",
                hasRawPendingInteraction: true
            ),
            hasTaskScopedMutationReservation: false
        ))
        XCTAssertFalse(ContinuedTaskStableStatePolicy.shouldHoldForTaskScopedMutation(
            state: RuntimeTaskStateDimensions(
                status: "completed",
                hasRawPendingInteraction: true
            ),
            hasTaskScopedMutationReservation: true
        ))
        XCTAssertFalse(ContinuedTaskStableStatePolicy.shouldHoldForTaskScopedMutation(
            state: RuntimeTaskStateDimensions(status: "active"),
            hasTaskScopedMutationReservation: true
        ))
    }

    func testActiveTaskKeepsExecutionOwnerWhileAnotherClarificationRemainsPending() {
        XCTAssertFalse(ContinuedTaskStableStatePolicy.shouldReleaseExecutionOwner(
            state: RuntimeTaskStateDimensions(
                status: "active",
                hasRawPendingInteraction: true
            )
        ))
        XCTAssertTrue(ContinuedTaskStableStatePolicy.shouldReleaseExecutionOwner(
            state: RuntimeTaskStateDimensions(
                status: "waiting",
                hasRawPendingInteraction: true
            )
        ))
        XCTAssertTrue(ContinuedTaskStableStatePolicy.shouldReleaseExecutionOwner(
            state: RuntimeTaskStateDimensions(status: "needs_user")
        ))
        XCTAssertTrue(ContinuedTaskStableStatePolicy.shouldReleaseExecutionOwner(
            state: RuntimeTaskStateDimensions(
                status: "blocked",
                hasRawPendingInteraction: true
            )
        ))
        XCTAssertTrue(ContinuedTaskStableStatePolicy.shouldReleaseExecutionOwner(
            state: RuntimeTaskStateDimensions(status: "blocked")
        ))
        XCTAssertFalse(ContinuedTaskStableStatePolicy.shouldReleaseExecutionOwner(
            state: RuntimeTaskStateDimensions(status: "active")
        ))
        XCTAssertFalse(ContinuedTaskStableStatePolicy.shouldReleaseExecutionOwner(
            state: RuntimeTaskStateDimensions(
                status: "completed",
                hasRawPendingInteraction: true
            )
        ))
    }

    func testTaskScopedIntentReservesBeforeBGCPTAndReleasesOnBothOutcomes() throws {
        let sourceURL = try ProductSourceFiles.iosRoot()
            .appendingPathComponent("Floweroll/App/FlowerollIntents.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let scope = try XCTUnwrap(source.range(of: "struct TaskScopedHouIntent: AppIntent"))
        let tail = String(source[scope.lowerBound...])
        let reserve = try XCTUnwrap(tail.range(of: "beginTaskScopedMutationReservation("))
        let bgcptBranch = String(tail[reserve.lowerBound...])
        let submit = try XCTUnwrap(bgcptBranch.range(of: "submitUserInitiatedContinuation("))
        let mutate = try XCTUnwrap(bgcptBranch.range(of: "performTaskScopedOperation("))
        let firstRelease = try XCTUnwrap(bgcptBranch.range(of: "endTaskScopedMutationReservation("))

        XCTAssertLessThan(submit.lowerBound, mutate.lowerBound)
        XCTAssertLessThan(mutate.lowerBound, firstRelease.lowerBound)
        XCTAssertEqual(bgcptBranch.components(separatedBy: "endTaskScopedMutationReservation(").count - 1, 2)
    }

    func testCustomActivityStartReusesOnlyMatchingTaskActivities() {
        XCTAssertEqual(
            FlowerollCustomActivityOwnershipPolicy.startDecision(matchingTaskActivityCount: 0),
            .requestNew
        )
        XCTAssertEqual(
            FlowerollCustomActivityOwnershipPolicy.startDecision(matchingTaskActivityCount: 1),
            .reuseMatchingTask(endDuplicateCount: 0)
        )
        XCTAssertEqual(
            FlowerollCustomActivityOwnershipPolicy.startDecision(matchingTaskActivityCount: 3),
            .reuseMatchingTask(endDuplicateCount: 2)
        )
    }

    func testPresentationLeaseRequiresExplicitReleaseBeforeOwnerMigration() async throws {
        let suite = "SystemEntryOwnershipTests.lease.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FlowerollPresentationLeaseStore(
            suiteName: suite,
            defaultsKey: "lease-state",
            processInstanceID: "process-a"
        )

        let firstValue = await store.acquire(taskID: "task-a", owner: .systemLongRunningIntent)
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(first.generation, 1)

        let reused = await store.acquire(taskID: "task-a", owner: .systemLongRunningIntent)
        XCTAssertEqual(reused, first)
        let overlapping = await store.acquire(taskID: "task-a", owner: .customActivityFallback)
        XCTAssertNil(overlapping)
        let released = await store.release(first)
        XCTAssertTrue(released)

        let secondValue = await store.acquire(taskID: "task-a", owner: .customActivityFallback)
        let second = try XCTUnwrap(secondValue)
        XCTAssertEqual(second.generation, 2)
        let staleReleased = await store.release(first)
        XCTAssertFalse(staleReleased)
        let current = await store.current(taskID: "task-a")
        XCTAssertEqual(current, second)
    }

    func testPresentationLeaseRelaunchReclaimsStaleLongRunningOwner() async throws {
        let suite = "SystemEntryOwnershipTests.relaunch.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstProcess = FlowerollPresentationLeaseStore(
            suiteName: suite,
            defaultsKey: "lease-state",
            processInstanceID: "process-a"
        )
        let firstValue = await firstProcess.acquire(taskID: "task-a", owner: .systemLongRunningIntent)
        let first = try XCTUnwrap(firstValue)

        let relaunched = FlowerollPresentationLeaseStore(
            suiteName: suite,
            defaultsKey: "lease-state",
            processInstanceID: "process-b"
        )
        let sameProcess = await relaunched.isCurrentProcess(first)
        XCTAssertFalse(sameProcess)
        let reclaimed = await relaunched.reclaimStale(
            taskID: "task-a",
            owners: [.systemLongRunningIntent]
        )
        XCTAssertEqual(reclaimed, first)
        let fallbackValue = await relaunched.acquire(taskID: "task-a", owner: .customActivityFallback)
        let fallback = try XCTUnwrap(fallbackValue)
        XCTAssertEqual(fallback.generation, 2)
    }

    func testRenewedLongRunningGenerationRejectsStaleRelease() async throws {
        let suite = "SystemEntryOwnershipTests.longrunning.\(UUID().uuidString)"
        let store = FlowerollPresentationLeaseStore(
            suiteName: suite,
            defaultsKey: "lease-state",
            processInstanceID: "process-a"
        )
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let firstValue = await store.acquire(taskID: "task-a", owner: .systemLongRunningIntent)
        let first = try XCTUnwrap(firstValue)
        let secondValue = await store.renew(taskID: "task-a", owner: .systemLongRunningIntent)
        let second = try XCTUnwrap(secondValue)
        XCTAssertEqual(first.generation, 1)
        XCTAssertEqual(second.generation, 2)
        let staleReleased = await store.release(first)
        XCTAssertFalse(staleReleased)
        let current = await store.current(taskID: "task-a")
        XCTAssertEqual(current, second)
        let released = await store.release(second)
        XCTAssertTrue(released)
    }

    func testSiblingFailureCannotTurnRemainingActiveTaskIntoFailedPresentation() {
        let failedSibling = Self.view(
            taskID: "task-failed",
            status: "failed",
            result: .object(["summary": .string("第一个任务失败")])
        )
        let activeRemaining = Self.view(
            taskID: "task-remaining",
            status: "active",
            activeTitle: "正在继续第二个任务"
        )
        let failedUpdate = SystemEntryRuntimeCoordinator.progressUpdate(from: failedSibling)
        let activeUpdate = SystemEntryRuntimeCoordinator.progressUpdate(from: activeRemaining)
        XCTAssertEqual(failedUpdate.completedUnitCount, failedUpdate.totalUnitCount)
        XCTAssertEqual(activeUpdate.title, "小卷正在处理")
        XCTAssertEqual(activeUpdate.subtitle, "正在继续第二个任务")
        XCTAssertLessThan(activeUpdate.completedUnitCount, activeUpdate.totalUnitCount)
    }

    func testTerminalReconciliationReleasesOnlyStaleLongRunningLease() async throws {
        let suite = "SystemEntryOwnershipTests.terminal-stale.\(UUID().uuidString)"
        let oldProcess = FlowerollPresentationLeaseStore(
            suiteName: suite,
            defaultsKey: "lease-state",
            processInstanceID: "process-a"
        )
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let staleValue = await oldProcess.acquire(taskID: "task-system", owner: .systemLongRunningIntent)
        let stale = try XCTUnwrap(staleValue)
        let relaunched = FlowerollPresentationLeaseStore(
            suiteName: suite,
            defaultsKey: "lease-state",
            processInstanceID: "process-b"
        )
        let reclaimed = await relaunched.reclaimStaleSystemForTerminal(taskID: "task-system")
        XCTAssertEqual(reclaimed, stale)
        let cleared = await relaunched.current(taskID: "task-system")
        XCTAssertNil(cleared)

        let currentValue = await relaunched.acquire(taskID: "task-current", owner: .systemLongRunningIntent)
        let current = try XCTUnwrap(currentValue)
        let currentReclaim = await relaunched.reclaimStaleSystemForTerminal(taskID: "task-current")
        XCTAssertNil(currentReclaim)
        let currentAfter = await relaunched.current(taskID: "task-current")
        XCTAssertEqual(currentAfter, current)
    }

    func testSystemTimeoutPreservesDurableTaskInsteadOfClaimingTaskFailure() async {
        let coordinator = SystemEntryRuntimeCoordinator(
            defaults: UserDefaults.standard,
            pendingStore: nil,
            deviceWorker: nil,
            session: Self.session()
        )
        let cancelled = await coordinator.handleSystemCancellation(
            taskID: "task-timeout",
            kind: .systemTimeout
        )
        XCTAssertFalse(cancelled)
    }

    func testSystemEntryKeepsLongRunningWhileInAppIntentsUseBGCPT() throws {
        let sourceURL = try ProductSourceFiles.iosRoot()
            .appendingPathComponent("Floweroll/App/FlowerollIntents.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("struct CaptureHouTaskIntent: LongRunningIntent, CancellableIntent"))
        XCTAssertTrue(source.contains("struct HomeHouTaskIntent: AppIntent"))
        XCTAssertTrue(source.contains("struct TaskScopedHouIntent: AppIntent"))
        XCTAssertTrue(source.contains("struct ThreadFollowUpHouIntent: AppIntent"))
        XCTAssertEqual(source.components(separatedBy: "performBackgroundTask").count - 1, 1)
        XCTAssertTrue(source.contains("intentProgress.completedUnitCount = update.completedUnitCount"))
        XCTAssertTrue(source.contains("reason == .timeout"))
        XCTAssertTrue(source.contains(".userCancelled"))
        XCTAssertTrue(source.contains("submitUserInitiatedContinuation("))
    }

    func testGlobalRoutingContractCannotFoldIndependentOrMixedInputIntoCurrentTask() throws {
        let appRoot = try ProductSourceFiles.iosRoot().appendingPathComponent("Floweroll/App")
        let policy = try String(
            contentsOf: appRoot.appendingPathComponent("RuntimeClient/Policies/GlobalInputRoutingPolicy.swift"),
            encoding: .utf8
        )
        let coordinator = try String(
            contentsOf: appRoot.appendingPathComponent("RuntimeClient/SystemEntryRuntimeCoordinator.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("Global Home / Action Button input is new-task-by-default"))
        XCTAssertTrue(policy.contains("private static func mixedRoute("))
        XCTAssertTrue(policy.contains("boundedNewTaskCarryover("))
        XCTAssertTrue(policy.contains("return .newTask"))

        XCTAssertTrue(coordinator.contains("system entry mixed route preserved both halves"))
        XCTAssertTrue(coordinator.contains("text: resolution.textForNewTask(fallback: normalized)"))
        XCTAssertTrue(coordinator.contains("handoffInAppTaskToSystemLongRunning("))
        XCTAssertFalse(coordinator.contains("system entry mixed route folded into current task"))
        XCTAssertFalse(coordinator.contains("system entry new-goal utterance folded into current task"))
    }

    func testGlobalDirectCancelUsesHostCancelInsteadOfUserTurn() throws {
        let sourceURL = try ProductSourceFiles.iosRoot()
            .appendingPathComponent("Floweroll/App/RuntimeClient/SystemEntryRuntimeCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("FlowerollDirectTaskControlPolicy.isCancelCommand(text)"))
        XCTAssertTrue(source.contains("reason: \"用户从全局输入明确取消当前任务\""))
        XCTAssertTrue(source.contains("reason: \"用户从首页明确取消当前任务\""))
        XCTAssertTrue(source.contains("client.cancelTask("))
    }

    func testInAppInputsJoinExistingSystemLongRunningOwnerBeforeStartingBGCPT() throws {
        let appRoot = try ProductSourceFiles.iosRoot().appendingPathComponent("Floweroll/App")
        let intents = try String(
            contentsOf: appRoot.appendingPathComponent("FlowerollIntents.swift"),
            encoding: .utf8
        )
        let coordinator = try String(
            contentsOf: appRoot.appendingPathComponent("RuntimeClient/SystemEntryRuntimeCoordinator.swift"),
            encoding: .utf8
        )

        let homeStart = try XCTUnwrap(intents.range(of: "struct HomeHouTaskIntent: AppIntent"))
        let taskScopedStart = try XCTUnwrap(
            intents.range(of: "struct TaskScopedHouIntent: AppIntent", range: homeStart.upperBound..<intents.endIndex)
        )
        let followUpStart = try XCTUnwrap(
            intents.range(of: "struct ThreadFollowUpHouIntent: AppIntent", range: taskScopedStart.upperBound..<intents.endIndex)
        )
        let homeScope = String(intents[homeStart.lowerBound..<taskScopedStart.lowerBound])
        let taskScopedScope = String(intents[taskScopedStart.lowerBound..<followUpStart.lowerBound])

        let homeJoin = try XCTUnwrap(homeScope.range(of: "hasActiveSystemExecution(taskID: taskID)"))
        let homeBGCPT = try XCTUnwrap(homeScope.range(of: "beginUserInitiatedOutboxContinuation("))
        XCTAssertLessThan(homeJoin.lowerBound, homeBGCPT.lowerBound)
        XCTAssertTrue(homeScope.contains("enqueuePreparedHomeInputWithoutNewExecutionWindow("))
        XCTAssertTrue(homeScope.contains("bgcpt-reacquired"))

        let scopedJoin = try XCTUnwrap(
            taskScopedScope.range(of: "hasActiveSystemExecution(taskID: normalizedTaskID)")
        )
        let scopedBGCPT = try XCTUnwrap(
            taskScopedScope.range(of: "beginTaskScopedMutationReservation(")
        )
        XCTAssertLessThan(scopedJoin.lowerBound, scopedBGCPT.lowerBound)
        XCTAssertTrue(taskScopedScope.contains("bgcpt-reacquired"))
        XCTAssertTrue(coordinator.contains("func hasActiveSystemExecution(taskID: String) -> Bool"))
    }

    func testSystemEntryTasksKeepRecoveryEligibilityWithoutJoiningBGCPT() throws {
        let sourceURL = try ProductSourceFiles.iosRoot()
            .appendingPathComponent("Floweroll/App/RuntimeClient/SystemEntryRuntimeCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let newStart = try XCTUnwrap(source.range(of: "private func submitNewSystemEntry("))
        let currentStart = try XCTUnwrap(
            source.range(of: "private func currentSystemEntryRoute(", range: newStart.upperBound..<source.endIndex)
        )
        let performStart = try XCTUnwrap(
            source.range(of: "private func performCurrentOperation(", range: currentStart.upperBound..<source.endIndex)
        )
        let newScope = String(source[newStart.lowerBound..<currentStart.lowerBound])
        let currentScope = String(source[currentStart.lowerBound..<performStart.lowerBound])

        XCTAssertTrue(newScope.contains("trackDurableTask(taskID, reason: \"system_entry_task_admitted\")"))
        XCTAssertTrue(newScope.contains("activeExecutionTaskIDs.insert(taskID)"))
        XCTAssertFalse(newScope.contains("submitUserInitiatedContinuation("))

        XCTAssertTrue(currentScope.contains("reason: \"system_entry_current_task_handoff\""))
        XCTAssertTrue(currentScope.contains("handoffInAppTaskToSystemLongRunning("))
        XCTAssertTrue(currentScope.contains("activeExecutionTaskIDs.insert(current.taskID).inserted"))
        XCTAssertFalse(currentScope.contains("submitUserInitiatedContinuation("))
    }

    func testSecondSystemEntryInvocationReusesExistingExecutionReservation() throws {
        let sourceURL = try ProductSourceFiles.iosRoot()
            .appendingPathComponent("Floweroll/App/RuntimeClient/SystemEntryRuntimeCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("activeExecutionTaskIDs.insert(current.taskID).inserted"))
        XCTAssertTrue(source.contains("ownsExecutionWindow: ownsExecutionWindow"))
        XCTAssertTrue(source.contains("enqueuePreparedHomeInputWithoutNewExecutionWindow("))
    }

    func testCustomLiveActivityRemotePushRemainsFrozenOutOfCurrentBuild() throws {
        let root = try ProductSourceFiles.iosRoot()
        let session = try String(
            contentsOf: root.appendingPathComponent("Floweroll/App/FlowerollActivitySession.swift"),
            encoding: .utf8
        )
        let client = try String(
            contentsOf: root.appendingPathComponent("Floweroll/App/RuntimeClient/FlowerollHostClient.swift"),
            encoding: .utf8
        )
        let project = try String(
            contentsOf: root.appendingPathComponent("Floweroll.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        XCTAssertFalse(session.contains("pushTokenUpdates"))
        XCTAssertFalse(session.contains("pushType: .token"))
        XCTAssertFalse(client.contains("\"live-activities\""))
        XCTAssertFalse(project.contains("APS_ENVIRONMENT"))
    }

    func testAppStartupRegistersBothExecutionLanesWithoutGlobalSweep() throws {
        let appRoot = try ProductSourceFiles.iosRoot().appendingPathComponent("Floweroll/App")
        let app = try String(contentsOf: appRoot.appendingPathComponent("FlowerollApp.swift"), encoding: .utf8)
        let controller = try String(
            contentsOf: appRoot.appendingPathComponent("RuntimeClient/DeviceBackgroundExecutionController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(app.contains("DeviceBackgroundExecutionController.shared.register()"))
        XCTAssertTrue(controller.contains("registerRecoveryHandler()"))
        XCTAssertTrue(controller.contains("registerGlobalHandler()"))
        XCTAssertTrue(controller.contains("retireCustomActivitiesForSystemContinuedProcessing("))
        XCTAssertFalse(controller.contains("retireAllCustomActivitiesForSystemOnlyMigration()"))
    }

    func testLongRunningNativeProgressRemainsVisibleWithoutVerifiedWorkCount() {
        let active = Self.view(status: "active", activeTitle: "正在查看日程")
        let update = SystemEntryRuntimeCoordinator.progressUpdate(from: active)
        XCTAssertEqual(update.title, "小卷正在处理")
        XCTAssertEqual(update.subtitle, "正在查看日程")
        XCTAssertEqual(update.completedUnitCount, SystemEntryProgressPresentationPolicy.activeFloorUnitCount)
        XCTAssertEqual(update.totalUnitCount, SystemEntryProgressPresentationPolicy.totalUnitCount)
    }

    @MainActor
    func testLongRunningBlockedTaskIsPausedNotFailed() async throws {
        let suite = "SystemEntryOwnershipTests.blocked.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)

        SystemEntryURLProtocol.install { _ in
            (200, try JSONEncoder.floweroll.encode(
                Self.view(status: "blocked", result: .object(["summary": .string("模型暂时不可用")]))
            ))
        }
        let coordinator = SystemEntryRuntimeCoordinator(
            defaults: defaults,
            pendingStore: nil,
            deviceWorker: nil,
            session: Self.session()
        )
        let outcome = try await coordinator.runSubmittedTask(
            taskID: "task-blocked",
            executionWindowSeconds: nil
        )
        XCTAssertEqual(outcome.state, .blocked)
        XCTAssertEqual(outcome.message, "模型暂时不可用")
    }

    @MainActor
    func testUnboundedLongRunningExecutionWaitsForDurableTerminalState() async throws {
        let suite = "SystemEntryOwnershipTests.terminal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)

        let sequence = SystemEntryViewSequence([
            Self.view(status: "active", activeTitle: "小卷正在思考"),
            Self.view(status: "active", activeTitle: "正在查看日程"),
            Self.view(status: "completed", result: .object(["summary": .string("日程查询完成")]))
        ])
        SystemEntryURLProtocol.install { _ in
            (200, try JSONEncoder.floweroll.encode(sequence.next()))
        }
        let recorder = SystemEntryProgressRecorder()
        let coordinator = SystemEntryRuntimeCoordinator(
            defaults: defaults,
            pendingStore: nil,
            deviceWorker: nil,
            session: Self.session()
        )
        let outcome = try await coordinator.runSubmittedTask(
            taskID: "task-system-entry",
            executionWindowSeconds: nil,
            onProgress: { recorder.append($0) }
        )
        XCTAssertEqual(outcome.state, .completed)
        XCTAssertEqual(outcome.message, "日程查询完成")
        let updates = recorder.snapshot()
        XCTAssertTrue(updates.dropLast().contains(where: {
            $0.completedUnitCount > 0 && $0.completedUnitCount < $0.totalUnitCount
        }))
        XCTAssertEqual(updates.last?.title, "小卷已完成")
        XCTAssertEqual(updates.last?.completedUnitCount, updates.last?.totalUnitCount)
    }

    @MainActor
    func testNeedsUserStaysNonterminalUntilExecutionWindowEnds() async throws {
        let suite = "SystemEntryOwnershipTests.needs-user.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)

        let waiting = Self.view(
            status: "waiting",
            pendingInteraction: .object([
                "kind": .string("clarification"),
                "clarification_id": .string("clar-1"),
                "question": .string("预算上限是多少？"),
                "suggested_options": .array([]),
                "accepts_text": .bool(true)
            ])
        )
        SystemEntryURLProtocol.install { _ in
            (200, try JSONEncoder.floweroll.encode(waiting))
        }
        let recorder = SystemEntryProgressRecorder()
        let coordinator = SystemEntryRuntimeCoordinator(
            defaults: defaults,
            pendingStore: nil,
            deviceWorker: nil,
            session: Self.session()
        )
        let outcome = try await coordinator.runSubmittedTask(
            taskID: "task-system-entry",
            executionWindowSeconds: 0.2,
            onProgress: { recorder.append($0) }
        )
        XCTAssertEqual(outcome.state, .delegated)
        let last = try XCTUnwrap(recorder.snapshot().last)
        XCTAssertEqual(last.title, "小卷需要你确认")
        XCTAssertEqual(last.subtitle, "预算上限是多少？")
        XCTAssertLessThan(last.completedUnitCount, last.totalUnitCount)
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SystemEntryURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func view(
        taskID: String = "task-system-entry",
        status: String,
        activeTitle: String? = nil,
        pendingInteraction: JSONValue? = nil,
        result: JSONValue? = nil
    ) -> HostTaskView {
        var timeline: [HostTimelineItem] = []
        if let activeTitle {
            timeline.append(HostTimelineItem(
                timelineItemID: "timeline-1",
                displayOrder: 1,
                kind: "TOOL_ACTIVITY",
                presentationState: "ACTIVE",
                title: activeTitle,
                summary: nil,
                payload: [:],
                revision: 1,
                createdAt: "2026-09-12T04:00:00Z",
                updatedAt: "2026-09-12T04:00:00Z"
            ))
        }
        return HostTaskView(
            task: HostTask(
                taskID: taskID,
                submissionID: nil,
                threadID: "thread-\(taskID)",
                parentTaskID: nil,
                goal: "查询日程并总结",
                status: status,
                currentStep: 0,
                idempotentReplay: nil,
                createdAt: "2026-09-12T04:00:00Z",
                updatedAt: "2026-09-12T04:00:01Z"
            ),
            timeline: timeline,
            artifacts: [],
            pendingInteraction: pendingInteraction,
            result: result,
            presentationCursor: timeline.count,
            workSummary: nil
        )
    }
    func testHomeInAppIntentPublishesStartedBeforeSlowAdmission() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Floweroll/App/FlowerollIntents.swift"),
            encoding: .utf8
        )
        let performRange = try XCTUnwrap(source.range(of: "struct HomeHouTaskIntent: AppIntent"))
        let tail = String(source[performRange.lowerBound...])
        let started = try XCTUnwrap(tail.range(of: "HomeInAppIntentEvents.postStarted"))
        let execute = try XCTUnwrap(tail.range(of: "executePreparedHomeInput"))
        XCTAssertLessThan(started.lowerBound, execute.lowerBound)

        let homeSource = try String(
            contentsOf: root.appendingPathComponent("Floweroll/App/Home/HomeView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(homeSource.contains("case \"started\":"))
        XCTAssertTrue(homeSource.contains("enteredHomeIntentSubmissionID == submissionID"))
    }

}
