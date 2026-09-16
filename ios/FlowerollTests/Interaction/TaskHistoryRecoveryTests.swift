import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Floweroll

extension RuntimeInteractionPolicyTests {

    @MainActor
    func testThreadDetailRefreshFailureRetainsSafeCachedRows() async throws {
        let suiteName = "RuntimeInteractionPolicyTests.thread-cache-refresh-failure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        RuntimeTaskStore(defaults: defaults, pendingStore: nil, deviceWorker: nil)
            .clearConfiguration()
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)

        let store = RuntimeTaskStore(
            defaults: defaults,
            session: homePresentationSession(),
            pendingStore: nil,
            deviceWorker: nil
        )
        defer { store.clearConfiguration() }
        _ = store.cacheTaskView(threadPresentationView(
            id: "task-cached-failure",
            threadID: "thread-cached-failure",
            status: "completed",
            goal: "cached meaningful result",
            createdAt: "2026-09-13T00:01:00Z",
            updatedAt: "2026-09-13T00:10:00Z"
        ))
        XCTAssertEqual(
            store.cachedThreadTasks(threadID: "thread-cached-failure").map(\.taskID),
            ["task-cached-failure"]
        )

        let counter = PresentationRequestCounter()
        HomePresentationURLProtocol.install { request in
            counter.record(request)
            return (503, Data(#"{"code":"TEMPORARY_THREAD_REFRESH_FAILURE"}"#.utf8))
        }

        let model = RuntimeThreadDetailModel()
        await model.load(threadID: "thread-cached-failure", store: store)

        XCTAssertEqual(model.tasks.map(\.taskID), ["task-cached-failure"])
        XCTAssertEqual(model.tasks.first?.title, "cached meaningful result")
        XCTAssertFalse(model.isLoading)
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(counter.count(method: "GET", path: "/v1/tasks"), 1)
        XCTAssertEqual(counter.count(suffix: "/view"), 0)
    }

    @MainActor
    func testCachedThreadTasksRestoresPersistedTerminalHistoryOnColdReopenInCreatedOrder() {
        let suiteName = "RuntimeInteractionPolicyTests.thread-cache-cold-reopen.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // The history presentation cache is process-global on disk. Start this
        // persistence test from a clean cache without relying on test order.
        RuntimeTaskStore(defaults: defaults, pendingStore: nil, deviceWorker: nil)
            .clearConfiguration()

        let first = RuntimeTaskStore(defaults: defaults, pendingStore: nil, deviceWorker: nil)
        _ = first.cacheTaskView(threadPresentationView(
            id: "task-late",
            threadID: "thread-long",
            status: "completed",
            createdAt: "2026-09-13T00:02:00Z",
            updatedAt: "2026-09-13T00:12:00Z"
        ))
        _ = first.cacheTaskView(threadPresentationView(
            id: "task-early",
            threadID: "thread-long",
            status: "failed",
            createdAt: "2026-09-13T00:01:00Z",
            updatedAt: "2026-09-13T00:11:00Z"
        ))
        _ = first.cacheTaskView(threadPresentationView(
            id: "task-other",
            threadID: "thread-other",
            status: "completed",
            createdAt: "2026-09-13T00:00:00Z",
            updatedAt: "2026-09-13T00:10:00Z"
        ))
        _ = first.cacheTaskView(threadPresentationView(
            id: "task-stale-active",
            threadID: "thread-long",
            status: "active",
            createdAt: "2026-09-13T00:03:00Z",
            updatedAt: "2026-09-13T00:13:00Z"
        ))

        let reopened = RuntimeTaskStore(defaults: defaults, pendingStore: nil, deviceWorker: nil)
        defer { reopened.clearConfiguration() }

        XCTAssertNil(reopened.threadTaskCache["thread-long"], "transient thread pages must not survive process reconstruction")
        XCTAssertEqual(
            reopened.cachedThreadTasks(threadID: "thread-long").map(\.taskID),
            ["task-early", "task-late"],
            "safe persisted terminal rows should paint immediately in stable createdAt order"
        )
        XCTAssertTrue(
            reopened.cachedThreadTasks(threadID: "thread-long").allSatisfy { $0.presentationTruth.isTerminal }
        )
        XCTAssertFalse(
            reopened.cachedThreadTasks(threadID: "thread-long").contains { $0.taskID == "task-stale-active" },
            "nonterminal disk truth must never be restored"
        )
        XCTAssertFalse(
            reopened.cachedThreadTasks(threadID: "thread-long").contains { $0.threadID == "thread-other" }
        )
    }

    @MainActor
    func testCachedThreadTasksDedupesTransientPageAndTerminalBeatsNewerStaleNonterminal() async throws {
        let suiteName = "RuntimeInteractionPolicyTests.thread-cache-terminal-monotonic.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        RuntimeTaskStore(defaults: defaults, pendingStore: nil, deviceWorker: nil)
            .clearConfiguration()

        let first = RuntimeTaskStore(defaults: defaults, pendingStore: nil, deviceWorker: nil)
        _ = first.cacheTaskView(threadPresentationView(
            id: "task-terminal",
            threadID: "thread-long",
            status: "completed",
            createdAt: "2026-09-13T00:01:00Z",
            updatedAt: "2026-09-13T00:10:00Z"
        ))

        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)
        let staleActive = threadIndexTask(
            id: "task-terminal",
            threadID: "thread-long",
            status: "active",
            title: "stale processing",
            createdAt: "2026-09-13T00:01:00Z",
            updatedAt: "2026-09-13T00:20:00Z"
        )
        let unrelated = threadIndexTask(
            id: "task-unrelated",
            threadID: "thread-other",
            status: "completed",
            title: "wrong thread",
            createdAt: "2026-09-13T00:02:00Z",
            updatedAt: "2026-09-13T00:21:00Z"
        )
        HomePresentationURLProtocol.install { _ in
            (200, try JSONEncoder.floweroll.encode(
                HostTaskIndexPage(items: [staleActive, unrelated], nextCursor: nil)
            ))
        }

        let reopened = RuntimeTaskStore(
            defaults: defaults,
            session: homePresentationSession(),
            pendingStore: nil,
            deviceWorker: nil
        )
        defer { reopened.clearConfiguration() }
        _ = try await reopened.fetchThreadTaskPage(threadID: "thread-long", limit: 20)

        let cached = reopened.cachedThreadTasks(threadID: "thread-long")
        XCTAssertEqual(cached.map(\.taskID), ["task-terminal"])
        XCTAssertEqual(cached.first?.presentationTruth.state, .completed)
        XCTAssertEqual(cached.first?.status, "completed")
        XCTAssertFalse(cached.contains(where: { $0.taskID == "task-unrelated" }))
        XCTAssertTrue(
            (reopened.threadTaskCache["thread-long"] ?? []).allSatisfy { $0.threadID == "thread-long" },
            "malformed unrelated rows from an exact-thread response must fail closed"
        )
    }

