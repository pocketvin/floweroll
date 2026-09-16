import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Floweroll

extension RuntimeInteractionPolicyTests {

    func testInboxBadgeAccentMaintainsReadableContrastAcrossThemes() {
        for choice in FlowerollAccentChoice.allCases {
            XCTAssertGreaterThanOrEqual(
                HomeInboxBadgePolicy.bestContrastRatio(accentRGB: choice.palette.accentRGB),
                4.5,
                "badge contrast for \(choice.rawValue)"
            )
        }
        XCTAssertNotEqual(
            FlowerollAccentChoice.blush.palette.accentRGB,
            FlowerollAccentChoice.lavender.palette.accentRGB
        )
    }

    func testAppShellOrdinaryTasksTabRoundTripPreservesNavigationGeneration() {
        var state = AppShellTaskNavigationState()
        XCTAssertEqual(state.generation, 0)

        state.ordinaryRootTabSelection()
        state.ordinaryRootTabSelection()

        XCTAssertEqual(
            state.generation,
            0,
            "Task Detail -> Home/Settings -> Tasks must preserve the existing Tasks NavigationStack"
        )
    }

    func testAppShellExplicitBringToHomeResetsTasksNavigationGeneration() {
        var state = AppShellTaskNavigationState()
        state.ordinaryRootTabSelection()
        XCTAssertEqual(state.generation, 0)

        state.explicitBringToHome()
        XCTAssertEqual(
            state.generation,
            1,
            "only explicit 调到前台/首页 handoff may reset Tasks to its list root"
        )

        state.ordinaryRootTabSelection()
        XCTAssertEqual(state.generation, 1)
    }

    @MainActor
    func testReturnToLatestButtonIsCompactAccessibleTarget() {
        let host = UIHostingController(rootView: HomeReturnToLatestButton(action: {}))
        let size = host.sizeThatFits(in: CGSize(width: 430, height: 1_000))
        XCTAssertEqual(size.width, 44, accuracy: 0.5)
        XCTAssertEqual(size.height, 44, accuracy: 0.5)
    }

    func testOnlyNamedNonTerminalEpisodeGetsLiveUpdates() {
        let terminal = task(id: "terminal", status: "completed")
        let active = task(id: "active", status: "active")
        let otherActive = task(id: "other-active", status: "active")

        XCTAssertEqual(RuntimeTaskDetailUpdatePolicy.mode(task: terminal, liveTaskID: "active"), .snapshotOnly)
        XCTAssertEqual(RuntimeTaskDetailUpdatePolicy.mode(task: active, liveTaskID: "active"), .live)
        XCTAssertEqual(RuntimeTaskDetailUpdatePolicy.mode(task: otherActive, liveTaskID: "active"), .snapshotOnly)
    }

    func testHistoryPageMergeKeepsPreviouslyLoadedRowsAndAddsNextPage() {
        let firstPage = (0..<50).map { task(id: "history-\($0)", status: "completed") }
        let secondPage = (50..<65).map { task(id: "history-\($0)", status: "completed") }

        let merged = RuntimeTaskStore.mergedTaskIndexItems(
            existing: firstPage,
            incoming: secondPage
        )

        XCTAssertEqual(merged.count, 65)
        XCTAssertEqual(
            Set(merged.map(\.taskID)),
            Set((0..<65).map { "history-\($0)" })
        )
    }


    func testCanonicalPresentationTruthMapsAllLifecycleStates() {
        XCTAssertEqual(task(id: "active", status: "active").presentationTruth.state, .active)
        XCTAssertEqual(task(id: "waiting", status: "waiting").presentationTruth.state, .waiting)
        XCTAssertEqual(task(id: "blocked", status: "blocked").presentationTruth.state, .paused)
        XCTAssertEqual(
            presentationTask(id: "needs", status: "active", needsUser: true).presentationTruth.state,
            .needsUser
        )
        XCTAssertEqual(task(id: "completed", status: "completed").presentationTruth.state, .completed)
        XCTAssertEqual(task(id: "failed", status: "failed").presentationTruth.state, .failed)
        XCTAssertEqual(task(id: "cancelled", status: "cancelled").presentationTruth.state, .cancelled)
    }

