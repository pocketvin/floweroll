import BackgroundTasks
import Foundation
import OSLog
import UserNotifications
import UIKit


final class FlowerollNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = FlowerollNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let content = notification.request.content
        if content.categoryIdentifier == NotifyUserConstants.categoryIdentifier {
            // `notify.user` is an explicit product capability. Keep D11's
            // foreground notification contract for that action only.
            completionHandler([.banner, .list, .sound])
            return
        }
        if content.userInfo[FlowerollTaskNotifications.kindUserInfoKey] as? String
            == FlowerollTaskNotifications.terminalKind {
            // Ordinary Task completion already has an in-app completion card /
            // Inbox while Floweroll is foreground. Do not duplicate it as a
            // system banner and sound on top of the active app.
            completionHandler([])
            return
        }
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let content = response.notification.request.content
        guard let route = NotifyUserRoute.parse(
            categoryIdentifier: content.categoryIdentifier,
            userInfo: content.userInfo
        ) else { return }
        NotifyUserRouteStore.shared.record(route)
        FlowerollNotificationDiagnostics.record(
            event: "notify_user_tap_routed",
            taskID: route.taskID,
            detail: "action_id=\(route.actionID)"
        )
    }
}


enum FlowerollTaskNotifications {
    private static let notifiedKey = "floweroll.notifications.terminalTaskIDs"
    static let kindUserInfoKey = "floweroll_notification_kind"
    static let terminalKind = "task_terminal"

    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        FlowerollNotificationDiagnostics.record(
            event: "authorization_checked",
            detail: "status=\(settings.authorizationStatus.rawValue)"
        )
        guard settings.authorizationStatus == .notDetermined else { return }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            FlowerollNotificationDiagnostics.record(
                event: "authorization_requested",
                detail: "granted=\(granted)"
            )
        } catch {
            let nsError = error as NSError
            FlowerollNotificationDiagnostics.record(
                event: "authorization_request_failed",
                detail: "domain=\(nsError.domain) code=\(nsError.code)"
            )
        }
    }

    static func notifyTerminalIfNeeded(
        taskID: String,
        title: String,
        body: String
    ) async {
        if let acceptanceStore = NotifyUserAcceptanceStore.shared,
           await acceptanceStore.hasAcceptedTerminalNotification(taskID: taskID) {
            FlowerollNotificationDiagnostics.record(
                event: "terminal_notification_suppressed_after_explicit_notify",
                taskID: taskID
            )
            return
        }

        let appIsActive = await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
        guard FlowerollTaskTerminalNotificationPolicy.shouldSchedule(appIsActive: appIsActive) else {
            FlowerollNotificationDiagnostics.record(
                event: "terminal_notification_suppressed_foreground",
                taskID: taskID,
                detail: "foreground_completion_attention_owner=app"
            )
            return
        }

        let defaults = UserDefaults.standard
        var notified = Set(defaults.stringArray(forKey: notifiedKey) ?? [])
        guard notified.insert(taskID).inserted else { return }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            FlowerollNotificationDiagnostics.record(
                event: "terminal_notification_skipped",
                taskID: taskID,
                detail: "authorization=\(settings.authorizationStatus.rawValue)"
            )
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "floweroll.tasks"
        content.userInfo = [
            "task_id": taskID,
            kindUserInfoKey: terminalKind,
        ]

        let request = UNNotificationRequest(
            identifier: "floweroll.task.\(taskID).terminal",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            defaults.set(Array(notified.prefix(200)), forKey: notifiedKey)
            FlowerollNotificationDiagnostics.record(
                event: "terminal_notification_added",
                taskID: taskID,
                detail: "authorization=\(settings.authorizationStatus.rawValue)"
            )
        } catch {
            notified.remove(taskID)
            let nsError = error as NSError
            FlowerollNotificationDiagnostics.record(
                event: "terminal_notification_failed",
                taskID: taskID,
                detail: "domain=\(nsError.domain) code=\(nsError.code)"
            )
        }
    }
}


private enum FlowerollNotificationDiagnostics {
    private static let lock = NSLock()
    private static let filename = "notification-diagnostic.jsonl"

    static func record(event: String, taskID: String? = nil, detail: String? = nil) {
        lock.lock()
        defer { lock.unlock() }

        var payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "event": event,
        ]
        if let taskID, !taskID.isEmpty { payload["task_id"] = taskID }
        if let detail, !detail.isEmpty { payload["detail"] = detail }
        guard JSONSerialization.isValidJSONObject(payload),
              var data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { return }
        data.append(0x0A)

        do {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("Floweroll", isDirectory: true)
            .appendingPathComponent("RuntimeClient", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            // Diagnostics must never change notification behavior.
        }
    }
}


enum BackgroundRecoveryRequestPolicy {
    static func shouldSubmit(
        identifier: String,
        pendingIdentifiers: Set<String>
    ) -> Bool {
        !pendingIdentifiers.contains(identifier)
    }
}


final class BackgroundCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}


struct TaskScopedContinuationReservationLedger: Equatable {
    private var counts: [String: Int] = [:]

    mutating func reserve(taskID: String) {
        let normalized = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        counts[normalized, default: 0] += 1
    }

    @discardableResult
    mutating func release(taskID: String) -> Int {
        let normalized = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, let count = counts[normalized] else { return 0 }
        if count <= 1 {
            counts.removeValue(forKey: normalized)
            return 0
        }
        let remaining = count - 1
        counts[normalized] = remaining
        return remaining
    }

