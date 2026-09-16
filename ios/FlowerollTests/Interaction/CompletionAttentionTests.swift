import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Floweroll

extension RuntimeInteractionPolicyTests {

    func testCompletionAttentionSurvivesTransientInactiveScene() {
        XCTAssertFalse(HomeCompletionAttentionScenePolicy.shouldClear(isBackground: false))
        XCTAssertTrue(HomeCompletionAttentionScenePolicy.shouldClear(isBackground: true))
        XCTAssertFalse(HomeCompletionAttentionScenePolicy.shouldBeginNewSession(
            wasBackground: false,
            isActive: true
        ))
        XCTAssertTrue(HomeCompletionAttentionScenePolicy.shouldBeginNewSession(
            wasBackground: true,
            isActive: true
        ))
    }

    func testCompletionAttentionQueuesWithoutReplacingCurrentResult() {
        var state = HomeCompletionAttentionState()
        XCTAssertEqual(state.enqueue(["task-a"]), ["task-a"])
        XCTAssertEqual(state.currentTaskID, "task-a")
        XCTAssertEqual(state.enqueue(["task-b", "task-a"]), ["task-b"])
        XCTAssertEqual(state.currentTaskID, "task-a")
        XCTAssertEqual(state.queuedTaskIDs, ["task-b"])
        state.dismissCurrent()
        XCTAssertEqual(state.currentTaskID, "task-b")
        state.dismissCurrent()
        XCTAssertNil(state.currentTaskID)
    }

    @MainActor
    func testGlobalCompletionAttentionUsesOneStoreOwnerAcrossAppSurfaces() {
        let suiteName = "RuntimeInteractionPolicyTests.global-completion-owner.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RuntimeTaskStore(
            defaults: defaults,
            session: homePresentationSession(),
            pendingStore: nil,
            deviceWorker: nil
        )
        let owner = store.completionAttentionOwner
        store.beginCompletionAttentionAppSession(
            at: Date(timeIntervalSince1970: 1_789_257_600)
        )

        _ = store.cacheTaskView(presentationView(
            id: "task-global-attention",
            status: "completed",
            updatedAt: "2026-09-13T00:00:01Z",
            cursor: 5
        ))

