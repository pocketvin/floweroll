import Observation
import SwiftUI


@MainActor
@Observable
private final class RuntimeCanonicalTaskDetailRouteModel {
    private(set) var threadID: String?
    private(set) var isLoading = true
    private(set) var lastError: String?

    func resolve(
        taskID: String,
        knownThreadID: String?,
        store: RuntimeTaskStore
    ) async {
        threadID = nil
        lastError = nil
        isLoading = true
        defer { isLoading = false }

        if let knownThreadID = knownThreadID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !knownThreadID.isEmpty {
            threadID = knownThreadID
            return
        }
        if let indexed = store.allKnownTasks.first(where: { $0.taskID == taskID }) {
            threadID = indexed.threadID
            return
        }
        if let cached = store.cachedTaskView(taskID: taskID) {
            threadID = cached.task.threadID
            return
        }

        do {
            let snapshot = try await store.makeClient().fetchTaskView(taskID: taskID)
            let accepted = store.cacheTaskView(snapshot)
            threadID = accepted.task.threadID
            lastError = nil
        } catch {
            lastError = RuntimeTaskStore.userMessage(for: error)
        }
    }
}

/// Canonical product-level Task detail route.
///
/// The product presents one durable Thread detail surface regardless of whether
/// navigation starts from Home, Inbox, Task List, notification or deep link.
/// A Task ID is only the locator for the owning Thread; the page itself is the
/// Thread read model so every entry point shares the same status/cache semantics.
struct RuntimeCanonicalTaskDetailView: View {
    let taskID: String
    let knownThreadID: String?
    let store: RuntimeTaskStore
    let onBringToHome: () -> Void

    @State private var model = RuntimeCanonicalTaskDetailRouteModel()

    var body: some View {
        Group {
            if let threadID = model.threadID {
                RuntimeThreadDetailView(
                    threadID: threadID,
                    initialTaskID: taskID,
                    store: store,
                    onBringToHome: onBringToHome
                )
            } else if model.isLoading {
                ProgressView(RuntimeThreadRestorationPresentation.routeResolutionMessage)
            } else {
                RuntimeEmptyState(
                    title: "暂时无法读取任务历史",
                    message: model.lastError ?? "后台没有返回这条任务工作流。",
                    symbol: "clock.arrow.circlepath"
                )
                .padding(.horizontal, 18)
            }
        }
        .task(id: taskID + ":" + (knownThreadID ?? "")) {
            markSelectedTaskReviewedIfTerminal()
            await model.resolve(
                taskID: taskID,
                knownThreadID: knownThreadID,
                store: store
            )
            markSelectedTaskReviewedIfTerminal()
        }
    }

    private func markSelectedTaskReviewedIfTerminal() {
        if let indexed = store.allKnownTasks.first(where: { $0.taskID == taskID }),
           indexed.presentationTruth.isTerminal {
            store.terminalReviewState.markReviewed(taskIDs: [taskID])
            return
        }
        if let cached = store.cachedTaskView(taskID: taskID),
           cached.presentationTruth.isTerminal {
            store.terminalReviewState.markReviewed(taskIDs: [taskID])
        }
    }
}
