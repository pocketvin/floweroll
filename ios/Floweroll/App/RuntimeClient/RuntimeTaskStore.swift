import Foundation
import Observation
import OSLog


enum RuntimeTaskStoreError: Error, LocalizedError, Equatable {
    case hostNotConfigured
    case invalidHostURL
    case pendingStoreUnavailable
    case noCancellableHomeTask

    var errorDescription: String? {
        switch self {
        case .hostNotConfigured:
            return "还没有配置花卷的后台 Host。"
        case .invalidHostURL:
            return "Host 地址无效。"
        case .pendingStoreUnavailable:
            return "无法打开本机待提交任务存储。"
        case .noCancellableHomeTask:
            return "当前首页没有可取消的任务。"
        }
    }
}

enum RuntimeConnectionState: Equatable {
    case notConfigured
    case connecting
    case connected
    case failed(String)
}


enum HomePresentationOwnership: String, Codable, Sendable, Equatable {
    case automaticRestore
    case explicitUserSelection
    case foregroundSubmission
    case systemEntry

    var isDurableSelection: Bool {
        self != .automaticRestore
    }
}


struct RuntimeTaskCancellationResult: Equatable, Sendable {
    let taskID: String
    let status: String
    let cancellationPending: Bool
}

enum RuntimeSubmissionCancellationOutcome: Equatable, Sendable {
    case stoppedBeforeAdmission
    case cancelledAdmittedTask(RuntimeTaskCancellationResult)
    case uncertain
}

struct RuntimeTaskInboxReadModel: Equatable, Sendable {
    let presentedThreadID: String?
    let needsUser: [HostTaskIndexItem]
    let runningElsewhere: [HostTaskIndexItem]
    let terminalElsewhere: [HostTaskIndexItem]

    var isEmpty: Bool {
        needsUser.isEmpty && runningElsewhere.isEmpty && terminalElsewhere.isEmpty
    }
}

struct RuntimeCompletionAttentionReadModel: Equatable, Sendable {
    let terminalTasks: [HostTaskIndexItem]
}

struct RuntimeHomePresentationSelection: Equatable, Sendable {
    let threadID: String
    let ownership: HomePresentationOwnership
    let continuationTaskID: String?
}

enum RuntimeLocalUserTurnDeliveryState: String, Equatable, Sendable {
    case sending
    case accepted
}

struct RuntimeLocalUserTurnProjection: Equatable, Sendable, Identifiable {
    let taskID: String
    let eventID: String
    let text: String
    let attachmentIDs: [String]
    let baselineAuthoritativeUserInputCount: Int
    let createdAt: Date
    var deliveryState: RuntimeLocalUserTurnDeliveryState
    var id: String { eventID }
}

private enum HomeThreadHydrationResult: Equatable {
    case notRequested
    case loaded(Int)
    case failed
}


@MainActor
@Observable
final class RuntimeTaskStore {
    nonisolated static let endpointDefaultsKey = "floweroll.hostEndpoint"
    nonisolated static let continuationTaskDefaultsKey = "floweroll.runtime.currentTaskID"
    nonisolated static let homeThreadDefaultsKey = "floweroll.home.currentThreadID"
    nonisolated static let homeThreadRetiredAtDefaultsKey = "floweroll.home.threadRetiredAt"
    nonisolated static let homeThreadRetiredIDDefaultsKey = "floweroll.home.retiredThreadID"
    nonisolated static let homeThreadAwaitingNewDefaultsKey = "floweroll.home.awaitingNewThread"
    nonisolated static let homePresentationOwnershipDefaultsKey = "floweroll.home.presentationOwnership.v1"
    private static let logger = Logger(
        subsystem: "com.maxenceyu.floweroll",
        category: "RuntimeTaskStore"
    )
    private static let historyCacheFilename = "task-history-index-cache.json"
    private static let activePresentationLimit = 100

    private struct HistoryPresentationCache: Codable {
        let items: [HostTaskIndexItem]
    }

    private struct TaskViewFetchLease {
        let id: UUID
        let task: Task<HostTaskView, Error>
    }

    private struct AttachmentUploadLease {
        let generation: UUID
        let task: Task<TaskMaterialFile, Error>
    }

    private let defaults: UserDefaults
    private let credentialStore: HostCredentialStore
    private let session: URLSession
    private let pendingStore: PendingSubmissionStore?
    private let deviceWorker: DeviceRuntimeWorker?
    let completionAttentionOwner: RuntimeCompletionAttentionOwner
    var completionAttentionState: RuntimeCompletionAttentionOwner { completionAttentionOwner }
    let terminalReviewState: RuntimeTerminalReviewState
    let historyPresentationState: RuntimeTaskHistoryPresentationState

    @ObservationIgnored
    private var deviceExecutionLeases: [String: Task<Void, Never>] = [:]
    @ObservationIgnored
    private var deviceExecutionLeaseGenerations: [String: UUID] = [:]
    @ObservationIgnored
    private var historyPaginationInitialized = false
    @ObservationIgnored
    private var presentationIndexRefreshInFlight = false
    @ObservationIgnored
    private var taskViewFetchLeases: [String: TaskViewFetchLease] = [:]
    @ObservationIgnored
    private var cancellationConvergenceTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored
    private var cancellationConvergenceGenerations: [String: UUID] = [:]
    @ObservationIgnored
    private var attachmentUploadLeases: [String: AttachmentUploadLease] = [:]

    private(set) var runningTasks: [HostTaskIndexItem] = []
    private(set) var needsUserTasks: [HostTaskIndexItem] = []
    private(set) var historyTasks: [HostTaskIndexItem] = []
    private(set) var historyNextCursor: String?
    private(set) var isLoadingMoreHistory = false
    private(set) var threadTaskCache: [String: [HostTaskIndexItem]] = [:]
    private(set) var taskViewCache: [String: HostTaskView] = [:]
    private(set) var homeThreadID: String? = nil
    private(set) var homePresentationOwnership: HomePresentationOwnership? = nil
    private(set) var connectionState: RuntimeConnectionState = .notConfigured
    private(set) var isRefreshing = false
    private(set) var isSubmitting = false
    private(set) var attachmentUploadStates: [String: AttachmentUploadState] = [:]
    private(set) var localUserTurnProjections: [String: [RuntimeLocalUserTurnProjection]] = [:]
    private(set) var lastError: String?

    var configuredEndpoint: String {
        defaults.string(forKey: Self.endpointDefaultsKey) ?? ""
    }

