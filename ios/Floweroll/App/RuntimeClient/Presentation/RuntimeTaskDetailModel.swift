import Observation
import SwiftUI



enum RuntimeTaskCancellationPresentation {
    static let terminalMessage = "已取消当前任务。"
    static let pendingMessage = "正在安全停止任务…"

    static func message(for result: RuntimeTaskCancellationResult) -> String {
        if !result.cancellationPending, result.status.lowercased() == "cancelled" {
            return terminalMessage
        }
        return pendingMessage
    }
}


@MainActor
@Observable
final class RuntimeTaskDetailModel {
    private(set) var view: HostTaskView?
    private(set) var materials: TaskMaterialManifest?
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var cancellationMessage: String?
    private(set) var isSending = false

    @ObservationIgnored
    private var updatesTask: Task<Void, Never>?
    @ObservationIgnored
    private var materialsTask: Task<Void, Never>?

    func seed(_ snapshot: HostTaskView) {
        view = snapshot
        isLoading = false
        lastError = nil
        cancellationMessage = nil
    }

    func start(
        taskID: String,
        store: RuntimeTaskStore,
        updateMode: RuntimeTaskDetailUpdateMode = .live
    ) {
        updatesTask?.cancel()
        materialsTask?.cancel()
        startMaterialsLoad(taskID: taskID, store: store)
        if view == nil, let cached = store.cachedTaskView(taskID: taskID) {
            seed(cached)
        }
        isLoading = view == nil
        lastError = nil

        if updateMode == .snapshotOnly {
            // Cached task detail is paint-only. Even a terminal Task must do one
            // authoritative /view read so result/pending/work state cannot remain
            // frozen at an older active snapshot after a bucket transition.
            updatesTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let snapshot = try await store.fetchTaskViewCoalesced(taskID: taskID)
                    guard !Task.isCancelled else { return }
                    adopt(snapshot, store: store)
                    await refreshGlobalIndexIfTerminal(store: store)
                    isLoading = false
                } catch {
                    if Self.isBenignCancellation(error) { return }
                    isLoading = false
                    lastError = RuntimeTaskStore.userMessage(for: error)
                }
            }
            return
        }

        updatesTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let client = try store.makeClient()
                var freshInitialSnapshot: HostTaskView?
                if view == nil {
                    let snapshot = try await store.fetchTaskViewCoalesced(taskID: taskID)
                    guard !Task.isCancelled else { return }
                    adopt(snapshot, store: store)
                    await refreshGlobalIndexIfTerminal(store: store)
                    freshInitialSnapshot = view
                    isLoading = false
                }
                let session = HostTaskLiveSession(
                    client: client,
                    taskID: taskID,
                    initialSnapshot: freshInitialSnapshot
                )
                for try await update in session.updates() {
                    guard !Task.isCancelled else { return }
                    switch update {
                    case let .snapshot(snapshot):
                        adopt(snapshot, store: store)
                        await refreshGlobalIndexIfTerminal(store: store)
                        isLoading = false
                    case let .presentation(event):
                        apply(event, store: store)
                    }
                }
                if view == nil {
                    let snapshot = try await client.fetchTaskView(taskID: taskID)
                    adopt(snapshot, store: store)
                    await refreshGlobalIndexIfTerminal(store: store)
                }
                isLoading = false
            } catch {
                if Self.isBenignCancellation(error) { return }
                isLoading = false
                lastError = RuntimeTaskStore.userMessage(for: error)
            }
        }
    }

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        materialsTask?.cancel()
        materialsTask = nil
    }

    private func startMaterialsLoad(taskID: String, store: RuntimeTaskStore) {
        materials = nil
        materialsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let delays: [UInt64] = [0, 250, 650, 1_200, 2_000]
            for delayMilliseconds in delays {
                if delayMilliseconds > 0 {
                    do {
                        try await Task.sleep(for: .milliseconds(delayMilliseconds))
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                do {
                    let manifest = try await store.makeClient().fetchTaskMaterials(taskID: taskID)
                    guard !Task.isCancelled else { return }
                    materials = manifest
                    return
                } catch {
                    // Task admission and material binding can become visible a
                    // fraction later than /view. Keep this retry model-owned so
                    // SwiftUI row reconstruction cannot silently cancel it.
                }
            }
        }
    }

    func refresh(taskID: String, store: RuntimeTaskStore) async {
        do {
            let client = try store.makeClient()
            let snapshot = try await client.fetchTaskView(taskID: taskID)
            adopt(snapshot, store: store)
            await refreshGlobalIndexIfTerminal(store: store)
            lastError = nil
        } catch {
            if Self.isBenignCancellation(error) { return }
            lastError = RuntimeTaskStore.userMessage(for: error)
        }
    }

    func retryPausedTask(taskID: String, store: RuntimeTaskStore) async -> Bool {
        guard !isSending else { return false }
        isSending = true
        defer { isSending = false }
        do {
            _ = try await store.retryPausedTask(taskID: taskID)
            let snapshot = try await store.makeClient().fetchTaskView(taskID: taskID)
            adopt(snapshot, store: store)
            lastError = nil
            return true
        } catch {
            if Self.isBenignCancellation(error) { return false }
            lastError = RuntimeTaskStore.userMessage(for: error)
            return false
        }
    }

    func sendUserTurn(taskID: String, text: String, store: RuntimeTaskStore) async -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return await perform(taskID: taskID, store: store) { client in
            _ = try await client.sendUserTurn(taskID: taskID, text: normalized)
        }
    }

    func respondToClarification(
        taskID: String,
        clarificationID: String,
        optionID: String? = nil,
        text: String? = nil,
        store: RuntimeTaskStore
    ) async -> Bool {
        await perform(taskID: taskID, store: store) { client in
            _ = try await client.respondToClarification(
                taskID: taskID,
                clarificationID: clarificationID,
                optionID: optionID,
                text: text
            )
        }
    }

    func respondToActionInput(
        taskID: String,
        inputRequestID: String,
        bindingDigest: String,
        response: [String: JSONValue],
        store: RuntimeTaskStore
    ) async -> Bool {
        await perform(taskID: taskID, store: store, resumeInBackground: response["approved"] != .bool(false)) { client in
            _ = try await client.respondToActionInput(
                taskID: taskID,
                inputRequestID: inputRequestID,
                bindingDigest: bindingDigest,
                response: response
            )
        }
    }

    func cancelUsingStore(
        taskID: String,
        store: RuntimeTaskStore,
        reason: String = "用户从小卷任务详情取消"
    ) async -> RuntimeTaskCancellationResult? {
        guard !isSending else { return nil }
        isSending = true
        defer { isSending = false }
        do {
            let result = try await store.cancelTask(taskID: taskID, reason: reason)
            if let snapshot = store.cachedTaskView(taskID: taskID) {
                adopt(snapshot, store: store)
            }
            cancellationMessage = RuntimeTaskCancellationPresentation.message(for: result)
            lastError = nil
            return result
        } catch {
            if Self.isBenignCancellation(error) { return nil }
            cancellationMessage = nil
            lastError = RuntimeTaskStore.userMessage(for: error)
            return nil
        }
    }


    private func perform(
        taskID: String,
        store: RuntimeTaskStore,
        resumeInBackground: Bool = false,
        operation: (FlowerollHostClient) async throws -> Void
    ) async -> Bool {
        guard !isSending else { return false }
        isSending = true
        defer { isSending = false }
        do {
            let client = try store.makeClient()
            try await operation(client)
            if resumeInBackground {
                // User confirmation renews durable recovery before read-side refresh.
                // The in-app BGCPT lane remains the preferred execution
                // owner while it is alive; BGProcessing preserves resumability
                // if the system has already reclaimed that session.
                await store.renewBackgroundExecution(taskID: taskID)
            }
            let snapshot = try await client.fetchTaskView(taskID: taskID)
            adopt(snapshot, store: store)
            lastError = nil
            await store.refresh()
            return true
        } catch {
            if Self.isBenignCancellation(error) { return false }
            lastError = RuntimeTaskStore.userMessage(for: error)
            return false
        }
    }

    private func refreshGlobalIndexIfTerminal(store: RuntimeTaskStore) async {
        guard let view, RuntimeTaskStore.isTerminalStatus(view.task.status) else { return }
        // The detail/live stream owns the earliest authoritative terminal view.
        // Promote that boundary into the global running/history index immediately
        // instead of waiting for Home's opportunistic 3-second poll (which may
        // itself be skipped while the store is busy).
        await store.refreshPresentationIndex()
    }

    private static func isBenignCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func adopt(_ snapshot: HostTaskView, store: RuntimeTaskStore) {
        let canonical = store.cacheTaskView(snapshot)
        if let current = view, current.task.taskID == canonical.task.taskID {
            view = RuntimeTaskPresentationReducer.preferred(
                existing: current,
                incoming: canonical
            )
        } else {
            view = canonical
        }
    }

    private func apply(_ event: HostPresentationEvent, store: RuntimeTaskStore) {
        guard let current = view,
              RuntimeTaskPresentationReducer.shouldApply(event: event, to: current)
        else { return }
        var timeline = current.timeline
        if let index = timeline.firstIndex(where: { $0.timelineItemID == event.payload.timelineItemID }) {
            let existing = timeline[index]
            if event.payload.revision >= existing.revision {
                timeline[index] = HostTimelineItem(
                    timelineItemID: existing.timelineItemID,
                    displayOrder: existing.displayOrder,
                    kind: event.payload.kind,
                    presentationState: event.payload.presentationState,
                    title: event.payload.title,
                    summary: event.payload.summary,
                    payload: event.payload.payload,
                    revision: event.payload.revision,
                    createdAt: existing.createdAt,
                    updatedAt: event.createdAt
                )
            }
        } else {
            let nextOrder = (timeline.map(\.displayOrder).max() ?? 0) + 1
            timeline.append(
                HostTimelineItem(
                    timelineItemID: event.payload.timelineItemID,
                    displayOrder: nextOrder,
                    kind: event.payload.kind,
                    presentationState: event.payload.presentationState,
                    title: event.payload.title,
                    summary: event.payload.summary,
                    payload: event.payload.payload,
                    revision: event.payload.revision,
                    createdAt: event.createdAt,
                    updatedAt: event.createdAt
                )
            )
        }
        let projected = HostTaskView(
            task: current.task,
            runtime: current.runtime,
            timeline: timeline.sorted { $0.displayOrder < $1.displayOrder },
            artifacts: current.artifacts,
            pendingInteraction: current.pendingInteraction,
            result: current.result,
            presentationCursor: max(current.presentationCursor, event.seq),
            workSummary: current.workSummary
        )
        view = store.cacheTaskView(projected)
    }
}