    func contains(taskID: String) -> Bool {
        let normalized = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty && (counts[normalized] ?? 0) > 0
    }

    func count(taskID: String) -> Int {
        let normalized = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? 0 : (counts[normalized] ?? 0)
    }
}


enum ContinuedTaskStableStatePolicy {
    static func shouldHoldForTaskScopedMutation(
        status: String,
        hasPendingInteraction: Bool,
        hasTaskScopedMutationReservation: Bool
    ) -> Bool {
        guard hasTaskScopedMutationReservation else { return false }
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !["completed", "failed", "cancelled"].contains(normalized) else { return false }
        return hasPendingInteraction || normalized == "needs_user"
    }

    /// A pending interaction does not imply that the whole Task is blocked.
    /// Host may intentionally keep a Task `active` while already-authorized work
    /// continues and a separate clarification remains unanswered. Release the
    /// iPhone execution owner only when Host lifecycle truth says execution is
    /// actually waiting on / blocked by the user.
    static func shouldReleaseForPendingInteraction(
        status: String,
        hasPendingInteraction: Bool
    ) -> Bool {
        guard hasPendingInteraction else { return false }
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "waiting", "needs_user", "blocked":
            return true
        default:
            return false
        }
    }
}


/// Keeps user-initiated 小卷 tasks eligible to continue after the app backgrounds.
///
/// Presentation SSE is deliberately not part of this execution path. Host Task /
/// Action state remains authoritative; this class only asks iOS for background
/// runtime and then drives the same HTTPS + DeviceActionJournal protocol used in
/// the foreground.


enum FlowerollTaskTerminalNotificationPolicy {
    static func shouldSchedule(appIsActive: Bool) -> Bool {
        !appIsActive
    }
}


@MainActor
final class DeviceBackgroundExecutionController {
    static let shared = DeviceBackgroundExecutionController()

    static let continuedIdentifierPrefix = "com.maxenceyu.floweroll.runtime.continued"
    static let permittedContinuedIdentifierPattern = continuedIdentifierPrefix + ".*"
    static let globalContinuedIdentifier = continuedIdentifierPrefix + ".global"
    static let recoveryIdentifier = "com.maxenceyu.floweroll.runtime.recovery"

    private static let trackedTaskIDsKey = "floweroll.background.userInitiatedTaskIDs"
    private static let continuedTaskIDsKey = "floweroll.background.inAppContinuedTaskIDs"
    private static let continuedOutboxIDsKey = "floweroll.background.inAppContinuedOutboxIDs"
    private static let diagnosticFilename = "background-execution-diagnostic.jsonl"
    private static let logger = Logger(
        subsystem: "com.maxenceyu.floweroll",
        category: "DeviceBackgroundExecution"
    )

    private let defaults = UserDefaults.standard
    private let credentialStore = HostCredentialStore()
    private var registeredIdentifiers = Set<String>()
    private var globalRequestSubmitted = false
    private var globalWork: Task<Void, Never>?
    private var globalExpired = false
    private var globalTaskProgress: [String: (completed: Int64, total: Int64)] = [:]
    private var finiteTaskHandoffs: [String: UIBackgroundTaskIdentifier] = [:]
    private var taskScopedMutationReservations = TaskScopedContinuationReservationLedger()
    private var recoveryWork: Task<Void, Never>?
    private var recoveryScheduling = false

    private init() {}

    // MARK: - Finite foreground -> background bridge

    @discardableResult
    func beginFiniteTaskHandoff(taskID: String) -> Bool {
        let normalized = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if finiteTaskHandoffs[normalized] != nil { return true }

        let diagnosticID = "uikit-background:\(normalized)"
        let identifier = UIApplication.shared.beginBackgroundTask(
            withName: "floweroll.device-handoff.\(String(normalized.prefix(8)))"
        ) { [weak self] in
            guard let self else { return }
            self.endFiniteTaskHandoff(taskID: normalized, reason: "system_expiration")
        }
        guard identifier != .invalid else {
            recordDiagnostic(
                event: "finite_handoff_rejected",
                taskID: normalized,
                identifier: diagnosticID,
                detail: "application_state=\(UIApplication.shared.applicationState.rawValue)"
            )
            return false
        }
        finiteTaskHandoffs[normalized] = identifier
        recordDiagnostic(
            event: "finite_handoff_started",
            taskID: normalized,
            identifier: diagnosticID,
            detail: "application_state=\(UIApplication.shared.applicationState.rawValue)"
        )
        return true
    }

    func endFiniteTaskHandoff(taskID: String, reason: String = "task_inactive") {
        let normalized = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let identifier = finiteTaskHandoffs.removeValue(forKey: normalized) else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        recordDiagnostic(
            event: "finite_handoff_ended",
            taskID: normalized,
            identifier: "uikit-background:\(normalized)",
            detail: "reason=\(reason)"
        )
    }

    func reconcileFiniteTaskHandoffs(activeTaskIDs: Set<String>) {
        for taskID in Array(finiteTaskHandoffs.keys) {
            // Outbox handoffs are explicitly ended when their send scope
            // finishes. Only task-scoped bridges participate in Task Index reconciliation.
            guard !taskID.hasPrefix("outbox:") else { continue }
            if !activeTaskIDs.contains(taskID) {
                endFiniteTaskHandoff(taskID: taskID, reason: "task_no_longer_active")
            }
        }
    }

