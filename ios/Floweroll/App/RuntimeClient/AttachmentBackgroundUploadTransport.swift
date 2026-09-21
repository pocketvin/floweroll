import Foundation
import OSLog
import UIKit


enum AttachmentBackgroundUploadPolicy {
    static let sessionIdentifier = "com.maxenceyu.floweroll.attachment-upload.v1"
    static let chunkBytes = 12 * 1024 * 1024
    static let recoveryLimit = 8

    static func shouldUseSystemBackgroundTransfer(baseURL: URL) -> Bool {
        guard baseURL.scheme?.lowercased() == "https",
              let host = baseURL.host?.lowercased()
        else { return false }
        return host != "localhost" && host != "127.0.0.1" && host != "::1"
    }

    enum ExistingTaskDisposition: Equatable {
        case reuse
        case resume
        case replace
    }

    static func existingTaskDisposition(for state: URLSessionTask.State) -> ExistingTaskDisposition {
        switch state {
        case .running, .canceling:
            return .reuse
        case .suspended:
            return .resume
        case .completed:
            return .replace
        @unknown default:
            return .reuse
        }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForResource = 30 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return configuration
    }
}


struct BackgroundAttachmentUploadJob: Codable, Equatable, Sendable {
    enum Operation: String, Codable, Sendable {
        case begin
        case chunk
    }

    let attachment: PendingAttachment
    let endpoint: String
    let operation: Operation
    let offset: Int
    let recoveryCount: Int
    let bodyFileName: String
    let laneID: String?

    init(
        attachment: PendingAttachment,
        endpoint: String,
        operation: Operation,
        offset: Int,
        recoveryCount: Int,
        bodyFileName: String,
        laneID: String? = nil
    ) {
        self.attachment = attachment
        self.endpoint = endpoint
        self.operation = operation
        self.offset = offset
        self.recoveryCount = recoveryCount
        self.bodyFileName = bodyFileName
        self.laneID = laneID
    }

    func withLaneID(_ laneID: String) -> Self {
        Self(
            attachment: attachment,
            endpoint: endpoint,
            operation: operation,
            offset: offset,
            recoveryCount: recoveryCount,
            bodyFileName: bodyFileName,
            laneID: laneID
        )
    }

    /// Socket bytes are display progress, never proof of durable completion.
    /// Resume offsets belong to the whole file; URLSession counts this request.
    func progressState(totalBytesSent: Int64) -> AttachmentUploadState {
        guard operation == .chunk else { return .reconciling }
        let total = Int64(max(0, attachment.sizeBytes))
        let committed = min(total, Int64(max(0, offset)))
        let sent = committed + min(total - committed, max(0, totalBytesSent))
        guard sent < total else { return .reconciling }
        return .uploading(sentBytes: sent, totalBytes: total)
    }

    func nextRecoveryCount(confirmedOffset: Int) -> Int {
        // A successful metadata request is not successful file transfer.
        confirmedOffset > offset ? 0 : recoveryCount
    }

    func encodedDescription() throws -> String {
        let data = try JSONEncoder.floweroll.encode(self)
        guard let value = String(data: data, encoding: .utf8) else {
            throw MaterialsError.message("附件后台上传任务无法编码。")
        }
        return value
    }

    static func decode(_ description: String?) -> Self? {
        guard let description,
              let data = description.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder.floweroll.decode(Self.self, from: data)
    }
}


private struct BackgroundAttachmentUploadDescriptor: Codable, Sendable {
    let fileID: String
    let offset: Int
    let complete: Bool
    let file: TaskMaterialFile?

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case offset, complete, file
    }
}


struct BackgroundAttachmentUploadLaneState: Equatable, Sendable {
    enum ExistingTaskDisposition: Equatable, Sendable {
        case abort
        case replaceStale(laneID: String)
        case use(laneID: String)
    }

    private var immediateOwnerCounts: [String: Int] = [:]
    private var activeBackgroundLaneIDs: [String: String] = [:]
    private var retiredBackgroundLaneIDs: Set<String> = []
    private var invalidatedLegacyAttachments: Set<String> = []

