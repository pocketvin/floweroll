import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Floweroll

extension RuntimeInteractionPolicyTests {

    func testTerminalReviewVisibilityRequiresForegroundActiveVisibleTerminalSurface() {
        for surface: RuntimeTerminalReviewSurface in [.homeResult, .taskDetail] {
            XCTAssertTrue(RuntimeTerminalReviewPolicy.canAccrueMeaningfulVisibility(
                state: .completed,
                surface: surface,
                appIsActive: true,
                surfaceIsActive: true,
                isActuallyVisible: true
            ))
            XCTAssertFalse(RuntimeTerminalReviewPolicy.canAccrueMeaningfulVisibility(
                state: .active,
                surface: surface,
                appIsActive: true,
                surfaceIsActive: true,
                isActuallyVisible: true
            ))
            XCTAssertFalse(RuntimeTerminalReviewPolicy.canAccrueMeaningfulVisibility(
                state: .completed,
                surface: surface,
                appIsActive: false,
                surfaceIsActive: true,
                isActuallyVisible: true
            ))
            XCTAssertFalse(RuntimeTerminalReviewPolicy.canAccrueMeaningfulVisibility(
                state: .completed,
                surface: surface,
                appIsActive: true,
                surfaceIsActive: false,
                isActuallyVisible: true
            ))
            XCTAssertFalse(RuntimeTerminalReviewPolicy.canAccrueMeaningfulVisibility(
                state: .completed,
                surface: surface,
                appIsActive: true,
                surfaceIsActive: true,
                isActuallyVisible: false
            ))
        }
        XCTAssertGreaterThan(
            RuntimeTerminalReviewPolicy.meaningfulVisibleDelayMilliseconds,
            AppShellCompletionAttentionPolicy.meaningfulVisibleDelayMilliseconds
        )
    }

    @MainActor
    func testFreshTerminalEntersInboxReviewPersistsAndBulkUsesSameTruth() {
        let suiteName = "RuntimeInteractionPolicyTests.terminal-review-persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = terminalReviewTask(
            id: "review-first",
            threadID: "review-thread-first",
            updatedAt: "2026-09-13T10:00:01Z"
        )
        let second = terminalReviewTask(
            id: "review-second",
            threadID: "review-thread-second",
            updatedAt: "2026-09-13T10:00:02Z"
        )
        let state = RuntimeTerminalReviewState(defaults: defaults)

        XCTAssertEqual(
            RuntimeTerminalReviewPolicy.pendingReviewTasks(
                terminalTasks: [first, second],
                reviewedTaskIDs: state.reviewedTaskIDs
            ).map(\.taskID),
            ["review-second", "review-first"]
        )

        // This is the exact mutation used by meaningful Home/Detail visibility
        // and by the Home "全部看过" action.
        state.markReviewed(taskIDs: [first.taskID, second.taskID])
        XCTAssertTrue(RuntimeTerminalReviewPolicy.pendingReviewTasks(
            terminalTasks: [first, second],
            reviewedTaskIDs: state.reviewedTaskIDs
        ).isEmpty)

