import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Floweroll

extension RuntimeInteractionPolicyTests {

    func testHomeSubmissionWatchdogDoesNotTreatSlowAttachmentUploadAsFailure() {
        XCTAssertEqual(
            HomeSubmissionWatchdogPolicy.state(intentEntered: true, hasAttachments: true),
            .uploadingAttachments
        )
        XCTAssertEqual(
            HomeSubmissionWatchdogPolicy.state(intentEntered: true, hasAttachments: false),
            .submitting
        )
        XCTAssertEqual(
            HomeSubmissionWatchdogPolicy.state(intentEntered: false, hasAttachments: true),
            .systemDidNotStart
        )
        XCTAssertFalse(
            HomeSubmissionWatchdogState.uploadingAttachments.message.contains("再次发送")
        )
        XCTAssertTrue(
            HomeSubmissionWatchdogState.uploadingAttachments.message.contains("后台上传")
        )
    }


    @MainActor
    func testLocalUserTurnProjectionShowsImmediatelyThenYieldsToAuthoritativeTimeline() throws {
        let suiteName = "RuntimeInteractionPolicyTests.local-user-turn.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RuntimeTaskStore(defaults: defaults, pendingStore: nil, deviceWorker: nil)

        store.beginLocalUserTurnProjection(
            taskID: "task-a",
            eventID: "turn-1",
            text: "再补充一句",
            attachmentIDs: ["file-1"],
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var merged = store.localUserTurnTimelineItems(
            taskID: "task-a",
            authoritativeTimeline: []
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].kind, "USER_INPUT")
        XCTAssertEqual(merged[0].summary, "再补充一句")
        XCTAssertEqual(merged[0].payload["local_delivery_state"]?.stringValue, "sending")

        store.markLocalUserTurnAccepted(taskID: "task-a", eventID: "turn-1")
        merged = store.localUserTurnTimelineItems(taskID: "task-a", authoritativeTimeline: [])
        XCTAssertEqual(merged[0].payload["local_delivery_state"]?.stringValue, "accepted")

        let base = presentationView(
            id: "task-a",
            status: "active",
            updatedAt: "2026-09-14T01:00:00Z",
            cursor: 3
        )
        let authoritativeInput = HostTimelineItem(
            timelineItemID: "tl-authoritative",
            displayOrder: 2,
            kind: "USER_INPUT",
            presentationState: "COMPLETE",
            title: "你补充了任务",
            summary: "再补充一句",
            payload: ["attachment_ids": .array([.string("file-1")])],
            revision: 1,
            createdAt: "2026-09-14T01:00:00Z",
            updatedAt: "2026-09-14T01:00:00Z"
        )
        let authoritative = HostTaskView(
            task: base.task,
            timeline: [authoritativeInput],
            artifacts: base.artifacts,
            pendingInteraction: base.pendingInteraction,
            result: base.result,
            presentationCursor: 3,
            workSummary: base.workSummary
        )
        _ = store.cacheTaskView(authoritative)

        XCTAssertNil(store.localUserTurnProjections["task-a"])
        let finalTimeline = store.localUserTurnTimelineItems(
            taskID: "task-a",
            authoritativeTimeline: authoritative.timeline
        )
        XCTAssertEqual(finalTimeline, [authoritativeInput])
    }

    @MainActor
    func testSelectedHomeThreadSurvivesTemporaryGlobalIndexGap() async throws {
        let suiteName = "RuntimeInteractionPolicyTests.home-gap.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)
        defaults.set("thread-a", forKey: RuntimeTaskStore.homeThreadDefaultsKey)

        let selected = HostTaskIndexItem(
            taskID: "task-a",
            submissionID: "submission-a",
            threadID: "thread-a",
            parentTaskID: nil,
            title: "当前任务",
            goal: "查询日程并总结",
            status: "active",
            phase: "executing",
            bucket: "running",
            needsUser: false,
            latestTimeline: nil,
            createdAt: "2026-09-12T02:14:41Z",
            updatedAt: "2026-09-12T02:14:42Z"
        )
        let exact = HostTaskIndexPage(items: [selected], nextCursor: nil)
        installHomePresentationResponses(exactPages: [exact])
        let store = RuntimeTaskStore(
            defaults: defaults,
            session: homePresentationSession()
        )

        await store.refresh()

        XCTAssertEqual(store.currentHomeThreadID, "thread-a")
        XCTAssertEqual(store.homeThreadTasks.map(\.taskID), ["task-a"])
        XCTAssertFalse(store.isAwaitingNewHomeThread)
    }

    @MainActor
    func testRepeatedRefreshKeepsExplicitHomePresentation() async throws {
        let (store, defaults, suiteName) = makeHomePresentationStore(
            ownership: .explicitUserSelection,
            exactPages: [homePage(status: "active"), homePage(status: "active")]
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }

        await store.refresh()
        await store.refresh()

        XCTAssertEqual(store.currentHomeThreadID, "thread-a")
        XCTAssertEqual(store.homePresentationOwnership, .explicitUserSelection)
        XCTAssertFalse(store.isAwaitingNewHomeThread)
        XCTAssertEqual(store.homeThreadTasks.map(\.taskID), ["task-a"])
    }

