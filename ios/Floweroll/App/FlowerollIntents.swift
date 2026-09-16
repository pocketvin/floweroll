import Foundation
import AppIntents
import AVFAudio



@available(iOS 27.0, *)
struct CaptureHouTaskIntent: LongRunningIntent, CancellableIntent {
    static let title: LocalizedStringResource = "交给小卷"
    static let description = IntentDescription("由系统收取一条自然语言任务，并让小卷在后台持续处理。")
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(
        title: "任务",
        requestValueDialog: "你想让小卷帮你做什么？",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var task: String

    func perform() async throws -> some IntentResult {
        SystemEntryIntentDiagnostics.record("capture.perform.enter")
        let normalized = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw $task.needsValueError("你想让小卷帮你做什么？")
        }

        let route = try await SystemEntryRuntimeCoordinator.shared.routeInput(
            text: normalized,
            invocationSource: "ios_app_intent"
        )
        SystemEntryIntentDiagnostics.record(
            "capture.route.done",
            detail: "task=\(route.taskID) kind=\(route.kind) owns=\(route.ownsExecutionWindow)"
        )

        // A second invocation may add a durable UserTurn to a Task whose
        // LongRunningIntent session is already alive. Do not create a duplicate
        // system Live Activity / execution owner in that case.
        guard route.ownsExecutionWindow else {
            SystemEntryIntentDiagnostics.record(
                "capture.perform.done",
                detail: "task=\(route.taskID) state=joined-existing-long-running-session"
            )
            return .result()
        }

        defer {
            Task {
                await SystemEntryRuntimeCoordinator.shared.releaseExecutionReservation(
                    taskID: route.taskID
                )
            }
        }

        guard await FlowerollActivitySession.prepareForSystemLongRunningIntent(taskID: route.taskID),
              let presentationLease = await FlowerollActivitySession.beginSystemPresentation(
                owner: .systemLongRunningIntent,
                taskID: route.taskID
              )
        else {
            throw NSError(
                domain: "FlowerollLongRunningIntent",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "小卷的系统后台执行窗口暂时无法建立。"]
            )
        }
        defer {
            Task {
                _ = await FlowerollActivitySession.releaseSystemPresentation(presentationLease)
            }
        }

        let taskID = route.taskID
        let intentProgress = progress
        intentProgress.totalUnitCount = SystemEntryProgressPresentationPolicy.totalUnitCount
        intentProgress.completedUnitCount = SystemEntryProgressPresentationPolicy.admittedUnitCount
        intentProgress.localizedDescription = "小卷正在处理"
        intentProgress.localizedAdditionalDescription = "任务已接收"

        let outcome = try await performBackgroundTask {
            try await SystemEntryRuntimeCoordinator.shared.runSubmittedTask(
                taskID: taskID,
                executionWindowSeconds: nil,
                hasExecutionReservation: true
            ) { update in
                intentProgress.totalUnitCount = update.totalUnitCount
                intentProgress.completedUnitCount = update.completedUnitCount
                intentProgress.localizedDescription = update.title
                intentProgress.localizedAdditionalDescription = update.subtitle
            }
        } onCancel: { reason in
            let kind: SystemEntryCancellationKind
            if reason == .userCancelled {
                kind = .userCancelled
            } else if reason == .timeout {
                kind = .systemTimeout
            } else {
                kind = .systemInterruption
            }
            Task {
                _ = await SystemEntryRuntimeCoordinator.shared.handleSystemCancellation(
                    taskID: taskID,
                    kind: kind
                )
                await MainActor.run {
                    DeviceBackgroundExecutionController.shared.scheduleRecoveryTask(
                        reason: "long_running_intent_cancelled"
                    )
                }
            }
        }

        SystemEntryIntentDiagnostics.record(
            "capture.perform.done",
            detail: "task=\(route.taskID) outcome=\(outcome.state)"
        )
        return .result()
    }
}