    func endAllFiniteTaskHandoffs(reason: String) {
        for taskID in Array(finiteTaskHandoffs.keys) {
            endFiniteTaskHandoff(taskID: taskID, reason: reason)
        }
    }

    // MARK: - Registration / migration

    /// App-invoked work uses one global BGCPT; Action Button / Siri /
    /// Shortcuts keep LongRunningIntent. BGProcessing remains recovery-only.
    func register() {
        _ = registerGlobalHandler()
        _ = registerRecoveryHandler()
        cancelLegacyPerTaskContinuedProcessingRequests()

        if !trackedTaskIDs().isEmpty {
            scheduleRecoveryTask(reason: "launch_recovered_tracked_tasks")
        }
        Task { @MainActor in
            await FlowerollActivitySession.retireCustomActivitiesForSystemContinuedProcessing(
                taskIDs: Set(Self.shared.continuedTaskIDs())
            )
            await Self.shared.recoverDurableWorkNow(reason: "app_launch")
            if UIApplication.shared.applicationState == .active,
               await Self.shared.hasInAppContinuedWork() {
                _ = await Self.shared.ensureGlobalContinuedProcessing(
                    subtitle: "正在恢复 App 内未完成任务",
                    reason: "app_launch_in_app_recovery"
                )
            }
        }
    }

    private func cancelLegacyPerTaskContinuedProcessingRequests() {
        for taskID in trackedTaskIDs() {
            let identifier = legacySystemIdentifier(for: taskID)
            guard identifier != Self.globalContinuedIdentifier else { continue }
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            recordDiagnostic(
                event: "legacy_per_task_request_cancelled",
                taskID: taskID,
                identifier: identifier
            )
        }
    }

    // MARK: - Persist-first / durable tracking

    /// Start BGCPT immediately from the foreground user action, before a
    /// potentially slow attachment wait. The UIKit task only bridges scheduler
    /// admission; BGCPT is the extended execution / system presentation owner.
    @discardableResult
    func beginUserInitiatedOutboxContinuation(
        submissionID: String,
        summary: String
    ) async -> Bool {
        trackContinuedOutbox(submissionID)
        let bridgeID = "outbox:" + submissionID
        _ = beginFiniteTaskHandoff(taskID: bridgeID)
        defer {
            endFiniteTaskHandoff(
                taskID: bridgeID,
                reason: "global_bgcpt_admission_finished"
            )
        }
        let concise = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let admitted = await ensureGlobalContinuedProcessing(
            subtitle: concise.isEmpty ? "正在准备任务" : "正在准备：\(String(concise.prefix(56)))",
            reason: "in_app_user_send_persisted"
        )
        if !admitted {
            scheduleRecoveryTask(reason: "in_app_bgcpt_admission_failed")
        }
        return admitted
    }

    func finishUserInitiatedOutboxContinuation(
        submissionID: String,
        reason: String = "host_admitted"
    ) {
        untrackContinuedOutbox(submissionID)
        endFiniteTaskHandoff(taskID: "outbox:" + submissionID, reason: reason)
    }

    /// A Task-scoped reply starts while Host may still expose the old
    /// needs-user snapshot. Keep that exact Task eligible for the already-owned
    /// BGCPT window until the Host mutation is durably acknowledged. This is
    /// intentionally process-local: a crash/relaunch cannot leave a ghost lock,
    /// while the persisted continued Task ID remains the durable execution hint.
    func beginTaskScopedMutationReservation(taskID: String) {
        let normalized = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        taskScopedMutationReservations.reserve(taskID: normalized)
        recordDiagnostic(
            event: "task_scoped_mutation_reservation_started",
            taskID: normalized,
            identifier: Self.globalContinuedIdentifier,
            detail: "count=\(taskScopedMutationReservations.count(taskID: normalized))"
        )
    }

    func endTaskScopedMutationReservation(taskID: String) {
        let normalized = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let remaining = taskScopedMutationReservations.release(taskID: normalized)
        recordDiagnostic(
            event: "task_scoped_mutation_reservation_ended",
            taskID: normalized,
            identifier: Self.globalContinuedIdentifier,
            detail: "remaining=\(remaining)"
        )
    }

    /// An explicit system-entry continuation (Action Button / Siri / Shortcut)
    /// transfers one exact durable Task out of the in-app BGCPT owner set before
    /// LongRunningIntent acquires it. Durable recovery tracking remains intact.
    func handoffInAppTaskToSystemLongRunning(taskID: String, reason: String) {
        let normalized = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let wasOwned = Set(continuedTaskIDs()).contains(normalized)
        untrackContinuedTask(normalized)
        globalTaskProgress.removeValue(forKey: normalized)
        if wasOwned {
            recordDiagnostic(
                event: "in_app_bgcpt_task_handed_to_long_running",
                taskID: normalized,
                identifier: Self.globalContinuedIdentifier,
                detail: "reason=\(reason)"
            )
        }
    }