        let relaunched = RuntimeTerminalReviewState(defaults: defaults)
        XCTAssertEqual(relaunched.reviewedTaskIDs, Set([first.taskID, second.taskID]))
    }

    @MainActor
    func testTerminalReviewMarkPendingReturnsToInboxAndCanBeReviewedAgain() {
        let suiteName = "RuntimeInteractionPolicyTests.terminal-review-reversible.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let task = terminalReviewTask(
            id: "review-reversible",
            threadID: "review-thread-reversible",
            updatedAt: "2026-09-13T10:01:00Z"
        )
        let state = RuntimeTerminalReviewState(defaults: defaults)
        state.markReviewed(taskIDs: [task.taskID])
        XCTAssertTrue(RuntimeTerminalReviewPolicy.pendingReviewTasks(
            terminalTasks: [task],
            reviewedTaskIDs: state.reviewedTaskIDs
        ).isEmpty)

        state.markPending(taskIDs: [task.taskID])
        XCTAssertEqual(
            RuntimeTerminalReviewPolicy.pendingReviewTasks(
                terminalTasks: [task],
                reviewedTaskIDs: state.reviewedTaskIDs
            ).map(\.taskID),
            [task.taskID]
        )

        XCTAssertTrue(RuntimeTerminalReviewPolicy.canAccrueMeaningfulVisibility(
            state: task.presentationTruth.state,
            surface: .taskDetail,
            appIsActive: true,
            surfaceIsActive: true,
            isActuallyVisible: true
        ))
        state.markReviewed(taskIDs: [task.taskID])
        XCTAssertTrue(RuntimeTerminalReviewPolicy.pendingReviewTasks(
            terminalTasks: [task],
            reviewedTaskIDs: state.reviewedTaskIDs
        ).isEmpty)
    }

    @MainActor
    func testHistoryPresentationHidePersistsWithoutChangingTerminalReviewState() {
        let suiteName = "RuntimeInteractionPolicyTests.history-local-hide.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let taskID = "history-hidden"
        let reviewState = RuntimeTerminalReviewState(defaults: defaults)
        let historyState = RuntimeTaskHistoryPresentationState(defaults: defaults)

        XCTAssertFalse(historyState.isHidden(taskID: taskID))
        XCTAssertFalse(reviewState.isReviewed(taskID: taskID))
        historyState.hide(taskIDs: [taskID])
        XCTAssertTrue(historyState.isHidden(taskID: taskID))
        XCTAssertFalse(reviewState.isReviewed(taskID: taskID))

        let relaunched = RuntimeTaskHistoryPresentationState(defaults: defaults)
        XCTAssertTrue(relaunched.isHidden(taskID: taskID))
    }

    @MainActor
    func testCompletionBannerOnlyDoesNotReviewAndPendingResetDoesNotReplayAttention() {
        let suiteName = "RuntimeInteractionPolicyTests.terminal-review-attention-independent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sessionStartedAt = Date(timeIntervalSince1970: 1_789_257_600)
        let task = completionAttentionTask(
            id: "review-attention-independent",
            updatedAt: "2026-09-13T00:00:01Z"
        )
        let readModel = RuntimeCompletionAttentionReadModel(terminalTasks: [task])
        let reviewState = RuntimeTerminalReviewState(defaults: defaults)
        let owner = RuntimeCompletionAttentionOwner(
            defaults: defaults,
            sessionStartedAt: sessionStartedAt
        )
        owner.reconcile(readModel: readModel)
        XCTAssertEqual(owner.currentTaskID, task.taskID)

        // Banner presentation is B17 attention state only; Inbox review stays pending.
        owner.markPresented(taskID: task.taskID)
        XCTAssertTrue(owner.seenTaskIDs.contains(task.taskID))
        XCTAssertFalse(reviewState.isReviewed(taskID: task.taskID))
        XCTAssertEqual(
            RuntimeTerminalReviewPolicy.pendingReviewTasks(
                terminalTasks: [task],
                reviewedTaskIDs: reviewState.reviewedTaskIDs
            ).map(\.taskID),
            [task.taskID]
        )
        XCTAssertEqual(owner.timeoutCurrent(), task.taskID)

        reviewState.markReviewed(taskIDs: [task.taskID])
        reviewState.markPending(taskIDs: [task.taskID])
        XCTAssertFalse(reviewState.isReviewed(taskID: task.taskID))

        // Reversing review cannot clear B17's seen state or replay its banner.
        let relaunchedOwner = RuntimeCompletionAttentionOwner(
            defaults: defaults,
            sessionStartedAt: sessionStartedAt
        )
        relaunchedOwner.reconcile(readModel: readModel)
        XCTAssertNil(relaunchedOwner.currentTaskID)
        XCTAssertTrue(relaunchedOwner.seenTaskIDs.contains(task.taskID))
        XCTAssertEqual(
            RuntimeTerminalReviewPolicy.pendingReviewTasks(
                terminalTasks: [task],
                reviewedTaskIDs: reviewState.reviewedTaskIDs
            ).map(\.taskID),
            [task.taskID]
        )
    }

    @MainActor
    func testTerminalReviewMigratesLegacyAcknowledgementOnceThenSeparates() throws {
        let suiteName = "RuntimeInteractionPolicyTests.terminal-review-migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyID = "legacy-reviewed"
        let encoded = try JSONEncoder().encode(Set([legacyID]))
        defaults.set(
            String(decoding: encoded, as: UTF8.self),
            forKey: RuntimeCompletionAttentionOwner.acknowledgedDefaultsKey
        )

        let migrated = RuntimeTerminalReviewState(defaults: defaults)
        XCTAssertTrue(migrated.isReviewed(taskID: legacyID))
        migrated.markPending(taskIDs: [legacyID])
        XCTAssertFalse(migrated.isReviewed(taskID: legacyID))

        let attention = RuntimeCompletionAttentionOwner(defaults: defaults)
        XCTAssertTrue(attention.acknowledgedTaskIDs.contains(legacyID))
        let relaunchedReview = RuntimeTerminalReviewState(defaults: defaults)
        XCTAssertFalse(relaunchedReview.isReviewed(taskID: legacyID))
    }

    @MainActor
    func testPendingReviewUsesNewestTerminalPerThreadBeforeReviewFilter() {
        let suiteName = "RuntimeInteractionPolicyTests.terminal-review-newest-thread.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let older = terminalReviewTask(
            id: "thread-old",
            threadID: "shared-review-thread",
            updatedAt: "2026-09-13T10:02:00Z"
        )
        let newer = terminalReviewTask(
            id: "thread-new",
            threadID: "shared-review-thread",
            updatedAt: "2026-09-13T10:03:00Z"
        )
        let state = RuntimeTerminalReviewState(defaults: defaults)
        state.markReviewed(taskIDs: [newer.taskID])

        XCTAssertTrue(RuntimeTerminalReviewPolicy.pendingReviewTasks(
            terminalTasks: [older, newer],
            reviewedTaskIDs: state.reviewedTaskIDs
        ).isEmpty)

        state.markPending(taskIDs: [newer.taskID])
        XCTAssertEqual(
            RuntimeTerminalReviewPolicy.pendingReviewTasks(
                terminalTasks: [older, newer],
                reviewedTaskIDs: state.reviewedTaskIDs
            ).map(\.taskID),
            [newer.taskID]
        )
    }
}