@available(iOS 27.0, *)
struct HomeHouTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "交给小卷"
    static let description = IntentDescription("从花卷首页提交任务，并在后台持续处理。")
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main
    static let isDiscoverable = false

    @Parameter(title: "任务")
    var text: String

    @Parameter(title: "提交编号")
    var submissionID: String

    @Parameter(title: "附件清单")
    var attachmentManifest: String

    init() {
        text = ""
        submissionID = ""
        attachmentManifest = ""
    }

    init(text: String, submissionID: String, attachments: [PendingAttachment]) {
        self.text = text
        self.submissionID = submissionID
        if attachments.isEmpty {
            attachmentManifest = ""
        } else if let encoded = try? JSONEncoder.floweroll.encode(attachments) {
            attachmentManifest = encoded.base64EncodedString()
        } else {
            attachmentManifest = ""
        }
    }

    func perform() async throws -> some IntentResult {
        SystemEntryIntentDiagnostics.record("home.perform.enter")
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSubmissionID = submissionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !normalizedSubmissionID.isEmpty else {
            throw NSError(
                domain: "FlowerollHomeInAppIntent",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "任务内容或提交编号无效。"]
            )
        }

        let attachments: [PendingAttachment]
        do {
            attachments = try decodeAttachments()
        } catch {
            await HomeInAppIntentEvents.postFailure(
                submissionID: normalizedSubmissionID,
                message: error.localizedDescription
            )
            throw error
        }
        await HomeInAppIntentEvents.postStarted(submissionID: normalizedSubmissionID)
        let coordinator = SystemEntryRuntimeCoordinator.shared
        let prepared: SystemEntryPreparedHomeInput
        do {
            prepared = try await coordinator.prepareHomeInput(text: normalized)
        } catch {
            await HomeInAppIntentEvents.postFailure(
                submissionID: normalizedSubmissionID,
                message: error.localizedDescription
            )
            throw error
        }

        // BGCPT must be requested while this foreground user action is still
        // executing. The exact outbox identity survives if AppIntent execution
        // is suspended after this point.
        _ = await DeviceBackgroundExecutionController.shared.beginUserInitiatedOutboxContinuation(
            submissionID: normalizedSubmissionID,
            summary: normalized
        )

        do {
            let route = try await coordinator.executePreparedHomeInput(
                prepared,
                submissionID: normalizedSubmissionID,
                attachments: attachments
            )
            _ = await DeviceBackgroundExecutionController.shared.submitUserInitiatedContinuation(
                taskID: route.taskID,
                goal: normalized
            )
            await DeviceBackgroundExecutionController.shared.finishUserInitiatedOutboxContinuation(
                submissionID: normalizedSubmissionID,
                reason: "home_in_app_host_admitted"
            )
            await HomeInAppIntentEvents.postAccepted(
                submissionID: normalizedSubmissionID,
                taskID: route.taskID,
                attachmentIDs: attachments.map(\.id),
                joinedExistingExecution: false
            )
            SystemEntryIntentDiagnostics.record(
                "home.perform.done",
                detail: "task=\(route.taskID) owner=bgcpt"
            )
            return .result()
        } catch {
            // An admission failure is not a reason to leave a phantom BGCPT
            // outbox owner. Persisted work, if any, remains eligible for the
            // independent BGProcessing recovery lane.
            await DeviceBackgroundExecutionController.shared.finishUserInitiatedOutboxContinuation(
                submissionID: normalizedSubmissionID,
                reason: "home_in_app_admission_failed"
            )
            await HomeInAppIntentEvents.postFailure(
                submissionID: normalizedSubmissionID,
                message: error.localizedDescription
            )
            throw error
        }
    }

    private func decodeAttachments() throws -> [PendingAttachment] {
        guard !attachmentManifest.isEmpty else { return [] }
        guard let data = Data(base64Encoded: attachmentManifest) else {
            throw NSError(
                domain: "FlowerollHomeInAppIntent",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "附件清单无法读取。"]
            )
        }
        return try JSONDecoder.floweroll.decode([PendingAttachment].self, from: data)
    }
}

@available(iOS 27.0, *)
struct TaskScopedHouIntent: AppIntent {
    static let title: LocalizedStringResource = "继续小卷任务"
    static let description = IntentDescription("向现有花卷任务补充要求或回复确认，并继续后台执行。")
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main
    static let isDiscoverable = false