    @discardableResult
    func submitUserInitiatedContinuation(taskID: String, goal: String) async -> Bool {
        track(taskID)
        trackContinuedTask(taskID)
        guard UIApplication.shared.applicationState == .active else {
            recordDiagnostic(
                event: "global_submit_deferred_not_foreground",
                taskID: taskID,
                identifier: Self.globalContinuedIdentifier
            )
            scheduleRecoveryTask(reason: "continued_processing_requires_foreground")
            return globalWork != nil
        }
        let concise = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        return await ensureGlobalContinuedProcessing(
            subtitle: concise.isEmpty ? "任务已接收" : "正在处理：\(String(concise.prefix(56)))",
            reason: "in_app_task_admitted"
        )
    }

    /// Host admission makes this task eligible for opportunistic BGProcessing
    /// recovery if its LongRunningIntent execution session is later reclaimed.
    func trackDurableTask(taskID: String, reason: String) {
        track(taskID)
        scheduleRecoveryTask(reason: reason)
        recordDiagnostic(
            event: "durable_task_tracked",
            taskID: taskID,
            identifier: Self.recoveryIdentifier,
            detail: "reason=\(reason)"
        )
    }

    func reconcileTrackedTasks(activeTaskIDs: Set<String>) {
        let existing = Set(trackedTaskIDs())
        let removed = existing.subtracting(activeTaskIDs)
        guard !removed.isEmpty else { return }
        for taskID in removed {
            untrack(taskID)
            untrackContinuedTask(taskID)
            globalTaskProgress.removeValue(forKey: taskID)
            recordDiagnostic(
                event: "tracking_finished",
                taskID: taskID,
                identifier: Self.recoveryIdentifier
            )
        }
    }

    // MARK: - In-app global BGCPT