    mutating func beginBackground(attachmentID: String) -> String? {
        guard allowsBackgroundTransfer(attachmentID: attachmentID) else { return nil }
        if let existing = activeBackgroundLaneIDs[attachmentID] { return existing }
        let laneID = UUID().uuidString
        activeBackgroundLaneIDs[attachmentID] = laneID
        return laneID
    }

    mutating func prepareDiscoveredExistingTask(
        attachmentID: String,
        provisionalLaneID: String,
        existingLaneID: String?,
        replaceExisting: Bool
    ) -> ExistingTaskDisposition {
        guard immediateOwnerCounts[attachmentID, default: 0] == 0,
              activeBackgroundLaneIDs[attachmentID] == provisionalLaneID,
              !retiredBackgroundLaneIDs.contains(provisionalLaneID)
        else { return .abort }

        if replaceExisting {
            if let existingLaneID {
                retiredBackgroundLaneIDs.insert(existingLaneID)
                if existingLaneID == provisionalLaneID {
                    let replacement = UUID().uuidString
                    activeBackgroundLaneIDs[attachmentID] = replacement
                    return .replaceStale(laneID: replacement)
                }
            }
            return .replaceStale(laneID: provisionalLaneID)
        }

        guard let existingLaneID else {
            if invalidatedLegacyAttachments.contains(attachmentID) {
                return .replaceStale(laneID: provisionalLaneID)
            }
            return .use(laneID: provisionalLaneID)
        }
        guard !retiredBackgroundLaneIDs.contains(existingLaneID) else {
            return .replaceStale(laneID: provisionalLaneID)
        }
        if existingLaneID != provisionalLaneID {
            retiredBackgroundLaneIDs.insert(provisionalLaneID)
            activeBackgroundLaneIDs[attachmentID] = existingLaneID
        }
        return .use(laneID: existingLaneID)
    }

    mutating func adoptBackgroundJob(
        attachmentID: String,
        laneID: String?
    ) -> String? {
        guard immediateOwnerCounts[attachmentID, default: 0] == 0 else { return nil }
        if let laneID {
            guard !retiredBackgroundLaneIDs.contains(laneID) else { return nil }
            if let active = activeBackgroundLaneIDs[attachmentID] {
                guard active == laneID else { return nil }
            } else {
                activeBackgroundLaneIDs[attachmentID] = laneID
            }
            return laneID
        }

        guard !invalidatedLegacyAttachments.contains(attachmentID) else { return nil }
        if let active = activeBackgroundLaneIDs[attachmentID] { return active }
        let adopted = UUID().uuidString
        activeBackgroundLaneIDs[attachmentID] = adopted
        return adopted
    }

    func isCurrentBackgroundLane(attachmentID: String, laneID: String) -> Bool {
        immediateOwnerCounts[attachmentID, default: 0] == 0
            && activeBackgroundLaneIDs[attachmentID] == laneID
            && !retiredBackgroundLaneIDs.contains(laneID)
    }

    mutating func finishBackground(attachmentID: String, laneID: String) -> Bool {
        guard isCurrentBackgroundLane(attachmentID: attachmentID, laneID: laneID) else {
            return false
        }
        activeBackgroundLaneIDs.removeValue(forKey: attachmentID)
        retiredBackgroundLaneIDs.insert(laneID)
        return true
    }

    mutating func retireBackground(attachmentID: String) {
        if let laneID = activeBackgroundLaneIDs.removeValue(forKey: attachmentID) {
            retiredBackgroundLaneIDs.insert(laneID)
        }
        invalidatedLegacyAttachments.insert(attachmentID)
    }

    mutating func beginImmediate(attachmentID: String) {
        immediateOwnerCounts[attachmentID, default: 0] += 1
        retireBackground(attachmentID: attachmentID)
    }

    mutating func endImmediate(attachmentID: String) {
        guard let count = immediateOwnerCounts[attachmentID] else { return }
        if count <= 1 {
            immediateOwnerCounts.removeValue(forKey: attachmentID)
        } else {
            immediateOwnerCounts[attachmentID] = count - 1
        }
    }

    func allowsBackgroundTransfer(attachmentID: String) -> Bool {
        immediateOwnerCounts[attachmentID, default: 0] == 0
    }

    func immediateOwnerCount(attachmentID: String) -> Int {
        immediateOwnerCounts[attachmentID] ?? 0
    }
}


