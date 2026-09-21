import Foundation
import OSLog


struct SystemEntryRuntimeProgressUpdate: Sendable, Equatable {
    let completedUnitCount: Int64
    let totalUnitCount: Int64
    let title: String
    let subtitle: String
}


/// Progress reported to Apple's system-owned long-running presentation.
///
/// Host `work_summary` remains the source of truth for verified work-item
/// completion. The system presentation needs a finite denominator in order to
/// keep its native progress bar visible before the Planner has produced a
/// verified work plan, so this policy maps Runtime lifecycle phases onto a
/// stable 100-unit presentation scale. The value is presentation-only and is
/// never written back into Host Task/work-item truth.
enum SystemEntryProgressPresentationPolicy {
    static let totalUnitCount: Int64 = 100
    static let admittedUnitCount: Int64 = 5
    static let activeFloorUnitCount: Int64 = 12
    static let activeCeilingUnitCount: Int64 = 95

    static func counts(from view: HostTaskView) -> (completed: Int64, total: Int64) {
        let state = view.runtimeStateDimensions
        // Terminal Host truth and a durable blocked/pause boundary end the
        // current system presentation session.
        switch state.lifecycle {
        case .completed, .cancelled, .failed, .blocked:
            return (totalUnitCount, totalUnitCount)
        case .active, .waiting, .unknown:
            break
        }
        if state.interaction.requiresUser {
            // Waiting for the person is not business completion. Keep the
            // system progress visibly unfinished until Host reaches a terminal
            // state or iOS ends this execution session.
            return (activeCeilingUnitCount, totalUnitCount)
        }

        // ACTIVE and WAITING without a user-input boundary remain real work.
        // Prefer Host-verified work counts; never invent time-based progress.
        guard let summary = view.workSummary,
              let fraction = summary.fraction
        else {
            return (activeFloorUnitCount, totalUnitCount)
        }
        let bounded = min(1, max(0, fraction))
        let span = activeCeilingUnitCount - activeFloorUnitCount
        let mapped = activeFloorUnitCount
            + Int64((Double(span) * bounded).rounded(.down))
        return (
            min(activeCeilingUnitCount, max(activeFloorUnitCount, mapped)),
            totalUnitCount
        )
    }
}


enum SystemEntryCancellationKind: Sendable, Equatable {
    case userCancelled
    case systemTimeout
    case systemInterruption
}


struct SystemEntryInputRoute: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case newTask
        case userTurn
        case followUp
    }

    let taskID: String
    let kind: Kind
    let ownsExecutionWindow: Bool
}




struct SystemEntryPreparedHomeInput: Sendable, Equatable {
    enum Target: Sendable, Equatable {
        case newTask(text: String)
        case currentTask(
            taskID: String,
            threadID: String,
            operation: FlowerollCurrentTaskOperation
        )
        case mixed(
            currentTaskID: String,
            currentThreadID: String,
            currentOperation: FlowerollCurrentTaskOperation,
            newTaskText: String
        )
    }

    let normalizedText: String
    let target: Target
}

enum TaskScopedOperation: Sendable, Equatable {
    case userTurn(text: String)
    case clarification(
        clarificationID: String,
        optionID: String?,
        text: String?
    )
    case actionInput(
        inputRequestID: String,
        bindingDigest: String,
        response: [String: JSONValue]
    )
}

struct SystemEntryRuntimeOutcome: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case completed
        case blocked
        case cancelled
        case failed
        case delegated
    }

    let taskID: String
    let state: State
    let message: String
}


