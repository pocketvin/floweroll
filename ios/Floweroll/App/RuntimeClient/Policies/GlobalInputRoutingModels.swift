import Foundation
import Observation



struct FlowerollPendingInteractionOption: Equatable, Sendable {
    let id: String
    let label: String
}


enum FlowerollPendingInteractionKind: Equatable, Sendable {
    case clarification
    case actionInput
}


struct FlowerollPendingInteractionRoutingContext: Equatable, Sendable {
    let kind: FlowerollPendingInteractionKind
    let id: String
    let prompt: String
    let options: [FlowerollPendingInteractionOption]
    let acceptsText: Bool
    let actionAttemptID: String?
    let bindingDigest: String?
}


struct FlowerollRoutingReferentSourceSnapshot: Equatable, Sendable {
    let taskID: String
    let taskUpdatedAt: String
    let goal: String
    let brief: String
}


enum FlowerollContextReferentKind: String, Equatable, Sendable {
    case company
}


struct FlowerollTaskContextCarryover: Equatable, Sendable {
    struct Binding: Equatable, Sendable {
        let mention: String
        let kind: FlowerollContextReferentKind
        let value: String
        let sourceTaskID: String
        let sourceTaskUpdatedAt: String
    }

    let binding: Binding
    let materializedText: String
}


struct FlowerollGlobalInputResolution: Equatable, Sendable {
    let route: FlowerollGlobalInputRoute
    let newTaskCarryover: FlowerollTaskContextCarryover?

    func textForNewTask(fallback: String) -> String {
        newTaskCarryover?.materializedText ?? fallback
    }
}


struct FlowerollGlobalInputRoutingContext: Equatable, Sendable {
    struct CurrentTask: Equatable, Sendable {
        let taskID: String
        let goal: String
        let pendingInteraction: FlowerollPendingInteractionRoutingContext?
        let referentSource: FlowerollRoutingReferentSourceSnapshot?

        init(
            taskID: String,
            goal: String,
            pendingInteraction: FlowerollPendingInteractionRoutingContext?,
            referentSource: FlowerollRoutingReferentSourceSnapshot? = nil
        ) {
            self.taskID = taskID
            self.goal = goal
            self.pendingInteraction = pendingInteraction
            self.referentSource = referentSource
        }
    }

    let currentTask: CurrentTask?

    static let none = FlowerollGlobalInputRoutingContext(currentTask: nil)
}


enum FlowerollPendingInteractionResponse: Equatable, Sendable {
    case text(String)
    case option(id: String)
    case approval(Bool)
}


enum FlowerollCurrentTaskOperation: Equatable, Sendable {
    case userTurn(text: String)
    case pendingInteraction(
        interaction: FlowerollPendingInteractionRoutingContext,
        response: FlowerollPendingInteractionResponse
    )
}


enum FlowerollGlobalInputRoute: Equatable, Sendable {
    case newTask
    case steerCurrentTask(taskID: String)
    case answerPendingInteraction(
        taskID: String,
        interaction: FlowerollPendingInteractionRoutingContext,
        response: FlowerollPendingInteractionResponse
    )
    case mixed(
        currentTaskID: String,
        currentOperation: FlowerollCurrentTaskOperation,
        newTaskText: String
    )
}


/// Global Home / Action Button input is a new Task by default.
///
/// Merely having an active Task never grants it capture rights. A global input
/// can target the current Home Task only when the utterance is a high-confidence
/// contextual continuation/control, or when it is a bounded answer to the exact
/// pending Clarification / ActionInput supplied in `context`.
///
/// Mixed current-task + independent-goal input is represented explicitly; the
/// caller must execute or explicitly escalate both halves rather than silently
/// choosing one.
enum FlowerollDirectTaskControlPolicy {
    private static let cancelCommands: Set<String> = [
        "取消", "停止", "停止任务", "取消任务",
        "停止当前任务", "取消当前任务", "停止这个任务", "取消这个任务", "取消整个任务",
        "别做了", "不用了", "先停下", "stop", "cancel"
    ]

    static func isCancelCommand(_ rawText: String) -> Bool {
        let normalized = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。！？!?，,"))
            .lowercased()
        return cancelCommands.contains(normalized)
    }
}