    @Parameter(title: "任务编号") var taskID: String
    @Parameter(title: "事件编号") var eventID: String
    @Parameter(title: "操作类型") var operationKind: String
    @Parameter(title: "目标编号") var targetID: String
    @Parameter(title: "绑定摘要") var bindingDigest: String
    @Parameter(title: "内容") var payload: String

    init() {
        taskID = ""
        eventID = ""
        operationKind = ""
        targetID = ""
        bindingDigest = ""
        payload = ""
    }

    private init(
        taskID: String,
        eventID: String,
        operationKind: String,
        targetID: String = "",
        bindingDigest: String = "",
        payload: String
    ) {
        self.taskID = taskID
        self.eventID = eventID
        self.operationKind = operationKind
        self.targetID = targetID
        self.bindingDigest = bindingDigest
        self.payload = payload
    }

    static func userTurn(taskID: String, eventID: String, text: String) -> Self {
        Self(taskID: taskID, eventID: eventID, operationKind: "user_turn", payload: text)
    }

    static func clarificationOption(
        taskID: String,
        eventID: String,
        clarificationID: String,
        optionID: String
    ) -> Self {
        Self(
            taskID: taskID,
            eventID: eventID,
            operationKind: "clarification_option",
            targetID: clarificationID,
            payload: optionID
        )
    }

    static func clarificationText(
        taskID: String,
        eventID: String,
        clarificationID: String,
        text: String
    ) -> Self {
        Self(
            taskID: taskID,
            eventID: eventID,
            operationKind: "clarification_text",
            targetID: clarificationID,
            payload: text
        )
    }

    static func actionInput(
        taskID: String,
        eventID: String,
        inputRequestID: String,
        bindingDigest: String,
        response: [String: JSONValue]
    ) -> Self {
        let encoded = (try? JSONEncoder.floweroll.encode(response))?.base64EncodedString() ?? ""
        return Self(
            taskID: taskID,
            eventID: eventID,
            operationKind: "action_input",
            targetID: inputRequestID,
            bindingDigest: bindingDigest,
            payload: encoded
        )
    }

    func perform() async throws -> some IntentResult {
        SystemEntryIntentDiagnostics.record("task_scoped.perform.enter")
        let normalizedTaskID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEventID = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTaskID.isEmpty, !normalizedEventID.isEmpty else {
            throw NSError(
                domain: "FlowerollTaskScopedInAppIntent",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "任务或事件编号无效。"]
            )
        }

        let operation: TaskScopedOperation
        do {
            operation = try decodedOperation()
        } catch {
            await TaskScopedInAppIntentEvents.postFailure(
                eventID: normalizedEventID,
                sourceTaskID: normalizedTaskID,
                message: error.localizedDescription
            )
            throw error
        }

        // Existing task identity is already known, so foreground interaction can
        // hand BGCPT the exact owner before the Host mutation starts. The Host
        // still exposes the old needs-user snapshot for a short race window;
        // reserve that Task until the exact mutation has been durably consumed.
        await DeviceBackgroundExecutionController.shared.beginTaskScopedMutationReservation(
            taskID: normalizedTaskID
        )
        _ = await DeviceBackgroundExecutionController.shared.submitUserInitiatedContinuation(
            taskID: normalizedTaskID,
            goal: ""
        )
        do {
            try await SystemEntryRuntimeCoordinator.shared.performTaskScopedOperation(
                taskID: normalizedTaskID,
                eventID: normalizedEventID,
                operation: operation
            )
            await DeviceBackgroundExecutionController.shared.endTaskScopedMutationReservation(
                taskID: normalizedTaskID
            )
            await TaskScopedInAppIntentEvents.postAccepted(
                eventID: normalizedEventID,
                sourceTaskID: normalizedTaskID,
                taskID: normalizedTaskID
            )
            SystemEntryIntentDiagnostics.record(
                "task_scoped.perform.done",
                detail: "task=\(normalizedTaskID) owner=bgcpt"
            )
            return .result()
        } catch {
            await DeviceBackgroundExecutionController.shared.endTaskScopedMutationReservation(
                taskID: normalizedTaskID
            )
            await TaskScopedInAppIntentEvents.postFailure(
                eventID: normalizedEventID,
                sourceTaskID: normalizedTaskID,
                message: error.localizedDescription
            )
            throw error
        }
    }

    private func decodedOperation() throws -> TaskScopedOperation {
        switch operationKind {
        case "user_turn":
            return .userTurn(text: payload)
        case "clarification_option":
            return .clarification(
                clarificationID: targetID,
                optionID: payload,
                text: nil
            )
        case "clarification_text":
            return .clarification(
                clarificationID: targetID,
                optionID: nil,
                text: payload
            )
        case "action_input":
            guard let data = Data(base64Encoded: payload) else {
                throw NSError(
                    domain: "FlowerollTaskScopedInAppIntent",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "确认内容无法读取。"]
                )
            }
            let response = try JSONDecoder.floweroll.decode([String: JSONValue].self, from: data)
            return .actionInput(
                inputRequestID: targetID,
                bindingDigest: bindingDigest,
                response: response
            )
        default:
            throw NSError(
                domain: "FlowerollTaskScopedInAppIntent",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "不支持的任务操作。"]
            )
        }
    }
}