    func testTerminalTruthAbsorbsNeedsUserAndPendingInteractionHints() {
        XCTAssertEqual(
            RuntimeTaskPresentationTruth.taskStatus(
                "completed", needsUser: true, hasPendingInteraction: true
            ).state,
            .completed
        )
        let completedWithStalePending = presentationView(
            id: "task-terminal",
            status: "completed",
            updatedAt: "2026-09-12T10:00:00Z",
            pendingInteraction: .object(["kind": .string("clarification")])
        )
        XCTAssertEqual(completedWithStalePending.presentationTruth.state, .completed)
    }

    func testHomeComposerExecutionStopPolicyOnlyStopsActiveExecution() {
        XCTAssertTrue(HomeComposerExecutionStopPolicy.shouldOfferStop(for: .active))
        XCTAssertFalse(HomeComposerExecutionStopPolicy.shouldOfferStop(for: .waiting))
        XCTAssertFalse(HomeComposerExecutionStopPolicy.shouldOfferStop(for: .paused))
        XCTAssertFalse(HomeComposerExecutionStopPolicy.shouldOfferStop(for: .needsUser))
        XCTAssertFalse(HomeComposerExecutionStopPolicy.shouldOfferStop(for: .completed))
        XCTAssertFalse(HomeComposerExecutionStopPolicy.shouldOfferStop(for: .failed))
        XCTAssertFalse(HomeComposerExecutionStopPolicy.shouldOfferStop(for: .cancelled))
        XCTAssertFalse(HomeComposerExecutionStopPolicy.shouldOfferStop(for: nil))
    }

