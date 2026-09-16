import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Floweroll

extension RuntimeInteractionPolicyTests {

    @MainActor
    func testPresentationIndexRefreshReadsOnlyTaskIndexWithoutBusyState() async throws {
        let suiteName = "RuntimeInteractionPolicyTests.presentation-index.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)

        let counter = PresentationRequestCounter()
        let terminalIndex = presentationTask(
            id: "task-presentation", status: "completed", updatedAt: "2026-09-12T10:00:00Z"
        )
        let terminalView = presentationView(
            id: "task-presentation", status: "completed", updatedAt: "2026-09-12T10:00:00Z", cursor: 3
        )
        installPresentationTruthResponses(
            counter: counter,
            terminalIndex: terminalIndex,
            terminalView: terminalView
        )
        let store = RuntimeTaskStore(
            defaults: defaults,
            session: homePresentationSession(),
            pendingStore: nil,
            deviceWorker: nil
        )
        defer { store.clearConfiguration() }

        XCTAssertFalse(store.isRefreshing)
        await store.refreshPresentationIndex()

        XCTAssertFalse(store.isRefreshing)
        XCTAssertEqual(store.presentationTruth(taskID: "task-presentation")?.state, .completed)
        XCTAssertEqual(counter.count(suffix: "/v1/tasks"), 3)
        XCTAssertEqual(counter.count(suffix: "/view"), 0)
    }

    @MainActor
    func testHomePullToRefreshReadsFreshStatusWithoutExecutingDeviceWork() async throws {
        let suiteName = "RuntimeInteractionPolicyTests.home-pull-refresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)
        RuntimeTaskStore.persistHomePresentationSelection(
            defaults: defaults,
            threadID: "thread-a",
            ownership: .explicitUserSelection
        )

        let counter = PresentationRequestCounter()
        let task = threadIndexTask(
            id: "task-home-refresh",
            threadID: "thread-a",
            status: "active",
            title: "刷新首页状态",
            latestSummary: "后台仍在处理",
            createdAt: "2026-09-14T05:30:00Z",
            updatedAt: "2026-09-14T05:31:00Z"
        )
        let page = HostTaskIndexPage(items: [task], nextCursor: nil)
        let empty = HostTaskIndexPage(items: [], nextCursor: nil)
        let view = threadPresentationView(
            id: task.taskID,
            threadID: task.threadID,
            status: "active",
            goal: task.goal,
            createdAt: task.createdAt,
            updatedAt: "2026-09-14T05:31:02Z"
        )
        let pageData = try JSONEncoder.floweroll.encode(page)
        let emptyData = try JSONEncoder.floweroll.encode(empty)
        let viewData = try JSONEncoder.floweroll.encode(view)
        HomePresentationURLProtocol.install { request in
            counter.record(request)
            guard request.httpMethod == "GET" else { return (405, Data()) }
            let path = request.url?.path ?? ""
            if path == "/v1/tasks/\(task.taskID)/view" {
                return (200, viewData)
            }
            guard path == "/v1/tasks" else { return (404, Data()) }
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            // This URLProtocol handler runs on CFNetwork's custom-protocol
            // queue, not MainActor. Avoid a nested predicate closure here: a
            // closure formed inside this @MainActor XCTest can inherit actor
            // isolation and trap under Swift 6 when CFNetwork invokes it.
            var bucket: String?
            var threadID: String?
            for item in components.queryItems ?? [] {
                if item.name == "bucket" { bucket = item.value }
                if item.name == "thread_id" { threadID = item.value }
            }
            if bucket == "all", threadID == "thread-a" {
                return (200, pageData)
            }
            if bucket == "running" {
                return (200, pageData)
            }
            return (200, emptyData)
        }

        let store = RuntimeTaskStore(
            defaults: defaults,
            session: homePresentationSession(),
            pendingStore: nil,
            deviceWorker: nil
        )
        defer { store.clearConfiguration() }

        await store.refreshHomeStatusReadModel()

        XCTAssertFalse(store.isRefreshing)
        XCTAssertEqual(store.currentHomeThreadID, "thread-a")
        XCTAssertEqual(store.activeHomeThreadTask?.taskID, task.taskID)
        XCTAssertEqual(store.cachedTaskView(taskID: task.taskID)?.task.updatedAt, view.task.updatedAt)
        XCTAssertEqual(counter.count(suffix: "/v1/tasks"), 4)
        XCTAssertEqual(counter.count(suffix: "/view"), 1)
        XCTAssertEqual(counter.count(suffix: "/actions/next"), 0)
        XCTAssertEqual(counter.count(method: "POST", path: "/v1/tasks"), 0)
    }

    @MainActor
    func testForegroundFastRefreshReconcilesLatestTaskViewAfterDroppedSSE() async throws {
        let suiteName = "RuntimeInteractionPolicyTests.foreground-fast-view.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)
        RuntimeTaskStore.persistHomePresentationSelection(
            defaults: defaults,
            threadID: "thread-a",
            ownership: .foregroundSubmission
        )

        let counter = PresentationRequestCounter()
        let task = threadIndexTask(
            id: "task-foreground-replay",
            threadID: "thread-a",
            status: "waiting",
            title: "后台任务",
            latestSummary: "等待下一步",
            createdAt: "2026-09-16T04:57:10Z",
            updatedAt: "2026-09-16T07:00:48Z"
        )
        let page = HostTaskIndexPage(items: [task], nextCursor: nil)
        let view = threadPresentationView(
            id: task.taskID,
            threadID: task.threadID,
            status: "waiting",
            goal: task.goal,
            createdAt: task.createdAt,
            updatedAt: "2026-09-16T07:00:48Z"
        )
        let pageData = try JSONEncoder.floweroll.encode(page)
        let viewData = try JSONEncoder.floweroll.encode(view)
        HomePresentationURLProtocol.install { request in
            counter.record(request)
            guard request.httpMethod == "GET" else { return (405, Data()) }
            let path = request.url?.path ?? ""
            if path == "/v1/tasks/\(task.taskID)/view" {
                return (200, viewData)
            }
            if path == "/v1/tasks" {
                let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                var threadID: String?
                for item in components.queryItems ?? [] where item.name == "thread_id" {
                    threadID = item.value
                }
                return (200, threadID == "thread-a" ? pageData : try JSONEncoder.floweroll.encode(HostTaskIndexPage(items: [], nextCursor: nil)))
            }
            return (404, Data())
        }

        let store = RuntimeTaskStore(
            defaults: defaults,
            session: homePresentationSession(),
            pendingStore: nil,
            deviceWorker: nil
        )
        defer { store.clearConfiguration() }

        await store.refreshCurrentHomeThreadFast()

        XCTAssertEqual(store.latestHomeThreadTask?.taskID, task.taskID)
        XCTAssertEqual(store.cachedTaskView(taskID: task.taskID)?.task.updatedAt, view.task.updatedAt)
        XCTAssertEqual(counter.count(suffix: "/view"), 1)
    }

    func testHomeTaskIndexPollingRunsOnlyOnVisibleActiveHome() {
        XCTAssertTrue(HomeTaskIndexPollingPolicy.shouldPoll(
            isRootTabActive: true,
            appIsActive: true
        ))
        XCTAssertFalse(HomeTaskIndexPollingPolicy.shouldPoll(
            isRootTabActive: false,
            appIsActive: true
        ))
        XCTAssertFalse(HomeTaskIndexPollingPolicy.shouldPoll(
            isRootTabActive: true,
            appIsActive: false
        ))
        XCTAssertEqual(HomeTaskIndexPollingPolicy.intervalSeconds, 3.0)
    }
}
