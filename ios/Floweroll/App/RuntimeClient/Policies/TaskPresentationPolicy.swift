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



/// Durable business lifecycle reported by Host Task truth.
///
/// This deliberately does NOT contain `needsUser`: needing user input is an
/// orthogonal interaction dimension and may coexist with an active Task while
/// already-authorized work continues.
enum RuntimeTaskLifecycle: Equatable, Sendable {
    case active
    case waiting
    case blocked
    case completed
    case failed
    case cancelled
    case unknown

    init(hostStatus: String) {
        switch hostStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "active": self = .active
        case "waiting", "needs_user": self = .waiting
        case "blocked": self = .blocked
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        default: self = .unknown
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .active, .waiting, .blocked, .unknown: return false
        }
    }
}


/// Pending user interaction is not a Task lifecycle state.
enum RuntimeTaskInteractionState: Equatable, Sendable {
    case none
    case clarification
    case actionInput
    /// Task Index and legacy `needs_user` status can prove that input is needed
    /// without carrying the typed interaction payload.
    case needsUserHint

    var requiresUser: Bool { self != .none }
}


/// Canonical, orthogonal state dimensions derived from Host truth.
struct RuntimeTaskStateDimensions: Equatable, Sendable {
    let lifecycle: RuntimeTaskLifecycle
    let interaction: RuntimeTaskInteractionState

    init(
        status: String,
        needsUserHint: Bool = false,
        pendingInteraction: HostPendingInteraction? = nil,
        hasRawPendingInteraction: Bool = false
    ) {
        let lifecycle = RuntimeTaskLifecycle(hostStatus: status)
        self.lifecycle = lifecycle

        // Terminal Host truth is absorbing. A stale interaction payload cannot
        // resurrect a completed/failed/cancelled Task as user-waiting.
        guard !lifecycle.isTerminal else {
            interaction = .none
            return
        }

        if let pendingInteraction {
            switch pendingInteraction {
            case .clarification: interaction = .clarification
            case .actionInput: interaction = .actionInput
            }
        } else if needsUserHint
                    || hasRawPendingInteraction
                    || status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "needs_user" {
            interaction = .needsUserHint
        } else {
            interaction = .none
        }
    }

    var displayState: RuntimeTaskPresentationState {
        switch lifecycle {
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .unknown: return .paused
        case .active, .waiting, .blocked: break
        }

        if interaction.requiresUser { return .needsUser }
        switch lifecycle {
        case .blocked: return .paused
        case .waiting: return .waiting
        case .active: return .active
        case .unknown:
            assertionFailure("unknown lifecycle handled above")
            return .paused
        case .completed, .failed, .cancelled:
            assertionFailure("terminal lifecycle handled above")
            return .active
        }
    }
}


/// Whether a nonterminal Task still benefits from an iPhone execution/recovery
/// window. This is deliberately separate from UI activity: a Task can remain
/// visible as nonterminal while it is paused or genuinely waiting for the user.
enum RuntimeTaskExecutionEligibilityPolicy {
    static func requiresDeviceExecution(_ state: RuntimeTaskStateDimensions) -> Bool {
        switch state.lifecycle {
        case .active:
            return true
        case .waiting:
            return !state.interaction.requiresUser
        case .blocked:
            return false
        case .completed, .failed, .cancelled:
            return false
        case .unknown:
            return false
        }
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
    let dimensions: RuntimeTaskStateDimensions

    var lifecycle: RuntimeTaskLifecycle { dimensions.lifecycle }
    var interaction: RuntimeTaskInteractionState { dimensions.interaction }
    var state: RuntimeTaskPresentationState { dimensions.displayState }
    var isTerminal: Bool { state.isTerminal }
    var statusLabel: String { state.statusLabel }

    static func taskStatus(
        _ status: String,
        needsUser: Bool = false,
        hasPendingInteraction: Bool = false
    ) -> RuntimeTaskPresentationTruth {
        RuntimeTaskPresentationTruth(
            dimensions: RuntimeTaskStateDimensions(
                status: status,
                needsUserHint: needsUser,
                hasRawPendingInteraction: hasPendingInteraction
            )
        )
    }
}

enum RuntimeTaskRetryPolicy {
    nonisolated static func canRetry(_ view: HostTaskView) -> Bool {
        view.presentationTruth.lifecycle == .blocked
            && !view.presentationTruth.interaction.requiresUser
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
        RuntimeTaskPresentationTruth(
            dimensions: RuntimeTaskStateDimensions(
                status: status,
                needsUserHint: needsUser
            )
        )
    }
}

extension HostTaskView {
    var runtimeStateDimensions: RuntimeTaskStateDimensions {
        RuntimeTaskStateDimensions(
            status: task.status,
            pendingInteraction: typedPendingInteraction,
            hasRawPendingInteraction: pendingInteraction != nil
        )
    }

    var presentationTruth: RuntimeTaskPresentationTruth {
        RuntimeTaskPresentationTruth(dimensions: runtimeStateDimensions)
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
