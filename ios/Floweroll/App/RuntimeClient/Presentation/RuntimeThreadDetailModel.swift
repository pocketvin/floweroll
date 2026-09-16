import Observation
import SwiftUI



enum RuntimeThreadRestorationPresentation {
    static let routeResolutionMessage = "正在打开任务…"
    static let firstPageLoadingMessage = "正在加载任务记录…"
    static let olderPageLabel = "加载更早记录"
    static let olderPageLoadingMessage = "正在加载更早记录…"

    static func showsBlockingFirstPageLoading(
        taskCount: Int,
        isLoading: Bool
    ) -> Bool {
        isLoading && taskCount == 0
    }
}

@MainActor
@Observable
final class RuntimeThreadDetailModel {
    private(set) var tasks: [HostTaskIndexItem] = []
    private(set) var isLoading = false
    private(set) var isSending = false
    private(set) var isLoadingMore = false
    private(set) var nextCursor: String?
    private(set) var lastError: String?

    var latestTask: HostTaskIndexItem? { tasks.last }

    var activeTask: HostTaskIndexItem? {
        tasks.last(where: { !$0.presentationTruth.isTerminal })
    }

    func load(threadID: String, store: RuntimeTaskStore) async {
        if tasks.isEmpty {
            tasks = store.cachedThreadTasks(threadID: threadID)
        }
        isLoading = tasks.isEmpty
        defer { isLoading = false }
        do {
            let page = try await store.fetchThreadTaskPage(threadID: threadID, cursor: nil, limit: 20)
            nextCursor = page.nextCursor
            tasks = store.cachedThreadTasks(threadID: threadID)
            lastError = nil
        } catch {
            lastError = RuntimeTaskStore.userMessage(for: error)
        }
    }

    func loadMore(threadID: String, store: RuntimeTaskStore) async {
        guard !isLoadingMore, let cursor = nextCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await store.fetchThreadTaskPage(
                threadID: threadID, cursor: cursor, limit: 20
            )
            nextCursor = page.nextCursor
            tasks = store.cachedThreadTasks(threadID: threadID)
            lastError = nil
        } catch {
            lastError = RuntimeTaskStore.userMessage(for: error)
        }
    }


}