/// A caller owns its wait, not the system transfer. Completion/cancellation
/// races (including cancellation before continuation registration) resolve once.
final class BackgroundAttachmentUploadWaiter: @unchecked Sendable {
    let onEvent: (@Sendable (AttachmentUploadEvent) -> Void)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    init(onEvent: (@Sendable (AttachmentUploadEvent) -> Void)? = nil) {
        self.onEvent = onEvent
    }

    func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return result != nil
    }
}


/// URLSession wake completion must not be held hostage by a slow Host. The
/// durable outbox survives either winner; only Apple's wake callback is bounded.
enum BackgroundUploadWakeCompletion {
    @MainActor
    static func run(
        budget: Duration = .seconds(5),
        recover: @escaping @MainActor () async -> Void,
        onDeferredRecovery: @escaping @MainActor () -> Void,
        completion: @escaping @MainActor () -> Void
    ) {
        let gate = BackgroundCompletionGate()
        let work = Task { @MainActor in
            await recover()
            if gate.claim() { completion() }
        }
        Task { @MainActor in
            do { try await Task.sleep(for: budget) } catch { return }
            guard gate.claim() else { return }
            work.cancel()
            onDeferredRecovery()
            completion()
        }
    }
}


/// System-owned attachment transfer lane.
///
/// Product/runtime truth remains the existing Host resumable-upload resource:
/// `file_id + sha256 + durable Upload-Offset`. This object only changes who owns
/// the network transfer while Floweroll is suspended. No Task lifecycle, Planner,
/// No Live Activity or long-running presentation ownership is introduced here.
final class AttachmentBackgroundUploadTransport: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = AttachmentBackgroundUploadTransport()
    private static let logger = Logger(subsystem: "com.maxenceyu.floweroll", category: "AttachmentUpload")

    private typealias Waiter = BackgroundAttachmentUploadWaiter

    private let lock = NSLock()
    private let credentialStore = HostCredentialStore()
    private let delegateQueue: OperationQueue
    private var waiters: [String: [Waiter]] = [:]
    private var responseBodies: [Int: Data] = [:]
    private var tokenOverrides: [String: String] = [:]
    private var backgroundCompletionHandler: (() -> Void)?
    private var laneState = BackgroundAttachmentUploadLaneState()

    private lazy var session: URLSession = {
        URLSession(
            configuration: AttachmentBackgroundUploadPolicy.configuration(),
            delegate: self,
            delegateQueue: delegateQueue
        )
    }()

    private override init() {
        let queue = OperationQueue()
        queue.name = "floweroll.attachment-background-upload"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        delegateQueue = queue
        super.init()
        _ = session
    }

    func uploadBytes(
        attachment: PendingAttachment,
        baseURL: URL,
        bearerToken: String?,
        startingOffset: Int,
        onEvent: (@Sendable (AttachmentUploadEvent) -> Void)?
    ) async throws {
        guard AttachmentBackgroundUploadPolicy.shouldUseSystemBackgroundTransfer(baseURL: baseURL) else {
            throw HostClientSecurityError.invalidEndpoint
        }
        _ = try attachment.verifiedFileURL()
        guard startingOffset >= 0, startingOffset <= attachment.sizeBytes else {
            throw URLError(.badURL)
        }
        guard startingOffset < attachment.sizeBytes else { return }

        let waiter = Waiter(onEvent: onEvent)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard waiter.install(continuation) else { return }
                let shouldDiscoverExisting: Bool
                let provisionalLaneID: String
                lock.lock()
                guard let laneID = laneState.beginBackground(attachmentID: attachment.id) else {
                    lock.unlock()
                    waiter.finish(.failure(CancellationError()))
                    return
                }
                provisionalLaneID = laneID
                if let bearerToken, !bearerToken.isEmpty {
                    tokenOverrides[attachment.id] = bearerToken
                }
                if waiters[attachment.id] == nil {
                    waiters[attachment.id] = [waiter]
                    shouldDiscoverExisting = true
                } else {
                    waiters[attachment.id, default: []].append(waiter)
                    shouldDiscoverExisting = false
                }
                lock.unlock()

                guard shouldDiscoverExisting else { return }
                session.getAllTasks { [weak self] tasks in
                    guard let self else { return }
                    guard self.isCurrentBackgroundLane(
                        attachmentID: attachment.id,
                        laneID: provisionalLaneID
                    ) else { return }

                    var laneID = provisionalLaneID
                    if let existing = tasks.first(where: {
                        BackgroundAttachmentUploadJob.decode($0.taskDescription)?.attachment.id == attachment.id
                    }), let rawJob = BackgroundAttachmentUploadJob.decode(existing.taskDescription) {
                        if rawJob.operation == .begin {
                            existing.taskDescription = nil
                            existing.cancel()
                            self.removeBodyFile(rawJob)
                        } else {
                            let existingDisposition = AttachmentBackgroundUploadPolicy.existingTaskDisposition(
                                for: existing.state
                            )
                            guard let prepared = self.prepareDiscoveredBackgroundJob(
                                rawJob,
                                task: existing,
                                provisionalLaneID: provisionalLaneID,
                                replaceExisting: existingDisposition == .replace
                            ) else { return }
                            laneID = prepared.laneID
                            if prepared.replaceExisting {
                                existing.taskDescription = nil
                                existing.cancel()
                                self.removeBodyFile(rawJob)
                            } else {
                                switch existingDisposition {
                                case .reuse:
                                    self.emitExistingTask(prepared.job, task: existing)
                                    return
                                case .resume:
                                    guard self.resumeExistingTaskIfCurrent(
                                        existing,
                                        job: prepared.job
                                    ) else { return }
                                    self.emitExistingTask(prepared.job, task: existing)
                                    return
                                case .replace:
                                    break
                                }
                            }
                        }
                    }

                    do {
                        try self.scheduleChunk(
                            attachment: attachment,
                            baseURL: baseURL,
                            offset: startingOffset,
                            recoveryCount: 0,
                            laneID: laneID
                        )
                    } catch {
                        self.finish(
                            attachmentID: attachment.id,
                            laneID: laneID,
                            result: .failure(error)
                        )
                    }
                }
            }
        } onCancel: {
            // BGProcessing expiration only stops this caller. URLSession still
            // owns the upload; another waiter or a relaunch can reconcile it.
            waiter.finish(.failure(CancellationError()))
        }
    }

    private struct PreparedBackgroundJob {
        let job: BackgroundAttachmentUploadJob
        let laneID: String
        let replaceExisting: Bool
    }

    private func isCurrentBackgroundLane(attachmentID: String, laneID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return laneState.isCurrentBackgroundLane(attachmentID: attachmentID, laneID: laneID)
    }

    private func prepareDiscoveredBackgroundJob(
        _ rawJob: BackgroundAttachmentUploadJob,
        task: URLSessionTask,
        provisionalLaneID: String,
        replaceExisting: Bool
    ) -> PreparedBackgroundJob? {
        lock.lock()
        let disposition = laneState.prepareDiscoveredExistingTask(
            attachmentID: rawJob.attachment.id,
            provisionalLaneID: provisionalLaneID,
            existingLaneID: rawJob.laneID,
            replaceExisting: replaceExisting
        )
        lock.unlock()

        switch disposition {
        case .abort:
            return nil
        case let .replaceStale(laneID):
            return PreparedBackgroundJob(
                job: rawJob.withLaneID(laneID),
                laneID: laneID,
                replaceExisting: true
            )
        case let .use(laneID):
            let job = rawJob.withLaneID(laneID)
            if rawJob.laneID != laneID {
                task.taskDescription = try? job.encodedDescription()
            }
            return PreparedBackgroundJob(
                job: job,
                laneID: laneID,
                replaceExisting: false
            )
        }
    }

    private func claimBackgroundJob(
        _ rawJob: BackgroundAttachmentUploadJob
    ) -> BackgroundAttachmentUploadJob? {
        lock.lock()
        let laneID = laneState.adoptBackgroundJob(
            attachmentID: rawJob.attachment.id,
            laneID: rawJob.laneID
        )
        lock.unlock()
        guard let laneID else { return nil }
        return rawJob.withLaneID(laneID)
    }

    private func resumeExistingTaskIfCurrent(
        _ task: URLSessionTask,
        job: BackgroundAttachmentUploadJob
    ) -> Bool {
        guard let laneID = job.laneID else { return false }
        lock.lock()
        guard laneState.isCurrentBackgroundLane(
            attachmentID: job.attachment.id,
            laneID: laneID
        ) else {
            lock.unlock()
            return false
        }
        task.resume()
        lock.unlock()
        return true
    }

    private func emitExistingTask(_ job: BackgroundAttachmentUploadJob, task: URLSessionTask) {
        guard let laneID = job.laneID else { return }
        emit(
            attachmentID: job.attachment.id,
            laneID: laneID,
            state: job.progressState(totalBytesSent: task.countOfBytesSent)
        )
    }

    /// Foreground recovery must refresh even when the Store still owns a lease
    /// and therefore intentionally does not call upload() a second time.
    func refreshProgress() {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            self.delegateQueue.addOperation { [weak self] in
                guard let self else { return }
                for task in tasks where task.state == .running || task.state == .suspended {
                    guard let rawJob = BackgroundAttachmentUploadJob.decode(task.taskDescription),
                          let job = self.claimBackgroundJob(rawJob)
                    else { continue }
                    self.emitExistingTask(job, task: task)
                }
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let rawJob = BackgroundAttachmentUploadJob.decode(task.taskDescription),
              rawJob.operation == .chunk,
              let job = claimBackgroundJob(rawJob)
        else { return }
        Self.logger.debug("id=\(String(job.attachment.id.prefix(8)), privacy: .public) offset=\(job.offset) sent=\(totalBytesSent) total=\(job.attachment.sizeBytes)")
        guard let laneID = job.laneID else { return }
        emit(
            attachmentID: job.attachment.id,
            laneID: laneID,
            state: job.progressState(totalBytesSent: totalBytesSent)
        )
    }

    @discardableResult
    func handleEventsForBackgroundURLSession(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) -> Bool {
        guard identifier == AttachmentBackgroundUploadPolicy.sessionIdentifier else { return false }
        lock.lock()
        let replaced = backgroundCompletionHandler
        backgroundCompletionHandler = completionHandler
        lock.unlock()
        if let replaced {
            DispatchQueue.main.async { replaced() }
        }
        _ = session
        return true
    }

    func cancel(attachmentID: String) {
        let values = claimImmediateUploadOwnership(attachmentID: attachmentID)
        for value in values {
            value.finish(.failure(CancellationError()))
        }
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            defer { self.endImmediateUploadHandoff(attachmentID: attachmentID) }
            for task in tasks where BackgroundAttachmentUploadJob.decode(task.taskDescription)?.attachment.id == attachmentID {
                if let job = BackgroundAttachmentUploadJob.decode(task.taskDescription) {
                    self.removeBodyFile(job)
                }
                task.taskDescription = nil
                task.cancel()
            }
            self.removeTransferDirectory(attachmentID: attachmentID)
        }
    }

    /// Retire the system-owned byte transfer for one exact file before a
    /// latency-sensitive foreground send owns the same Host resumable offset.
    /// The marker stays active until endImmediateUploadHandoff().
    func beginImmediateUploadHandoff(attachmentID: String) async {
        let values = claimImmediateUploadOwnership(attachmentID: attachmentID)
        for value in values {
            value.finish(.failure(CancellationError()))
        }

        let matchingTasks: [URLSessionTask] = await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks.filter {
                    BackgroundAttachmentUploadJob.decode($0.taskDescription)?.attachment.id == attachmentID
                })
            }
        }
        for task in matchingTasks {
            if let job = BackgroundAttachmentUploadJob.decode(task.taskDescription) {
                removeBodyFile(job)
            }
            // A late delegate completion must not schedule another background
            // chunk after the foreground lane has taken ownership.
            task.taskDescription = nil
            task.cancel()
        }
        removeTransferDirectory(attachmentID: attachmentID)

        // URLSession cancellation is asynchronous. Keep this bounded; if one
        // request still races, resumable PATCH reconciliation advances from the
        // Host-confirmed offset without changing file identity.
        for _ in 0..<20 where matchingTasks.contains(where: { $0.state != .completed }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func claimImmediateUploadOwnership(attachmentID: String) -> [Waiter] {
        lock.lock()
        defer { lock.unlock() }
        laneState.beginImmediate(attachmentID: attachmentID)
        tokenOverrides.removeValue(forKey: attachmentID)
        return waiters.removeValue(forKey: attachmentID) ?? []
    }

    func endImmediateUploadHandoff(attachmentID: String) {
        lock.lock()
        laneState.endImmediate(attachmentID: attachmentID)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        responseBodies[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let body = responseBodies.removeValue(forKey: task.taskIdentifier) ?? Data()
        lock.unlock()
        guard let rawJob = BackgroundAttachmentUploadJob.decode(task.taskDescription) else { return }
        removeBodyFile(rawJob)
        guard let job = claimBackgroundJob(rawJob),
              let laneID = job.laneID
        else { return }

        if let error {
            if (error as? URLError)?.code == .cancelled {
                finish(attachmentID: job.attachment.id, laneID: laneID, result: .failure(CancellationError()))
                return
            }
            if job.operation == .begin {
                finish(
                    attachmentID: job.attachment.id,
                    laneID: laneID,
                    result: .failure(MaterialsError.message("旧版附件确认任务未完成，已保留文件；重新发送会从服务器状态继续。"))
                )
            } else {
                recover(job, reason: error)
            }
            return
        }
        guard let response = task.response as? HTTPURLResponse else {
            recover(job, reason: URLError(.badServerResponse))
            return
        }

        do {
            switch job.operation {
            case .begin:
                try handleBegin(job: job, response: response, body: body)
            case .chunk:
                try handleChunk(job: job, response: response)
            }
        } catch {
            if response.statusCode >= 500 {
                recover(job, reason: error)
            } else {
                finish(
                    attachmentID: job.attachment.id,
                    laneID: laneID,
                    result: .failure(error)
                )
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        lock.unlock()
        guard let handler else { return }

        Task { @MainActor in
            BackgroundUploadWakeCompletion.run {
                await DeviceBackgroundExecutionController.shared.recoverDurableWorkNow(
                    reason: "background_attachment_events_finished",
                    includeDeviceActions: false
                )
            } onDeferredRecovery: {
                DeviceBackgroundExecutionController.shared.scheduleRecoveryTask(
                    reason: "background_attachment_wake_budget_exhausted"
                )
            } completion: {
                handler()
            }
        }
    }

    private func handleBegin(
        job: BackgroundAttachmentUploadJob,
        response: HTTPURLResponse,
        body: Data
    ) throws {
        guard let laneID = job.laneID else { throw CancellationError() }
        guard [200, 201].contains(response.statusCode) else {
            throw productError(statusCode: response.statusCode)
        }
        let descriptor = try JSONDecoder.floweroll.decode(BackgroundAttachmentUploadDescriptor.self, from: body)
        guard descriptor.fileID == job.attachment.id,
              descriptor.offset >= 0,
              descriptor.offset <= job.attachment.sizeBytes
        else { throw URLError(.badServerResponse) }

        if descriptor.complete {
            guard descriptor.file != nil else { throw URLError(.badServerResponse) }
            finish(
                attachmentID: job.attachment.id,
                laneID: laneID,
                result: .success(())
            )
            removeTransferDirectory(attachmentID: job.attachment.id)
            return
        }
        guard descriptor.offset < job.attachment.sizeBytes else {
            throw URLError(.badServerResponse)
        }
        emit(
            attachmentID: job.attachment.id,
            laneID: laneID,
            state: .uploading(
                sentBytes: Int64(descriptor.offset),
                totalBytes: Int64(job.attachment.sizeBytes)
            )
        )
        try scheduleChunk(
            attachment: job.attachment,
            baseURL: try endpoint(job),
            offset: descriptor.offset,
            recoveryCount: job.nextRecoveryCount(confirmedOffset: descriptor.offset),
            laneID: laneID
        )
    }

    private func handleChunk(
        job: BackgroundAttachmentUploadJob,
        response: HTTPURLResponse
    ) throws {
        guard let laneID = job.laneID else { throw CancellationError() }
        guard response.statusCode == 204 || response.statusCode == 409,
              let rawOffset = response.value(forHTTPHeaderField: "Upload-Offset"),
              let confirmedOffset = Int(rawOffset),
              confirmedOffset >= 0,
              confirmedOffset <= job.attachment.sizeBytes
        else { throw productError(statusCode: response.statusCode) }

        if response.statusCode == 204, confirmedOffset <= job.offset {
            throw URLError(.cannotWriteToFile)
        }
        emit(
            attachmentID: job.attachment.id,
            laneID: laneID,
            state: .uploading(
                sentBytes: Int64(confirmedOffset),
                totalBytes: Int64(job.attachment.sizeBytes)
            )
        )

        if confirmedOffset == job.attachment.sizeBytes {
            // PATCH offset is durable byte-transfer truth. The caller performs
            // the small immutable GET receipt on the ordinary session before
            // claiming attachment completion.
            emit(
                attachmentID: job.attachment.id,
                laneID: laneID,
                state: .reconciling
            )
            finish(
                attachmentID: job.attachment.id,
                laneID: laneID,
                result: .success(())
            )
            removeTransferDirectory(attachmentID: job.attachment.id)
        } else {
            try scheduleChunk(
                attachment: job.attachment,
                baseURL: try endpoint(job),
                offset: confirmedOffset,
                recoveryCount: 0,
                laneID: laneID
            )
        }
    }

    private func recover(_ job: BackgroundAttachmentUploadJob, reason: Error) {
        guard let laneID = job.laneID else { return }
        let next = job.recoveryCount + 1
        guard next <= AttachmentBackgroundUploadPolicy.recoveryLimit else {
            finish(
                attachmentID: job.attachment.id,
                laneID: laneID,
                result: .failure(MaterialsError.message("附件后台上传多次中断，已保留进度；重新打开花卷会从服务器确认位置继续。"))
            )
            return
        }
        emit(
            attachmentID: job.attachment.id,
            laneID: laneID,
            state: .reconciling
        )
        do {
            // Replaying the exact same PATCH offset is safe: if Host committed
            // the prior bytes but its response was lost, it answers 409 with
            // the authoritative newer offset and handleChunk advances from it.
            try scheduleChunk(
                attachment: job.attachment,
                baseURL: try endpoint(job),
                offset: job.offset,
                recoveryCount: next,
                laneID: laneID
            )
        } catch {
            finish(
                attachmentID: job.attachment.id,
                laneID: laneID,
                result: .failure(error)
            )
        }
    }

    // `.begin` stays in BackgroundAttachmentUploadJob only to decode and
    // retire in-flight zero-byte tasks created by older installed builds.

    private func scheduleChunk(
        attachment: PendingAttachment,
        baseURL: URL,
        offset: Int,
        recoveryCount: Int,
        laneID: String
    ) throws {
        guard offset >= 0, offset < attachment.sizeBytes else { throw URLError(.badURL) }
        let localURL = try attachment.fileURL()
        let values = try localURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.fileSize == attachment.sizeBytes else {
            throw MaterialsError.message("附件已损坏或丢失，请重新选择。")
        }
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let wanted = min(AttachmentBackgroundUploadPolicy.chunkBytes, attachment.sizeBytes - offset)
        guard let chunk = try handle.read(upToCount: wanted), chunk.count == wanted else {
            throw MaterialsError.message("读取本地附件时发现文件不完整，请重新选择。")
        }
        let bodyURL = try bodyFileURL(attachmentID: attachment.id, prefix: "chunk-\(offset)")
        try chunk.write(
            to: bodyURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        var request = authenticatedRequest(
            method: "PATCH",
            url: endpointURL(baseURL, path: ["v1", "files", "uploads", attachment.id]),
            attachmentID: attachment.id,
            baseURL: baseURL
        )
        request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("?1", forHTTPHeaderField: "X-Floweroll-Background-Upload")
        request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        request.setValue(offset + wanted == attachment.sizeBytes ? "?1" : "?0", forHTTPHeaderField: "Upload-Complete")
        let job = BackgroundAttachmentUploadJob(
            attachment: attachment,
            endpoint: baseURL.absoluteString,
            operation: .chunk,
            offset: offset,
            recoveryCount: recoveryCount,
            bodyFileName: bodyURL.lastPathComponent,
            laneID: laneID
        )
        try schedule(request: request, bodyURL: bodyURL, job: job, expectedBytes: wanted)
    }

    private func schedule(
        request: URLRequest,
        bodyURL: URL,
        job: BackgroundAttachmentUploadJob,
        expectedBytes: Int
    ) throws {
        lock.lock()
        guard let laneID = job.laneID,
              laneState.isCurrentBackgroundLane(
                attachmentID: job.attachment.id,
                laneID: laneID
              )
        else {
            lock.unlock()
            try? FileManager.default.removeItem(at: bodyURL)
            throw CancellationError()
        }
        let task = session.uploadTask(with: request, fromFile: bodyURL)
        task.taskDescription = try? job.encodedDescription()
        task.countOfBytesClientExpectsToSend = Int64(expectedBytes)
        task.resume()
        lock.unlock()
    }

    private func authenticatedRequest(
        method: String,
        url: URL,
        attachmentID: String,
        baseURL: URL
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let token = token(attachmentID: attachmentID, baseURL: baseURL), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func token(attachmentID: String, baseURL: URL?) -> String? {
        lock.lock()
        let override = tokenOverrides[attachmentID]
        lock.unlock()
        if let override { return override }
        guard let baseURL else { return nil }
        return try? credentialStore.bearerToken(for: baseURL)
    }

    private func endpoint(_ job: BackgroundAttachmentUploadJob) throws -> URL {
        guard let endpoint = URL(string: job.endpoint),
              AttachmentBackgroundUploadPolicy.shouldUseSystemBackgroundTransfer(baseURL: endpoint)
        else { throw HostClientSecurityError.invalidEndpoint }
        return endpoint
    }

    private func endpointURL(_ baseURL: URL, path: [String]) -> URL {
        path.reduce(baseURL) { $0.appendingPathComponent($1) }
    }

    private func bodyFileURL(attachmentID: String, prefix: String) throws -> URL {
        let root = try transferRoot().appendingPathComponent(attachmentID, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("\(prefix)-\(UUID().uuidString).body")
    }

    private func transferRoot() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appendingPathComponent("Floweroll/BackgroundAttachmentUploads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func removeBodyFile(_ job: BackgroundAttachmentUploadJob) {
        guard let root = try? transferRoot() else { return }
        let path = root
            .appendingPathComponent(job.attachment.id, isDirectory: true)
            .appendingPathComponent(job.bodyFileName)
        try? FileManager.default.removeItem(at: path)
    }

    private func removeTransferDirectory(attachmentID: String) {
        guard let root = try? transferRoot() else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(attachmentID, isDirectory: true))
    }

    private func emit(
        attachmentID: String,
        laneID: String,
        state: AttachmentUploadState
    ) {
        lock.lock()
        guard laneState.isCurrentBackgroundLane(
            attachmentID: attachmentID,
            laneID: laneID
        ) else {
            lock.unlock()
            return
        }
        let callbacks = waiters[attachmentID]?.filter { !$0.isFinished }.compactMap(\.onEvent) ?? []
        lock.unlock()
        let event = AttachmentUploadEvent(attachmentID: attachmentID, state: state)
        for callback in callbacks { callback(event) }
    }

    private func finish(
        attachmentID: String,
        laneID: String,
        result: Result<Void, Error>
    ) {
        lock.lock()
        guard laneState.finishBackground(attachmentID: attachmentID, laneID: laneID) else {
            lock.unlock()
            return
        }
        let values = waiters.removeValue(forKey: attachmentID) ?? []
        tokenOverrides.removeValue(forKey: attachmentID)
        lock.unlock()
        for value in values { value.finish(result) }
    }

    private func productError(statusCode: Int) -> Error {
        switch statusCode {
        case 401, 403:
            return MaterialsError.message("附件后台上传的 Host 配对已失效，请重新连接后重试。")
        case 413:
            return MaterialsError.message("附件超过服务器允许的上传大小，请压缩或分批添加。")
        default:
            return MaterialsError.message("服务器拒绝了附件后台上传（HTTP \(statusCode)）。")
        }
    }
}


final class FlowerollAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard AttachmentBackgroundUploadTransport.shared.handleEventsForBackgroundURLSession(
            identifier: identifier,
            completionHandler: completionHandler
        ) else {
            completionHandler()
            return
        }
    }
}