    @MainActor
    func testAuthoritativeThreadPageEnrichesCachedTerminalWhileFirstPaintStaysAvailable() async throws {
        let suiteName = "RuntimeInteractionPolicyTests.thread-cache-authoritative-enrich.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        RuntimeTaskStore(defaults: defaults, pendingStore: nil, deviceWorker: nil)
            .clearConfiguration()

        let first = RuntimeTaskStore(defaults: defaults, pendingStore: nil, deviceWorker: nil)
        _ = first.cacheTaskView(threadPresentationView(
            id: "task-enrich",
            threadID: "thread-enrich",
            status: "completed",
            goal: "cached title",
            createdAt: "2026-09-13T00:01:00Z",
            updatedAt: "2026-09-13T00:10:00Z"
        ))

        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)
        let fresh = threadIndexTask(
            id: "task-enrich",
            threadID: "thread-enrich",
            status: "completed",
            title: "fresh authoritative title",
            latestSummary: "fresh result summary",
            createdAt: "2026-09-13T00:01:00Z",
            updatedAt: "2026-09-13T00:20:00Z"
        )
        let counter = PresentationRequestCounter()
        HomePresentationURLProtocol.install { request in
            counter.record(request)
            return (200, try JSONEncoder.floweroll.encode(
                HostTaskIndexPage(items: [fresh], nextCursor: "older-page")
            ))
        }