    var hasConfiguredEndpoint: Bool {
        !configuredEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var currentHomeThreadID: String? {
        homeThreadID
    }

    var hasHomePresentationSelection: Bool {
        currentHomeThreadID != nil && !isAwaitingNewHomeThread
    }

    var isAwaitingNewHomeThread: Bool {
        defaults.bool(forKey: Self.homeThreadAwaitingNewDefaultsKey)
    }

    var canLoadMoreHistory: Bool {
        historyNextCursor != nil
    }

    var allKnownTasks: [HostTaskIndexItem] {
        Self.canonicalTaskIndexItems(activeTasks + historyTasks)
    }

    var homeThreadTasks: [HostTaskIndexItem] {
        guard let threadID = currentHomeThreadID else { return [] }
        return Self.canonicalTaskIndexItems(
            allKnownTasks.filter { $0.threadID == threadID }
                + (threadTaskCache[threadID] ?? [])
        )
        .sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.taskID < rhs.taskID }
            return lhs.createdAt < rhs.createdAt
        }
    }

    var latestHomeThreadTask: HostTaskIndexItem? {
        homeThreadTasks.max { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt { return lhs.taskID < rhs.taskID }
            return lhs.updatedAt < rhs.updatedAt
        }
    }

    var activeHomeThreadTask: HostTaskIndexItem? {
        homeThreadTasks.last(where: { !Self.isTerminalStatus($0.status) })
    }

    var activeTasks: [HostTaskIndexItem] {
        Self.canonicalTaskIndexItems(needsUserTasks + runningTasks)
            .filter { !$0.presentationTruth.isTerminal }
    }

    /// Durable Task truth for the global Inbox. Presentation-only acknowledgement
    /// remains a foreground concern: C can filter `terminalElsewhere` with its
    /// existing seen/ack state without inventing another lifecycle state.
    var taskInboxReadModel: RuntimeTaskInboxReadModel {
        let presentedThreadID = currentHomeThreadID
        let isElsewhere: (HostTaskIndexItem) -> Bool = { task in
            guard let presentedThreadID else { return true }
            return task.threadID != presentedThreadID
        }
        let newestFirst: ([HostTaskIndexItem]) -> [HostTaskIndexItem] = { tasks in
            tasks.sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt { return lhs.taskID > rhs.taskID }
                return lhs.updatedAt > rhs.updatedAt
            }
        }
        return RuntimeTaskInboxReadModel(
            presentedThreadID: presentedThreadID,
            needsUser: newestFirst(needsUserTasks),
            runningElsewhere: newestFirst(runningTasks.filter(isElsewhere)),
            terminalElsewhere: newestFirst(historyTasks.filter(isElsewhere))
        )
    }

    /// App-global completion attention derives only from the canonical terminal
    /// Task read model. It is presentation state, never a second Task lifecycle.
    var completionAttentionReadModel: RuntimeCompletionAttentionReadModel {
        RuntimeCompletionAttentionReadModel(
            terminalTasks: Self.canonicalTaskIndexItems(historyTasks)
                .filter { $0.presentationTruth.isTerminal }
        )
    }

    func beginCompletionAttentionAppSession(at date: Date = Date()) {
        completionAttentionOwner.beginAppSession(at: date)
        completionAttentionOwner.reconcile(readModel: completionAttentionReadModel)
    }

    func reconcileCompletionAttention() {
        completionAttentionOwner.reconcile(readModel: completionAttentionReadModel)
    }

    var currentHomePresentationSelection: RuntimeHomePresentationSelection? {
        guard let threadID = currentHomeThreadID,
              let ownership = homePresentationOwnership,
              !isAwaitingNewHomeThread
        else { return nil }
        return RuntimeHomePresentationSelection(
            threadID: threadID,
            ownership: ownership,
            continuationTaskID: defaults.string(forKey: Self.continuationTaskDefaultsKey)
        )
    }

    init(
        defaults: UserDefaults = .standard,
        credentialStore: HostCredentialStore = HostCredentialStore(),
        session: URLSession = .shared,
        pendingStore: PendingSubmissionStore? = PendingSubmissionStore.shared,
        deviceWorker: DeviceRuntimeWorker? = DeviceRuntimeWorker.shared
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        self.session = session
        self.pendingStore = pendingStore
        self.deviceWorker = deviceWorker
        self.completionAttentionOwner = RuntimeCompletionAttentionOwner(defaults: defaults)
        self.terminalReviewState = RuntimeTerminalReviewState(defaults: defaults)
        self.historyPresentationState = RuntimeTaskHistoryPresentationState(defaults: defaults)
        self.homeThreadID = defaults.string(forKey: Self.homeThreadDefaultsKey)
        self.homePresentationOwnership = Self.persistedHomePresentationOwnership(
            defaults: defaults,
            threadID: self.homeThreadID
        )
        self.historyTasks = Self.loadHistoryPresentationCache()
        if self.deviceWorker != nil {
            Self.logger.notice("shared DeviceActionJournal initialized")
        } else {
            Self.logger.error("shared DeviceActionJournal init failed")
        }
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let injectedEndpoint = environment["FLOWEROLL_DEBUG_HOST_ENDPOINT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !injectedEndpoint.isEmpty,
           let url = URL(string: injectedEndpoint),
           (url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""))),
           url.host != nil {
            defaults.set(injectedEndpoint, forKey: Self.endpointDefaultsKey)
            if let injectedToken = environment["FLOWEROLL_DEBUG_HOST_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !injectedToken.isEmpty {
                try? credentialStore.saveBearerToken(injectedToken, for: url)
            }
            Self.logger.notice("applied DEBUG Host endpoint injection")
        }
        #endif

        let endpoint = defaults.string(forKey: Self.endpointDefaultsKey)
        self.connectionState = endpoint == nil ? .notConfigured : .connecting
        reconcileCompletionAttention()
        Self.logger.info("initialized; endpoint_configured=\(endpoint != nil, privacy: .public)")
    }

    func makeClient() throws -> FlowerollHostClient {
        let raw = configuredEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw RuntimeTaskStoreError.hostNotConfigured
        }
        guard let url = URL(string: raw), url.scheme != nil, url.host != nil else {
            throw RuntimeTaskStoreError.invalidHostURL
        }
        Self.logger.info(
            "creating Host client; scheme=\(url.scheme ?? "?", privacy: .public) host=\(url.host ?? "?", privacy: .public) port=\(url.port ?? -1, privacy: .public)"
        )
        let host = url.host?.lowercased()
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        let client: FlowerollHostClient
        if isLoopback {
            // Simulator/local development does not need a pairing secret, and
            // CODE_SIGNING_ALLOWED=NO builds cannot reliably use Keychain.
            #if DEBUG
            client = FlowerollHostClient(
                baseURL: url,
                session: session,
                bearerToken: ProcessInfo.processInfo.environment["FLOWEROLL_DEBUG_HOST_TOKEN"]
            )
            #else
            client = FlowerollHostClient(baseURL: url, session: session)
            #endif
        } else {
            client = try FlowerollHostClient.paired(
                baseURL: url,
                session: session,
                credentialStore: credentialStore
            )
        }
        try client.validateEndpointSecurity()
        return client
    }

    func bootstrap() async {
        Self.logger.info("bootstrap started; configured=\(self.hasConfiguredEndpoint, privacy: .public)")
        guard hasConfiguredEndpoint else {
            connectionState = .notConfigured
            lastError = nil
            Self.logger.info("bootstrap stopped: no Host endpoint")
            return
        }
        connectionState = .connecting
        do {
            await retryPendingSubmissions()
            try await refreshThrowing()
            Self.logger.info("bootstrap completed")
        } catch {
            let message = Self.userMessage(for: error)
            Self.logger.error(
                "bootstrap failed; error_type=\(String(reflecting: type(of: error)), privacy: .public) message=\(message, privacy: .public)"
            )
            connectionState = .failed(message)
            lastError = message
        }
    }

    func refreshCurrentHomeThreadFast() async {
        guard hasConfiguredEndpoint else { return }
        synchronizeHomePresentationSelectionFromDefaults()
        guard let threadID = homeThreadID, !threadID.isEmpty else { return }
        do {
            let client = try makeClient()
            _ = try await fetchThreadTaskPage(threadID: threadID, cursor: nil, limit: 20)
            // Returning from background cannot rely on the old SSE socket still
            // being alive. Pull one authoritative /view snapshot so every
            // presentation event produced while iOS suspended the app is visible
            // immediately; the live model can then continue from that cursor.
            if let taskID = latestHomeThreadTask?.taskID {
                do {
                    let snapshot = try await client.fetchTaskView(taskID: taskID)
                    _ = cacheTaskView(snapshot)
                } catch {
                    Self.logger.notice(
                        "Home foreground exact view reconciliation deferred; task=\(String(taskID.prefix(8)), privacy: .public)"
                    )
                }
            }
            if connectionState != .connected {
                connectionState = .connected
            }
            if lastError != nil {
                lastError = nil
            }
        } catch {
            // Fast-path failure must not blank already-rendered Home state. The
            // ordinary refresh path will surface a persistent connection error.
        }
    }

    func refresh() async {
        guard hasConfiguredEndpoint else {
            runningTasks = []
            needsUserTasks = []
            historyTasks = []
            reconcileCompletionAttention()
            historyNextCursor = nil
            historyPaginationInitialized = false
            connectionState = .notConfigured
            lastError = nil
            return
        }
        do {
            try await refreshThrowing()
        } catch {
            let message = Self.userMessage(for: error)
            connectionState = .failed(message)
            lastError = message
        }
    }

    /// User-initiated Home pull-to-refresh.
    ///
    /// This is deliberately read-only: it refreshes the durable Task Index,
    /// the exact currently presented Thread, and the latest Task `/view`, but
    /// it never runs DeviceRuntimeWorker, retries submissions, schedules
    /// notifications, or re-dispatches an Action. That keeps "刷新状态" from
    /// becoming an accidental side-effect trigger.
    func refreshHomeStatusReadModel() async {
        guard hasConfiguredEndpoint else {
            connectionState = .notConfigured
            lastError = nil
            return
        }
        guard !isRefreshing else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let client = try makeClient()
            let pages = try await fetchIndexPages(client: client)
            adoptIndexPages(
                running: pages.running,
                needsUser: pages.needsUser,
                history: pages.history
            )

            let hydration = await hydrateSelectedHomeThread(client: client)
            reconcileHomeThreadPresentation(now: Date(), hydration: hydration)

            // The Index/Thread pages are enough for Inbox and lifecycle truth.
            // Refresh the latest exact Task view too so a dropped SSE cannot
            // leave Home's visible timeline/result behind the authoritative
            // Host state. Failure here does not discard the fresh Index read.
            if let taskID = latestHomeThreadTask?.taskID {
                do {
                    let snapshot = try await client.fetchTaskView(taskID: taskID)
                    _ = cacheTaskView(snapshot)
                } catch {
                    Self.logger.notice(
                        "Home manual refresh exact view deferred; task=\(String(taskID.prefix(8)), privacy: .public)"
                    )
                }
            }

            connectionState = .connected
            lastError = nil
        } catch {
            let message = Self.userMessage(for: error)
            connectionState = .failed(message)
            lastError = message
        }
    }

    /// Refresh only the durable Task Index presentation read model.
    ///
    /// Home uses this while visible to discover other background Tasks that
    /// reached a terminal state. It deliberately does not run device work,
    /// notifications, Live Activity reconciliation, or Home-thread hydration.
    /// Failures keep the last good presentation model instead of flashing a
    /// transient connection error every polling interval.
    func refreshPresentationIndex() async {
        guard hasConfiguredEndpoint,
              !isRefreshing,
              !presentationIndexRefreshInFlight
        else { return }

        presentationIndexRefreshInFlight = true
        defer { presentationIndexRefreshInFlight = false }
        do {
            let pages = try await fetchIndexPages(client: makeClient())
            adoptIndexPages(
                running: pages.running,
                needsUser: pages.needsUser,
                history: pages.history
            )
            if connectionState != .connected {
                connectionState = .connected
            }
        } catch {
            // Presentation polling is opportunistic. The ordinary explicit
            // refresh path owns durable connection-error presentation.
        }
    }

    func loadMoreHistory() async {
        guard hasConfiguredEndpoint, !isLoadingMoreHistory, let cursor = historyNextCursor else { return }
        isLoadingMoreHistory = true
        defer { isLoadingMoreHistory = false }
        do {
            let page = try await makeClient().fetchTaskIndex(
                bucket: "history", cursor: cursor, limit: 50
            )
            historyTasks = Self.mergedTaskIndexItems(existing: historyTasks, incoming: page.items)
                .filter { $0.presentationTruth.isTerminal }
            reconcileCompletionAttention()
            historyNextCursor = page.nextCursor
            historyPaginationInitialized = true
            persistHistoryPresentationCache()
            connectionState = .connected
            lastError = nil
        } catch {
            let message = Self.userMessage(for: error)
            connectionState = .failed(message)
            lastError = message
        }
    }

    nonisolated static func mergedTaskIndexItems(
        existing: [HostTaskIndexItem],
        incoming: [HostTaskIndexItem]
    ) -> [HostTaskIndexItem] {
        canonicalTaskIndexItems(existing + incoming)
    }

    nonisolated static func canonicalTaskIndexItems(
        _ items: [HostTaskIndexItem]
    ) -> [HostTaskIndexItem] {
        var byID: [String: HostTaskIndexItem] = [:]
        for raw in items {
            let task = RuntimeTaskPresentationReducer.normalized(raw)
            if let existing = byID[task.taskID] {
                byID[task.taskID] = RuntimeTaskPresentationReducer.preferred(
                    existing: existing,
                    incoming: task
                )
            } else {
                byID[task.taskID] = task
            }
        }
        return byID.values.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt { return lhs.taskID > rhs.taskID }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    /// Begin transferring a draft attachment as soon as the bytes are durable on-device.
    /// Uploading a file does not create/bind a Runtime Task; the later send keeps
    /// the existing submission_id boundary and only binds these exact file IDs.
    func preuploadAttachment(_ attachment: PendingAttachment) {
        if case .uploaded? = attachmentUploadStates[attachment.id] { return }
        do {
            _ = try startAttachmentUploadIfNeeded(attachment)
        } catch {
            attachmentUploadStates[attachment.id] = .failed(Self.userMessage(for: error))
        }
    }

    func preuploadAttachments(_ attachments: [PendingAttachment]) {
        for attachment in attachments { preuploadAttachment(attachment) }
        if !attachments.isEmpty, !attachmentUploadLeases.isEmpty {
            AttachmentBackgroundUploadTransport.shared.refreshProgress()
        }
    }

    func cancelAttachmentPreupload(attachmentID: String) {
        // Explicit removal is different from a background worker losing its
        // execution window: stop the system transfer, not merely its waiter.
        AttachmentBackgroundUploadTransport.shared.cancel(attachmentID: attachmentID)
        attachmentUploadLeases[attachmentID]?.task.cancel()
        attachmentUploadLeases.removeValue(forKey: attachmentID)
        attachmentUploadStates.removeValue(forKey: attachmentID)
    }

    private func startAttachmentUploadIfNeeded(_ attachment: PendingAttachment) throws -> AttachmentUploadLease {
        if let existing = attachmentUploadLeases[attachment.id] { return existing }

        let client = try makeClient()
        let generation = UUID()
        let handler = attachmentEventHandler()
        attachmentUploadStates[attachment.id] = .queued
        let task = Task {
            try Task.checkCancellation()
            return try await client.uploadTaskAttachment(attachment, onEvent: handler)
        }
        let lease = AttachmentUploadLease(generation: generation, task: task)
        attachmentUploadLeases[attachment.id] = lease

        Task { @MainActor [weak self] in
            do {
                _ = try await task.value
            } catch is CancellationError {
                // Removing a draft item may stop an in-flight pre-upload. A later
                // re-add/send can safely resume from Host-confirmed offset.
            } catch {
                guard let self, self.attachmentUploadLeases[attachment.id]?.generation == generation else { return }
                self.attachmentUploadStates[attachment.id] = .failed(Self.userMessage(for: error))
            }
            guard let self, self.attachmentUploadLeases[attachment.id]?.generation == generation else { return }
            self.attachmentUploadLeases.removeValue(forKey: attachment.id)
        }
        return lease
    }

    /// Wait for the same draft pre-upload lease without owning/cancelling it.
    /// This polling wait is intentionally cancellation-aware: cancelling Send
    /// stops waiting immediately, while the useful draft pre-upload may continue.
    private func prepareAttachmentsForSubmission(_ attachments: [PendingAttachment]) async throws {
        for attachment in attachments {
            try Task.checkCancellation()
            if case .uploaded? = attachmentUploadStates[attachment.id] { continue }

            var retriedAfterSpeculativeFailure = false
            if attachmentUploadLeases[attachment.id] == nil {
                if case .failed? = attachmentUploadStates[attachment.id] {
                    retriedAfterSpeculativeFailure = true
                    attachmentUploadStates[attachment.id] = .queued
                }
                _ = try startAttachmentUploadIfNeeded(attachment)
            }

            while true {
                try Task.checkCancellation()
                if case .uploaded? = attachmentUploadStates[attachment.id] { break }
                if case let .failed(message)? = attachmentUploadStates[attachment.id],
                   attachmentUploadLeases[attachment.id] == nil {
                    guard !retriedAfterSpeculativeFailure else {
                        throw MaterialsError.message(message)
                    }
                    retriedAfterSpeculativeFailure = true
                    attachmentUploadStates[attachment.id] = .queued
                    _ = try startAttachmentUploadIfNeeded(attachment)
                }
                try await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    @discardableResult
    func submit(
        text: String,
        attachments: [PendingAttachment] = [],
        submissionID: String = UUID().uuidString
    ) async throws -> HostTask {
        guard let pendingStore else {
            throw RuntimeTaskStoreError.pendingStoreUnavailable
        }
        isSubmitting = true
        defer { isSubmitting = false }

        let client = try makeClient()
        // Persist the exact send before waiting for attachment transport. If iOS
        // suspends or kills the app while background URLSession still owns the
        // bytes, bootstrap/background recovery can replay this same submission_id.
        let pending = try await pendingStore.create(
            text: text,
            invocationSource: "ios_new_task",
            attachments: attachments,
            submissionID: submissionID
        )
        _ = await DeviceBackgroundExecutionController.shared.beginUserInitiatedOutboxContinuation(
            submissionID: submissionID,
            summary: text
        )
        defer {
            DeviceBackgroundExecutionController.shared.finishUserInitiatedOutboxContinuation(
                submissionID: submissionID,
                reason: "submission_scope_finished"
            )
        }
        DeviceBackgroundExecutionController.shared.scheduleRecoveryTask(reason: "pending_submission_persisted")
        do {
            try await prepareAttachmentsForSubmission(attachments)
        } catch {
            try? await pendingStore.markFailed(
                submissionID: submissionID,
                message: Self.userMessage(for: error)
            )
            throw error
        }
        let task = try await client.submitExisting(
            pending,
            pendingStore: pendingStore,
            onAttachmentEvent: attachmentEventHandler()
        )
        _ = adoptSubmittedTask(task)
        await beginAcceptedTaskExecutionHandoff(taskID: task.taskID, goal: task.goal)
        setHomeThread(
            threadID: task.threadID,
            currentTaskID: task.taskID,
            ownership: .foregroundSubmission
        )
        lastError = nil
        connectionState = .connected
        startAcceptedSubmissionConvergence(task: task, goal: text)
        return task
    }


    @discardableResult
    func submitFollowUp(
        text: String,
        parentTaskID: String,
        attachments: [PendingAttachment] = [],
        submissionID: String = UUID().uuidString
    ) async throws -> HostTask {
        guard let pendingStore else {
            throw RuntimeTaskStoreError.pendingStoreUnavailable
        }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw PendingSubmissionStoreError.emptyText
        }

        isSubmitting = true
        defer { isSubmitting = false }

        let client = try makeClient()
        let pending = try await pendingStore.create(
            text: normalized,
            invocationSource: "ios_follow_up",
            parentTaskID: parentTaskID,
            attachments: attachments,
            submissionID: submissionID
        )
        _ = await DeviceBackgroundExecutionController.shared.beginUserInitiatedOutboxContinuation(
            submissionID: submissionID,
            summary: normalized
        )
        defer {
            DeviceBackgroundExecutionController.shared.finishUserInitiatedOutboxContinuation(
                submissionID: submissionID,
                reason: "follow_up_scope_finished"
            )
        }
        DeviceBackgroundExecutionController.shared.scheduleRecoveryTask(reason: "pending_follow_up_persisted")
        do {
            try await prepareAttachmentsForSubmission(attachments)
        } catch {
            try? await pendingStore.markFailed(
                submissionID: submissionID,
                message: Self.userMessage(for: error)
            )
            throw error
        }
        let task = try await client.submitExisting(
            pending,
            pendingStore: pendingStore,
            onAttachmentEvent: attachmentEventHandler()
        )
        _ = adoptSubmittedTask(task)
        await beginAcceptedTaskExecutionHandoff(taskID: task.taskID, goal: task.goal)
        setHomeThread(
            threadID: task.threadID,
            currentTaskID: task.taskID,
            ownership: .foregroundSubmission
        )
        lastError = nil
        connectionState = .connected
        startAcceptedSubmissionConvergence(task: task, goal: normalized)
        return task
    }


    func sendUserTurn(taskID: String, text: String, attachments: [PendingAttachment] = [], eventID: String = UUID().uuidString) async throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard let pendingStore else {
            throw RuntimeTaskStoreError.pendingStoreUnavailable
        }

        isSubmitting = true
        defer { isSubmitting = false }

        beginLocalUserTurnProjection(
            taskID: taskID,
            eventID: eventID,
            text: normalized,
            attachmentIDs: attachments.map(\.id)
        )

        let client = try makeClient()
        let pending = try await pendingStore.createUserTurn(
            taskID: taskID,
            text: normalized,
            attachments: attachments,
            eventID: eventID
        )
        _ = await DeviceBackgroundExecutionController.shared.beginUserInitiatedOutboxContinuation(
            submissionID: eventID,
            summary: normalized
        )
        defer {
            DeviceBackgroundExecutionController.shared.finishUserInitiatedOutboxContinuation(
                submissionID: eventID,
                reason: "user_turn_scope_finished"
            )
        }
        DeviceBackgroundExecutionController.shared.scheduleRecoveryTask(reason: "pending_user_turn_persisted")

        var hostAccepted = false
        do {
            try await prepareAttachmentsForSubmission(attachments)
            _ = try await client.submitExistingUserTurn(
                pending,
                pendingStore: pendingStore,
                onAttachmentEvent: attachmentEventHandler()
            )
            hostAccepted = true
            markLocalUserTurnAccepted(taskID: taskID, eventID: eventID)
            setContinuationTarget(taskID: taskID)
            await renewBackgroundExecution(taskID: taskID)

            // HTTP 202 is the durable Host admission boundary. The outbox is
            // removed only after this exact event_id has been accepted.
            lastError = nil
            connectionState = .connected

            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let snapshot = try await client.fetchTaskView(taskID: taskID)
                    _ = self.cacheTaskView(snapshot)
                } catch {
                    Self.logger.notice("accepted user turn readback deferred; task=\(String(taskID.prefix(8)), privacy: .public)")
                }
                await self.refreshPresentationIndex()
            }
        } catch {
            if Task.isCancelled, !hostAccepted {
                _ = try? await pendingStore.discardUserTurn(eventID: eventID)
                removeLocalUserTurnProjection(taskID: taskID, eventID: eventID)
            }
            // Transport failures deliberately keep the durable projection/outbox:
            // foreground bootstrap, attachment completion or BGProcessing can
            // replay the same event_id without duplicating the user turn.
            throw error
        }
    }

    func localUserTurnTimelineItems(
        taskID: String,
        authoritativeTimeline: [HostTimelineItem]
    ) -> [HostTimelineItem] {
        let projections = localUserTurnProjections[taskID] ?? []
        guard !projections.isEmpty else { return authoritativeTimeline }

        let authoritativeUserInputCount = authoritativeTimeline.reduce(into: 0) { count, item in
            if item.kind.uppercased() == "USER_INPUT" { count += 1 }
        }
        var output = authoritativeTimeline
        let baseOrder = authoritativeTimeline.map(\.displayOrder).max() ?? 0
        for (offset, projection) in projections.enumerated()
        where authoritativeUserInputCount <= projection.baselineAuthoritativeUserInputCount {
            output.append(
                HostTimelineItem(
                    timelineItemID: "local-user-turn:\(projection.eventID)",
                    displayOrder: baseOrder + offset + 1,
                    kind: "USER_INPUT",
                    presentationState: projection.deliveryState == .accepted ? "COMPLETE" : "INFO",
                    title: "你补充了任务",
                    summary: projection.text,
                    payload: [
                        "event_id": .string(projection.eventID),
                        "attachment_ids": .array(projection.attachmentIDs.map(JSONValue.string)),
                        "local_delivery_state": .string(projection.deliveryState.rawValue),
                    ],
                    revision: projection.deliveryState == .accepted ? 2 : 1,
                    createdAt: Self.isoTimestamp(projection.createdAt),
                    updatedAt: Self.isoTimestamp(projection.createdAt)
                )
            )
        }
        return output.sorted { lhs, rhs in
            if lhs.displayOrder == rhs.displayOrder { return lhs.timelineItemID < rhs.timelineItemID }
            return lhs.displayOrder < rhs.displayOrder
        }
    }

    func beginLocalUserTurnProjection(
        taskID: String,
        eventID: String,
        text: String,
        attachmentIDs: [String],
        now: Date = Date()
    ) {
        let authoritativeCount = cachedTaskView(taskID: taskID)?.timeline.reduce(into: 0) { count, item in
            if item.kind.uppercased() == "USER_INPUT" { count += 1 }
        } ?? 0
        let existingCount = localUserTurnProjections[taskID]?.count ?? 0
        var projections = localUserTurnProjections[taskID] ?? []
        projections.removeAll { $0.eventID == eventID }
        projections.append(
            RuntimeLocalUserTurnProjection(
                taskID: taskID,
                eventID: eventID,
                text: text,
                attachmentIDs: attachmentIDs,
                baselineAuthoritativeUserInputCount: authoritativeCount + existingCount,
                createdAt: now,
                deliveryState: .sending
            )
        )
        localUserTurnProjections[taskID] = projections
    }

    func markLocalUserTurnAccepted(taskID: String, eventID: String) {
        guard var projections = localUserTurnProjections[taskID],
              let index = projections.firstIndex(where: { $0.eventID == eventID })
        else { return }
        projections[index].deliveryState = .accepted
        localUserTurnProjections[taskID] = projections
    }

    private func removeLocalUserTurnProjection(taskID: String, eventID: String) {
        guard var projections = localUserTurnProjections[taskID] else { return }
        projections.removeAll { $0.eventID == eventID }
        if projections.isEmpty {
            localUserTurnProjections.removeValue(forKey: taskID)
        } else {
            localUserTurnProjections[taskID] = projections
        }
    }

    private func reconcileLocalUserTurnProjections(with view: HostTaskView) {
        let taskID = view.task.taskID
        guard var projections = localUserTurnProjections[taskID], !projections.isEmpty else { return }
        let authoritativeCount = view.timeline.reduce(into: 0) { count, item in
            if item.kind.uppercased() == "USER_INPUT" { count += 1 }
        }
        projections.removeAll { authoritativeCount > $0.baselineAuthoritativeUserInputCount }
        if projections.isEmpty {
            localUserTurnProjections.removeValue(forKey: taskID)
        } else {
            localUserTurnProjections[taskID] = projections
        }
    }

    nonisolated private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    @discardableResult
    func retryPausedTask(taskID: String) async throws -> HostTaskRetryResponse {
        let normalized = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw URLError(.badURL) }
        isSubmitting = true
        defer { isSubmitting = false }

        let client = try makeClient()
        let response = try await client.retryTask(taskID: normalized)
        _ = adoptSubmittedTask(response.task)
        if response.task.status.lowercased() == "active" {
            // The retry mutation is already durable before acquiring the iOS
            // execution owner. No fake UserTurn or duplicate Host Task exists.
            await renewBackgroundExecution(taskID: normalized)
        }
        do {
            let snapshot = try await client.fetchTaskView(taskID: normalized)
            _ = cacheTaskView(snapshot)
        } catch {
            Self.logger.notice(
                "post-retry task view readback deferred; task=\(String(normalized.prefix(8)), privacy: .public)"
            )
        }
        await refreshPresentationIndex()
        lastError = nil
        connectionState = .connected
        return response
    }

    @discardableResult
    func cancelTask(
        taskID: String,
        reason: String = "用户从小卷取消任务"
    ) async throws -> RuntimeTaskCancellationResult {
        let normalized = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw URLError(.badURL) }
        isSubmitting = true
        defer { isSubmitting = false }

        let client = try makeClient()
        let response = try await client.cancelTask(
            taskID: normalized,
            eventID: "ios-direct-cancel-\(UUID().uuidString)",
            reason: reason
        )

        // The 202 response is already durable Host truth from consume_cancel_request.
        // Publish that exact same Task identity into every index projection before
        // waiting on any follow-up read. This fixes the historical "cancelled only
        // after manual refresh" gap without inventing a local optimistic terminal.
        _ = adoptCancellationSnapshot(response.task)
        if defaults.string(forKey: Self.continuationTaskDefaultsKey) == normalized {
            defaults.removeObject(forKey: Self.continuationTaskDefaultsKey)
        }

        let cancellationPending = response.task.cancellationPending == true
        let responseIsTerminal = Self.isTerminalStatus(response.task.status)
        if cancellationPending || !responseIsTerminal {
            startCancellationConvergence(taskID: normalized)
        } else {
            stopCancellationConvergence(taskID: normalized)
        }

        // Mutation readback is intentionally a fresh authoritative /view, not the
        // pre-mutation first-view coalescing lease used by Detail→Home handoff.
        // A pre-cancel in-flight snapshot may still finish later; B12 absorbing
        // terminal truth prevents it from reviving processing state.
        do {
            let snapshot = try await client.fetchTaskView(taskID: normalized)
            let canonical = cacheTaskView(snapshot)
            if canonical.presentationTruth.isTerminal {
                stopCancellationConvergence(taskID: normalized)
            }
        } catch {
            // The cancel mutation was already durably accepted. A transient
            // readback failure must not be misreported as a failed cancellation;
            // the bounded convergence lease / normal read-side refresh can retry.
            Self.logger.notice(
                "post-cancel task view readback deferred; task=\(String(normalized.prefix(8)), privacy: .public) error=\(String(reflecting: type(of: error)), privacy: .public)"
            )
        }

        await refreshPresentationIndex()
        lastError = nil
        connectionState = .connected
        return RuntimeTaskCancellationResult(
            taskID: response.task.taskID,
            status: response.task.status,
            cancellationPending: cancellationPending
        )
    }

    @discardableResult
    func cancelCurrentHomeTask(
        reason: String = "用户从小卷取消当前任务"
    ) async throws -> RuntimeTaskCancellationResult {
        guard let current = activeHomeThreadTask else {
            throw RuntimeTaskStoreError.noCancellableHomeTask
        }
        return try await cancelTask(taskID: current.taskID, reason: reason)
    }

    /// Product-level "delete" for one running row in the Tasks list.
    /// The row is hidden only after the Host has durably accepted cancellation
    /// for that exact Task ID; UI deletion can never substitute for stopping work.
    @discardableResult
    func cancelAndHideActiveTaskFromList(
        taskID: String,
        reason: String = "用户从任务列表左滑删除进行中任务"
    ) async throws -> RuntimeTaskCancellationResult {
        let normalized = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw URLError(.badURL) }

        let cancellation = try await cancelTask(taskID: normalized, reason: reason)

        // POST /cancel returning here means durable Host cancellation admission
        // already succeeded. Only now may product-level deletion hide this Task.
        completionAttentionOwner.acknowledge(taskIDs: [normalized])
        terminalReviewState.markReviewed(taskIDs: [normalized])
        historyPresentationState.hide(taskIDs: [normalized])
        return cancellation
    }


    func fetchThreadTaskPage(
        threadID: String,
        cursor: String? = nil,
        limit: Int = 20
    ) async throws -> HostTaskIndexPage {
        let normalized = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return HostTaskIndexPage(items: [], nextCursor: nil)
        }
        let page = try await makeClient().fetchTaskIndex(
            bucket: "all", cursor: cursor, limit: limit, threadID: normalized
        )
        adoptThreadTaskPage(page, threadID: normalized)
        return page
    }

    func cachedThreadTasks(threadID: String) -> [HostTaskIndexItem] {
        let normalized = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        // Cold/reopen first paint may safely reuse only the canonical Task rows
        // already admitted by the store. `historyTasks` can contain persisted
        // rows because disk restoration filters them to immutable terminal truth;
        // active/waiting state is never restored from disk. Merge that safe
        // global projection with any fresher in-memory exact-thread pages so
        // Thread Detail can paint meaningful cached content immediately while
        // its mandatory authoritative page refresh continues in the background.
        return Self.canonicalTaskIndexItems(
            allKnownTasks.filter { $0.threadID == normalized }
                + (threadTaskCache[normalized] ?? []).filter { $0.threadID == normalized }
        )
        .sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.taskID < rhs.taskID }
            return lhs.createdAt < rhs.createdAt
        }
    }

    func cachedTaskView(taskID: String) -> HostTaskView? {
        guard let cached = taskViewCache[taskID] else { return nil }
        return RuntimeTaskPresentationReducer.terminalizingCachedView(
            cached,
            indexItem: canonicalIndexItem(taskID: taskID)
        )
    }

    /// Coalesce the authoritative first `/view` read for one Task across
    /// presentation owners. A Task Detail -> Home handoff can otherwise cancel
    /// the detail model's request as that view disappears, forcing Home to
    /// restart the same tunnel round trip from zero.
    ///
    /// The fetch task is store-owned rather than child-owned by either screen,
    /// so cancelling one consumer never cancels the shared network operation.
    /// The accepted snapshot is cached before the lease is released, allowing
    /// the next presentation owner to paint immediately.
    func fetchTaskViewCoalesced(taskID: String) async throws -> HostTaskView {
        let normalized = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw URLError(.badURL)
        }

        let lease: TaskViewFetchLease
        if let existing = taskViewFetchLeases[normalized] {
            lease = existing
        } else {
            let client = try makeClient()
            let created = Task<HostTaskView, Error> {
                try await client.fetchTaskView(taskID: normalized)
            }
            lease = TaskViewFetchLease(id: UUID(), task: created)
            taskViewFetchLeases[normalized] = lease
        }

        do {
            let snapshot = try await lease.task.value
            let accepted = cacheTaskView(snapshot)
            if taskViewFetchLeases[normalized]?.id == lease.id {
                taskViewFetchLeases.removeValue(forKey: normalized)
            }
            return accepted
        } catch {
            if taskViewFetchLeases[normalized]?.id == lease.id {
                taskViewFetchLeases.removeValue(forKey: normalized)
            }
            throw error
        }
    }

    @discardableResult
    func cacheTaskView(_ incoming: HostTaskView) -> HostTaskView {
        let taskID = incoming.task.taskID
        var candidate = RuntimeTaskPresentationReducer.terminalizingCachedView(
            incoming,
            indexItem: canonicalIndexItem(taskID: taskID)
        )
        if let existing = taskViewCache[taskID] {
            candidate = RuntimeTaskPresentationReducer.preferred(
                existing: existing,
                incoming: candidate
            )
        }
        taskViewCache[taskID] = candidate
        reconcileLocalUserTurnProjections(with: candidate)
        adoptTaskViewTruth(candidate)
        return candidate
    }

    func presentationTruth(taskID: String, view: HostTaskView? = nil) -> RuntimeTaskPresentationTruth? {
        RuntimeTaskPresentationReducer.truth(
            indexItem: canonicalIndexItem(taskID: taskID),
            view: view
        )
    }

    @discardableResult
    func activateHomeThread(
        threadID: String,
        preferredTaskID: String? = nil
    ) -> RuntimeHomePresentationSelection? {
        let normalized = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        persistHomePresentationSelection(
            threadID: normalized,
            ownership: .explicitUserSelection
        )

        // Task detail loads the exact thread before exposing "调到前台". Do not
        // throw that stronger thread-scoped evidence away merely because the
        // task is temporarily absent from a global top-page index.
        var candidateByID: [String: HostTaskIndexItem] = [:]
        for task in allKnownTasks where task.threadID == normalized {
            candidateByID[task.taskID] = task
        }
        for task in threadTaskCache[normalized] ?? [] {
            candidateByID[task.taskID] = task
        }
        let candidates = candidateByID.values.filter { !Self.isTerminalStatus($0.status) }
        let selected: HostTaskIndexItem?
        if let preferredTaskID,
           let preferred = candidates.first(where: { $0.taskID == preferredTaskID }) {
            selected = preferred
        } else {
            selected = candidates.max { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt { return lhs.taskID < rhs.taskID }
                return lhs.updatedAt < rhs.updatedAt
            }
        }

        if let selected {
            defaults.set(selected.taskID, forKey: Self.continuationTaskDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.continuationTaskDefaultsKey)
        }
        return currentHomePresentationSelection
    }

    func setContinuationTarget(taskID: String?) {
        if let taskID, !taskID.isEmpty {
            defaults.set(taskID, forKey: Self.continuationTaskDefaultsKey)
        } else {
            // Execution targeting is explicit. Clearing it never authorizes a
            // future global Home/Action-Button expression to attach itself to
            // a recent Task merely because that Task is still active.
            defaults.removeObject(forKey: Self.continuationTaskDefaultsKey)
        }
    }

    func beginNewHomeThread(now: Date = Date()) {
        let retiringThreadID = homeThreadID ?? defaults.string(forKey: Self.homeThreadDefaultsKey)
        defaults.removeObject(forKey: Self.continuationTaskDefaultsKey)
        defaults.removeObject(forKey: Self.homeThreadDefaultsKey)
        defaults.removeObject(forKey: Self.homePresentationOwnershipDefaultsKey)
        if let retiringThreadID, !retiringThreadID.isEmpty {
            defaults.set(retiringThreadID, forKey: Self.homeThreadRetiredIDDefaultsKey)
        }
        defaults.set(now.timeIntervalSince1970, forKey: Self.homeThreadRetiredAtDefaultsKey)
        defaults.set(true, forKey: Self.homeThreadAwaitingNewDefaultsKey)
        homeThreadID = nil
        homePresentationOwnership = nil
    }

    @discardableResult
    private func adoptSubmittedTask(_ task: HostTask) -> HostTaskIndexItem {
        let existing = canonicalIndexItem(taskID: task.taskID)
        let projected = RuntimeTaskPresentationReducer.normalized(
            HostTaskIndexItem(
                taskID: task.taskID,
                submissionID: task.submissionID,
                threadID: task.threadID,
                parentTaskID: task.parentTaskID,
                title: existing?.title ?? task.goal,
                goal: task.goal,
                status: task.status,
                phase: existing?.phase,
                bucket: existing?.bucket ?? "running",
                needsUser: false,
                latestTimeline: existing?.latestTimeline,
                createdAt: task.createdAt,
                updatedAt: task.updatedAt
            )
        )
        let canonical = Self.canonicalTaskIndexItems(
            runningTasks + needsUserTasks + historyTasks + [projected]
        )
        runningTasks = canonical.filter {
            switch $0.presentationTruth.state {
            case .active, .waiting, .paused: return true
            case .needsUser, .completed, .failed, .cancelled: return false
            }
        }
        needsUserTasks = canonical.filter { $0.presentationTruth.state == .needsUser }
        historyTasks = canonical.filter { $0.presentationTruth.isTerminal }
        threadTaskCache[task.threadID] = Self.canonicalTaskIndexItems(
            (threadTaskCache[task.threadID] ?? []) + [projected]
        )
        .sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.taskID < rhs.taskID }
            return lhs.createdAt < rhs.createdAt
        }
        reconcileCompletionAttention()
        return canonical.first(where: { $0.taskID == task.taskID }) ?? projected
    }

    private func startAcceptedSubmissionConvergence(task: HostTask, goal: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let client = try self.makeClient()
                let snapshot = try await client.fetchTaskView(taskID: task.taskID)
                _ = self.cacheTaskView(snapshot)
            } catch {
                Self.logger.notice(
                    "accepted submission readback deferred; task=\(String(task.taskID.prefix(8)), privacy: .public) error=\(String(reflecting: type(of: error)), privacy: .public)"
                )
            }
            await self.refreshPresentationIndex()
        }
    }

    private func setHomeThread(
        threadID: String,
        currentTaskID: String?,
        ownership: HomePresentationOwnership
    ) {
        persistHomePresentationSelection(threadID: threadID, ownership: ownership)
        if let currentTaskID, !currentTaskID.isEmpty {
            defaults.set(currentTaskID, forKey: Self.continuationTaskDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.continuationTaskDefaultsKey)
        }
    }

    private func persistHomePresentationSelection(
        threadID: String,
        ownership: HomePresentationOwnership
    ) {
        Self.persistHomePresentationSelection(
            defaults: defaults,
            threadID: threadID,
            ownership: ownership
        )
        homeThreadID = threadID
        homePresentationOwnership = ownership
    }

    nonisolated static func persistHomePresentationSelection(
        defaults: UserDefaults,
        threadID: String,
        ownership: HomePresentationOwnership
    ) {
        defaults.set(threadID, forKey: homeThreadDefaultsKey)
        defaults.set(ownership.rawValue, forKey: homePresentationOwnershipDefaultsKey)
        defaults.removeObject(forKey: homeThreadRetiredAtDefaultsKey)
        defaults.removeObject(forKey: homeThreadRetiredIDDefaultsKey)
        defaults.removeObject(forKey: homeThreadAwaitingNewDefaultsKey)
    }

    private func synchronizeHomePresentationSelectionFromDefaults() {
        let threadID = defaults.string(forKey: Self.homeThreadDefaultsKey)
        let ownership = Self.persistedHomePresentationOwnership(
            defaults: defaults,
            threadID: threadID
        )
        if homeThreadID != threadID {
            homeThreadID = threadID
        }
        if homePresentationOwnership != ownership {
            homePresentationOwnership = ownership
        }
    }

    nonisolated static func persistedHomePresentationOwnership(
        defaults: UserDefaults,
        threadID: String?
    ) -> HomePresentationOwnership? {
        guard let threadID, !threadID.isEmpty else { return nil }
        guard let raw = defaults.string(forKey: homePresentationOwnershipDefaultsKey),
              let ownership = HomePresentationOwnership(rawValue: raw)
        else {
            // Legacy selections predate explicit presentation ownership and
            // retain the previous auto-restoration/retirement behavior.
            return .automaticRestore
        }
        return ownership
    }

    func configure(endpoint: String, bearerToken: String?) throws {
        let normalized = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: normalized), url.scheme != nil, url.host != nil else {
            throw RuntimeTaskStoreError.invalidHostURL
        }

        let host = url.host?.lowercased()
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        var wroteToken = false
        if !isLoopback, let token, !token.isEmpty {
            try credentialStore.saveBearerToken(token, for: url)
            wroteToken = true
        }
        do {
            let client: FlowerollHostClient
            if isLoopback {
                client = FlowerollHostClient(baseURL: url)
            } else {
                client = try FlowerollHostClient.paired(
                    baseURL: url,
                    credentialStore: credentialStore
                )
            }
            try client.validateEndpointSecurity()
        } catch {
            if wroteToken {
                try? credentialStore.removeBearerToken(for: url)
            }
            throw error
        }

        cancelTaskViewFetchLeases()
        defaults.set(normalized, forKey: Self.endpointDefaultsKey)
        connectionState = .connecting
        lastError = nil
    }

    func removeCredentialForConfiguredEndpoint() throws {
        let raw = configuredEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), url.scheme != nil, url.host != nil else {
            throw RuntimeTaskStoreError.invalidHostURL
        }
        try credentialStore.removeBearerToken(for: url)
        connectionState = .connecting
    }

    func clearConfiguration() {
        stopDeviceExecutionLeases()
        cancelTaskViewFetchLeases()
        cancelCancellationConvergenceTasks()
        if let url = URL(string: configuredEndpoint), url.scheme != nil, url.host != nil {
            try? credentialStore.removeBearerToken(for: url)
        }
        defaults.removeObject(forKey: Self.endpointDefaultsKey)
        defaults.removeObject(forKey: Self.continuationTaskDefaultsKey)
        defaults.removeObject(forKey: Self.homeThreadDefaultsKey)
        defaults.removeObject(forKey: Self.homeThreadRetiredAtDefaultsKey)
        defaults.removeObject(forKey: Self.homeThreadRetiredIDDefaultsKey)
        defaults.removeObject(forKey: Self.homeThreadAwaitingNewDefaultsKey)
        defaults.removeObject(forKey: Self.homePresentationOwnershipDefaultsKey)
        homeThreadID = nil
        homePresentationOwnership = nil
        threadTaskCache.removeAll()
        taskViewCache.removeAll()
        runningTasks = []
        needsUserTasks = []
        historyTasks = []
        completionAttentionOwner.beginAppSession()
        reconcileCompletionAttention()
        historyNextCursor = nil
        historyPaginationInitialized = false
        Self.removeHistoryPresentationCache()
        connectionState = .notConfigured
        lastError = nil
    }

    @discardableResult
    private func adoptCancellationSnapshot(
        _ snapshot: HostTaskCancellationResponse.TaskSnapshot
    ) -> HostTaskIndexItem {
        let existing = canonicalIndexItem(taskID: snapshot.taskID)
        let responseIsTerminal = Self.isTerminalStatus(snapshot.status)
        let projected = RuntimeTaskPresentationReducer.normalized(
            HostTaskIndexItem(
                taskID: snapshot.taskID,
                submissionID: snapshot.submissionID,
                threadID: snapshot.threadID,
                parentTaskID: snapshot.parentTaskID,
                title: existing?.title ?? snapshot.goal,
                goal: snapshot.goal,
                status: snapshot.status,
                phase: responseIsTerminal ? nil : existing?.phase,
                bucket: existing?.bucket ?? "running",
                needsUser: responseIsTerminal ? false : (existing?.needsUser ?? false),
                latestTimeline: responseIsTerminal ? nil : existing?.latestTimeline,
                createdAt: snapshot.createdAt,
                updatedAt: snapshot.updatedAt
            )
        )
        let canonical = Self.canonicalTaskIndexItems(
            runningTasks + needsUserTasks + historyTasks + [projected]
        )
        runningTasks = canonical.filter {
            switch $0.presentationTruth.state {
            case .active, .waiting, .paused: return true
            case .needsUser, .completed, .failed, .cancelled: return false
            }
        }
        needsUserTasks = canonical.filter { $0.presentationTruth.state == .needsUser }
        historyTasks = canonical.filter { $0.presentationTruth.isTerminal }
        reconcileCompletionAttention()
        threadTaskCache[snapshot.threadID] = Self.canonicalTaskIndexItems(
            (threadTaskCache[snapshot.threadID] ?? []) + [projected]
        )
        .sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.taskID < rhs.taskID }
            return lhs.createdAt < rhs.createdAt
        }
        if projected.presentationTruth.isTerminal {
            persistHistoryPresentationCache()
        }
        return canonical.first(where: { $0.taskID == snapshot.taskID }) ?? projected
    }

    private func startCancellationConvergence(taskID: String) {
        stopCancellationConvergence(taskID: taskID)
        let generation = UUID()
        cancellationConvergenceGenerations[taskID] = generation
        cancellationConvergenceTasks[taskID] = Task { @MainActor [weak self] in
            guard let self else { return }
            // Explicit user cancellation gets a short, bounded readback window.
            // This is not permanent polling and it never creates/replans a Task.
            let delays: [UInt64] = [150, 250, 400, 650, 1_000, 1_500, 2_000]
            for delayMilliseconds in delays {
                do {
                    try await Task.sleep(nanoseconds: delayMilliseconds * 1_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      self.cancellationConvergenceGenerations[taskID] == generation
                else { return }
                do {
                    let snapshot = try await self.makeClient().fetchTaskView(taskID: taskID)
                    let canonical = self.cacheTaskView(snapshot)
                    if canonical.presentationTruth.isTerminal {
                        if self.defaults.string(forKey: Self.continuationTaskDefaultsKey) == taskID {
                            self.defaults.removeObject(forKey: Self.continuationTaskDefaultsKey)
                        }
                        break
                    }
                } catch is CancellationError {
                    return
                } catch {
                    continue
                }
            }
            guard self.cancellationConvergenceGenerations[taskID] == generation else { return }
            await self.refreshPresentationIndex()
            self.cancellationConvergenceTasks.removeValue(forKey: taskID)
            self.cancellationConvergenceGenerations.removeValue(forKey: taskID)
        }
    }

    private func stopCancellationConvergence(taskID: String) {
        cancellationConvergenceTasks[taskID]?.cancel()
        cancellationConvergenceTasks.removeValue(forKey: taskID)
        cancellationConvergenceGenerations.removeValue(forKey: taskID)
    }

    private func cancelCancellationConvergenceTasks() {
        for task in cancellationConvergenceTasks.values {
            task.cancel()
        }
        cancellationConvergenceTasks.removeAll()
        cancellationConvergenceGenerations.removeAll()
    }

    private func cancelTaskViewFetchLeases() {
        for lease in taskViewFetchLeases.values {
            lease.task.cancel()
        }
        taskViewFetchLeases.removeAll()
    }

    /// Device execution owns its own task-centric HTTPS lease. Presentation SSE
    /// remains presentation-only: losing or delaying an SSE frame can no longer
    /// delay whether a trusted iPhone Action executes.
    private func syncDeviceExecutionLeases(active: [HostTaskIndexItem]) {
        let activeIDs = Set(active.map(\.taskID))
        for taskID in Array(deviceExecutionLeases.keys) where !activeIDs.contains(taskID) {
            deviceExecutionLeases[taskID]?.cancel()
            deviceExecutionLeases.removeValue(forKey: taskID)
            deviceExecutionLeaseGenerations.removeValue(forKey: taskID)
        }
        for taskID in activeIDs where deviceExecutionLeases[taskID] == nil {
            // Foreground latency stays low through this task-scoped long poll.
            // Once the app backgrounds, BGCPT owns in-app user-initiated continuation; BGProcessing is recovery only.
            let generation = UUID()
            deviceExecutionLeaseGenerations[taskID] = generation
            deviceExecutionLeases[taskID] = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runDeviceExecutionLease(taskID: taskID)
                if self.deviceExecutionLeaseGenerations[taskID] == generation {
                    self.deviceExecutionLeases.removeValue(forKey: taskID)
                    self.deviceExecutionLeaseGenerations.removeValue(forKey: taskID)
                }
            }
        }
    }

    private func stopDeviceExecutionLeases() {
        for lease in deviceExecutionLeases.values {
            lease.cancel()
        }
        deviceExecutionLeases.removeAll()
        deviceExecutionLeaseGenerations.removeAll()
    }

    func renewBackgroundExecution(taskID: String) async {
        let goal = canonicalIndexItem(taskID: taskID)?.goal
            ?? taskViewCache[taskID]?.task.goal
            ?? ""
        await beginAcceptedTaskExecutionHandoff(taskID: taskID, goal: goal)
    }

    private func beginAcceptedTaskExecutionHandoff(taskID: String, goal: String) async {
        let controller = DeviceBackgroundExecutionController.shared
        _ = await controller.submitUserInitiatedContinuation(taskID: taskID, goal: goal)
        // A freshly admitted Task is already canonical local ACTIVE truth. Do
        // not wait for a later index refresh before opening the device-action
        // long poll; both paths share DeviceRuntimeWorker's exact-attempt gates.
        if deviceWorker != nil {
            syncDeviceExecutionLeases(active: activeTasks)
        }
    }

    private func runDeviceExecutionLease(taskID: String) async {
        guard let deviceWorker else { return }
        do {
            let client = try makeClient()
            while !Task.isCancelled {
                // One hanging request replaces repeated foreground polling. The
                // Host returns immediately when Planner commits an iOS Action.
                let report = await deviceWorker.processTask(
                    client: client,
                    taskID: taskID,
                    waitSeconds: 12
                )
                guard !Task.isCancelled else { return }

                if !report.reconciliationTaskIDs.isEmpty {
                    Self.logger.notice(
                        "device execution lease needs reconciliation; task=\(String(taskID.prefix(8)), privacy: .public)"
                    )
                    return
                }

                if !report.changedTaskIDs.isEmpty {
                    let pages = try await fetchIndexPages(client: client)
                    adoptIndexPages(
                        running: pages.running,
                        needsUser: pages.needsUser,
                        history: pages.history
                    )
                    connectionState = .connected
                    lastError = nil
                    let stillActive = activeTasks.contains { $0.taskID == taskID }
                    if !stillActive { return }
                    // A REPLAN task may produce another iOS Action. Keep the
                    // lease alive rather than waiting for a separate refresh.
                    continue
                }

                // A 204 after the bounded wait means no iOS Action was ready.
                // Check durable task state once; continue only for an ACTIVE
                // task (for example while a Host/MCP Action is progressing).
                let view = try await client.fetchTaskView(taskID: taskID)
                if view.task.status.lowercased() != "active" {
                    return
                }
            }
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error(
                "device execution lease stopped; task=\(String(taskID.prefix(8)), privacy: .public) error_type=\(String(reflecting: type(of: error)), privacy: .public)"
            )
        }
    }

    private static func historyCacheURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("Floweroll", isDirectory: true)
            .appendingPathComponent("RuntimeClient", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(historyCacheFilename)
    }

    private static func loadHistoryPresentationCache() -> [HostTaskIndexItem] {
        guard let url = try? historyCacheURL(),
              let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder.floweroll.decode(HistoryPresentationCache.self, from: data)
        else { return [] }
        // Only immutable terminal history is safe to paint before the first
        // network refresh. Active/waiting truth is always fetched from Host.
        return cached.items.filter { isTerminalStatus($0.status) }
    }

    private func adoptHistoryIndexPage(_ page: HostTaskIndexPage) {
        let previousCount = historyTasks.count
        historyTasks = Self.mergedTaskIndexItems(existing: historyTasks, incoming: page.items)
            .filter { $0.presentationTruth.isTerminal }
        reconcileCompletionAttention()
        if !historyPaginationInitialized || previousCount <= page.items.count {
            historyNextCursor = page.nextCursor
        }
        historyPaginationInitialized = true
        persistHistoryPresentationCache()
    }

    private func adoptIndexPages(
        running: HostTaskIndexPage,
        needsUser: HostTaskIndexPage,
        history: HostTaskIndexPage
    ) {
        let previousHistory = historyTasks
        let previousHistoryCount = previousHistory.count
        let canonical = Self.canonicalTaskIndexItems(
            running.items + needsUser.items + historyTasks + history.items
        )
        let nextRunningTasks = canonical.filter {
            switch $0.presentationTruth.state {
            case .active, .waiting, .paused: return true
            case .needsUser, .completed, .failed, .cancelled: return false
            }
        }
        let nextNeedsUserTasks = canonical.filter { $0.presentationTruth.state == .needsUser }
        let nextHistoryTasks = canonical.filter { $0.presentationTruth.isTerminal }

        // @Observable invalidates dependent SwiftUI trees on writes, even when
        // the replacement value is identical. Presentation polling runs every
        // few seconds, so publish only real changes instead of continuously
        // rebuilding Home/Tasks/Settings around identical Task Index pages.
        if runningTasks != nextRunningTasks {
            runningTasks = nextRunningTasks
        }
        if needsUserTasks != nextNeedsUserTasks {
            needsUserTasks = nextNeedsUserTasks
        }
        if historyTasks != nextHistoryTasks {
            historyTasks = nextHistoryTasks
            reconcileCompletionAttention()
        }
        if !historyPaginationInitialized || previousHistoryCount <= history.items.count {
            if historyNextCursor != history.nextCursor {
                historyNextCursor = history.nextCursor
            }
        }
        if !historyPaginationInitialized {
            historyPaginationInitialized = true
        }
        if historyTasks != previousHistory {
            persistHistoryPresentationCache()
        }
    }

    private func canonicalIndexItem(taskID: String) -> HostTaskIndexItem? {
        let candidates = runningTasks
            + needsUserTasks
            + historyTasks
            + threadTaskCache.values.flatMap { $0 }
        return candidates
            .filter { $0.taskID == taskID }
            .reduce(nil as HostTaskIndexItem?) { current, incoming in
                guard let current else {
                    return RuntimeTaskPresentationReducer.normalized(incoming)
                }
                return RuntimeTaskPresentationReducer.preferred(
                    existing: current,
                    incoming: incoming
                )
            }
    }

    private func adoptTaskViewTruth(_ view: HostTaskView) {
        let existing = canonicalIndexItem(taskID: view.task.taskID)
        let latest = view.timeline.max { lhs, rhs in
            if lhs.displayOrder == rhs.displayOrder {
                return lhs.timelineItemID < rhs.timelineItemID
            }
            return lhs.displayOrder < rhs.displayOrder
        }
        let projected = RuntimeTaskPresentationReducer.normalized(
            HostTaskIndexItem(
                taskID: view.task.taskID,
                submissionID: view.task.submissionID,
                threadID: view.task.threadID,
                parentTaskID: view.task.parentTaskID,
                title: existing?.title ?? view.task.goal,
                goal: view.task.goal,
                status: view.task.status,
                phase: existing?.phase,
                bucket: existing?.bucket ?? "running",
                needsUser: view.presentationTruth.state == .needsUser,
                latestTimeline: latest.map {
                    HostTaskIndexItem.LatestTimeline(
                        title: $0.title,
                        summary: $0.summary,
                        updatedAt: $0.updatedAt
                    )
                },
                createdAt: view.task.createdAt,
                updatedAt: view.task.updatedAt
            )
        )
        let canonical = Self.canonicalTaskIndexItems(
            runningTasks + needsUserTasks + historyTasks + [projected]
        )
        runningTasks = canonical.filter {
            switch $0.presentationTruth.state {
            case .active, .waiting, .paused: return true
            case .needsUser, .completed, .failed, .cancelled: return false
            }
        }
        needsUserTasks = canonical.filter { $0.presentationTruth.state == .needsUser }
        historyTasks = canonical.filter { $0.presentationTruth.isTerminal }
        reconcileCompletionAttention()
        threadTaskCache[view.task.threadID] = Self.canonicalTaskIndexItems(
            (threadTaskCache[view.task.threadID] ?? []) + [projected]
        )
        .sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.taskID < rhs.taskID }
            return lhs.createdAt < rhs.createdAt
        }
        persistHistoryPresentationCache()
    }

    private func persistHistoryPresentationCache() {
        let items = Array(historyTasks.filter { Self.isTerminalStatus($0.status) }.prefix(100))
        guard let url = try? Self.historyCacheURL(),
              let data = try? JSONEncoder().encode(HistoryPresentationCache(items: items))
        else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func removeHistoryPresentationCache() {
        guard let url = try? historyCacheURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func retryPendingSubmissions() async {
        guard let pendingStore, let client = try? makeClient() else { return }
        for pending in await pendingStore.pending() {
            do {
                let task = try await client.submitExisting(
                    pending,
                    pendingStore: pendingStore,
                    onAttachmentEvent: attachmentEventHandler()
                )
                _ = adoptSubmittedTask(task)
                DeviceBackgroundExecutionController.shared.finishUserInitiatedOutboxContinuation(
                    submissionID: pending.submissionID,
                    reason: "recovery_admitted"
                )
                await beginAcceptedTaskExecutionHandoff(taskID: task.taskID, goal: task.goal)
                let acceptedAttachmentIDs = Set((pending.attachments ?? []).map(\.id))
                TaskAttachmentDraft.clearAcceptedReferences(acceptedAttachmentIDs)
                for attachmentID in acceptedAttachmentIDs {
                    attachmentUploadStates.removeValue(forKey: attachmentID)
                }
            } catch {
                // Each persisted submission is an independent outbox entry. A
                // broken old A must never prevent a later B from reconciling.
                let message = Self.userMessage(for: error)
                try? await pendingStore.markFailed(
                    submissionID: pending.submissionID,
                    message: message
                )
                Self.logger.notice(
                    "pending submission retry deferred; submission=\(String(pending.submissionID.prefix(8)), privacy: .public) message=\(message, privacy: .public)"
                )
                continue
            }
        }

        for pending in await pendingStore.pendingUserTurns() {
            do {
                _ = try await client.submitExistingUserTurn(
                    pending,
                    pendingStore: pendingStore,
                    onAttachmentEvent: attachmentEventHandler()
                )
                DeviceBackgroundExecutionController.shared.finishUserInitiatedOutboxContinuation(
                    submissionID: pending.eventID,
                    reason: "recovery_user_turn_admitted"
                )
                let acceptedAttachmentIDs = Set((pending.attachments ?? []).map(\.id))
                TaskAttachmentDraft.clearAcceptedReferences(acceptedAttachmentIDs)
                for attachmentID in acceptedAttachmentIDs {
                    attachmentUploadStates.removeValue(forKey: attachmentID)
                }
                setContinuationTarget(taskID: pending.taskID)
                await renewBackgroundExecution(taskID: pending.taskID)
            } catch {
                let message = Self.userMessage(for: error)
                try? await pendingStore.markUserTurnFailed(
                    eventID: pending.eventID,
                    message: message
                )
                Self.logger.notice(
                    "pending user turn retry deferred; event=\(String(pending.eventID.prefix(8)), privacy: .public) message=\(message, privacy: .public)"
                )
                continue
            }
        }
    }

    func discardPendingSubmission(submissionID: String) async {
        DeviceBackgroundExecutionController.shared.finishUserInitiatedOutboxContinuation(
            submissionID: submissionID,
            reason: "submission_discarded"
        )
        guard let pendingStore else { return }
        if let removed = try? await pendingStore.discard(submissionID: submissionID) {
            for attachment in removed.attachments ?? [] {
                cancelAttachmentPreupload(attachmentID: attachment.id)
            }
        }
        if let removedTurn = try? await pendingStore.discardUserTurn(eventID: submissionID) {
            for attachment in removedTurn.attachments ?? [] {
                cancelAttachmentPreupload(attachmentID: attachment.id)
            }
        }
    }

    /// Cancel a composer send without leaving a persist-first outbox entry that
    /// could silently replay on relaunch. If the new Task crossed the Host
    /// admission boundary before local cancellation won the race, reconcile by
    /// submission_id and cancel that exact Task rather than creating/guessing.
    func reconcileCancelledSubmission(
        submissionID: String
    ) async -> RuntimeSubmissionCancellationOutcome {
        guard let pendingStore else { return .uncertain }
        // Remove replay eligibility before any network readback. A concurrent
        // recovery callback must not restart this cancelled send during the
        // reconciliation delay; an already-admitted Task is still cancelled by ID.
        _ = try? await pendingStore.discard(submissionID: submissionID)
        _ = try? await pendingStore.discardUserTurn(eventID: submissionID)
        let client = try? makeClient()
        let delays: [Duration] = [.zero, .milliseconds(120), .milliseconds(280), .milliseconds(500)]

        if let client {
            for delay in delays {
                if delay != .zero { try? await Task.sleep(for: delay) }
                if let admitted = try? await client.taskForSubmissionID(submissionID) {
                    do {
                        let cancellation = try await cancelTask(
                            taskID: admitted.taskID,
                            reason: "用户取消尚在发送中的新任务"
                        )
                        _ = try? await pendingStore.discard(submissionID: submissionID)
                        return .cancelledAdmittedTask(cancellation)
                    } catch {
                        _ = try? await pendingStore.discard(submissionID: submissionID)
                        return .uncertain
                    }
                }
            }
        }

        _ = try? await pendingStore.discard(submissionID: submissionID)
        return client == nil ? .uncertain : .stoppedBeforeAdmission
    }

    func clearAttachmentUploadStates(_ ids: Set<String>) {
        for id in ids {
            attachmentUploadLeases[id]?.task.cancel()
            attachmentUploadLeases.removeValue(forKey: id)
            attachmentUploadStates.removeValue(forKey: id)
        }
    }

    private func attachmentEventHandler() -> @Sendable (AttachmentUploadEvent) -> Void {
        { [weak self] event in
            Task { @MainActor [weak self] in
                self?.attachmentUploadStates[event.attachmentID] = event.state
            }
        }
    }

    private func refreshThrowing() async throws {
        isRefreshing = true
        defer { isRefreshing = false }
        let client = try makeClient()

        var pages = try await fetchIndexPages(client: client)

        // Make the already-fetched Host read model visible before device work.
        // A long device lease must not delay Home/history after a cold relaunch.
        adoptIndexPages(
            running: pages.running,
            needsUser: pages.needsUser,
            history: pages.history
        )
        var homeHydration = await hydrateSelectedHomeThread(client: client)
        reconcileHomeThreadPresentation(now: Date(), hydration: homeHydration)
        connectionState = .connected
        lastError = nil

        let active = activeTasks

        Self.logger.notice("device pass eligibility; active=\(active.count, privacy: .public) worker=\(self.deviceWorker != nil, privacy: .public)")
        if let deviceWorker, !active.isEmpty {
            // Foreground recovery may do one low-latency native pass. Long-lived
            // in-app continuation is owned by BGCPT when alive, with BGProcessing as opportunistic recovery.
            let report = await deviceWorker.processOnePass(client: client, tasks: active)
            if !report.reconciliationTaskIDs.isEmpty {
                Self.logger.notice(
                    "device reconciliation pending for \(report.reconciliationTaskIDs.count, privacy: .public) Task(s)"
                )
            }
            if !report.changedTaskIDs.isEmpty {
                // One bounded refetch publishes the Host state produced by
                // exact Attempt results. Never recurse or let the iPhone own
                // the Task loop.
                pages = try await fetchIndexPages(client: client)
                adoptIndexPages(
                    running: pages.running,
                    needsUser: pages.needsUser,
                    history: pages.history
                )
                homeHydration = await hydrateSelectedHomeThread(client: client)
            }
        }

        let now = Date()
        for task in historyTasks where Self.isTerminalStatus(task.status) {
            guard let updated = Self.hostDate(task.updatedAt), now.timeIntervalSince(updated) <= 90 else { continue }
            let title: String
            switch task.status.lowercased() {
            case "completed": title = "小卷任务已完成"
            case "cancelled": title = "小卷任务已取消"
            default: title = "小卷任务需要查看"
            }
            Task {
                await FlowerollTaskNotifications.notifyTerminalIfNeeded(
                    taskID: task.taskID,
                    title: title,
                    body: task.latestTimeline?.summary ?? task.latestTimeline?.title ?? task.goal
                )
            }
        }
        reconcileHomeThreadPresentation(now: now, hydration: homeHydration)
        let activeForExecution = activeTasks
        syncDeviceExecutionLeases(active: activeForExecution)
        let backgroundController = DeviceBackgroundExecutionController.shared
        for task in activeForExecution {
            backgroundController.trackDurableTask(
                taskID: task.taskID,
                reason: "foreground_index_recovery"
            )
        }
        backgroundController.reconcileTrackedTasks(
            activeTaskIDs: Set(activeForExecution.map(\.taskID))
        )
        Self.logger.info(
            "Task Index refreshed; running=\(self.runningTasks.count, privacy: .public) needs_user=\(self.needsUserTasks.count, privacy: .public) history=\(self.historyTasks.count, privacy: .public)"
        )
        connectionState = .connected
        lastError = nil
    }

    private func fetchIndexPages(
        client: FlowerollHostClient
    ) async throws -> (
        running: HostTaskIndexPage,
        needsUser: HostTaskIndexPage,
        history: HostTaskIndexPage
    ) {
        async let running = client.fetchTaskIndex(bucket: "running", limit: 50)
        async let needsUser = client.fetchTaskIndex(bucket: "needs_user", limit: 50)
        async let history = client.fetchTaskIndex(bucket: "history", limit: 50)
        return try await (running, needsUser, history)
    }

    private func adoptThreadTaskPage(_ page: HostTaskIndexPage, threadID: String) {
        // The request is exact-thread scoped. Fail closed if a malformed/stale
        // server page ever carries another Thread instead of contaminating the
        // local read model.
        let scopedItems = page.items.filter { $0.threadID == threadID }
        let nextTasks = Self.canonicalTaskIndexItems(
            (threadTaskCache[threadID] ?? []) + scopedItems
        )
        .sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.taskID < rhs.taskID }
            return lhs.createdAt < rhs.createdAt
        }
        if threadTaskCache[threadID] != nextTasks {
            threadTaskCache[threadID] = nextTasks
        }
    }

    private func hydrateSelectedHomeThread(client: FlowerollHostClient) async -> HomeThreadHydrationResult {
        synchronizeHomePresentationSelectionFromDefaults()
        guard let threadID = currentHomeThreadID, !threadID.isEmpty else {
            return .notRequested
        }
        do {
            let page = try await client.fetchTaskIndex(
                bucket: "all",
                limit: 50,
                threadID: threadID
            )
            adoptThreadTaskPage(page, threadID: threadID)
            return .loaded(page.items.count)
        } catch {
            // Read-model uncertainty must never delete a durable presentation
            // selection. Existing cached episodes remain paintable until a
            // later exact-thread hydration succeeds.
            Self.logger.notice(
                "selected Home thread hydration failed; preserving presentation thread=\(String(threadID.prefix(8)), privacy: .public)"
            )
            return .failed
        }
    }

    private func reconcileHomeThreadPresentation(
        now: Date,
        hydration: HomeThreadHydrationResult
    ) {
        synchronizeHomePresentationSelectionFromDefaults()
        let tasks = allKnownTasks

        if currentHomeThreadID == nil {
            if defaults.bool(forKey: Self.homeThreadAwaitingNewDefaultsKey) {
                return
            }
            let retiredThreadID = defaults.string(forKey: Self.homeThreadRetiredIDDefaultsKey)
            let eligibleTasks = tasks.filter { $0.threadID != retiredThreadID }
            guard let candidate = eligibleTasks.max(by: { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt { return lhs.taskID < rhs.taskID }
                return lhs.updatedAt < rhs.updatedAt
            }) else { return }
            guard let activityDate = Self.hostDate(candidate.updatedAt) else { return }

            let retiredAt = defaults.double(forKey: Self.homeThreadRetiredAtDefaultsKey)
            if retiredAt > 0, activityDate.timeIntervalSince1970 <= retiredAt {
                return
            }
            if !Self.isTerminalStatus(candidate.status)
                || Self.shouldKeepTerminalThread(lastActivity: activityDate, now: now)
            {
                setHomeThread(
                    threadID: candidate.threadID,
                    currentTaskID: Self.isTerminalStatus(candidate.status) ? nil : candidate.taskID,
                    ownership: .automaticRestore
                )
            }
            return
        }

        let ownership = homePresentationOwnership ?? .automaticRestore

        // A failed exact-thread read is uncertainty, never proof that the
        // selected presentation disappeared. Fail closed by preserving Home.
        if hydration == .failed {
            return
        }

        // Only an automatically inferred selection may be retired from a
        // confirmed exact-thread empty result. Explicit user/product choices
        // stay selected until New Task or another explicit selection replaces
        // them.
        if hydration == .loaded(0), !ownership.isDurableSelection {
            beginNewHomeThread(now: now)
            return
        }

        let threadTasks = homeThreadTasks
        guard !threadTasks.isEmpty else {
            return
        }

        let nonTerminal = threadTasks.filter { !Self.isTerminalStatus($0.status) }
        if !nonTerminal.isEmpty {
            return
        }

        // Execution continuation and Home presentation are intentionally
        // independent. Once every known episode is terminal, the thread may
        // remain on screen but no terminal Task retains continuation authority.
        if let continuationID = defaults.string(forKey: Self.continuationTaskDefaultsKey),
           threadTasks.contains(where: { $0.taskID == continuationID }) {
            defaults.removeObject(forKey: Self.continuationTaskDefaultsKey)
        }

        if ownership.isDurableSelection {
            return
        }

        guard let latest = threadTasks.max(by: { $0.updatedAt < $1.updatedAt }),
              let activityDate = Self.hostDate(latest.updatedAt)
        else { return }
        if !Self.shouldKeepTerminalThread(lastActivity: activityDate, now: now) {
            beginNewHomeThread(now: now)
        }
    }

    nonisolated static func shouldKeepTerminalThread(
        lastActivity: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let idle = max(0, now.timeIntervalSince(lastActivity))
        if idle >= 24 * 60 * 60 {
            return false
        }
        let shiftedLast = lastActivity.addingTimeInterval(-4 * 60 * 60)
        let shiftedNow = now.addingTimeInterval(-4 * 60 * 60)
        let crossedProductDay = !calendar.isDate(shiftedLast, inSameDayAs: shiftedNow)
        if crossedProductDay && idle >= 6 * 60 * 60 {
            return false
        }
        return true
    }

    // Immutable Foundation parse styles avoid rebuilding ICU formatters inside
    // SwiftUI body evaluation and sorting comparators. Safe across executors.
    nonisolated private static let fractionalHostDateStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )
    nonisolated private static let plainHostDateStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: false
    )

    nonisolated static func hostDate(_ rawValue: String) -> Date? {
        (try? fractionalHostDateStyle.parse(rawValue))
            ?? (try? plainHostDateStyle.parse(rawValue))
    }

    nonisolated static func isTerminalStatus(_ status: String) -> Bool {
        ["completed", "failed", "cancelled"].contains(status.lowercased())
    }

    static func userMessage(for error: Error) -> String {
        if let problem = error as? HostProblem {
            return problem.detail ?? problem.title ?? problem.code ?? "后台请求失败。"
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return "操作已取消。"
            case .notConnectedToInternet:
                return "当前没有网络，内容已保留，联网后可以重试。"
            case .timedOut:
                return "连接超时，内容已保留；附件会先核对服务器状态再决定是否重传。"
            case .networkConnectionLost:
                return "网络连接中断，内容已安全保留，可以直接重试。"
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return "暂时连不上花卷 Host，内容已保留，请稍后重试。"
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .clientCertificateRejected,
                 .clientCertificateRequired:
                return "安全连接失败，请检查网络或 Host 证书后重试。"
            default:
                return "网络请求没有完成，内容已保留，请稍后重试。"
            }
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        switch error {
        case HostClientSecurityError.insecureRemoteEndpoint:
            return "真实 iPhone 连接后台必须使用 HTTPS。"
        case HostClientSecurityError.missingCredential:
            return "这个后台地址还没有配对凭据。"
        case HostClientSecurityError.invalidEndpoint:
            return "Host 地址无效。"
        default:
            return "操作没有完成，请稍后重试。"
        }
    }
}