    @MainActor
    func testDurableHomePresentationSurvivesExactThreadEmptyPageAndRecovers() async throws {
        let empty = HostTaskIndexPage(items: [], nextCursor: nil)
        let (store, defaults, suiteName) = makeHomePresentationStore(
            ownership: .explicitUserSelection,
            continuationTaskID: "task-a",
            exactPages: [empty, homePage(status: "active")]
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A confirmed empty exact-thread response can still be a transient
        // read-model/cache hole. Durable presentation ownership must fail
        // closed instead of interpreting it as a user request for New Task.
        await store.refresh()

        XCTAssertEqual(store.currentHomeThreadID, "thread-a")
        XCTAssertEqual(store.homePresentationOwnership, .explicitUserSelection)
        XCTAssertTrue(store.homeThreadTasks.isEmpty)
        XCTAssertTrue(store.hasHomePresentationSelection)
        XCTAssertFalse(store.isAwaitingNewHomeThread)

        await store.refresh()

        XCTAssertEqual(store.currentHomeThreadID, "thread-a")
        XCTAssertEqual(store.activeHomeThreadTask?.taskID, "task-a")
        XCTAssertFalse(store.isAwaitingNewHomeThread)
    }

    @MainActor
    func testForegroundFastHydrationThenFullRefreshKeepsSystemEntryPresentation() async throws {
        let suiteName = "RuntimeInteractionPolicyTests.foreground-refresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)
        defaults.set("task-a", forKey: RuntimeTaskStore.continuationTaskDefaultsKey)
        RuntimeTaskStore.persistHomePresentationSelection(
            defaults: defaults,
            threadID: "thread-a",
            ownership: .systemEntry
        )
        installHomePresentationResponses(exactPages: [
            HostTaskIndexPage(items: [], nextCursor: nil),
            homePage(status: "active"),
        ])
        let store = RuntimeTaskStore(defaults: defaults, session: homePresentationSession())

        // This is the same order Home uses when it becomes visible/active:
        // paint an exact-thread fast read first, then run the ordinary refresh.
        await store.refreshCurrentHomeThreadFast()
        XCTAssertEqual(store.currentHomeThreadID, "thread-a")
        XCTAssertEqual(store.homePresentationOwnership, .systemEntry)
        XCTAssertTrue(store.homeThreadTasks.isEmpty)
        XCTAssertTrue(store.hasHomePresentationSelection)

        await store.refresh()

        XCTAssertEqual(store.currentHomeThreadID, "thread-a")
        XCTAssertEqual(store.homePresentationOwnership, .systemEntry)
        XCTAssertEqual(store.activeHomeThreadTask?.taskID, "task-a")
        XCTAssertFalse(store.isAwaitingNewHomeThread)
    }

    @MainActor
    func testActivateHomeThreadUsesPrefetchedThreadCacheForContinuation() async throws {
        let suiteName = "RuntimeInteractionPolicyTests.prefetched-foreground.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)
        installHomePresentationResponses(exactPages: [homePage(status: "active")])
        let store = RuntimeTaskStore(defaults: defaults, session: homePresentationSession())

        _ = try await store.fetchThreadTaskPage(threadID: "thread-a")
        XCTAssertFalse(
            store.allKnownTasks.contains(where: { $0.taskID == "task-a" }),
            "fixture keeps task-a out of global index pages even when unrelated terminal history was restored"
        )

        store.activateHomeThread(threadID: "thread-a", preferredTaskID: "task-a")

        XCTAssertEqual(store.currentHomeThreadID, "thread-a")
        XCTAssertEqual(store.homePresentationOwnership, .explicitUserSelection)
        XCTAssertEqual(defaults.string(forKey: RuntimeTaskStore.continuationTaskDefaultsKey), "task-a")
    }

    @MainActor
    func testActiveToTerminalClearsContinuationButKeepsDurablePresentation() async throws {
        let (store, defaults, suiteName) = makeHomePresentationStore(
            ownership: .foregroundSubmission,
            continuationTaskID: "task-a",
            exactPages: [
                homePage(status: "active", updatedAt: "2026-09-12T02:14:42Z"),
                homePage(status: "completed", updatedAt: "2026-09-12T02:15:09Z"),
            ]
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }

        await store.refresh()
        await store.refresh()

        XCTAssertEqual(store.currentHomeThreadID, "thread-a")
        XCTAssertEqual(store.homePresentationOwnership, .foregroundSubmission)
        XCTAssertEqual(store.latestHomeThreadTask?.status, "completed")
        XCTAssertNil(defaults.string(forKey: RuntimeTaskStore.continuationTaskDefaultsKey))
        XCTAssertFalse(store.isAwaitingNewHomeThread)
    }

    @MainActor
    func testOldTerminalManuallyForegroundedStaysPresented() async throws {
        let suiteName = "RuntimeInteractionPolicyTests.old-terminal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)
        installHomePresentationResponses(exactPages: [
            homePage(status: "completed", updatedAt: "2026-01-01T00:00:00Z")
        ])
        let store = RuntimeTaskStore(defaults: defaults, session: homePresentationSession())
        store.activateHomeThread(threadID: "thread-a", preferredTaskID: "task-a")

        await store.refresh()

        XCTAssertEqual(store.currentHomeThreadID, "thread-a")
        XCTAssertEqual(store.homePresentationOwnership, .explicitUserSelection)
        XCTAssertEqual(store.latestHomeThreadTask?.status, "completed")
        XCTAssertFalse(store.isAwaitingNewHomeThread)
    }

    @MainActor
    func testAutomaticOldTerminalStillRetiresInsteadOfLockingHomeForever() async throws {
        let (store, defaults, suiteName) = makeHomePresentationStore(
            ownership: .automaticRestore,
            exactPages: [homePage(status: "completed", updatedAt: "2026-01-01T00:00:00Z")]
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }

        await store.refresh()

        XCTAssertNil(store.currentHomeThreadID)
        XCTAssertNil(store.homePresentationOwnership)
        XCTAssertTrue(store.isAwaitingNewHomeThread)
    }

    @MainActor
    func testExplicitHomePresentationPersistsAcrossStoreRecreation() {
        let suiteName = "RuntimeInteractionPolicyTests.recreation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = RuntimeTaskStore(defaults: defaults)
        first.activateHomeThread(threadID: "thread-a", preferredTaskID: nil)

        let recreated = RuntimeTaskStore(defaults: defaults)

        XCTAssertEqual(recreated.currentHomeThreadID, "thread-a")
        XCTAssertEqual(recreated.homePresentationOwnership, .explicitUserSelection)
        XCTAssertFalse(recreated.isAwaitingNewHomeThread)
    }

    @MainActor
    func testSystemEntryPresentationSurvivesGlobalGapAndRepeatedRefresh() async throws {
        let suiteName = "RuntimeInteractionPolicyTests.system-entry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)
        defaults.set("task-a", forKey: RuntimeTaskStore.continuationTaskDefaultsKey)
        RuntimeTaskStore.persistHomePresentationSelection(
            defaults: defaults,
            threadID: "thread-a",
            ownership: .systemEntry
        )
        installHomePresentationResponses(exactPages: [homePage(status: "active"), homePage(status: "active")])
        let store = RuntimeTaskStore(defaults: defaults, session: homePresentationSession())

        await store.refresh()
        await store.refresh()

        XCTAssertEqual(store.currentHomeThreadID, "thread-a")
        XCTAssertEqual(store.homePresentationOwnership, .systemEntry)
        XCTAssertEqual(store.activeHomeThreadTask?.taskID, "task-a")
        XCTAssertFalse(store.isAwaitingNewHomeThread)
    }

    @MainActor
    func testExplicitNewTaskLeavesCurrentPresentation() {
        let suiteName = "RuntimeInteractionPolicyTests.new-task.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RuntimeTaskStore(defaults: defaults)
        store.activateHomeThread(threadID: "thread-a")
        store.setContinuationTarget(taskID: "task-a")

        store.beginNewHomeThread()

        XCTAssertNil(store.currentHomeThreadID)
        XCTAssertNil(store.homePresentationOwnership)
        XCTAssertTrue(store.isAwaitingNewHomeThread)
        XCTAssertNil(defaults.string(forKey: RuntimeTaskStore.continuationTaskDefaultsKey))
    }

    @MainActor
    func testExplicitSwitchReplacesPresentationSelection() {
        let suiteName = "RuntimeInteractionPolicyTests.switch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RuntimeTaskStore(defaults: defaults)

        store.activateHomeThread(threadID: "thread-a")
        store.activateHomeThread(threadID: "thread-b")

        XCTAssertEqual(store.currentHomeThreadID, "thread-b")
        XCTAssertEqual(store.homePresentationOwnership, .explicitUserSelection)
        XCTAssertFalse(store.isAwaitingNewHomeThread)
    }

    @MainActor
    func testContinuationTargetCannotReplaceHomePresentation() {
        let suiteName = "RuntimeInteractionPolicyTests.continuation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RuntimeTaskStore(defaults: defaults)
        store.activateHomeThread(threadID: "thread-a")

        store.setContinuationTarget(taskID: "task-b")

        XCTAssertEqual(store.currentHomeThreadID, "thread-a")
        XCTAssertEqual(store.homePresentationOwnership, .explicitUserSelection)
        XCTAssertEqual(defaults.string(forKey: RuntimeTaskStore.continuationTaskDefaultsKey), "task-b")
    }
}