        XCTAssertTrue(owner === store.completionAttentionOwner)
        XCTAssertEqual(store.completionAttentionReadModel.terminalTasks.map(\.taskID), ["task-global-attention"])
        for surface: RuntimeCompletionAttentionSurface in [
            .home,
            .tasks,
            .taskDetail(taskID: "task-explicit-detail"),
            .settings,
        ] {
            XCTAssertEqual(
                owner.presentation(on: surface)?.taskID,
                "task-global-attention"
            )
        }
        XCTAssertEqual(owner.currentTaskID, "task-global-attention")
        XCTAssertTrue(owner.queuedTaskIDs.isEmpty)
    }

    @MainActor
    func testGlobalCompletionAttentionDoesNotQueueCancelledTasks() {
        let suiteName = "RuntimeInteractionPolicyTests.global-completion-cancelled.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let owner = RuntimeCompletionAttentionOwner(
            defaults: defaults,
            sessionStartedAt: Date(timeIntervalSince1970: 1_789_257_600)
        )
        let readModel = RuntimeCompletionAttentionReadModel(terminalTasks: [
            completionAttentionTask(id: "task-cancelled", status: "cancelled", updatedAt: "2026-09-13T00:00:01Z"),
            completionAttentionTask(id: "task-completed", status: "completed", updatedAt: "2026-09-13T00:00:02Z"),
            completionAttentionTask(id: "task-failed", status: "failed", updatedAt: "2026-09-13T00:00:03Z"),
        ])

        owner.reconcile(readModel: readModel)

        XCTAssertEqual(owner.currentTaskID, "task-completed")
        XCTAssertEqual(owner.queuedTaskIDs, ["task-failed"])
        XCTAssertFalse(owner.queuedTaskIDs.contains("task-cancelled"))
        XCTAssertNotEqual(owner.presentation(on: .tasks)?.taskID, "task-cancelled")
    }

    @MainActor
    func testGlobalCompletionAttentionFIFOShowsAtMostOneAndTimeoutDoesNotAcknowledge() {
        let suiteName = "RuntimeInteractionPolicyTests.global-completion-fifo.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let owner = RuntimeCompletionAttentionOwner(
            defaults: defaults,
            sessionStartedAt: Date(timeIntervalSince1970: 1_789_257_600)
        )
        let readModel = RuntimeCompletionAttentionReadModel(terminalTasks: [
            completionAttentionTask(id: "task-c", updatedAt: "2026-09-13T00:00:03Z"),
            completionAttentionTask(id: "task-a", updatedAt: "2026-09-13T00:00:01Z"),
            completionAttentionTask(id: "task-b", updatedAt: "2026-09-13T00:00:02Z"),
        ])

        owner.reconcile(readModel: readModel)
        XCTAssertEqual(owner.currentTaskID, "task-a")
        XCTAssertEqual(owner.queuedTaskIDs, ["task-b", "task-c"])
        XCTAssertEqual(owner.presentation(on: .home)?.taskID, "task-a")

        XCTAssertEqual(owner.timeoutCurrent(), "task-a")
        XCTAssertEqual(owner.lastConsumptionReason, .timeout)
        XCTAssertEqual(owner.currentTaskID, "task-b")
        XCTAssertFalse(owner.acknowledgedTaskIDs.contains("task-a"))

        owner.reconcile(readModel: readModel)
        XCTAssertEqual(owner.currentTaskID, "task-b")
        XCTAssertEqual(owner.queuedTaskIDs, ["task-c"])
        XCTAssertFalse(owner.acknowledgedTaskIDs.contains("task-a"))
    }

    @MainActor
    func testGlobalCompletionAttentionDismissAndTabSwitchDoNotResurrectConsumedCard() {
        let suiteName = "RuntimeInteractionPolicyTests.global-completion-dismiss.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let owner = RuntimeCompletionAttentionOwner(
            defaults: defaults,
            sessionStartedAt: Date(timeIntervalSince1970: 1_789_257_600)
        )
        let readModel = RuntimeCompletionAttentionReadModel(terminalTasks: [
            completionAttentionTask(id: "task-dismiss", updatedAt: "2026-09-13T00:00:01Z"),
            completionAttentionTask(id: "task-next", updatedAt: "2026-09-13T00:00:02Z"),
        ])

        owner.reconcile(readModel: readModel)
        XCTAssertEqual(owner.presentation(on: .tasks)?.taskID, "task-dismiss")
        XCTAssertEqual(owner.dismissCurrent(), "task-dismiss")
        XCTAssertEqual(owner.lastConsumptionReason, .dismissed)
        XCTAssertFalse(owner.acknowledgedTaskIDs.contains("task-dismiss"))
        XCTAssertEqual(owner.presentation(on: .settings)?.taskID, "task-next")
        XCTAssertEqual(owner.presentation(on: .home)?.taskID, "task-next")

        owner.reconcile(readModel: readModel)
        XCTAssertEqual(owner.currentTaskID, "task-next")
        XCTAssertFalse(owner.queuedTaskIDs.contains("task-dismiss"))
        XCTAssertFalse(owner.acknowledgedTaskIDs.contains("task-dismiss"))
    }

    @MainActor
    func testGlobalCompletionAttentionViewRoutesExactTaskWithoutStealingExplicitDetailNavigation() {
        let suiteName = "RuntimeInteractionPolicyTests.global-completion-route.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let owner = RuntimeCompletionAttentionOwner(
            defaults: defaults,
            sessionStartedAt: Date(timeIntervalSince1970: 1_789_257_600)
        )
        owner.reconcile(readModel: RuntimeCompletionAttentionReadModel(terminalTasks: [
            completionAttentionTask(id: "task-attention", updatedAt: "2026-09-13T00:00:01Z")
        ]))

        XCTAssertEqual(
            owner.viewCurrent(explicitTaskDetailID: "task-user-selected"),
            .preserveExplicitTask(taskID: "task-user-selected")
        )
        XCTAssertEqual(owner.currentTaskID, "task-attention")

        XCTAssertEqual(
            owner.viewCurrent(),
            .openTask(taskID: "task-attention")
        )
        XCTAssertNil(owner.currentTaskID)
        XCTAssertEqual(owner.lastConsumptionReason, .viewed)
        XCTAssertFalse(owner.acknowledgedTaskIDs.contains("task-attention"))
    }

    @MainActor
    func testAcknowledgedGlobalCompletionAttentionDoesNotReappear() {
        let suiteName = "RuntimeInteractionPolicyTests.global-completion-ack.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sessionStartedAt = Date(timeIntervalSince1970: 1_789_257_600)
        let readModel = RuntimeCompletionAttentionReadModel(terminalTasks: [
            completionAttentionTask(id: "task-ack", updatedAt: "2026-09-13T00:00:01Z")
        ])
        let owner = RuntimeCompletionAttentionOwner(
            defaults: defaults,
            sessionStartedAt: sessionStartedAt
        )
        owner.reconcile(readModel: readModel)
        XCTAssertEqual(owner.currentTaskID, "task-ack")

        owner.acknowledge(taskIDs: ["task-ack"])
        XCTAssertNil(owner.currentTaskID)
        XCTAssertTrue(owner.acknowledgedTaskIDs.contains("task-ack"))
        owner.reconcile(readModel: readModel)
        XCTAssertNil(owner.currentTaskID)

        let recreated = RuntimeCompletionAttentionOwner(
            defaults: defaults,
            sessionStartedAt: sessionStartedAt
        )
        recreated.reconcile(readModel: readModel)
        XCTAssertNil(recreated.currentTaskID)
        XCTAssertTrue(recreated.acknowledgedTaskIDs.contains("task-ack"))
    }

    @MainActor
    func testNotifyUserDeliveryDoesNotSuppressOrConsumeGlobalCompletionAttention() {
        let suiteName = "RuntimeInteractionPolicyTests.global-completion-notify.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let owner = RuntimeCompletionAttentionOwner(
            defaults: defaults,
            sessionStartedAt: Date(timeIntervalSince1970: 1_789_257_600)
        )
        let readModel = RuntimeCompletionAttentionReadModel(terminalTasks: [
            completionAttentionTask(id: "task-notify-independent", updatedAt: "2026-09-13T00:00:01Z")
        ])

        XCTAssertFalse(
            RuntimeCompletionAttentionPolicy.shouldSuppressInAppAttentionForSystemNotification(
                delivered: true
            )
        )
        XCTAssertFalse(
            RuntimeCompletionAttentionPolicy.shouldSuppressInAppAttentionForSystemNotification(
                delivered: false
            )
        )
        owner.reconcile(readModel: readModel)
        XCTAssertEqual(owner.currentTaskID, "task-notify-independent")
        XCTAssertEqual(owner.presentation(on: .settings)?.taskID, "task-notify-independent")
    }

    func testCompletionAttentionOnlyTargetsNewBackgroundResults() {
        let sessionStart = Date(timeIntervalSince1970: 1_000)
        let after = Date(timeIntervalSince1970: 1_010)
        let before = Date(timeIntervalSince1970: 990)
        XCTAssertTrue(HomeCompletionAttentionPolicy.shouldEnqueue(
            taskID: "background", taskThreadID: "thread-b", currentThreadID: "thread-a",
            completedAt: after, sessionStartedAt: sessionStart, seenTaskIDs: []
        ))
        XCTAssertFalse(HomeCompletionAttentionPolicy.shouldEnqueue(
            taskID: "foreground", taskThreadID: "thread-a", currentThreadID: "thread-a",
            completedAt: after, sessionStartedAt: sessionStart, seenTaskIDs: []
        ))
        XCTAssertFalse(HomeCompletionAttentionPolicy.shouldEnqueue(
            taskID: "old", taskThreadID: "thread-b", currentThreadID: "thread-a",
            completedAt: before, sessionStartedAt: sessionStart, seenTaskIDs: []
        ))
        XCTAssertFalse(HomeCompletionAttentionPolicy.shouldEnqueue(
            taskID: "seen", taskThreadID: "thread-b", currentThreadID: "thread-a",
            completedAt: after, sessionStartedAt: sessionStart, seenTaskIDs: ["seen"]
        ))
    }
}
