import Foundation
import Observation


enum RuntimeCompletionAttentionSurface: Equatable, Sendable {
    case home
    case tasks
    case taskDetail(taskID: String)
    case settings
    case other
}

struct RuntimeCompletionAttentionPresentation: Equatable, Sendable {
    let taskID: String
    let status: String
    let title: String
}

enum RuntimeCompletionAttentionNavigationDecision: Equatable, Sendable {
    case none
    case preserveExplicitTask(taskID: String)
    case openTask(taskID: String)
}

enum RuntimeCompletionAttentionConsumptionReason: Equatable, Sendable {
    case timeout
    case dismissed
    case viewed
}

struct RuntimeCompletionAttentionQueueState: Equatable, Sendable {
    private(set) var currentTaskID: String?
    private(set) var queuedTaskIDs: [String] = []

    @discardableResult
    mutating func enqueue(_ taskIDs: [String]) -> [String] {
        var accepted: [String] = []
        for taskID in taskIDs where !taskID.isEmpty {
            guard taskID != currentTaskID,
                  !queuedTaskIDs.contains(taskID)
            else { continue }
            accepted.append(taskID)
            if currentTaskID == nil {
                currentTaskID = taskID
            } else {
                queuedTaskIDs.append(taskID)
            }
        }
        return accepted
    }

    @discardableResult
    mutating func consumeCurrent() -> String? {
        guard let consumed = currentTaskID else { return nil }
        currentTaskID = queuedTaskIDs.isEmpty ? nil : queuedTaskIDs.removeFirst()
        return consumed
    }

    mutating func remove(_ taskIDs: Set<String>) {
        guard !taskIDs.isEmpty else { return }
        queuedTaskIDs.removeAll(where: taskIDs.contains)
        while let currentTaskID, taskIDs.contains(currentTaskID) {
            _ = consumeCurrent()
        }
    }

    mutating func clear() {
        currentTaskID = nil
        queuedTaskIDs.removeAll(keepingCapacity: false)
    }
}

enum RuntimeCompletionAttentionPolicy {
    static func shouldEnqueue(
        taskID: String,
        status: String,
        completedAt: Date?,
        sessionStartedAt: Date,
        acknowledgedTaskIDs: Set<String>,
        seenTaskIDs: Set<String>,
        consumedTaskIDs: Set<String>
    ) -> Bool {
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedStatus == "completed" || normalizedStatus == "failed",
              !acknowledgedTaskIDs.contains(taskID),
              !seenTaskIDs.contains(taskID),
              !consumedTaskIDs.contains(taskID),
              let completedAt,
              completedAt >= sessionStartedAt
        else { return false }
        return true
    }

    static func orderedFIFO(_ tasks: [HostTaskIndexItem]) -> [HostTaskIndexItem] {
        tasks.sorted { lhs, rhs in
            let lhsDate = RuntimeTaskStore.hostDate(lhs.updatedAt)
            let rhsDate = RuntimeTaskStore.hostDate(rhs.updatedAt)
            switch (lhsDate, rhsDate) {
            case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                return lhsDate < rhsDate
            case (nil, nil) where lhs.updatedAt != rhs.updatedAt:
                return lhs.updatedAt < rhs.updatedAt
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.taskID < rhs.taskID
            }
        }
    }

    static func navigationDecision(
        explicitTaskDetailID: String?,
        attentionTaskID: String?
    ) -> RuntimeCompletionAttentionNavigationDecision {
        if let explicitTaskDetailID = normalizedTaskID(explicitTaskDetailID) {
            return .preserveExplicitTask(taskID: explicitTaskDetailID)
        }
        if let attentionTaskID = normalizedTaskID(attentionTaskID) {
            return .openTask(taskID: attentionTaskID)
        }
        return .none
    }

    /// OS `notify.user` delivery is an independent attention channel. Its
    /// delivery/readback must never mutate or suppress the single in-app owner.
    static func shouldSuppressInAppAttentionForSystemNotification(
        delivered: Bool
    ) -> Bool {
        _ = delivered
        return false
    }

    private static func normalizedTaskID(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
