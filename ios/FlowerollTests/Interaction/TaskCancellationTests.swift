import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Floweroll

extension RuntimeInteractionPolicyTests {

    func testCancelResponseReplayDecodesWhenCancellationPendingFieldIsAbsent() throws {
        let data = Data(#"""
        {
          "accepted":{"duplicate":true},
          "task":{
            "task_id":"task-replay",
            "submission_id":"submission-replay",
            "thread_id":"thread-replay",
            "parent_task_id":null,
            "goal":"replay",
            "status":"cancelled",
            "current_step":0,
            "cancel_requested_at":"2026-09-13T03:00:00Z",
            "cancel_reason":"cancelled",
            "created_at":"2026-09-13T02:59:00Z",
            "updated_at":"2026-09-13T03:00:00Z"
          }
        }
        """#.utf8)
        let decoded = try JSONDecoder.floweroll.decode(HostTaskCancellationResponse.self, from: data)
        XCTAssertEqual(decoded.task.taskID, "task-replay")
        XCTAssertEqual(decoded.task.status, "cancelled")
        XCTAssertNil(decoded.task.cancellationPending)
    }

    @MainActor
    func testDirectCancelPublishesSameTaskTerminalTruthBeforeReadbackAndNeverCreatesSecondTask() async throws {
        let suiteName = "RuntimeInteractionPolicyTests.direct-cancel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)
        let counter = PresentationRequestCounter()
        let cancelledAt = "2026-09-13T02:00:02Z"
        let cancelResponse = cancellationResponse(
            taskID: "task-cancel",
            status: "cancelled",
            pending: false,
            updatedAt: cancelledAt
        )
        let cancelledView = presentationView(
            id: "task-cancel",
            status: "cancelled",
            updatedAt: cancelledAt,
            cursor: 4
        )
        HomePresentationURLProtocol.install { request in
            counter.record(request)
            if request.httpMethod == "POST", request.url?.path == "/v1/tasks/task-cancel/cancel" {
                return (202, try JSONEncoder.floweroll.encode(cancelResponse))
            }
            if request.url?.path == "/v1/tasks/task-cancel/view" {
                Thread.sleep(forTimeInterval: 0.25)
                return (200, try JSONEncoder.floweroll.encode(cancelledView))
            }
            return (200, try JSONEncoder.floweroll.encode(
                HostTaskIndexPage(items: [], nextCursor: nil)
            ))
        }

        let store = RuntimeTaskStore(
            defaults: defaults,
            session: homePresentationSession(),
            pendingStore: nil,
            deviceWorker: nil
        )
        _ = store.cacheTaskView(presentationView(
            id: "task-cancel",
            status: "active",
            updatedAt: "2026-09-13T02:00:01Z",
            cursor: 1
        ))
        let cancellation = Task {
            try await store.cancelTask(taskID: "task-cancel", reason: "test cancel")
        }

        for _ in 0..<80 where counter.count(method: "POST", path: "/v1/tasks/task-cancel/cancel") == 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        for _ in 0..<80 where store.presentationTruth(taskID: "task-cancel")?.state != .cancelled {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(store.presentationTruth(taskID: "task-cancel")?.state, .cancelled)
        XCTAssertEqual(store.historyTasks.first(where: { $0.taskID == "task-cancel" })?.status, "cancelled")
        XCTAssertFalse(store.activeTasks.contains(where: { $0.taskID == "task-cancel" }))
        XCTAssertEqual(counter.count(method: "POST", path: "/v1/tasks"), 0)

        let result = try await cancellation.value
        XCTAssertEqual(result.taskID, "task-cancel")
        XCTAssertEqual(result.status, "cancelled")
        XCTAssertFalse(result.cancellationPending)
        XCTAssertEqual(store.cachedTaskView(taskID: "task-cancel")?.presentationTruth.state, .cancelled)
    }

    @MainActor
    func testPausedPlannerRetryUsesExactTaskEndpointAndNeverCreatesUserTurn() async throws {
        let suiteName = "RuntimeInteractionPolicyTests.paused-retry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)
        let counter = PresentationRequestCounter()
        let task = HostTask(
            taskID: "task-retry", submissionID: nil, threadID: "thread-retry", parentTaskID: nil,
            goal: "继续复杂任务", status: "active", currentStep: 0, idempotentReplay: nil,
            createdAt: "2026-09-16T00:00:00Z", updatedAt: "2026-09-16T00:02:00Z"
        )
        let response = HostTaskRetryResponse(task: task, resumed: true)
        let activeView = presentationView(
            id: "task-retry", status: "active", updatedAt: "2026-09-16T00:02:00Z", cursor: 3
        )
        HomePresentationURLProtocol.install { request in
            counter.record(request)
            if request.httpMethod == "POST", request.url?.path == "/v1/tasks/task-retry/retry" {
                return (202, try JSONEncoder.floweroll.encode(response))
            }
            if request.url?.path == "/v1/tasks/task-retry/view" {
                return (200, try JSONEncoder.floweroll.encode(activeView))
            }
            return (200, try JSONEncoder.floweroll.encode(HostTaskIndexPage(items: [], nextCursor: nil)))
        }

        let store = RuntimeTaskStore(
            defaults: defaults, session: homePresentationSession(), pendingStore: nil, deviceWorker: nil
        )
        let result = try await store.retryPausedTask(taskID: "task-retry")

        XCTAssertTrue(result.resumed)
        XCTAssertEqual(result.task.taskID, "task-retry")
        XCTAssertEqual(counter.count(method: "POST", path: "/v1/tasks/task-retry/retry"), 1)
        XCTAssertEqual(counter.count(method: "POST", path: "/v1/tasks/task-retry/turns"), 0)
        XCTAssertEqual(counter.count(method: "POST", path: "/v1/tasks"), 0)
        XCTAssertEqual(store.presentationTruth(taskID: "task-retry")?.state, .active)
    }

    @MainActor
    func testActiveListDeleteCancelsExactTaskBeforeHidingIt() async throws {
        let suiteName = "RuntimeInteractionPolicyTests.active-list-delete.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)

        let counter = PresentationRequestCounter()
        let taskID = "task-list-delete"
        let cancelledAt = "2026-09-13T07:00:03Z"
        let response = cancellationResponse(
            taskID: taskID,
            status: "cancelled",
            pending: false,
            updatedAt: cancelledAt
        )
        let cancelledView = presentationView(
            id: taskID,
            status: "cancelled",
            updatedAt: cancelledAt,
            cursor: 9
        )
        HomePresentationURLProtocol.install { request in
            counter.record(request)
            if request.httpMethod == "POST", request.url?.path == "/v1/tasks/\(taskID)/cancel" {
                return (202, try JSONEncoder.floweroll.encode(response))
            }
            if request.url?.path == "/v1/tasks/\(taskID)/view" {
                return (200, try JSONEncoder.floweroll.encode(cancelledView))
            }
            return (200, try JSONEncoder.floweroll.encode(HostTaskIndexPage(items: [], nextCursor: nil)))
        }

        let store = RuntimeTaskStore(
            defaults: defaults,
            session: homePresentationSession(),
            pendingStore: nil,
            deviceWorker: nil
        )
        _ = store.cacheTaskView(presentationView(
            id: taskID,
            status: "active",
            updatedAt: "2026-09-13T07:00:01Z"
        ))

        let result = try await store.cancelAndHideActiveTaskFromList(
            taskID: taskID,
            reason: "list swipe delete regression"
        )

        XCTAssertEqual(result.taskID, taskID)
        XCTAssertEqual(counter.count(method: "POST", path: "/v1/tasks/\(taskID)/cancel"), 1)
        XCTAssertEqual(counter.count(method: "POST", path: "/v1/tasks"), 0)
        XCTAssertTrue(store.historyPresentationState.isHidden(taskID: taskID))
        XCTAssertTrue(store.terminalReviewState.isReviewed(taskID: taskID))
        XCTAssertTrue(store.completionAttentionState.acknowledgedTaskIDs.contains(taskID))
        XCTAssertFalse(store.activeTasks.contains(where: { $0.taskID == taskID }))
    }

    @MainActor
    func testActiveListDeleteNeverHidesTaskWhenCancellationWasNotAccepted() async throws {
        let suiteName = "RuntimeInteractionPolicyTests.active-list-delete-failure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)

        let counter = PresentationRequestCounter()
        let taskID = "task-list-delete-failure"
        HomePresentationURLProtocol.install { request in
            counter.record(request)
            if request.httpMethod == "POST", request.url?.path == "/v1/tasks/\(taskID)/cancel" {
                return (500, Data(#"{"error":"cancel rejected"}"#.utf8))
            }
            return (200, try JSONEncoder.floweroll.encode(HostTaskIndexPage(items: [], nextCursor: nil)))
        }

        let store = RuntimeTaskStore(
            defaults: defaults,
            session: homePresentationSession(),
            pendingStore: nil,
            deviceWorker: nil
        )
        _ = store.cacheTaskView(presentationView(
            id: taskID,
            status: "active",
            updatedAt: "2026-09-13T07:10:01Z"
        ))

        do {
            _ = try await store.cancelAndHideActiveTaskFromList(
                taskID: taskID,
                reason: "list swipe delete failure regression"
            )
            XCTFail("delete must fail when durable task cancellation is not accepted")
        } catch {
            // Expected: local deletion is fail-closed behind durable cancellation.
        }

        XCTAssertEqual(counter.count(method: "POST", path: "/v1/tasks/\(taskID)/cancel"), 1)
        XCTAssertFalse(store.historyPresentationState.isHidden(taskID: taskID))
        XCTAssertFalse(store.terminalReviewState.isReviewed(taskID: taskID))
        XCTAssertFalse(store.completionAttentionState.acknowledgedTaskIDs.contains(taskID))
        XCTAssertTrue(store.activeTasks.contains(where: { $0.taskID == taskID }))
    }

    @MainActor
    func testNeedsUserWholeTaskCancelConvergesSameIdentityAndClearsNeedsUserBucket() async throws {
        let suiteName = "RuntimeInteractionPolicyTests.needs-user-cancel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)
        let cancelledAt = "2026-09-13T02:10:02Z"
        let cancelResponse = cancellationResponse(
            taskID: "task-needs",
            status: "cancelled",
            pending: false,
            updatedAt: cancelledAt
        )
        let cancelledView = presentationView(
            id: "task-needs",
            status: "cancelled",
            updatedAt: cancelledAt,
            cursor: 6
        )
        HomePresentationURLProtocol.install { request in
            if request.httpMethod == "POST", request.url?.path == "/v1/tasks/task-needs/cancel" {
                return (202, try JSONEncoder.floweroll.encode(cancelResponse))
            }
            if request.url?.path == "/v1/tasks/task-needs/view" {
                return (200, try JSONEncoder.floweroll.encode(cancelledView))
            }
            return (200, try JSONEncoder.floweroll.encode(
                HostTaskIndexPage(items: [], nextCursor: nil)
            ))
        }
        let store = RuntimeTaskStore(
            defaults: defaults,
            session: homePresentationSession(),
            pendingStore: nil,
            deviceWorker: nil
        )
        _ = store.cacheTaskView(presentationView(
            id: "task-needs",
            status: "waiting",
            updatedAt: "2026-09-13T02:10:01Z",
            pendingInteraction: .object([
                "kind": .string("clarification"),
                "clarification_id": .string("clar-needs"),
                "question": .string("几点？"),
                "suggested_options": .array([]),
                "accepts_text": .bool(true)
            ])
        ))
        XCTAssertEqual(store.needsUserTasks.map(\.taskID), ["task-needs"])

        let result = try await store.cancelTask(taskID: "task-needs")

        XCTAssertEqual(result.taskID, "task-needs")
        XCTAssertEqual(store.presentationTruth(taskID: "task-needs")?.state, .cancelled)
        XCTAssertFalse(store.needsUserTasks.contains(where: { $0.taskID == "task-needs" }))
        XCTAssertTrue(store.historyTasks.contains(where: { $0.taskID == "task-needs" && $0.status == "cancelled" }))
        XCTAssertNil(store.cachedTaskView(taskID: "task-needs")?.pendingInteraction)
    }

    @MainActor
    func testTaskDetailCancelTargetsSameTaskAndConvergesWithoutCreatingSecondTask() async {
        let suiteName = "RuntimeInteractionPolicyTests.detail-cancel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)
        let counter = PresentationRequestCounter()
        let taskID = "task-detail-cancel"
        let cancelledAt = "2026-09-13T04:40:02Z"
        let response = cancellationResponse(
            taskID: taskID,
            status: "cancelled",
            pending: false,
            updatedAt: cancelledAt
        )
        let terminalView = presentationView(
            id: taskID,
            status: "cancelled",
            updatedAt: cancelledAt,
            cursor: 7,
            threadID: "thread-task-detail-cancel"
        )
        let terminalIndex = HostTaskIndexItem(
            taskID: taskID,
            submissionID: "submission-detail-cancel",
            threadID: "thread-task-detail-cancel",
            parentTaskID: nil,
            title: "detail cancel",
            goal: "detail cancel",
            status: "cancelled",
            phase: nil,
            bucket: "history",
            needsUser: false,
            latestTimeline: nil,
            createdAt: "2026-09-13T04:40:00Z",
            updatedAt: cancelledAt
        )
        installDetailCancelResponses(
            counter: counter,
            taskID: taskID,
            cancelResponse: response,
            terminalView: terminalView,
            terminalIndex: terminalIndex
        )
        let store = RuntimeTaskStore(
            defaults: defaults,
            session: homePresentationSession(),
            pendingStore: nil,
            deviceWorker: nil
        )
        defer { store.clearConfiguration() }
        let model = RuntimeTaskDetailModel()
        model.seed(presentationView(
            id: taskID,
            status: "waiting",
            updatedAt: "2026-09-13T04:40:01Z",
            pendingInteraction: .object([
                "kind": .string("clarification"),
                "clarification_id": .string("clar-detail"),
                "question": .string("确认？"),
                "suggested_options": .array([]),
                "accepts_text": .bool(true)
            ]),
            threadID: "thread-task-detail-cancel"
        ))

        let result = await model.cancelUsingStore(taskID: taskID, store: store)
        XCTAssertEqual(result?.taskID, taskID)
        XCTAssertEqual(result?.status, "cancelled")
        XCTAssertEqual(model.cancellationMessage, RuntimeTaskCancellationPresentation.terminalMessage)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(counter.count(method: "POST", path: "/v1/tasks/\(taskID)/cancel"), 1)
        XCTAssertEqual(counter.count(method: "POST", path: "/v1/tasks"), 0)
        XCTAssertEqual(model.view?.presentationTruth.state, .cancelled)
        XCTAssertEqual(store.presentationTruth(taskID: taskID)?.state, .cancelled)
        XCTAssertFalse(store.activeTasks.contains(where: { $0.taskID == taskID }))
    }

    func testCancellationPresentationCopyDistinguishesTerminalAndPending() {
        XCTAssertEqual(
            RuntimeTaskCancellationPresentation.message(for: .init(
                taskID: "task-terminal", status: "cancelled", cancellationPending: false
            )),
            "已取消当前任务。"
        )
        XCTAssertEqual(
            RuntimeTaskCancellationPresentation.message(for: .init(
                taskID: "task-pending", status: "active", cancellationPending: true
            )),
            "正在安全停止任务…"
        )
        XCTAssertNotEqual(
            RuntimeTaskCancellationPresentation.message(for: .init(
                taskID: "task-pending", status: "active", cancellationPending: true
            )),
            "已取消当前任务。"
        )
    }

    @MainActor
    func testSharedCancellationKeepsCommitted202TerminalTruthWhenViewReadbackFails() async throws {
        let suiteName = "RuntimeInteractionPolicyTests.c23-cancel-readback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)
        let counter = PresentationRequestCounter()
        let taskID = "task-c23-terminal"
        let response = cancellationResponse(
            taskID: taskID,
            status: "cancelled",
            pending: false,
            updatedAt: "2026-09-13T05:20:02Z"
        )
        let terminalItem = HostTaskIndexItem(
            taskID: taskID,
            submissionID: "submission-c23-terminal",
            threadID: "thread-task-c23-terminal",
            parentTaskID: nil,
            title: "C23 terminal cancellation",
            goal: "C23 terminal cancellation",
            status: "cancelled",
            phase: nil,
            bucket: "history",
            needsUser: false,
            latestTimeline: nil,
            createdAt: "2026-09-13T05:20:00Z",
            updatedAt: "2026-09-13T05:20:02Z"
        )
        installCancelAcceptedWithReadbackFailureResponses(
            counter: counter,
            taskID: taskID,
            cancelResponse: response,
            terminalIndex: terminalItem
        )
        let store = RuntimeTaskStore(
            defaults: defaults,
            session: homePresentationSession(),
            pendingStore: nil,
            deviceWorker: nil
        )
        defer { store.clearConfiguration() }
        let model = RuntimeTaskDetailModel()
        model.seed(presentationView(
            id: taskID,
            status: "waiting",
            updatedAt: "2026-09-13T05:20:01Z",
            pendingInteraction: .object([
                "kind": .string("clarification"),
                "clarification_id": .string("clar-c23"),
                "question": .string("继续吗？"),
                "suggested_options": .array([]),
                "accepts_text": .bool(true)
            ]),
            threadID: "thread-task-c23-terminal"
        ))

        let result = await model.cancelUsingStore(
            taskID: taskID,
            store: store,
            reason: "C23 committed-202 regression"
        )

        XCTAssertEqual(result?.taskID, taskID)
        XCTAssertEqual(result?.status, "cancelled")
        XCTAssertEqual(result?.cancellationPending, false)
        XCTAssertEqual(model.cancellationMessage, RuntimeTaskCancellationPresentation.terminalMessage)
        XCTAssertNil(model.lastError, "a failed post-202 /view must not turn accepted cancellation into UI failure")
        XCTAssertEqual(counter.count(method: "POST", path: "/v1/tasks/\(taskID)/cancel"), 1)
        XCTAssertEqual(counter.count(method: "POST", path: "/v1/tasks"), 0)
        XCTAssertEqual(store.presentationTruth(taskID: taskID)?.state, .cancelled)
        XCTAssertTrue(store.historyTasks.contains(where: { $0.taskID == taskID && $0.status == "cancelled" }))
        XCTAssertFalse(store.activeTasks.contains(where: { $0.taskID == taskID }))
        XCTAssertGreaterThanOrEqual(counter.count(method: "GET", path: "/v1/tasks/\(taskID)/view"), 1)
    }

    @MainActor
    func testCancellationPendingAutomaticallyConvergesToTerminalWithoutManualRefresh() async throws {
        let suiteName = "RuntimeInteractionPolicyTests.cancel-convergence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)
        let counter = PresentationRequestCounter()
        let activeView = presentationView(
            id: "task-pending-cancel",
            status: "active",
            updatedAt: "2026-09-13T02:20:02Z",
            cursor: 2
        )
        let cancelledView = presentationView(
            id: "task-pending-cancel",
            status: "cancelled",
            updatedAt: "2026-09-13T02:20:03Z",
            cursor: 5
        )
        let views = HostTaskViewSequence([activeView, cancelledView])
        let response = cancellationResponse(
            taskID: "task-pending-cancel",
            status: "active",
            pending: true,
            updatedAt: "2026-09-13T02:20:02Z"
        )
        HomePresentationURLProtocol.install { request in
            counter.record(request)
            if request.httpMethod == "POST", request.url?.path == "/v1/tasks/task-pending-cancel/cancel" {
                return (202, try JSONEncoder.floweroll.encode(response))
            }
            if request.url?.path == "/v1/tasks/task-pending-cancel/view" {
                return (200, try JSONEncoder.floweroll.encode(views.next()))
            }
            let page = HostTaskIndexPage(items: [], nextCursor: nil)
            return (200, try JSONEncoder.floweroll.encode(page))
        }
        let store = RuntimeTaskStore(
            defaults: defaults,
            session: homePresentationSession(),
            pendingStore: nil,
            deviceWorker: nil
        )
        _ = store.cacheTaskView(presentationView(
            id: "task-pending-cancel",
            status: "active",
            updatedAt: "2026-09-13T02:20:01Z"
        ))

        let result = try await store.cancelTask(taskID: "task-pending-cancel")
        XCTAssertTrue(result.cancellationPending)
        XCTAssertEqual(result.taskID, "task-pending-cancel")

        for _ in 0..<160 where store.presentationTruth(taskID: "task-pending-cancel")?.state != .cancelled {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.presentationTruth(taskID: "task-pending-cancel")?.state, .cancelled)
        XCTAssertGreaterThanOrEqual(counter.count(suffix: "/view"), 2)
        XCTAssertEqual(counter.count(method: "POST", path: "/v1/tasks"), 0)
    }
}
