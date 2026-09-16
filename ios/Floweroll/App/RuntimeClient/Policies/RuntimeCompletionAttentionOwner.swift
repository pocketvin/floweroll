import Foundation
import Observation



@MainActor
@Observable
final class RuntimeCompletionAttentionOwner {
    nonisolated static let acknowledgedDefaultsKey = "floweroll.homeAcknowledgedTerminalTaskIDs"
    nonisolated static let seenDefaultsKey = "floweroll.homeSeenTerminalTaskIDs"

    private let defaults: UserDefaults
    private(set) var sessionStartedAt: Date
    private(set) var queue = RuntimeCompletionAttentionQueueState()
    private(set) var consumedTaskIDs: Set<String> = []
    private(set) var lastConsumptionReason: RuntimeCompletionAttentionConsumptionReason?
    private var latestTaskByID: [String: HostTaskIndexItem] = [:]

    init(defaults: UserDefaults = .standard, sessionStartedAt: Date = Date()) {
        self.defaults = defaults
        self.sessionStartedAt = sessionStartedAt
    }

    var currentTaskID: String? {
        queue.currentTaskID
    }

    var queuedTaskIDs: [String] {
        queue.queuedTaskIDs
    }

    var acknowledgedTaskIDs: Set<String> {
        Self.loadTaskIDs(defaults: defaults, key: Self.acknowledgedDefaultsKey)
    }

    var seenTaskIDs: Set<String> {
        Self.loadTaskIDs(defaults: defaults, key: Self.seenDefaultsKey)
    }

    func beginAppSession(at date: Date = Date()) {
        sessionStartedAt = date
        queue.clear()
        consumedTaskIDs.removeAll(keepingCapacity: false)
        latestTaskByID.removeAll(keepingCapacity: false)
        lastConsumptionReason = nil
    }

    func reconcile(readModel: RuntimeCompletionAttentionReadModel) {
        let acknowledged = acknowledgedTaskIDs
        let seen = seenTaskIDs
        queue.remove(acknowledged)

        for task in readModel.terminalTasks where RuntimeTaskStore.isTerminalStatus(task.status) {
            latestTaskByID[task.taskID] = task
        }

        let eligible = RuntimeCompletionAttentionPolicy.orderedFIFO(readModel.terminalTasks)
            .filter { task in
                RuntimeCompletionAttentionPolicy.shouldEnqueue(
                    taskID: task.taskID,
                    status: task.status,
                    completedAt: RuntimeTaskStore.hostDate(task.updatedAt),
                    sessionStartedAt: sessionStartedAt,
                    acknowledgedTaskIDs: acknowledged,
                    seenTaskIDs: seen,
                    consumedTaskIDs: consumedTaskIDs
                )
            }
            .map(\.taskID)
        _ = queue.enqueue(eligible)
    }

    func presentation(
        on surface: RuntimeCompletionAttentionSurface
    ) -> RuntimeCompletionAttentionPresentation? {
        _ = surface
        guard let taskID = queue.currentTaskID,
              let task = latestTaskByID[taskID]
        else { return nil }
        return RuntimeCompletionAttentionPresentation(
            taskID: task.taskID,
            status: task.status,
            title: task.title
        )
    }

    func markPresented(taskID: String) {
        guard queue.currentTaskID == taskID else { return }
        var seen = seenTaskIDs
        seen.insert(taskID)
        Self.persistTaskIDs(seen, defaults: defaults, key: Self.seenDefaultsKey)
    }

    @discardableResult
    func timeoutCurrent() -> String? {
        consumeCurrent(reason: .timeout)
    }

    @discardableResult
    func dismissCurrent() -> String? {
        consumeCurrent(reason: .dismissed)
    }

    func viewCurrent(
        explicitTaskDetailID: String? = nil
    ) -> RuntimeCompletionAttentionNavigationDecision {
        let decision = RuntimeCompletionAttentionPolicy.navigationDecision(
            explicitTaskDetailID: explicitTaskDetailID,
            attentionTaskID: queue.currentTaskID
        )
        guard case .openTask = decision else { return decision }
        _ = consumeCurrent(reason: .viewed)
        return decision
    }

    func acknowledge(taskIDs: [String]) {
        let normalized = Set(taskIDs.compactMap { rawValue -> String? in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        })
        guard !normalized.isEmpty else { return }

        var acknowledged = acknowledgedTaskIDs
        acknowledged.formUnion(normalized)
        Self.persistTaskIDs(
            acknowledged,
            defaults: defaults,
            key: Self.acknowledgedDefaultsKey
        )
        consumedTaskIDs.formUnion(normalized)
        queue.remove(normalized)
    }

    private func consumeCurrent(
        reason: RuntimeCompletionAttentionConsumptionReason
    ) -> String? {
        guard let taskID = queue.consumeCurrent() else { return nil }
        consumedTaskIDs.insert(taskID)
        lastConsumptionReason = reason
        return taskID
    }

    nonisolated private static func loadTaskIDs(
        defaults: UserDefaults,
        key: String
    ) -> Set<String> {
        guard let raw = defaults.string(forKey: key),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Set<String>.self, from: data)
        else { return [] }
        return decoded
    }

    nonisolated private static func persistTaskIDs(
        _ taskIDs: Set<String>,
        defaults: UserDefaults,
        key: String
    ) {
        guard let data = try? JSONEncoder().encode(taskIDs),
              let raw = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(raw, forKey: key)
    }
}