/// Bridges an App Intent/system entry into the exact same durable Runtime used
/// by the foreground composer.
///
/// Host Task truth is shared by two execution lanes: system-entry LongRunningIntent and in-app BGCPT. This actor
/// owns only durable admission/routing and Host/device progress; Host state
/// remains authoritative if iOS ends the current execution session.
actor SystemEntryRuntimeCoordinator {
    static let shared = SystemEntryRuntimeCoordinator()

    private static let logger = Logger(
        subsystem: "com.maxenceyu.floweroll",
        category: "SystemEntryRuntime"
    )

    private let defaults: UserDefaults
    private let credentialStore: HostCredentialStore
    private let pendingStore: PendingSubmissionStore?
    private let deviceWorker: DeviceRuntimeWorker?
    private let session: URLSession
    private var activeExecutionTaskIDs = Set<String>()

    init(
        defaults: UserDefaults = .standard,
        credentialStore: HostCredentialStore = HostCredentialStore(),
        pendingStore: PendingSubmissionStore? = PendingSubmissionStore.shared,
        deviceWorker: DeviceRuntimeWorker? = DeviceRuntimeWorker.shared,
        session: URLSession = .shared
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        self.pendingStore = pendingStore
        self.deviceWorker = deviceWorker
        self.session = session
    }

    func submitAndRun(
        text: String,
        invocationSource: String = "ios_app_intent",
        executionWindowSeconds: TimeInterval? = 24,
        onProgress: (@Sendable (SystemEntryRuntimeProgressUpdate) async -> Void)? = nil
    ) async throws -> SystemEntryRuntimeOutcome {
        let taskID = try await submit(
            text: text,
            invocationSource: invocationSource
        )
        return try await runSubmittedTask(
            taskID: taskID,
            executionWindowSeconds: executionWindowSeconds,
            onProgress: onProgress
        )
    }

    /// Creates the durable Host Task and returns its identity before extended
    /// execution begins. iOS 27 cancellation therefore always targets the
    /// exact Task instead of racing task creation.
    func submit(
        text: String,
        invocationSource: String = "ios_app_intent"
    ) async throws -> String {
        guard let pendingStore else {
            throw RuntimeTaskStoreError.pendingStoreUnavailable
        }

        let client = try makeStoredClient()
        let task = try await client.submitDurably(
            text: text,
            invocationSource: invocationSource,
            pendingStore: pendingStore
        )
        let taskID = task.taskID
        defaults.set(taskID, forKey: RuntimeTaskStore.continuationTaskDefaultsKey)
        RuntimeTaskStore.persistHomePresentationSelection(
            defaults: defaults,
            threadID: task.threadID,
            ownership: .systemEntry
        )
        Self.logger.notice(
            "system entry submitted durable task; task=\(String(taskID.prefix(8)), privacy: .public)"
        )
        return taskID
    }

    /// Resolve Home routing without mutating durable state. The in-app caller requests BGCPT separately; route resolution itself must not create presentation ownership.
    func prepareHomeInput(text: String) async throws -> SystemEntryPreparedHomeInput {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw PendingSubmissionStoreError.emptyText }

        let client = try makeStoredClient()
        let current = try await resolveCurrentHomeActiveTask(client: client)
        let fetchedView: HostTaskView?
        if let current {
            fetchedView = try? await client.fetchTaskView(taskID: current.taskID)
        } else {
            fetchedView = nil
        }
        let context = Self.routingContext(current: current, view: fetchedView)
        let resolution = FlowerollGlobalInputRoutingPolicy.resolve(
            text: normalized,
            context: context
        )

        switch resolution.route {
        case let .steerCurrentTask(taskID):
            guard let current, current.taskID == taskID else {
                return .init(
                    normalizedText: normalized,
                    target: .newTask(text: resolution.textForNewTask(fallback: normalized))
                )
            }
            return .init(
                normalizedText: normalized,
                target: .currentTask(
                    taskID: taskID,
                    threadID: current.threadID,
                    operation: .userTurn(text: normalized)
                )
            )

        case let .answerPendingInteraction(taskID, interaction, response):
            guard let current, current.taskID == taskID else {
                return .init(normalizedText: normalized, target: .newTask(text: normalized))
            }
            return .init(
                normalizedText: normalized,
                target: .currentTask(
                    taskID: taskID,
                    threadID: current.threadID,
                    operation: .pendingInteraction(interaction: interaction, response: response)
                )
            )

        case let .mixed(currentTaskID, currentOperation, newTaskText):
            guard let current, current.taskID == currentTaskID else {
                return .init(normalizedText: normalized, target: .newTask(text: newTaskText))
            }
            return .init(
                normalizedText: normalized,
                target: .mixed(
                    currentTaskID: currentTaskID,
                    currentThreadID: current.threadID,
                    currentOperation: currentOperation,
                    newTaskText: newTaskText
                )
            )

        case .newTask:
            return .init(
                normalizedText: normalized,
                target: .newTask(text: resolution.textForNewTask(fallback: normalized))
            )
        }
    }

    /// Apply one exact task-scoped mutation with a caller-owned event id. Host
    /// idempotency remains authoritative if the system retries this Intent.
    func performTaskScopedOperation(
        taskID: String,
        eventID: String,
        operation: TaskScopedOperation
    ) async throws {
        let client = try makeStoredClient()
        switch operation {
        case let .userTurn(text):
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { throw PendingSubmissionStoreError.emptyText }
            guard let pendingStore else { throw RuntimeTaskStoreError.pendingStoreUnavailable }
            let pending = try await pendingStore.createUserTurn(
                taskID: taskID,
                text: normalized,
                eventID: eventID
            )
            await scheduleRecovery(reason: "task_scoped_user_turn_persisted")
            _ = try await client.submitExistingUserTurn(
                pending,
                pendingStore: pendingStore
            )

        case let .clarification(clarificationID, optionID, text):
            _ = try await client.respondToClarification(
                taskID: taskID,
                clarificationID: clarificationID,
                optionID: optionID,
                text: text,
                eventID: eventID
            )

        case let .actionInput(inputRequestID, bindingDigest, response):
            guard !bindingDigest.isEmpty else {
                throw NSError(
                    domain: "FlowerollTaskScopedOperation",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "当前确认请求缺少绑定信息。"]
                )
            }
            _ = try await client.respondToActionInput(
                taskID: taskID,
                inputRequestID: inputRequestID,
                bindingDigest: bindingDigest,
                response: response,
                eventID: eventID
            )
        }

        await trackDurableTask(taskID, reason: "task_scoped_operation_admitted")
        await scheduleRecovery(reason: "task_scoped_operation_admitted")
    }

    func submitInAppFollowUp(
        parentTaskID: String,
        text: String,
        submissionID: String
    ) async throws -> HostTask {
        guard let pendingStore else { throw RuntimeTaskStoreError.pendingStoreUnavailable }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw PendingSubmissionStoreError.emptyText }
        let pending = try await pendingStore.create(
            text: normalized,
            invocationSource: "ios_thread_in_app",
            parentTaskID: parentTaskID,
            submissionID: submissionID
        )
        await scheduleRecovery(reason: "thread_in_app_follow_up_persisted")
        let task = try await makeStoredClient().submitExisting(
            pending,
            pendingStore: pendingStore
        )
        persistHomeSelection(threadID: task.threadID, taskID: task.taskID)
        await trackDurableTask(task.taskID, reason: "thread_in_app_follow_up_admitted")
        return task
    }

    /// Admit prepared Home input from a foreground AppIntent after BGCPT has
    /// already been requested. The durable Host/outbox identity remains truth;
    /// background URLSession remains the attachment byte-transfer owner.
    func executePreparedHomeInput(
        _ prepared: SystemEntryPreparedHomeInput,
        submissionID: String,
        attachments: [PendingAttachment]
    ) async throws -> SystemEntryInputRoute {
        switch prepared.target {
        case let .newTask(text):
            let task = try await submitHomeTask(
                text: text,
                submissionID: submissionID,
                attachments: attachments
            )
            return .init(taskID: task.taskID, kind: .newTask, ownsExecutionWindow: false)

        case let .currentTask(taskID, threadID, operation):
            try await performHomeCurrentOperation(
                taskID: taskID,
                operation: operation,
                attachments: attachments,
                eventID: submissionID
            )
            persistHomeSelection(threadID: threadID, taskID: taskID)
            await trackDurableTask(taskID, reason: "home_in_app_current_input")
            return .init(taskID: taskID, kind: .userTurn, ownsExecutionWindow: false)

        case let .mixed(currentTaskID, currentThreadID, currentOperation, newTaskText):
            guard attachments.isEmpty else {
                throw MaterialsError.message("同时修改当前任务并创建新任务时，请把附件单独发送，避免材料归错任务。")
            }
            try await performHomeCurrentOperation(
                taskID: currentTaskID,
                operation: currentOperation,
                attachments: [],
                eventID: submissionID + "-current"
            )
            persistHomeSelection(threadID: currentThreadID, taskID: currentTaskID)
            let task = try await submitHomeTask(
                text: newTaskText,
                submissionID: submissionID,
                attachments: []
            )
            return .init(taskID: task.taskID, kind: .newTask, ownsExecutionWindow: false)
        }
    }

    /// Persist an exact current-task input without creating presentation ownership. The active execution lane (BGCPT or system-entry LongRunningIntent) consumes durable truth.
    func enqueuePreparedHomeInputWithoutNewExecutionWindow(
        _ prepared: SystemEntryPreparedHomeInput,
        submissionID: String,
        attachments: [PendingAttachment]
    ) async throws -> SystemEntryInputRoute {
        guard case let .currentTask(taskID, threadID, operation) = prepared.target else {
            throw NSError(
                domain: "FlowerollSystemEntry",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "只有已存在执行窗口的当前任务可以复用后台会话。"]
            )
        }
        switch operation {
        case let .userTurn(text):
            let client = try makeStoredClient()
            if FlowerollDirectTaskControlPolicy.isCancelCommand(text) {
                guard attachments.isEmpty else {
                    throw MaterialsError.message("取消任务时请先移除附件，避免材料归错任务。")
                }
                _ = try await client.cancelTask(
                    taskID: taskID,
                    eventID: submissionID,
                    reason: "用户从首页明确取消当前任务"
                )
                break
            }

            guard let pendingStore else { throw RuntimeTaskStoreError.pendingStoreUnavailable }
            let pending = try await pendingStore.createUserTurn(
                taskID: taskID,
                text: text,
                attachments: attachments,
                eventID: submissionID
            )
            // Persist before any network work. If this AppIntent is reclaimed,
            // BGProcessing/background-URLSession recovery can replay the exact
            // event_id without creating a second execution owner.
            await scheduleRecovery(reason: "home_joined_existing_user_turn_persisted")

            // Draft selection may already have started a background URLSession
            // upload. Explicit Send must not wait for iOS to schedule those
            // bytes: take over the same resumable file ID immediately, then
            // admit this exact user turn while the existing LongRunningIntent
            // continues to own task execution/presentation.
            for attachment in attachments {
                _ = try await client.uploadTaskAttachment(
                    attachment,
                    executionMode: .immediateResumable
                )
            }
            _ = try await client.submitExistingUserTurn(pending, pendingStore: pendingStore)
            let acceptedAttachmentIDs = Set(attachments.map(\.id))
            await MainActor.run {
                TaskAttachmentDraft.clearAcceptedReferences(acceptedAttachmentIDs)
            }
        case .pendingInteraction:
            guard attachments.isEmpty else {
                throw MaterialsError.message("回复确认时请先移除附件，避免材料归错任务。")
            }
            try await performHomeCurrentOperation(
                taskID: taskID,
                operation: operation,
                attachments: [],
                eventID: submissionID
            )
        }
        persistHomeSelection(threadID: threadID, taskID: taskID)
        await trackDurableTask(taskID, reason: "home_input_joined_existing_long_running")
        await scheduleRecovery(reason: "home_input_joined_existing_long_running")
        return .init(taskID: taskID, kind: .userTurn, ownsExecutionWindow: false)
    }

    private func submitHomeTask(
        text: String,
        submissionID: String,
        attachments: [PendingAttachment]
    ) async throws -> HostTask {
        guard let pendingStore else { throw RuntimeTaskStoreError.pendingStoreUnavailable }
        let client = try makeStoredClient()
        let pending = try await pendingStore.create(
            text: text,
            invocationSource: "ios_home_in_app",
            attachments: attachments,
            submissionID: submissionID
        )
        await scheduleRecovery(reason: "home_in_app_submission_persisted")
        // The outbox is already durable above. Draft selection may have started
        // a system background upload, but iOS can defer those bytes for minutes.
        // An explicit foreground Send takes over unfinished bytes on the same
        // resumable file ID; recovery still owns the submission if this stops.
        for attachment in attachments {
            _ = try await client.uploadTaskAttachment(
                attachment,
                executionMode: .immediateResumable
            )
        }
        let task = try await client.submitExisting(pending, pendingStore: pendingStore)
        let acceptedAttachmentIDs = Set(attachments.map(\.id))
        await MainActor.run {
            TaskAttachmentDraft.clearAcceptedReferences(acceptedAttachmentIDs)
        }
        persistHomeSelection(threadID: task.threadID, taskID: task.taskID)
        await trackDurableTask(task.taskID, reason: "home_in_app_task_admitted")
        return task
    }

    private func performHomeCurrentOperation(
        taskID: String,
        operation: FlowerollCurrentTaskOperation,
        attachments: [PendingAttachment],
        eventID: String
    ) async throws {
        let client = try makeStoredClient()
        switch operation {
        case let .userTurn(text):
            if FlowerollDirectTaskControlPolicy.isCancelCommand(text) {
                guard attachments.isEmpty else {
                    throw MaterialsError.message("取消任务时请先移除附件，避免材料归错任务。")
                }
                _ = try await client.cancelTask(
                    taskID: taskID,
                    eventID: eventID,
                    reason: "用户从首页明确取消当前任务"
                )
                await trackDurableTask(taskID, reason: "home_direct_cancel_admitted")
                return
            }
            guard let pendingStore else { throw RuntimeTaskStoreError.pendingStoreUnavailable }
            let pending = try await pendingStore.createUserTurn(
                taskID: taskID,
                text: text,
                attachments: attachments,
                eventID: eventID
            )
            await scheduleRecovery(reason: "home_in_app_user_turn_persisted")
            _ = try await client.submitExistingUserTurn(pending, pendingStore: pendingStore)
            let acceptedAttachmentIDs = Set(attachments.map(\.id))
            await MainActor.run {
                TaskAttachmentDraft.clearAcceptedReferences(acceptedAttachmentIDs)
            }

        case let .pendingInteraction(interaction, response):
            guard attachments.isEmpty else {
                throw MaterialsError.message("回复确认时请先移除附件，避免材料归错任务。")
            }
            switch interaction.kind {
            case .clarification:
                switch response {
                case let .option(id):
                    _ = try await client.respondToClarification(
                        taskID: taskID, clarificationID: interaction.id,
                        optionID: id, eventID: eventID
                    )
                case let .text(text):
                    _ = try await client.respondToClarification(
                        taskID: taskID, clarificationID: interaction.id,
                        text: text, eventID: eventID
                    )
                case let .approval(value):
                    _ = try await client.respondToClarification(
                        taskID: taskID, clarificationID: interaction.id,
                        text: value ? "确认" : "不确认", eventID: eventID
                    )
                }
            case .actionInput:
                guard let bindingDigest = interaction.bindingDigest, !bindingDigest.isEmpty else {
                    throw NSError(
                        domain: "FlowerollGlobalInputRouting", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "当前确认请求缺少绑定信息。"]
                    )
                }
                let payload: [String: JSONValue]
                switch response {
                case let .option(id): payload = ["option_id": .string(id)]
                case let .text(text): payload = ["text": .string(text)]
                case let .approval(value): payload = ["approved": .bool(value)]
                }
                _ = try await client.respondToActionInput(
                    taskID: taskID,
                    inputRequestID: interaction.id,
                    bindingDigest: bindingDigest,
                    response: payload,
                    eventID: eventID
                )
            }
        }
    }

    private func persistHomeSelection(threadID: String, taskID: String) {
        defaults.set(taskID, forKey: RuntimeTaskStore.continuationTaskDefaultsKey)
        RuntimeTaskStore.persistHomePresentationSelection(
            defaults: defaults,
            threadID: threadID,
            ownership: .foregroundSubmission
        )
    }

    private func trackDurableTask(_ taskID: String, reason: String) async {
        await MainActor.run {
            DeviceBackgroundExecutionController.shared.trackDurableTask(
                taskID: taskID,
                reason: reason
            )
        }
    }

    private func scheduleRecovery(reason: String) async {
        await MainActor.run {
            DeviceBackgroundExecutionController.shared.scheduleRecoveryTask(reason: reason)
        }
    }

    /// Action Button follows the same global-input contract as Home:
    /// new-task-by-default, with only high-confidence continuation/control or
    /// an exact pending-interaction answer targeting the current Task. Mixed
    /// input preserves both the current-task operation and the independent goal.
    func routeInput(
        text: String,
        invocationSource: String = "ios_app_intent"
    ) async throws -> SystemEntryInputRoute {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw PendingSubmissionStoreError.emptyText
        }

        let client = try makeStoredClient()
        let current = try await resolveCurrentHomeActiveTask(client: client)
        var currentView: HostTaskView?
        if let current {
            currentView = try? await client.fetchTaskView(taskID: current.taskID)
        }
        let context = Self.routingContext(current: current, view: currentView)
        let resolution = FlowerollGlobalInputRoutingPolicy.resolve(
            text: normalized,
            context: context
        )
        let route = resolution.route

        switch route {
        case let .steerCurrentTask(taskID):
            guard let current, current.taskID == taskID else {
                return try await submitNewSystemEntry(
                    text: normalized,
                    invocationSource: invocationSource
                )
            }
            try await performCurrentOperation(
                taskID: current.taskID,
                operation: .userTurn(text: normalized)
            )
            return await currentSystemEntryRoute(current)

        case let .answerPendingInteraction(taskID, interaction, response):
            guard let current, current.taskID == taskID else {
                return try await submitNewSystemEntry(
                    text: normalized,
                    invocationSource: invocationSource
                )
            }
            try await performCurrentOperation(
                taskID: current.taskID,
                operation: .pendingInteraction(
                    interaction: interaction,
                    response: response
                )
            )
            return await currentSystemEntryRoute(current)

        case let .mixed(currentTaskID, currentOperation, newTaskText):
            guard let current, current.taskID == currentTaskID else {
                return try await submitNewSystemEntry(
                    text: newTaskText,
                    invocationSource: invocationSource
                )
            }

            try await performCurrentOperation(
                taskID: current.taskID,
                operation: currentOperation
            )
            Self.logger.notice(
                "system entry mixed route preserved both halves; current=\(String(current.taskID.prefix(8)), privacy: .public)"
            )
            return try await submitNewSystemEntry(
                text: newTaskText,
                invocationSource: invocationSource
            )

        case .newTask:
            return try await submitNewSystemEntry(
                text: resolution.textForNewTask(fallback: normalized),
                invocationSource: invocationSource
            )
        }
    }

    private func submitNewSystemEntry(
        text: String,
        invocationSource: String
    ) async throws -> SystemEntryInputRoute {
        let taskID = try await submit(text: text, invocationSource: invocationSource)
        // LongRunningIntent owns the immediate system execution window, while
        // trackedTaskIDs preserves recovery eligibility if iOS reclaims it.
        // Do not add this Task to continuedTaskIDs: that set belongs to BGCPT.
        await trackDurableTask(taskID, reason: "system_entry_task_admitted")
        _ = activeExecutionTaskIDs.insert(taskID)
        return SystemEntryInputRoute(
            taskID: taskID,
            kind: .newTask,
            ownsExecutionWindow: true
        )
    }

    private func currentSystemEntryRoute(
        _ current: HostTaskIndexItem
    ) async -> SystemEntryInputRoute {
        defaults.set(current.taskID, forKey: RuntimeTaskStore.continuationTaskDefaultsKey)
        RuntimeTaskStore.persistHomePresentationSelection(
            defaults: defaults,
            threadID: current.threadID,
            ownership: .systemEntry
        )

        // Recovery eligibility is independent from whichever system window
        // currently owns execution. Re-assert it before removing the BGCPT owner.
        await trackDurableTask(
            current.taskID,
            reason: "system_entry_current_task_handoff"
        )
        await DeviceBackgroundExecutionController.shared.handoffInAppTaskToSystemLongRunning(
            taskID: current.taskID,
            reason: "explicit_system_entry_continuation"
        )
        let ownsExecutionWindow = activeExecutionTaskIDs.insert(current.taskID).inserted
        Self.logger.notice(
            "system entry routed to exact current task; task=\(String(current.taskID.prefix(8)), privacy: .public) owns_execution=\(ownsExecutionWindow, privacy: .public)"
        )
        return SystemEntryInputRoute(
            taskID: current.taskID,
            kind: .userTurn,
            ownsExecutionWindow: ownsExecutionWindow
        )
    }

    private func performCurrentOperation(
        taskID: String,
        operation: FlowerollCurrentTaskOperation
    ) async throws {
        let eventID = UUID().uuidString
        switch operation {
        case let .userTurn(text):
            if FlowerollDirectTaskControlPolicy.isCancelCommand(text) {
                let client = try makeStoredClient()
                _ = try await client.cancelTask(
                    taskID: taskID,
                    eventID: eventID,
                    reason: "用户从全局输入明确取消当前任务"
                )
                await trackDurableTask(taskID, reason: "system_entry_direct_cancel_admitted")
                return
            }
            try await performTaskScopedOperation(
                taskID: taskID,
                eventID: eventID,
                operation: .userTurn(text: text)
            )

        case let .pendingInteraction(interaction, response):
            let taskScoped: TaskScopedOperation
            switch interaction.kind {
            case .clarification:
                switch response {
                case let .option(id):
                    taskScoped = .clarification(
                        clarificationID: interaction.id,
                        optionID: id,
                        text: nil
                    )
                case let .text(text):
                    taskScoped = .clarification(
                        clarificationID: interaction.id,
                        optionID: nil,
                        text: text
                    )
                case let .approval(value):
                    taskScoped = .clarification(
                        clarificationID: interaction.id,
                        optionID: nil,
                        text: value ? "确认" : "不确认"
                    )
                }

            case .actionInput:
                guard let bindingDigest = interaction.bindingDigest, !bindingDigest.isEmpty else {
                    throw NSError(
                        domain: "FlowerollGlobalInputRouting",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "当前确认请求缺少绑定信息。"]
                    )
                }
                let payload: [String: JSONValue]
                switch response {
                case let .option(id): payload = ["option_id": .string(id)]
                case let .text(text): payload = ["text": .string(text)]
                case let .approval(value): payload = ["approved": .bool(value)]
                }
                taskScoped = .actionInput(
                    inputRequestID: interaction.id,
                    bindingDigest: bindingDigest,
                    response: payload
                )
            }
            try await performTaskScopedOperation(
                taskID: taskID,
                eventID: eventID,
                operation: taskScoped
            )
        }
    }

    private static func routingContext(
        current: HostTaskIndexItem?,
        view: HostTaskView?
    ) -> FlowerollGlobalInputRoutingContext {
        guard let current else { return .none }
        if let view, RuntimeTaskStore.isTerminalStatus(view.task.status) {
            return .none
        }
        let referentSource: FlowerollRoutingReferentSourceSnapshot?
        if let view,
           view.task.taskID == current.taskID,
           view.task.updatedAt == current.updatedAt {
            referentSource = .init(
                taskID: view.task.taskID,
                taskUpdatedAt: view.task.updatedAt,
                goal: view.task.goal,
                brief: current.title
            )
        } else {
            referentSource = nil
        }
        return FlowerollGlobalInputRoutingContext(
            currentTask: .init(
                taskID: current.taskID,
                goal: current.goal,
                pendingInteraction: routingPendingInteraction(from: view?.typedPendingInteraction),
                referentSource: referentSource
            )
        )
    }

    private static func routingPendingInteraction(
        from interaction: HostPendingInteraction?
    ) -> FlowerollPendingInteractionRoutingContext? {
        guard let interaction else { return nil }
        switch interaction {
        case let .clarification(id, question, options, acceptsText, _):
            return FlowerollPendingInteractionRoutingContext(
                kind: .clarification,
                id: id,
                prompt: question,
                options: options.map { .init(id: $0.id, label: $0.label) },
                acceptsText: acceptsText,
                actionAttemptID: nil,
                bindingDigest: nil
            )
        case let .actionInput(id, attemptID, prompt, options, acceptsText, _, bindingDigest):
            return FlowerollPendingInteractionRoutingContext(
                kind: .actionInput,
                id: id,
                prompt: prompt,
                options: options.map { .init(id: $0.id, label: $0.label) },
                acceptsText: acceptsText,
                actionAttemptID: attemptID,
                bindingDigest: bindingDigest
            )
        }
    }

    func hasActiveSystemExecution(taskID: String) -> Bool {
        let normalized = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty && activeExecutionTaskIDs.contains(normalized)
    }

    func releaseExecutionReservation(taskID: String) {
        activeExecutionTaskIDs.remove(taskID)
    }

    /// Advances an already-created durable Task using the same Host View and
    /// DeviceRuntimeWorker path used elsewhere in the app.
    func runSubmittedTask(
        taskID: String,
        executionWindowSeconds: TimeInterval? = 24,
        hasExecutionReservation: Bool = false,
        onProgress: (@Sendable (SystemEntryRuntimeProgressUpdate) async -> Void)? = nil
    ) async throws -> SystemEntryRuntimeOutcome {
        if !hasExecutionReservation {
            _ = activeExecutionTaskIDs.insert(taskID)
        }
        defer {
            activeExecutionTaskIDs.remove(taskID)
        }

        let client = try makeStoredClient()
        let deadline = executionWindowSeconds.map {
            Date().addingTimeInterval(max(1, $0))
        }

        await onProgress?(SystemEntryRuntimeProgressUpdate(
            completedUnitCount: SystemEntryProgressPresentationPolicy.admittedUnitCount,
            totalUnitCount: SystemEntryProgressPresentationPolicy.totalUnitCount,
            title: "小卷正在处理",
            subtitle: "任务已接收"
        ))

        while !Task.isCancelled, deadline.map({ Date() < $0 }) ?? true {
            // A second Home invocation may have joined this exact Task without
            // creating another LongRunningIntent. Consume its persisted outbox
            // before sampling Host state.
            await DeviceBackgroundExecutionController.shared.recoverDurableWorkNow(
                reason: "long_running_intent_loop",
                includeDeviceActions: false
            )
            let view = try await client.fetchTaskView(taskID: taskID)
            let state = view.runtimeStateDimensions
            await onProgress?(Self.progressUpdate(from: view))

            switch state.lifecycle {
            case .completed:
                let message = Self.resultSummary(from: view) ?? "任务已完成"
                return SystemEntryRuntimeOutcome(
                    taskID: taskID,
                    state: .completed,
                    message: message
                )
            case .waiting:
                // A needs-user boundary is not completion. LongRunningIntent
                // stays alive and keeps reporting the durable Host state for as
                // long as iOS grants this execution session. If iOS reclaims
                // it first, Host truth remains and BGProcessing can recover.
                try? await Task.sleep(for: .milliseconds(500))
                continue
            case .cancelled:
                let message = "任务已取消"
                return SystemEntryRuntimeOutcome(
                    taskID: taskID,
                    state: .cancelled,
                    message: message
                )
            case .blocked:
                let message = Self.resultSummary(from: view) ?? "任务已暂停，可稍后继续"
                return SystemEntryRuntimeOutcome(
                    taskID: taskID,
                    state: .blocked,
                    message: message
                )
            case .failed:
                let message = Self.resultSummary(from: view) ?? "任务暂时无法继续"
                return SystemEntryRuntimeOutcome(
                    taskID: taskID,
                    state: .failed,
                    message: message
                )
            case .active, .unknown:
                break
            }

            if let deviceWorker {
                let remaining = deadline.map { max(0, $0.timeIntervalSinceNow) }
                if let remaining, remaining <= 0 { break }
                let waitSeconds = remaining.map {
                    min(4, max(1, Int($0.rounded(.down))))
                } ?? 4
                let report = await deviceWorker.processTask(
                    client: client,
                    taskID: taskID,
                    waitSeconds: waitSeconds
                )

                if !report.reconciliationTaskIDs.isEmpty {
                    // UNKNOWN/may-have-started is not completion. Keep the
                    // system-owned LongRunningIntent window alive and observe
                    // durable Host truth until reconciliation resolves or iOS
                    // reclaims the execution window.
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                if !report.busyTaskIDs.isEmpty {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            } else {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        try Task.checkCancellation()
        let message = "任务已保存，后台状态会继续保留"
        return SystemEntryRuntimeOutcome(
            taskID: taskID,
            state: .delegated,
            message: message
        )
    }

    /// Maps system LongRunningIntent cancellation onto durable Host semantics.
    /// Explicit user cancellation cancels the Task; system timeout/interruption
    /// ends only the current execution window and preserves Host truth.
    @discardableResult
    func handleSystemCancellation(
        taskID: String,
        kind: SystemEntryCancellationKind
    ) async -> Bool {
        switch kind {
        case .userCancelled:
            do {
                let client = try makeStoredClient()
                _ = try await client.cancelTask(
                    taskID: taskID,
                    eventID: "ios-long-running-cancel-\(taskID)",
                    reason: "用户从系统长任务界面取消"
                )
                Self.logger.notice(
                    "system-entry user cancellation admitted by Host; task=\(String(taskID.prefix(8)), privacy: .public)"
                )
                return true
            } catch {
                Self.logger.error(
                    "system-entry cancellation failed to reach Host; task=\(String(taskID.prefix(8)), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                return false
            }
        case .systemTimeout:
            // The LongRunningIntent owns the system presentation while it is
            // alive. Do not touch/create custom ActivityKit here: the caller
            // migrates to a new custom generation only after the system owner
            // has actually relinquished its execution/presentation window.
            Self.logger.notice(
                "LongRunningIntent timed out; preserving durable Host task=\(String(taskID.prefix(8)), privacy: .public)"
            )
            return false
        case .systemInterruption:
            Self.logger.notice(
                "LongRunningIntent was interrupted by the system; preserving durable Host task=\(String(taskID.prefix(8)), privacy: .public)"
            )
            return false
        }
    }

    func fetchDurableTaskView(taskID: String) async throws -> HostTaskView {
        try await makeStoredClient().fetchTaskView(taskID: taskID)
    }

    private func resolveCurrentHomeActiveTask(
        client: FlowerollHostClient
    ) async throws -> HostTaskIndexItem? {
        guard !defaults.bool(forKey: RuntimeTaskStore.homeThreadAwaitingNewDefaultsKey),
              let threadID = defaults.string(forKey: RuntimeTaskStore.homeThreadDefaultsKey),
              !threadID.isEmpty
        else {
            defaults.removeObject(forKey: RuntimeTaskStore.continuationTaskDefaultsKey)
            return nil
        }

        async let running = client.fetchTaskIndex(
            bucket: "running", limit: 100, threadID: threadID
        )
        async let needsUser = client.fetchTaskIndex(
            bucket: "needs_user", limit: 100, threadID: threadID
        )
        let pages = try await (running, needsUser)
        let active = newest(pages.0.items + pages.1.items)
        if let active {
            defaults.set(active.taskID, forKey: RuntimeTaskStore.continuationTaskDefaultsKey)
        } else {
            defaults.removeObject(forKey: RuntimeTaskStore.continuationTaskDefaultsKey)
        }
        return active
    }

    private func newest(_ tasks: [HostTaskIndexItem]) -> HostTaskIndexItem? {
        tasks.max { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt { return lhs.taskID < rhs.taskID }
            return lhs.updatedAt < rhs.updatedAt
        }
    }

    private func makeStoredClient() throws -> FlowerollHostClient {
        let raw = defaults.string(forKey: RuntimeTaskStore.endpointDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else {
            throw RuntimeTaskStoreError.hostNotConfigured
        }
        guard let url = URL(string: raw), url.scheme != nil, url.host != nil else {
            throw RuntimeTaskStoreError.invalidHostURL
        }

        let host = url.host?.lowercased()
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        let client = isLoopback
            ? FlowerollHostClient(baseURL: url, session: session)
            : try FlowerollHostClient.paired(
                baseURL: url,
                session: session,
                credentialStore: credentialStore
            )
        try client.validateEndpointSecurity()
        return client
    }

    static func progressUpdate(from view: HostTaskView) -> SystemEntryRuntimeProgressUpdate {
        let counts = SystemEntryProgressPresentationPolicy.counts(from: view)
        let state = view.runtimeStateDimensions
        let title: String
        let subtitle: String
        switch state.lifecycle {
        case .completed:
            title = "小卷已完成"
            subtitle = resultSummary(from: view) ?? "已经完成你交代的任务"
        case .cancelled:
            title = "小卷已取消"
            subtitle = "已经停止后续处理"
        case .waiting:
            if state.interaction.requiresUser {
                title = "小卷需要你确认"
                subtitle = pendingInteractionSummary(from: view) ?? "打开花卷继续这个任务"
            } else {
                title = "小卷正在处理"
                subtitle = activeSummary(from: view) ?? "正在等待下一步"
            }
        case .failed, .blocked:
            title = "小卷暂时无法继续"
            subtitle = resultSummary(from: view) ?? "打开花卷查看详情"
        case .active, .unknown:
            title = "小卷正在处理"
            subtitle = activeSummary(from: view) ?? "正在处理"
        }
        return SystemEntryRuntimeProgressUpdate(completedUnitCount: counts.completed,
            totalUnitCount: counts.total, title: title, subtitle: subtitle)
    }

    private static func activeSummary(from view: HostTaskView) -> String? {
        if let active = view.timeline.last(where: {
            $0.isUserVisible && $0.presentationState.uppercased() == "ACTIVE"
        }) {
            return String(active.title.prefix(96))
        }
        if let latest = view.timeline.last(where: { $0.isUserVisible }) {
            let text = latest.summary ?? latest.title
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(text.prefix(96))
            }
        }
        return nil
    }

    private static func resultSummary(from view: HostTaskView) -> String? {
        if let summary = view.result?.objectValue?["summary"]?.stringValue,
           !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(summary.prefix(96))
        }
        if let summary = view.timeline.last(where: { $0.kind == "RESULT" })?.summary,
           !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(summary.prefix(96))
        }
        return nil
    }

    private static func pendingInteractionSummary(from view: HostTaskView) -> String? {
        guard let interaction = view.typedPendingInteraction else { return nil }
        switch interaction {
        case let .clarification(_, question, _, _, _):
            return String(question.prefix(96))
        case let .actionInput(_, _, prompt, _, _, _, _):
            return String(prompt.prefix(96))
        }
    }
}