    @discardableResult
    private func ensureGlobalContinuedProcessing(
        subtitle: String,
        reason: String
    ) async -> Bool {
        guard UIApplication.shared.applicationState == .active else {
            scheduleRecoveryTask(reason: reason + "_not_foreground")
            return false
        }
        guard registerGlobalHandler() else {
            scheduleRecoveryTask(reason: reason + "_handler_unavailable")
            return false
        }
        if globalRequestSubmitted || globalWork != nil {
            recordDiagnostic(
                event: "global_submit_duplicate_ignored",
                taskID: "__global__",
                identifier: Self.globalContinuedIdentifier,
                detail: "reason=\(reason)"
            )
            return true
        }

        await FlowerollActivitySession.retireCustomActivitiesForSystemContinuedProcessing(
            taskIDs: Set(continuedTaskIDs())
        )
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.globalContinuedIdentifier,
            title: "小卷正在处理",
            subtitle: subtitle
        )
        request.strategy = .queue
        globalRequestSubmitted = true
        recordDiagnostic(
            event: "global_submit_attempt",
            taskID: "__global__",
            identifier: Self.globalContinuedIdentifier,
            detail: "reason=\(reason)"
        )
        do {
            if #available(iOS 27.0, *) {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } else {
                try BGTaskScheduler.shared.submit(request)
            }
            recordDiagnostic(
                event: "global_submit_succeeded",
                taskID: "__global__",
                identifier: Self.globalContinuedIdentifier,
                detail: "reason=\(reason)"
            )
            scheduleRecoveryTask(reason: "global_continued_processing_submitted")
            return true
        } catch {
            globalRequestSubmitted = false
            let nsError = error as NSError
            recordDiagnostic(
                event: "global_submit_failed",
                taskID: "__global__",
                identifier: Self.globalContinuedIdentifier,
                detail: "reason=\(reason) domain=\(nsError.domain) code=\(nsError.code)"
            )
            scheduleRecoveryTask(reason: "global_continued_processing_submit_failed")
            return false
        }
    }

    @discardableResult
    private func registerGlobalHandler() -> Bool {
        let identifier = Self.globalContinuedIdentifier
        if registeredIdentifiers.contains(identifier) { return true }
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: .main
        ) { task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                Self.shared.handleGlobal(continued)
            }
        }
        if registered {
            registeredIdentifiers.insert(identifier)
            recordDiagnostic(event: "global_register_succeeded", taskID: "__global__", identifier: identifier)
        } else {
            recordDiagnostic(event: "global_register_rejected", taskID: "__global__", identifier: identifier)
        }
        return registered
    }

    private func handleGlobal(_ backgroundTask: BGContinuedProcessingTask) {
        globalWork?.cancel()
        globalRequestSubmitted = false
        globalExpired = false
        recordDiagnostic(
            event: "global_handler_started",
            taskID: "__global__",
            identifier: Self.globalContinuedIdentifier
        )
        backgroundTask.progress.totalUnitCount = SystemEntryProgressPresentationPolicy.totalUnitCount
        backgroundTask.progress.completedUnitCount = SystemEntryProgressPresentationPolicy.admittedUnitCount
        backgroundTask.updateTitle("小卷正在处理", subtitle: "正在连接任务状态")

        let completionGate = BackgroundCompletionGate()
        backgroundTask.expirationHandler = {
            if completionGate.claim() {
                backgroundTask.updateTitle(
                    "小卷继续处理",
                    subtitle: "系统后台窗口已结束，任务状态已安全保留"
                )
                // Window expiration is not Host failure. Completing the OS lease
                // successfully prevents a false failed Live Activity.
                backgroundTask.setTaskCompleted(success: true)
            }
            Task { @MainActor in
                Self.shared.globalExpired = true
                Self.shared.recordDiagnostic(
                    event: "global_handler_expired_completed_successfully",
                    taskID: "__global__",
                    identifier: Self.globalContinuedIdentifier
                )
                Self.shared.scheduleRecoveryTask(reason: "global_continued_processing_expired")
                Self.shared.globalWork?.cancel()
            }
        }

        globalWork = Task { @MainActor [weak self, backgroundTask] in
            guard let self else { return }
            while !Task.isCancelled {
                let needsMore = await self.runInAppContinuedPass()
                let pendingCount = self.continuedOutboxIDs().count
                let taskIDs = self.continuedTaskIDs()
                self.updateGlobalProgress(
                    backgroundTask,
                    pendingCount: pendingCount,
                    taskIDs: taskIDs
                )

                if !needsMore && pendingCount == 0 && taskIDs.isEmpty {
                    backgroundTask.progress.completedUnitCount = SystemEntryProgressPresentationPolicy.totalUnitCount
                    backgroundTask.updateTitle("小卷已处理完", subtitle: "当前后台任务已经结束")
                    if completionGate.claim() { backgroundTask.setTaskCompleted(success: true) }
                    self.recordDiagnostic(
                        event: "global_handler_completed",
                        taskID: "__global__",
                        identifier: Self.globalContinuedIdentifier
                    )
                    break
                }
                backgroundTask.updateTitle(
                    "小卷正在处理",
                    subtitle: self.globalSubtitle(pendingCount: pendingCount, taskCount: taskIDs.count)
                )
                try? await Task.sleep(for: .seconds(1))
            }

            let expired = self.globalExpired
            let remains = await self.hasInAppContinuedWork()
            self.globalWork = nil
            self.globalRequestSubmitted = false
            if expired || remains {
                self.scheduleRecoveryTask(
                    reason: expired ? "global_window_expired_with_work" : "global_window_ended_with_work"
                )
            }
        }
    }

    private func runInAppContinuedPass() async -> Bool {
        let outboxIDs = Set(continuedOutboxIDs())
        let taskIDsBefore = continuedTaskIDs()
        guard !outboxIDs.isEmpty || !taskIDsBefore.isEmpty else { return false }
        let client: FlowerollHostClient
        do { client = try makeStoredClient() } catch { return true }

        let pendingStore = PendingSubmissionStore.shared
        if let pendingStore {
            for item in await pendingStore.pending() where outboxIDs.contains(item.submissionID) {
                guard !Task.isCancelled else { return true }
                do {
                    let task = try await client.submitExisting(item, pendingStore: pendingStore)
                    track(task.taskID)
                    trackContinuedTask(task.taskID)
                    untrackContinuedOutbox(item.submissionID)
                    TaskAttachmentDraft.clearAcceptedReferences(Set((item.attachments ?? []).map(\.id)))
                } catch {
                    try? await pendingStore.markFailed(
                        submissionID: item.submissionID,
                        message: "后台恢复暂未完成，将继续重试。"
                    )
                }
            }
            for turn in await pendingStore.pendingUserTurns() where outboxIDs.contains(turn.eventID) {
                guard !Task.isCancelled else { return true }
                do {
                    _ = try await client.submitExistingUserTurn(turn, pendingStore: pendingStore)
                    track(turn.taskID)
                    trackContinuedTask(turn.taskID)
                    untrackContinuedOutbox(turn.eventID)
                    TaskAttachmentDraft.clearAcceptedReferences(Set((turn.attachments ?? []).map(\.id)))
                } catch {
                    try? await pendingStore.markUserTurnFailed(
                        eventID: turn.eventID,
                        message: "后台恢复暂未完成，将继续重试。"
                    )
                }
            }
        }

        if let worker = DeviceRuntimeWorker.shared {
            for taskID in continuedTaskIDs() {
                guard !Task.isCancelled else { return true }
                let view: HostTaskView
                do { view = try await client.fetchTaskView(taskID: taskID) }
                catch { continue }
                let update = SystemEntryRuntimeCoordinator.progressUpdate(from: view)
                globalTaskProgress[taskID] = (update.completedUnitCount, update.totalUnitCount)
                if await consumeStableTaskState(view) {
                    untrackContinuedTask(taskID)
                    globalTaskProgress.removeValue(forKey: taskID)
                    continue
                }
                if !(await worker.isProcessing(taskID: taskID)) {
                    _ = await worker.processTask(client: client, taskID: taskID, waitSeconds: 4)
                }
                if let after = try? await client.fetchTaskView(taskID: taskID) {
                    let afterUpdate = SystemEntryRuntimeCoordinator.progressUpdate(from: after)
                    globalTaskProgress[taskID] = (afterUpdate.completedUnitCount, afterUpdate.totalUnitCount)
                    if await consumeStableTaskState(after) {
                        untrackContinuedTask(taskID)
                        globalTaskProgress.removeValue(forKey: taskID)
                    }
                }
            }
        }
        return await hasInAppContinuedWork()
    }

    private func updateGlobalProgress(
        _ backgroundTask: BGContinuedProcessingTask,
        pendingCount: Int,
        taskIDs: [String]
    ) {
        let itemTotal = SystemEntryProgressPresentationPolicy.totalUnitCount
        let admitted = SystemEntryProgressPresentationPolicy.admittedUnitCount
        let itemCount = max(1, pendingCount + taskIDs.count)
        let total = Int64(itemCount) * itemTotal
        var completed = Int64(pendingCount) * admitted
        for taskID in taskIDs {
            guard let counts = globalTaskProgress[taskID], counts.total > 0 else {
                completed += admitted
                continue
            }
            let fraction = min(1, max(0, Double(counts.completed) / Double(counts.total)))
            completed += Int64((Double(itemTotal) * fraction).rounded(.down))
        }
        if pendingCount + taskIDs.count > 0 { completed = min(max(0, completed), max(0, total - 1)) }
        else { completed = total }
        let progress = backgroundTask.progress
        guard progress.totalUnitCount != total || progress.completedUnitCount != completed else { return }
        progress.totalUnitCount = total
        progress.completedUnitCount = completed
        recordDiagnostic(
            event: "global_progress_updated",
            taskID: "__global__",
            identifier: Self.globalContinuedIdentifier,
            detail: "completed=\(completed) total=\(total) pending=\(pendingCount) tracked=\(taskIDs.count)"
        )
    }

    private func globalSubtitle(pendingCount: Int, taskCount: Int) -> String {
        if pendingCount > 0, taskCount > 0 { return "正在提交 \(pendingCount) 项，并处理 \(taskCount) 个任务" }
        if pendingCount > 0 { return "正在上传并提交 \(pendingCount) 项任务" }
        if taskCount > 1 { return "正在处理 \(taskCount) 个任务" }
        if taskCount == 1 { return "正在处理任务" }
        return "正在确认任务状态"
    }

    private func hasInAppContinuedWork() async -> Bool {
        !continuedOutboxIDs().isEmpty || !continuedTaskIDs().isEmpty
    }

    // MARK: - Invisible BGProcessing recovery

    @discardableResult
    private func registerRecoveryHandler() -> Bool {
        let identifier = Self.recoveryIdentifier
        if registeredIdentifiers.contains(identifier) { return true }
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: .main
        ) { task in
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                Self.shared.handleRecovery(processing)
            }
        }
        if registered {
            registeredIdentifiers.insert(identifier)
            recordDiagnostic(
                event: "recovery_register_succeeded",
                taskID: "__recovery__",
                identifier: identifier
            )
        } else {
            recordDiagnostic(
                event: "recovery_register_rejected",
                taskID: "__recovery__",
                identifier: identifier
            )
        }
        return registered
    }

    func scheduleRecoveryTask(reason: String) {
        guard !recoveryScheduling, registerRecoveryHandler() else { return }
        recoveryScheduling = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.recoveryScheduling = false }
            let pendingIdentifiers: Set<String> = await withCheckedContinuation { continuation in
                BGTaskScheduler.shared.getPendingTaskRequests { requests in
                    continuation.resume(returning: Set(requests.map(\.identifier)))
                }
            }
            // Re-submission replaces the old request, including its earliest
            // date. Preserve the system's queued opportunity on every refresh.
            guard BackgroundRecoveryRequestPolicy.shouldSubmit(
                identifier: Self.recoveryIdentifier,
                pendingIdentifiers: pendingIdentifiers
            ) else { return }
            let request = BGProcessingTaskRequest(identifier: Self.recoveryIdentifier)
            request.requiresNetworkConnectivity = true
            request.requiresExternalPower = false
            // Do not impose an extra product delay. BGTaskScheduler still owns
            // the real launch time and may defer this request substantially.
            request.earliestBeginDate = Date()
            do {
                if #available(iOS 27.0, *) {
                    try await BGTaskScheduler.shared.submitTaskRequest(request)
                } else {
                    try BGTaskScheduler.shared.submit(request)
                }
                self.recordDiagnostic(
                    event: "recovery_submit_succeeded",
                    taskID: "__recovery__",
                    identifier: Self.recoveryIdentifier,
                    detail: "reason=\(reason)"
                )
            } catch {
                let nsError = error as NSError
                self.recordDiagnostic(
                    event: "recovery_submit_failed",
                    taskID: "__recovery__",
                    identifier: Self.recoveryIdentifier,
                    detail: "reason=\(reason) domain=\(nsError.domain) code=\(nsError.code)"
                )
            }
        }
    }

    private func handleRecovery(_ backgroundTask: BGProcessingTask) {
        recoveryWork?.cancel()
        recordDiagnostic(
            event: "recovery_handler_started",
            taskID: "__recovery__",
            identifier: Self.recoveryIdentifier
        )
        let completionGate = BackgroundCompletionGate()
        backgroundTask.expirationHandler = { [weak self] in
            guard let self else { return }
            if completionGate.claim() {
                backgroundTask.setTaskCompleted(success: true)
            }
            Task { @MainActor in
                self.recordDiagnostic(
                    event: "recovery_handler_expired",
                    taskID: "__recovery__",
                    identifier: Self.recoveryIdentifier
                )
                self.recoveryWork?.cancel()
                self.recoveryWork = nil
                self.scheduleRecoveryTask(reason: "processing_recovery_expired")
            }
        }

        recoveryWork = Task { @MainActor [weak self, backgroundTask] in
            guard let self else { return }
            var consecutivePassesWithoutResolution = 0
            while !Task.isCancelled {
                let needsMoreWork = await self.runRecoveryPass(includeDeviceActions: true)
                if !needsMoreWork {
                    self.recordDiagnostic(
                        event: "recovery_handler_completed",
                        taskID: "__recovery__",
                        identifier: Self.recoveryIdentifier,
                        detail: "durable_work_remaining=false"
                    )
                    if completionGate.claim() {
                        backgroundTask.setTaskCompleted(success: true)
                    }
                    self.recoveryWork = nil
                    return
                }

                // A system-granted processing window is scarce: keep consuming
                // it instead of voluntarily ending after one pass. Back off a
                // little when Host work remains to avoid a tight poll loop.
                consecutivePassesWithoutResolution += 1
                let delaySeconds = min(5, max(1, consecutivePassesWithoutResolution))
                do {
                    try await Task.sleep(for: .seconds(delaySeconds))
                } catch {
                    break
                }
            }

            let workRemains = await self.hasDurableWork()
            self.recordDiagnostic(
                event: "recovery_handler_cancelled",
                taskID: "__recovery__",
                identifier: Self.recoveryIdentifier,
                detail: "durable_work_remaining=\(workRemains)"
            )
            if workRemains {
                self.scheduleRecoveryTask(reason: "processing_recovery_cancelled_with_work")
            }
            if completionGate.claim() {
                backgroundTask.setTaskCompleted(success: true)
            }
            self.recoveryWork = nil
        }
    }

    /// Run one bounded durable recovery pass in an execution window the system
    /// already granted (foreground launch, background URLSession callback,
    /// LongRunningIntent, or BGProcessing). All replay identities are durable
    /// and idempotent.
    func recoverDurableWorkNow(
        reason: String,
        includeDeviceActions: Bool = true
    ) async {
        let needsMoreWork = await runRecoveryPass(includeDeviceActions: includeDeviceActions)
        recordDiagnostic(
            event: "durable_recovery_pass_finished",
            taskID: "__recovery__",
            identifier: Self.recoveryIdentifier,
            detail: "reason=\(reason) needs_more=\(needsMoreWork)"
        )
        if needsMoreWork {
            scheduleRecoveryTask(reason: reason + "_remaining")
        }
    }

    // MARK: - Durable outbox / device execution pass

    private func runRecoveryPass(includeDeviceActions: Bool) async -> Bool {
        let pendingStore = PendingSubmissionStore.shared
        let submissions = await pendingStore?.pending() ?? []
        let userTurns = await pendingStore?.pendingUserTurns() ?? []
        let trackedBefore = trackedTaskIDs()
        guard !submissions.isEmpty || !userTurns.isEmpty || !trackedBefore.isEmpty else { return false }

        let client: FlowerollHostClient
        do {
            client = try makeStoredClient()
        } catch {
            return true
        }

        var needsMoreWork = false
        if let pendingStore {
            for item in submissions {
                guard !Task.isCancelled else { return true }
                if !includeDeviceActions {
                    guard await attachmentsAreVerified(item.attachments ?? [], client: client) else {
                        needsMoreWork = true
                        continue
                    }
                }
                do {
                    let task = try await client.submitExisting(item, pendingStore: pendingStore)
                    track(task.taskID)
                    TaskAttachmentDraft.clearAcceptedReferences(Set((item.attachments ?? []).map(\.id)))
                } catch {
                    needsMoreWork = true
                    try? await pendingStore.markFailed(
                        submissionID: item.submissionID,
                        message: "后台恢复暂未完成，将继续重试。"
                    )
                }
            }

            for turn in userTurns {
                guard !Task.isCancelled else { return true }
                if !includeDeviceActions {
                    guard await attachmentsAreVerified(turn.attachments ?? [], client: client) else {
                        needsMoreWork = true
                        continue
                    }
                }
                do {
                    _ = try await client.submitExistingUserTurn(turn, pendingStore: pendingStore)
                    track(turn.taskID)
                    TaskAttachmentDraft.clearAcceptedReferences(Set((turn.attachments ?? []).map(\.id)))
                } catch {
                    needsMoreWork = true
                    try? await pendingStore.markUserTurnFailed(
                        eventID: turn.eventID,
                        message: "后台恢复暂未完成，将继续重试。"
                    )
                }
            }
        }

        if includeDeviceActions, let worker = DeviceRuntimeWorker.shared {
            for taskID in trackedTaskIDs() {
                guard !Task.isCancelled else { return true }
                let view: HostTaskView
                do {
                    view = try await client.fetchTaskView(taskID: taskID)
                } catch {
                    needsMoreWork = true
                    continue
                }
                if await consumeStableTaskState(view) { continue }

                needsMoreWork = true
                if !(await worker.isProcessing(taskID: taskID)) {
                    _ = await worker.processTask(client: client, taskID: taskID, waitSeconds: 4)
                }
                if let after = try? await client.fetchTaskView(taskID: taskID) {
                    _ = await consumeStableTaskState(after)
                }
            }
        }

        let remainingSubmissions = await pendingStore?.pending() ?? []
        let remainingTurns = await pendingStore?.pendingUserTurns() ?? []
        let outboxRemaining = !remainingSubmissions.isEmpty || !remainingTurns.isEmpty
        return needsMoreWork || outboxRemaining || !trackedTaskIDs().isEmpty
    }

    private func attachmentsAreVerified(
        _ attachments: [PendingAttachment],
        client: FlowerollHostClient
    ) async -> Bool {
        for attachment in attachments {
            do {
                guard try await client.uploadedAttachmentIfVerified(attachment) != nil else { return false }
            } catch {
                return false
            }
        }
        return true
    }

    /// Returns true when no further device execution is required for this Task.
    private func consumeStableTaskState(_ view: HostTaskView) async -> Bool {
        let taskID = view.task.taskID
        let status = view.task.status.lowercased()
        let hasPendingInteraction = view.pendingInteraction != nil
        if ContinuedTaskStableStatePolicy.shouldHoldForTaskScopedMutation(
            status: status,
            hasPendingInteraction: hasPendingInteraction,
            hasTaskScopedMutationReservation: taskScopedMutationReservations.contains(taskID: taskID)
        ) {
            return false
        }
        if ContinuedTaskStableStatePolicy.shouldReleaseForPendingInteraction(
            status: status,
            hasPendingInteraction: hasPendingInteraction
        ) {
            untrack(taskID)
            return true
        }
        switch status {
        case "completed":
            untrack(taskID)
            await FlowerollTaskNotifications.notifyTerminalIfNeeded(
                taskID: taskID,
                title: "小卷任务已完成",
                body: view.timeline.last(where: { $0.isUserVisible })?.summary
                    ?? view.timeline.last(where: { $0.isUserVisible })?.title
                    ?? view.task.goal
            )
            return true
        case "failed":
            untrack(taskID)
            await FlowerollTaskNotifications.notifyTerminalIfNeeded(
                taskID: taskID,
                title: "小卷任务需要查看",
                body: view.timeline.last(where: { $0.isUserVisible })?.summary
                    ?? view.timeline.last(where: { $0.isUserVisible })?.title
                    ?? view.task.goal
            )
            return true
        case "cancelled", "needs_user":
            untrack(taskID)
            return true
        default:
            return false
        }
    }

    private func hasDurableWork() async -> Bool {
        let pendingStore = PendingSubmissionStore.shared
        if !(await pendingStore?.pending() ?? []).isEmpty { return true }
        if !(await pendingStore?.pendingUserTurns() ?? []).isEmpty { return true }
        return !trackedTaskIDs().isEmpty
    }

    // MARK: - Stored Host / tracking

    private func makeStoredClient() throws -> FlowerollHostClient {
        let raw = defaults.string(forKey: RuntimeTaskStore.endpointDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: raw), url.scheme != nil, url.host != nil else {
            throw RuntimeTaskStoreError.hostNotConfigured
        }
        let host = url.host?.lowercased()
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        let client = isLoopback
            ? FlowerollHostClient(baseURL: url)
            : try FlowerollHostClient.paired(baseURL: url, credentialStore: credentialStore)
        try client.validateEndpointSecurity()
        return client
    }

    private func legacySystemIdentifier(for taskID: String) -> String {
        let compact = taskID.lowercased().filter { $0.isLetter || $0.isNumber }
        return Self.continuedIdentifierPrefix + "." + compact
    }

    private func trackContinuedTask(_ taskID: String) {
        let normalized = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        var ids = Set(continuedTaskIDs())
        ids.insert(normalized)
        defaults.set(ids.sorted(), forKey: Self.continuedTaskIDsKey)
    }

    private func untrackContinuedTask(_ taskID: String) {
        var ids = Set(continuedTaskIDs())
        ids.remove(taskID)
        defaults.set(ids.sorted(), forKey: Self.continuedTaskIDsKey)
    }

    private func continuedTaskIDs() -> [String] {
        defaults.stringArray(forKey: Self.continuedTaskIDsKey) ?? []
    }

    private func trackContinuedOutbox(_ eventID: String) {
        let normalized = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        var ids = Set(continuedOutboxIDs())
        ids.insert(normalized)
        defaults.set(ids.sorted(), forKey: Self.continuedOutboxIDsKey)
    }

    private func untrackContinuedOutbox(_ eventID: String) {
        var ids = Set(continuedOutboxIDs())
        ids.remove(eventID)
        defaults.set(ids.sorted(), forKey: Self.continuedOutboxIDsKey)
    }

    private func continuedOutboxIDs() -> [String] {
        defaults.stringArray(forKey: Self.continuedOutboxIDsKey) ?? []
    }

    private func track(_ taskID: String) {
        let normalized = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        var ids = Set(trackedTaskIDs())
        ids.insert(normalized)
        defaults.set(ids.sorted(), forKey: Self.trackedTaskIDsKey)
    }

    private func untrack(_ taskID: String) {
        var ids = Set(trackedTaskIDs())
        ids.remove(taskID)
        defaults.set(ids.sorted(), forKey: Self.trackedTaskIDsKey)
    }

    private func trackedTaskIDs() -> [String] {
        defaults.stringArray(forKey: Self.trackedTaskIDsKey) ?? []
    }

    private func recordDiagnostic(
        event: String,
        taskID: String,
        identifier: String,
        detail: String? = nil
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var payload: [String: Any] = [
            "timestamp": timestamp,
            "event": event,
            "task_id": taskID,
            "system_identifier": identifier,
        ]
        if let detail, !detail.isEmpty { payload["detail"] = detail }
        guard JSONSerialization.isValidJSONObject(payload),
              var data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { return }
        data.append(0x0A)

        do {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("Floweroll", isDirectory: true)
            .appendingPathComponent("RuntimeClient", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(Self.diagnosticFilename)
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
        } catch {
            Self.logger.error(
                "background diagnostic write failed; error_type=\(String(reflecting: type(of: error)), privacy: .public)"
            )
        }
    }
}