@available(iOS 27.0, *)
struct ThreadFollowUpHouIntent: AppIntent {
    static let title: LocalizedStringResource = "继续这件事"
    static let description = IntentDescription("在已经结束的任务历史中创建下一轮，并继续后台执行。")
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main
    static let isDiscoverable = false

    @Parameter(title: "上一轮任务") var parentTaskID: String
    @Parameter(title: "要求") var text: String
    @Parameter(title: "提交编号") var submissionID: String

    init() {
        parentTaskID = ""
        text = ""
        submissionID = ""
    }

    init(parentTaskID: String, text: String, submissionID: String) {
        self.parentTaskID = parentTaskID
        self.text = text
        self.submissionID = submissionID
    }

    func perform() async throws -> some IntentResult {
        SystemEntryIntentDiagnostics.record("thread_follow_up.perform.enter")
        let normalizedParentID = parentTaskID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSubmissionID = submissionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedParentID.isEmpty, !normalizedText.isEmpty, !normalizedSubmissionID.isEmpty else {
            throw NSError(
                domain: "FlowerollThreadFollowUpInAppIntent",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "继续任务所需的信息不完整。"]
            )
        }

        _ = await DeviceBackgroundExecutionController.shared.beginUserInitiatedOutboxContinuation(
            submissionID: normalizedSubmissionID,
            summary: normalizedText
        )
        do {
            let task = try await SystemEntryRuntimeCoordinator.shared.submitInAppFollowUp(
                parentTaskID: normalizedParentID,
                text: normalizedText,
                submissionID: normalizedSubmissionID
            )
            _ = await DeviceBackgroundExecutionController.shared.submitUserInitiatedContinuation(
                taskID: task.taskID,
                goal: normalizedText
            )
            await DeviceBackgroundExecutionController.shared.finishUserInitiatedOutboxContinuation(
                submissionID: normalizedSubmissionID,
                reason: "thread_follow_up_host_admitted"
            )
            await TaskScopedInAppIntentEvents.postAccepted(
                eventID: normalizedSubmissionID,
                sourceTaskID: normalizedParentID,
                taskID: task.taskID
            )
            SystemEntryIntentDiagnostics.record(
                "thread_follow_up.perform.done",
                detail: "task=\(task.taskID) owner=bgcpt"
            )
            return .result()
        } catch {
            await DeviceBackgroundExecutionController.shared.finishUserInitiatedOutboxContinuation(
                submissionID: normalizedSubmissionID,
                reason: "thread_follow_up_admission_failed"
            )
            await TaskScopedInAppIntentEvents.postFailure(
                eventID: normalizedSubmissionID,
                sourceTaskID: normalizedParentID,
                message: error.localizedDescription
            )
            throw error
        }
    }
}