        let reopened = RuntimeTaskStore(
            defaults: defaults,
            session: homePresentationSession(),
            pendingStore: nil,
            deviceWorker: nil
        )
        defer { reopened.clearConfiguration() }

        XCTAssertEqual(reopened.cachedThreadTasks(threadID: "thread-enrich").first?.title, "cached title")
        let page = try await reopened.fetchThreadTaskPage(threadID: "thread-enrich", limit: 20)
        XCTAssertEqual(page.nextCursor, "older-page")
        let enriched = try XCTUnwrap(reopened.cachedThreadTasks(threadID: "thread-enrich").first)
        XCTAssertEqual(enriched.title, "fresh authoritative title")
        XCTAssertEqual(enriched.latestTimeline?.summary, "fresh result summary")
        XCTAssertEqual(counter.count(suffix: "/view"), 0)
        XCTAssertEqual(counter.count(method: "GET", path: "/v1/tasks"), 1)
        XCTAssertTrue(counter.queries(path: "/v1/tasks").allSatisfy { $0.contains("limit=20") })
    }

    @MainActor
    func testKnownThreadAndCachedTaskIdentityAvoidTaskViewLookupButStillRefreshAuthoritatively() async {
        let suiteName = "RuntimeInteractionPolicyTests.thread-known-identity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        RuntimeTaskStore(defaults: defaults, pendingStore: nil, deviceWorker: nil)
            .clearConfiguration()
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)

        let store = RuntimeTaskStore(
            defaults: defaults,
            session: homePresentationSession(),
            pendingStore: nil,
            deviceWorker: nil
        )
        defer { store.clearConfiguration() }
        _ = store.cacheTaskView(threadPresentationView(
            id: "task-known",
            threadID: "thread-known",
            status: "completed",
            createdAt: "2026-09-13T00:01:00Z",
            updatedAt: "2026-09-13T00:10:00Z"
        ))
        XCTAssertEqual(store.allKnownTasks.first(where: { $0.taskID == "task-known" })?.threadID, "thread-known")
        XCTAssertEqual(store.cachedTaskView(taskID: "task-known")?.task.threadID, "thread-known")

        let counter = PresentationRequestCounter()
        let fresh = threadIndexTask(
            id: "task-known",
            threadID: "thread-known",
            status: "completed",
            title: "fresh",
            createdAt: "2026-09-13T00:01:00Z",
            updatedAt: "2026-09-13T00:11:00Z"
        )
        HomePresentationURLProtocol.install { request in
            counter.record(request)
            if request.url?.path.hasSuffix("/view") == true {
                return (500, Data())
            }
            return (200, try JSONEncoder.floweroll.encode(
                HostTaskIndexPage(items: [fresh], nextCursor: nil)
            ))
        }

        let model = RuntimeThreadDetailModel()
        await model.load(threadID: "thread-known", store: store)

        XCTAssertEqual(counter.count(suffix: "/view"), 0)
        XCTAssertEqual(counter.count(method: "GET", path: "/v1/tasks"), 1)
        XCTAssertEqual(model.tasks.map(\.taskID), ["task-known"])
        XCTAssertEqual(model.tasks.first?.title, "fresh")
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testLongThreadHistoryRemainsTwentyRowCursorPaginationPastFiftyRows() async throws {
        let suiteName = "RuntimeInteractionPolicyTests.thread-pagination.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        RuntimeTaskStore(defaults: defaults, pendingStore: nil, deviceWorker: nil)
            .clearConfiguration()
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)

        let allRows = (0..<60).map { index in
            threadIndexTask(
                id: String(format: "task-%02d", index),
                threadID: "thread-60",
                status: "completed",
                title: String(format: "task-%02d", index),
                createdAt: String(format: "2026-09-13T00:%02d:00Z", index),
                updatedAt: String(format: "2026-09-13T01:%02d:00Z", index)
            )
        }
        let counter = PresentationRequestCounter()
        HomePresentationURLProtocol.install { request in
            counter.record(request)
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            var query: [String: String] = [:]
            for item in components.queryItems ?? [] {
                query[item.name] = item.value ?? ""
            }
            let page: HostTaskIndexPage
            switch query["cursor"] {
            case nil:
                page = HostTaskIndexPage(items: Array(allRows[0..<20]), nextCursor: "cursor-20")
            case "cursor-20":
                page = HostTaskIndexPage(items: Array(allRows[20..<40]), nextCursor: "cursor-40")
            case "cursor-40":
                page = HostTaskIndexPage(items: Array(allRows[40..<60]), nextCursor: nil)
            default:
                return (400, Data())
            }
            return (200, try JSONEncoder.floweroll.encode(page))
        }

        let store = RuntimeTaskStore(
            defaults: defaults,
            session: homePresentationSession(),
            pendingStore: nil,
            deviceWorker: nil
        )
        defer { store.clearConfiguration() }

        let first = try await store.fetchThreadTaskPage(
            threadID: "thread-60", cursor: nil, limit: 20
        )
        XCTAssertEqual(first.nextCursor, "cursor-20")
        XCTAssertEqual(store.cachedThreadTasks(threadID: "thread-60").count, 20)
        XCTAssertEqual(counter.count(method: "GET", path: "/v1/tasks"), 1)

        let second = try await store.fetchThreadTaskPage(
            threadID: "thread-60", cursor: try XCTUnwrap(first.nextCursor), limit: 20
        )
        XCTAssertEqual(second.nextCursor, "cursor-40")
        XCTAssertEqual(store.cachedThreadTasks(threadID: "thread-60").count, 40)
        XCTAssertEqual(counter.count(method: "GET", path: "/v1/tasks"), 2)

        let third = try await store.fetchThreadTaskPage(
            threadID: "thread-60", cursor: try XCTUnwrap(second.nextCursor), limit: 20
        )
        XCTAssertNil(third.nextCursor)
        XCTAssertEqual(store.cachedThreadTasks(threadID: "thread-60").count, 60)
        XCTAssertEqual(counter.count(method: "GET", path: "/v1/tasks"), 3)
        XCTAssertEqual(counter.count(suffix: "/view"), 0)

        let queries = counter.queries(path: "/v1/tasks")
        XCTAssertEqual(queries.count, 3)
        XCTAssertTrue(queries.allSatisfy { $0.contains("limit=20") && $0.contains("thread_id=thread-60") })
        XCTAssertFalse(queries[0].contains("cursor="))
        XCTAssertTrue(queries[1].contains("cursor=cursor-20"))
        XCTAssertTrue(queries[2].contains("cursor=cursor-40"))
    }

    @MainActor
    func testTerminalPresentationSurvivesStoreRecreationWithoutProcessingResurrection() async throws {
        let suiteName = "RuntimeInteractionPolicyTests.presentation-reopen.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)

        let firstStore = RuntimeTaskStore(
            defaults: defaults,
            session: homePresentationSession(),
            pendingStore: nil,
            deviceWorker: nil
        )
        let terminal = presentationView(
            id: "task-reopen",
            status: "completed",
            updatedAt: "2026-09-12T10:00:00Z",
            cursor: 9,
            result: .object(["summary": .string("persisted terminal")])
        )
        _ = firstStore.cacheTaskView(terminal)
        XCTAssertEqual(firstStore.historyTasks.first(where: { $0.taskID == "task-reopen" })?.presentationTruth.state, .completed)

        // A new Store models app-process reconstruction. Only immutable terminal
        // history is allowed to paint before the next network refresh.
        let reopened = RuntimeTaskStore(
            defaults: defaults,
            session: homePresentationSession(),
            pendingStore: nil,
            deviceWorker: nil
        )
        XCTAssertEqual(
            reopened.historyTasks.first(where: { $0.taskID == "task-reopen" })?.presentationTruth.state,
            .completed
        )
        XCTAssertFalse(reopened.activeTasks.contains(where: { $0.taskID == "task-reopen" }))
        reopened.clearConfiguration()
    }

    @MainActor
    func testSnapshotOnlyDetailRefreshesAuthoritativeViewEvenWhenCacheExists() async throws {
        let suiteName = "RuntimeInteractionPolicyTests.presentation-truth.\\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)
        let counter = PresentationRequestCounter()
        let terminalIndex = presentationTask(
            id: "task-a", status: "completed", updatedAt: "2026-09-12T10:00:00Z"
        )
        let terminalView = presentationView(
            id: "task-a",
            status: "completed",
            updatedAt: "2026-09-12T10:00:00Z",
            cursor: 8,
            result: .object(["summary": .string("done")])
        )
        installPresentationTruthResponses(
            counter: counter,
            terminalIndex: terminalIndex,
            terminalView: terminalView
        )

        let store = RuntimeTaskStore(defaults: defaults, session: homePresentationSession())
        let staleCachedView = presentationView(
            id: "task-a", status: "active", updatedAt: "2026-09-12T09:59:00Z", cursor: 2
        )
        _ = store.cacheTaskView(staleCachedView)
        await store.refresh()
        XCTAssertEqual(store.presentationTruth(taskID: "task-a")?.state, .completed)

        let model = RuntimeTaskDetailModel()
        model.start(taskID: "task-a", store: store, updateMode: .snapshotOnly)
        for _ in 0..<30 where counter.count(suffix: "/view") == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        for _ in 0..<30 where model.view?.result == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        model.stop()

        XCTAssertGreaterThanOrEqual(counter.count(suffix: "/view"), 1)
        XCTAssertEqual(model.view?.presentationTruth.state, .completed)
        XCTAssertEqual(model.view?.result?.objectValue?["summary"]?.stringValue, "done")
        XCTAssertEqual(store.cachedTaskView(taskID: "task-a")?.presentationTruth.state, .completed)
    }

    @MainActor
    func testTaskDetailToHomeHandoffDoesNotRestartInFlightInitialViewFetch() async throws {
        let suiteName = "RuntimeInteractionPolicyTests.foreground-view-handoff.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)

        let counter = PresentationRequestCounter()
        let activeView = presentationView(
            id: "task-a",
            status: "active",
            updatedAt: "2026-09-13T04:30:00Z",
            cursor: 4
        )
        HomePresentationURLProtocol.install { request in
            counter.record(request)
            if request.url?.path.hasSuffix("/view") == true {
                // Keep the first authoritative read in flight long enough to
                // reproduce the real Detail -> Home ownership transition.
                Thread.sleep(forTimeInterval: 0.18)
                return (200, try JSONEncoder.floweroll.encode(activeView))
            }
            return (200, try JSONEncoder.floweroll.encode(
                HostTaskIndexPage(items: [], nextCursor: nil)
            ))
        }

        let store = RuntimeTaskStore(defaults: defaults, session: homePresentationSession())
        let detailModel = RuntimeTaskDetailModel()
        detailModel.start(taskID: "task-a", store: store, updateMode: .snapshotOnly)

        for _ in 0..<50 where counter.count(suffix: "/view") == 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(counter.count(suffix: "/view"), 1)

        // Switching root tabs tears down the detail presentation owner while
        // the request is still in flight. The shared Store must retain that
        // fetch so Home can join it instead of starting another tunnel GET.
        detailModel.stop()
        let homeModel = RuntimeTaskDetailModel()
        homeModel.start(taskID: "task-a", store: store, updateMode: .snapshotOnly)

        for _ in 0..<80 where homeModel.view == nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        homeModel.stop()

        XCTAssertNotNil(homeModel.view)
        XCTAssertEqual(counter.count(suffix: "/view"), 1)
        XCTAssertEqual(store.cachedTaskView(taskID: "task-a")?.task.taskID, "task-a")
    }
}
