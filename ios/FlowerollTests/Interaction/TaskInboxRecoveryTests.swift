import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Floweroll

extension RuntimeInteractionPolicyTests {

    @MainActor
    func testInboxReadModelSeparatesNeedsUserOtherRunningAndTerminalCandidates() {
        let suiteName = "RuntimeInteractionPolicyTests.inbox-read.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RuntimeTaskStore(defaults: defaults, pendingStore: nil, deviceWorker: nil)
        store.clearConfiguration()
        defer { store.clearConfiguration() }
        _ = store.cacheTaskView(presentationView(
            id: "task-current",
            status: "active",
            updatedAt: "2026-09-13T03:00:00Z",
            threadID: "thread-task-current"
        ))
        _ = store.cacheTaskView(presentationView(
            id: "task-other-running",
            status: "active",
            updatedAt: "2026-09-13T03:01:00Z",
            threadID: "thread-task-other-running"
        ))
        _ = store.cacheTaskView(presentationView(
            id: "task-needs-inbox",
            status: "waiting",
            updatedAt: "2026-09-13T03:02:00Z",
            pendingInteraction: .object([
                "kind": .string("clarification"),
                "clarification_id": .string("clar-inbox"),
                "question": .string("确认？"),
                "suggested_options": .array([]),
                "accepts_text": .bool(true)
            ]),
            threadID: "thread-task-needs-inbox"
        ))
        _ = store.cacheTaskView(presentationView(
            id: "task-terminal-inbox",
            status: "completed",
            updatedAt: "2026-09-13T03:03:00Z",
            threadID: "thread-task-terminal-inbox"
        ))
        _ = store.activateHomeThread(
            threadID: "thread-task-current",
            preferredTaskID: "task-current"
        )

        let inbox = store.taskInboxReadModel
        XCTAssertEqual(inbox.presentedThreadID, "thread-task-current")
        XCTAssertEqual(inbox.needsUser.map(\.taskID), ["task-needs-inbox"])
        XCTAssertEqual(inbox.runningElsewhere.map(\.taskID), ["task-other-running"])
        XCTAssertEqual(inbox.terminalElsewhere.map(\.taskID), ["task-terminal-inbox"])
        XCTAssertFalse(inbox.isEmpty)
    }

    @MainActor
    func testExactForegroundSelectionContractPersistsAcrossRecreationAndTerminalTruth() {
        let suiteName = "RuntimeInteractionPolicyTests.foreground-selection-contract.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RuntimeTaskStore(defaults: defaults, pendingStore: nil, deviceWorker: nil)
        store.clearConfiguration()
        defer { store.clearConfiguration() }
        _ = store.cacheTaskView(presentationView(
            id: "task-foreground",
            status: "active",
            updatedAt: "2026-09-13T03:10:00Z",
            threadID: "thread-task-foreground"
        ))

        let selected = store.activateHomeThread(
            threadID: "thread-task-foreground",
            preferredTaskID: "task-foreground"
        )
        XCTAssertEqual(selected?.threadID, "thread-task-foreground")
        XCTAssertEqual(selected?.ownership, .explicitUserSelection)
        XCTAssertEqual(selected?.continuationTaskID, "task-foreground")

        _ = store.cacheTaskView(presentationView(
            id: "task-foreground",
            status: "completed",
            updatedAt: "2026-09-13T03:11:00Z",
            threadID: "thread-task-foreground"
        ))
        XCTAssertEqual(store.currentHomePresentationSelection?.threadID, "thread-task-foreground")
        XCTAssertEqual(store.currentHomePresentationSelection?.ownership, .explicitUserSelection)

        let reopened = RuntimeTaskStore(defaults: defaults, pendingStore: nil, deviceWorker: nil)
        XCTAssertEqual(reopened.currentHomePresentationSelection?.threadID, "thread-task-foreground")
        XCTAssertEqual(reopened.currentHomePresentationSelection?.ownership, .explicitUserSelection)
        XCTAssertFalse(reopened.isAwaitingNewHomeThread)
    }

    @MainActor
    func testKillReopenPreservesAllTerminalStatesWithoutProcessingResurrection() {
        let cases: [(status: String, state: RuntimeTaskPresentationState)] = [
            ("completed", .completed),
            ("failed", .failed),
            ("cancelled", .cancelled),
        ]
        for item in cases {
            let suiteName = "RuntimeInteractionPolicyTests.reopen-\(item.status).\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let first = RuntimeTaskStore(defaults: defaults, pendingStore: nil, deviceWorker: nil)
            _ = first.cacheTaskView(presentationView(
                id: "task-reopen-\(item.status)",
                status: item.status,
                updatedAt: "2026-09-13T03:20:00Z"
            ))

            let reopened = RuntimeTaskStore(defaults: defaults, pendingStore: nil, deviceWorker: nil)
            XCTAssertEqual(
                reopened.presentationTruth(taskID: "task-reopen-\(item.status)")?.state,
                item.state,
                item.status
            )
            XCTAssertFalse(
                reopened.activeTasks.contains(where: { $0.taskID == "task-reopen-\(item.status)" }),
                item.status
            )
            reopened.clearConfiguration()
        }
    }

    @MainActor
    func testKillReopenDoesNotPaintStaleActiveOrNeedsUserBeforeAuthoritativeIndexRefresh() async {
        let suiteName = "RuntimeInteractionPolicyTests.reopen-nonterminal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)

        let first = RuntimeTaskStore(defaults: defaults, pendingStore: nil, deviceWorker: nil)
        _ = first.cacheTaskView(presentationView(
            id: "task-stale-active",
            status: "active",
            updatedAt: "2026-09-13T03:20:00Z"
        ))
        _ = first.cacheTaskView(presentationView(
            id: "task-stale-needs",
            status: "waiting",
            updatedAt: "2026-09-13T03:20:00Z",
            pendingInteraction: .object([
                "kind": .string("clarification"),
                "clarification_id": .string("clar-reopen"),
                "question": .string("确认？"),
                "suggested_options": .array([]),
                "accepts_text": .bool(true)
            ])
        ))

        let reopened = RuntimeTaskStore(
            defaults: defaults,
            session: homePresentationSession(),
            pendingStore: nil,
            deviceWorker: nil
        )
        XCTAssertTrue(reopened.runningTasks.isEmpty)
        XCTAssertTrue(reopened.needsUserTasks.isEmpty)

        let running = presentationTask(
            id: "task-stale-active",
            status: "active",
            updatedAt: "2026-09-13T03:21:00Z"
        )
        let needs = presentationTask(
            id: "task-stale-needs",
            status: "waiting",
            needsUser: true,
            updatedAt: "2026-09-13T03:21:00Z"
        )
        installTaskIndexBucketResponses(
            running: HostTaskIndexPage(items: [running], nextCursor: nil),
            needsUser: HostTaskIndexPage(items: [needs], nextCursor: nil)
        )
        await reopened.refreshPresentationIndex()
        XCTAssertEqual(reopened.runningTasks.map(\.taskID), ["task-stale-active"])
        XCTAssertEqual(reopened.needsUserTasks.map(\.taskID), ["task-stale-needs"])
        XCTAssertEqual(reopened.presentationTruth(taskID: "task-stale-needs")?.state, .needsUser)
        reopened.clearConfiguration()
    }
}