enum TaskScopedInAppIntentEvents {
    static let notification = Notification.Name("com.maxenceyu.floweroll.task-scoped-in-app-intent")
    static let kindKey = "kind"
    static let eventIDKey = "event_id"
    static let sourceTaskIDKey = "source_task_id"
    static let taskIDKey = "task_id"
    static let messageKey = "message"

    @MainActor
    static func postAccepted(
        eventID: String, sourceTaskID: String, taskID: String
    ) {
        NotificationCenter.default.post(
            name: notification,
            object: nil,
            userInfo: [
                kindKey: "accepted",
                eventIDKey: eventID,
                sourceTaskIDKey: sourceTaskID,
                taskIDKey: taskID,
            ]
        )
    }

    @MainActor
    static func postFailure(eventID: String, sourceTaskID: String, message: String) {
        NotificationCenter.default.post(
            name: notification,
            object: nil,
            userInfo: [
                kindKey: "failed",
                eventIDKey: eventID,
                sourceTaskIDKey: sourceTaskID,
                messageKey: message,
            ]
        )
    }
}


enum HomeInAppIntentEvents {
    static let notification = Notification.Name("com.maxenceyu.floweroll.home-in-app-intent")
    static let kindKey = "kind"
    static let submissionIDKey = "submission_id"
    static let taskIDKey = "task_id"
    static let attachmentIDsKey = "attachment_ids"
    static let messageKey = "message"
    static let joinedExistingExecutionKey = "joined_existing_execution"

    @MainActor
    static func postStarted(submissionID: String) {
        NotificationCenter.default.post(
            name: notification,
            object: nil,
            userInfo: [
                kindKey: "started",
                submissionIDKey: submissionID,
            ]
        )
    }

    @MainActor
    static func postAccepted(
        submissionID: String,
        taskID: String,
        attachmentIDs: [String],
        joinedExistingExecution: Bool
    ) {
        NotificationCenter.default.post(
            name: notification,
            object: nil,
            userInfo: [
                kindKey: "accepted",
                submissionIDKey: submissionID,
                taskIDKey: taskID,
                attachmentIDsKey: attachmentIDs,
                joinedExistingExecutionKey: joinedExistingExecution,
            ]
        )
    }

    @MainActor
    static func postFailure(submissionID: String, message: String) {
        NotificationCenter.default.post(
            name: notification,
            object: nil,
            userInfo: [
                kindKey: "failed",
                submissionIDKey: submissionID,
                messageKey: message,
            ]
        )
    }
}


/// Development-only audio feasibility probe. It intentionally has no custom
/// ActivityKit presentation; Task execution uses only system-owned surfaces.
struct BackgroundListeningProbeIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "花卷后台监听实验"
    static let description = IntentDescription("测试 Action Button / Shortcut 是否能在不切前台的情况下启动麦克风。")
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult {
        try await AudioCaptureService.shared.start()
        return .result()
    }
}

struct StopHouListeningIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "停止小卷监听"
    static let description = IntentDescription("停止麦克风采集。")
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult {
        await AudioCaptureService.shared.stop()
        return .result()
    }
}


private enum SystemEntryIntentDiagnostics {
    private static let lock = NSLock()

    static func record(_ stage: String, detail: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = base.appendingPathComponent("Floweroll/Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("system-entry.jsonl")
            let payload: [String: String] = [
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "stage": stage,
                "detail": detail ?? "",
            ]
            let line = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) + Data("\n".utf8)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
            }
        } catch {
            // Diagnostics must never affect the user task path.
        }
    }
}

struct FlowerollShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureHouTaskIntent(),
            phrases: [
                "交给 \(.applicationName)"
            ],
            shortTitle: "交给小卷",
            systemImageName: "quote.bubble"
        )

        AppShortcut(
            intent: BackgroundListeningProbeIntent(),
            phrases: [
                "让 \(.applicationName) 听我说"
            ],
            shortTitle: "后台监听实验",
            systemImageName: "waveform"
        )

        AppShortcut(
            intent: StopHouListeningIntent(),
            phrases: [
                "停止 \(.applicationName) 监听"
            ],
            shortTitle: "停止监听",
            systemImageName: "stop.circle"
        )
    }
}