    func testPlannerRuntimePauseIsRetryableWithoutBecomingUserInput() throws {
        let json = Data(#"""
        {
          "task": {
            "task_id":"retryable", "submission_id":null, "thread_id":"thread-retryable",
            "parent_task_id":null, "goal":"继续", "status":"blocked", "current_step":0,
            "created_at":"2026-09-16T00:00:00Z", "updated_at":"2026-09-16T00:01:00Z"
          },
          "runtime": {"phase":"planning", "block_reason":"planner_runtime_error"},
          "timeline":[], "artifacts":[], "pending_interaction":null, "result":null,
          "presentation_cursor":1
        }
        """#.utf8)
        let view = try JSONDecoder.floweroll.decode(HostTaskView.self, from: json)
        XCTAssertEqual(view.presentationTruth.state, .paused)
        XCTAssertEqual(view.runtime?.blockReason, "planner_runtime_error")
        XCTAssertTrue(RuntimeTaskRetryPolicy.canRetry(view))

        let restrictedJSON = Data(String(data: json, encoding: .utf8)!
            .replacingOccurrences(of: "planner_runtime_error", with: "task_capability_denied").utf8)
        let restricted = try JSONDecoder.floweroll.decode(HostTaskView.self, from: restrictedJSON)
        XCTAssertFalse(RuntimeTaskRetryPolicy.canRetry(restricted))
    }

    func testGenericComposerIsHiddenAtPendingInteractionBoundary() {
        XCTAssertTrue(RuntimeTaskComposerPolicy.showsGenericComposer(
            isTerminal: false, hasPendingInteraction: false
        ))
        XCTAssertFalse(RuntimeTaskComposerPolicy.showsGenericComposer(
            isTerminal: false, hasPendingInteraction: true
        ))
        XCTAssertFalse(RuntimeTaskComposerPolicy.showsGenericComposer(
            isTerminal: true, hasPendingInteraction: false
        ))
    }

    func testHomeInboxPresentationUsesCanonicalNeedsUserAndTerminalTruth() {
        let activeNeedsUser = presentationTask(
            id: "inbox-active-needs",
            status: "active",
            needsUser: true
        )
        XCTAssertEqual(HomeInboxTaskPresentationPolicy.truth(for: activeNeedsUser).state, .needsUser)
        XCTAssertEqual(HomeInboxTaskPresentationPolicy.section(for: activeNeedsUser), .needsUser)
        XCTAssertEqual(HomeInboxTaskPresentationPolicy.label(for: activeNeedsUser), "需要你")

        let waitingNeedsUser = presentationTask(
            id: "inbox-waiting-needs",
            status: "waiting",
            needsUser: true
        )
        XCTAssertEqual(HomeInboxTaskPresentationPolicy.truth(for: waitingNeedsUser).state, .needsUser)
        XCTAssertEqual(HomeInboxTaskPresentationPolicy.section(for: waitingNeedsUser), .needsUser)
        XCTAssertEqual(HomeInboxTaskPresentationPolicy.label(for: waitingNeedsUser), "需要你")

        let blocked = presentationTask(id: "inbox-blocked", status: "blocked")
        XCTAssertEqual(HomeInboxTaskPresentationPolicy.truth(for: blocked).state, .paused)
        XCTAssertEqual(HomeInboxTaskPresentationPolicy.section(for: blocked), .running)
        XCTAssertEqual(HomeInboxTaskPresentationPolicy.label(for: blocked), "已暂停")

        let blockedWithRealInteraction = presentationTask(
            id: "inbox-blocked-needs", status: "blocked", needsUser: true
        )
        XCTAssertEqual(HomeInboxTaskPresentationPolicy.truth(for: blockedWithRealInteraction).state, .needsUser)
        XCTAssertEqual(HomeInboxTaskPresentationPolicy.section(for: blockedWithRealInteraction), .needsUser)

        XCTAssertEqual(
            RuntimeTaskPresentationTruth.taskStatus(
                "waiting",
                hasPendingInteraction: true
            ).state,
            .needsUser
        )

        let waiting = presentationTask(id: "inbox-waiting", status: "waiting")
        XCTAssertEqual(HomeInboxTaskPresentationPolicy.section(for: waiting), .running)
        XCTAssertEqual(HomeInboxTaskPresentationPolicy.label(for: waiting), "等待中")

        for (status, state, label) in [
            ("completed", RuntimeTaskPresentationState.completed, "已完成"),
            ("failed", RuntimeTaskPresentationState.failed, "失败"),
            ("cancelled", RuntimeTaskPresentationState.cancelled, "已取消"),
        ] {
            let terminal = presentationTask(
                id: "inbox-terminal-\(status)",
                status: status,
                needsUser: true
            )
            XCTAssertEqual(HomeInboxTaskPresentationPolicy.truth(for: terminal).state, state)
            XCTAssertEqual(HomeInboxTaskPresentationPolicy.section(for: terminal), .terminal)
            XCTAssertEqual(HomeInboxTaskPresentationPolicy.label(for: terminal), label)
        }
    }

    func testTerminalIndexBeatsNewerLookingStaleActiveAcrossBuckets() {
        let terminal = presentationTask(
            id: "task-a",
            status: "completed",
            updatedAt: "2026-09-12T10:00:00Z"
        )
        let staleActive = presentationTask(
            id: "task-a",
            status: "active",
            updatedAt: "2026-09-12T10:01:00Z"
        )

        let merged = RuntimeTaskStore.mergedTaskIndexItems(
            existing: [staleActive],
            incoming: [terminal]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].presentationTruth.state, .completed)
        XCTAssertEqual(merged[0].bucket, "history")
        XCTAssertFalse(merged[0].needsUser)
    }

    func testFailedAndCancelledAlsoAbsorbStaleProcessingRows() {
        for terminalStatus in ["failed", "cancelled"] {
            let staleActive = presentationTask(
                id: "task-\\(terminalStatus)",
                status: "active",
                updatedAt: "2026-09-12T10:01:00Z"
            )
            let terminal = presentationTask(
                id: "task-\\(terminalStatus)",
                status: terminalStatus,
                updatedAt: "2026-09-12T10:00:00Z"
            )
            let merged = RuntimeTaskStore.mergedTaskIndexItems(
                existing: [staleActive], incoming: [terminal]
            )
            XCTAssertEqual(merged.count, 1)
            XCTAssertTrue(merged[0].presentationTruth.isTerminal)
            XCTAssertEqual(merged[0].status, terminalStatus)
        }
    }

    func testCanonicalMergeKeepsParallelTasksIsolated() {
        let taskATerminal = presentationTask(id: "task-a", status: "completed")
        let taskAStale = presentationTask(id: "task-a", status: "active", updatedAt: "2026-09-12T11:00:00Z")
        let taskBWaiting = presentationTask(id: "task-b", status: "waiting")
        let taskCNeedsUser = presentationTask(id: "task-c", status: "active", needsUser: true)

        let merged = RuntimeTaskStore.canonicalTaskIndexItems([
            taskAStale, taskBWaiting, taskATerminal, taskCNeedsUser,
        ])
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged.first(where: { $0.taskID == "task-a" })?.presentationTruth.state, .completed)
        XCTAssertEqual(merged.first(where: { $0.taskID == "task-b" })?.presentationTruth.state, .waiting)
        XCTAssertEqual(merged.first(where: { $0.taskID == "task-c" })?.presentationTruth.state, .needsUser)
    }

    func testIndexAndDetailResolveToSameTerminalTruth() {
        let index = presentationTask(
            id: "task-a", status: "completed", updatedAt: "2026-09-12T10:00:00Z"
        )
        let staleDetail = presentationView(
            id: "task-a", status: "active", updatedAt: "2026-09-12T09:59:00Z"
        )

        let truth = RuntimeTaskPresentationReducer.truth(indexItem: index, view: staleDetail)
        XCTAssertEqual(truth?.state, .completed)

        let terminalized = RuntimeTaskPresentationReducer.terminalizingCachedView(
            staleDetail, indexItem: index
        )
        XCTAssertEqual(terminalized.task.status, "completed")
        XCTAssertNil(terminalized.pendingInteraction)
    }

    func testTerminalViewRejectsLaterStaleSSEPresentationDelta() {
        let active = presentationView(
            id: "task-a", status: "active", updatedAt: "2026-09-12T10:00:00Z", cursor: 4
        )
        let terminal = presentationView(
            id: "task-a", status: "completed", updatedAt: "2026-09-12T10:01:00Z", cursor: 4
        )
        let event = presentationEvent(taskID: "task-a", seq: 5, revision: 2)
        XCTAssertTrue(RuntimeTaskPresentationReducer.shouldApply(event: event, to: active))
        XCTAssertFalse(RuntimeTaskPresentationReducer.shouldApply(event: event, to: terminal))
        XCTAssertFalse(
            RuntimeTaskPresentationReducer.shouldApply(
                event: presentationEvent(taskID: "task-a", seq: 4, revision: 2),
                to: active
            )
        )
    }


    func testThreadRestorationLoadingCopyMatchesBoundedPresentationStates() {
        XCTAssertEqual(RuntimeThreadRestorationPresentation.routeResolutionMessage, "正在打开任务…")
        XCTAssertEqual(RuntimeThreadRestorationPresentation.firstPageLoadingMessage, "正在加载任务记录…")
        XCTAssertEqual(RuntimeThreadRestorationPresentation.olderPageLabel, "加载更早记录")
        XCTAssertEqual(RuntimeThreadRestorationPresentation.olderPageLoadingMessage, "正在加载更早记录…")
        XCTAssertFalse(RuntimeThreadRestorationPresentation.routeResolutionMessage.contains("完整任务历史"))
        XCTAssertFalse(RuntimeThreadRestorationPresentation.firstPageLoadingMessage.contains("完整任务历史"))

        XCTAssertTrue(
            RuntimeThreadRestorationPresentation.showsBlockingFirstPageLoading(
                taskCount: 0,
                isLoading: true
            )
        )
        XCTAssertFalse(
            RuntimeThreadRestorationPresentation.showsBlockingFirstPageLoading(
                taskCount: 1,
                isLoading: true
            ),
            "meaningful cached rows must win over the first-page loading stage"
        )
        XCTAssertFalse(
            RuntimeThreadRestorationPresentation.showsBlockingFirstPageLoading(
                taskCount: 0,
                isLoading: false
            )
        )
    }
}
