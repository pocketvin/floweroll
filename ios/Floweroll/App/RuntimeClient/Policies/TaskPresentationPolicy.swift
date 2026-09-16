import Foundation
import Observation


struct TaskTabRootNavigationState: Equatable {
    private(set) var generation = 0

    mutating func userSelectedTasksTab() {
        generation &+= 1
    }
}

enum RuntimeTaskDetailUpdateMode: Equatable {
    case snapshotOnly
    case live
}

enum RuntimeTaskDetailUpdatePolicy {
    static func mode(task: HostTaskIndexItem, liveTaskID: String?) -> RuntimeTaskDetailUpdateMode {
        guard !RuntimeTaskStore.isTerminalStatus(task.status),
              task.taskID == liveTaskID
        else {
            return .snapshotOnly
        }
        return .live
    }
}



enum RuntimeTaskPresentationState: String, Equatable, Sendable {
    case active
    case waiting
    case paused
    case needsUser
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .active, .waiting, .paused, .needsUser: return false
        }
    }

    var statusLabel: String {
        switch self {
        case .active: return "处理中"
        case .waiting: return "等待中"
        case .paused: return "已暂停"
        case .needsUser: return "需要你"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    fileprivate var tieBreakRank: Int {
        switch self {
        case .active: return 0
        case .waiting: return 1
        case .paused: return 2
        case .needsUser: return 3
        case .cancelled: return 4
        case .failed: return 5
        case .completed: return 6
        }
    }
}

struct RuntimeTaskPresentationTruth: Equatable, Sendable {
    let state: RuntimeTaskPresentationState

    var isTerminal: Bool { state.isTerminal }
    var statusLabel: String { state.statusLabel }

    static func taskStatus(
        _ status: String,
        needsUser: Bool = false,
        hasPendingInteraction: Bool = false
    ) -> RuntimeTaskPresentationTruth {
        // Durable Task terminal state is absorbing. Presentation hints, stale
        // interaction state and local acknowledgement can never downgrade it.
        switch status.lowercased() {
        case "completed": return RuntimeTaskPresentationTruth(state: .completed)
        case "failed": return RuntimeTaskPresentationTruth(state: .failed)
        case "cancelled": return RuntimeTaskPresentationTruth(state: .cancelled)
        default: break
        }

        if needsUser || hasPendingInteraction {
            return RuntimeTaskPresentationTruth(state: .needsUser)
        }
        if status.lowercased() == "blocked" {
            return RuntimeTaskPresentationTruth(state: .paused)
        }
        if status.lowercased() == "waiting" {
            return RuntimeTaskPresentationTruth(state: .waiting)
        }
        return RuntimeTaskPresentationTruth(state: .active)
    }
}

enum RuntimeTaskRetryPolicy {
    nonisolated static func canRetry(_ view: HostTaskView) -> Bool {
        view.presentationTruth.state == .paused
            && view.typedPendingInteraction == nil
            && view.runtime?.blockReason == "planner_runtime_error"
    }
}

enum RuntimeTaskComposerPolicy {
    nonisolated static func showsGenericComposer(
        isTerminal: Bool,
        hasPendingInteraction: Bool
    ) -> Bool {
        !isTerminal && !hasPendingInteraction
    }
}

extension HostTaskIndexItem {
    var presentationTruth: RuntimeTaskPresentationTruth {
        .taskStatus(status, needsUser: needsUser)
    }
}

extension HostTaskView {
    var presentationTruth: RuntimeTaskPresentationTruth {
        .taskStatus(
            task.status,
            hasPendingInteraction: pendingInteraction != nil
        )
    }
}

enum RuntimeTaskDetailRoutePolicy {
    /// Explicit user navigation/deep-link ownership outranks a queued notification route.
    /// A pending notification is consumed only when no Task detail is currently owned.
    nonisolated static func shouldConsumePendingNotification(
        currentLinkedTaskID: String?,
        tasksTabIsActive: Bool = false
    ) -> Bool {
        currentLinkedTaskID == nil && !tasksTabIsActive
    }

    /// Re-drive a persisted notification route only on the exact ownership
    /// transition from blocked to unowned. This avoids polling and avoids
    /// replaying a consumed route on unrelated state changes.
    nonisolated static func shouldRedrivePendingNotification(
        previousLinkedTaskID: String?,
        currentLinkedTaskID: String?,
        previousTasksTabIsActive: Bool,
        currentTasksTabIsActive: Bool
    ) -> Bool {
        let wasBlocked = !shouldConsumePendingNotification(
            currentLinkedTaskID: previousLinkedTaskID,
            tasksTabIsActive: previousTasksTabIsActive
        )
        let isNowUnowned = shouldConsumePendingNotification(
            currentLinkedTaskID: currentLinkedTaskID,
            tasksTabIsActive: currentTasksTabIsActive
        )
        return wasBlocked && isNowUnowned
    }
}


enum RuntimeTaskPresentationReducer {
    static func preferred(
        existing: HostTaskIndexItem,
        incoming: HostTaskIndexItem
    ) -> HostTaskIndexItem {
        precondition(existing.taskID == incoming.taskID)
        let lhs = normalized(existing)
        let rhs = normalized(incoming)
        let lhsTruth = lhs.presentationTruth
        let rhsTruth = rhs.presentationTruth

        if lhsTruth.isTerminal != rhsTruth.isTerminal {
            return lhsTruth.isTerminal ? lhs : rhs
        }
        switch compareDates(lhs.updatedAt, rhs.updatedAt) {
        case .orderedAscending: return rhs
        case .orderedDescending: return lhs
        case .orderedSame:
            if lhsTruth.state.tieBreakRank != rhsTruth.state.tieBreakRank {
                return lhsTruth.state.tieBreakRank > rhsTruth.state.tieBreakRank ? lhs : rhs
            }
            return rhs
        }
    }

    static func preferred(
        existing: HostTaskView,
        incoming: HostTaskView
    ) -> HostTaskView {
        precondition(existing.task.taskID == incoming.task.taskID)
        let lhsTruth = existing.presentationTruth
        let rhsTruth = incoming.presentationTruth
        if lhsTruth.isTerminal != rhsTruth.isTerminal {
            return lhsTruth.isTerminal ? existing : incoming
        }
        switch compareDates(existing.task.updatedAt, incoming.task.updatedAt) {
        case .orderedAscending: return incoming
        case .orderedDescending: return existing
        case .orderedSame:
            if existing.presentationCursor != incoming.presentationCursor {
                return existing.presentationCursor > incoming.presentationCursor ? existing : incoming
            }
            if lhsTruth.state.tieBreakRank != rhsTruth.state.tieBreakRank {
                return lhsTruth.state.tieBreakRank > rhsTruth.state.tieBreakRank ? existing : incoming
            }
            return incoming
        }
    }

    static func truth(
        indexItem: HostTaskIndexItem?,
        view: HostTaskView?
    ) -> RuntimeTaskPresentationTruth? {
        guard let indexItem else { return view?.presentationTruth }
        guard let view, view.task.taskID == indexItem.taskID else {
            return indexItem.presentationTruth
        }
        let indexTruth = indexItem.presentationTruth
        let viewTruth = view.presentationTruth
        if indexTruth.isTerminal != viewTruth.isTerminal {
            return indexTruth.isTerminal ? indexTruth : viewTruth
        }
        switch compareDates(indexItem.updatedAt, view.task.updatedAt) {
        case .orderedAscending: return viewTruth
        case .orderedDescending: return indexTruth
        case .orderedSame:
            return indexTruth.state.tieBreakRank >= viewTruth.state.tieBreakRank
                ? indexTruth
                : viewTruth
        }
    }

    static func normalized(_ item: HostTaskIndexItem) -> HostTaskIndexItem {
        let truth = item.presentationTruth
        let bucket: String
        switch truth.state {
        case .completed, .failed, .cancelled:
            bucket = "history"
        case .needsUser:
            bucket = "needs_user"
        case .active, .waiting, .paused:
            bucket = "running"
        }
        let normalizedNeedsUser = truth.state == .needsUser
        guard item.bucket != bucket || item.needsUser != normalizedNeedsUser else {
            return item
        }
        return HostTaskIndexItem(
            taskID: item.taskID,
            submissionID: item.submissionID,
            threadID: item.threadID,
            parentTaskID: item.parentTaskID,
            title: item.title,
            goal: item.goal,
            status: item.status,
            phase: item.phase,
            bucket: bucket,
            needsUser: normalizedNeedsUser,
            latestTimeline: item.latestTimeline,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt
        )
    }

    static func terminalizingCachedView(
        _ view: HostTaskView,
        indexItem: HostTaskIndexItem?
    ) -> HostTaskView {
        guard let indexItem,
              indexItem.taskID == view.task.taskID,
              indexItem.presentationTruth.isTerminal,
              !view.presentationTruth.isTerminal
        else { return view }

        let task = HostTask(
            taskID: view.task.taskID,
            submissionID: view.task.submissionID,
            threadID: view.task.threadID,
            parentTaskID: view.task.parentTaskID,
            goal: view.task.goal,
            status: indexItem.status,
            currentStep: view.task.currentStep,
            idempotentReplay: view.task.idempotentReplay,
            createdAt: view.task.createdAt,
            updatedAt: indexItem.updatedAt
        )
        return HostTaskView(
            task: task,
            runtime: view.runtime,
            timeline: view.timeline,
            artifacts: view.artifacts,
            pendingInteraction: nil,
            result: view.result,
            presentationCursor: view.presentationCursor,
            workSummary: view.workSummary
        )
    }

    static func shouldApply(
        event: HostPresentationEvent,
        to view: HostTaskView
    ) -> Bool {
        event.taskID == view.task.taskID
            && event.seq > view.presentationCursor
            && !view.presentationTruth.isTerminal
    }

    private static func compareDates(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let lhsDate = hostDate(lhs), let rhsDate = hostDate(rhs) {
            return lhsDate.compare(rhsDate)
        }
        return lhs.compare(rhs)
    }

    private static func hostDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = fractional.date(from: raw) { return value }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
