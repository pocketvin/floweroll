import Foundation
import CryptoKit


enum HostClientSecurityError: Error, Equatable {
    case invalidEndpoint
    case insecureRemoteEndpoint
    case missingCredential
}


struct FlowerollHostClient: Sendable {
    private struct TaskInput: Codable, Sendable {
        let kind: String
        let text: String
        var attachmentIDs: [String]? = nil
        enum CodingKeys: String, CodingKey {
            case kind, text
            case attachmentIDs = "attachment_ids"
        }
    }

    private struct TaskSubmissionBody: Codable, Sendable {
        let submissionID: String
        let input: TaskInput
        let invocationSource: String
        let parentTaskID: String?
        let clientCreatedAt: Date

        enum CodingKeys: String, CodingKey {
            case submissionID = "submission_id"
            case input
            case invocationSource = "invocation_source"
            case parentTaskID = "parent_task_id"
            case clientCreatedAt = "client_created_at"
        }
    }

    private struct ActionResultBody: Codable, Sendable {
        let attemptID: String
        let success: Bool
        let output: [String: JSONValue]
        let error: String?

        enum CodingKeys: String, CodingKey {
            case attemptID = "attempt_id"
            case success
            case output
            case error
        }
    }

    private struct UserTurnBody: Codable, Sendable {
        struct Content: Codable, Sendable {
            let kind: String
            let text: String
            var attachmentIDs: [String]? = nil
            enum CodingKeys: String, CodingKey {
                case kind, text
                case attachmentIDs = "attachment_ids"
            }
        }

        let eventID: String
        let content: Content

        enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case content
        }
    }

    private struct CancelBody: Codable, Sendable {
        let eventID: String
        let reason: String?

        enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case reason
        }
    }

    private struct ClarificationResponseBody: Codable, Sendable {
        struct Response: Codable, Sendable {
            let optionID: String?
            let text: String?

            enum CodingKeys: String, CodingKey {
                case optionID = "option_id"
                case text
            }
        }

        let eventID: String
        let response: Response

        enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case response
        }
    }

    private struct ActionInputResponseBody: Codable, Sendable {
        let eventID: String
        let bindingDigest: String
        let response: [String: JSONValue]

        enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case bindingDigest = "binding_digest"
            case response
        }
    }

    private struct ArtifactRevisionBody: Codable, Sendable {
        let eventID: String
        let expectedRevisionID: String
        let content: [String: JSONValue]

        enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case expectedRevisionID = "expected_revision_id"
            case content
        }
    }

    let baseURL: URL
    private let session: URLSession
    /// Runtime-only credential. It is never written by PendingSubmissionStore
    /// or DeviceActionJournal. A real pairing flow should source it from Keychain.
    private let bearerToken: String?

    init(
        baseURL: URL,
        session: URLSession = .shared,
        bearerToken: String? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.bearerToken = bearerToken
    }

    static func paired(
        baseURL: URL,
        session: URLSession = .shared,
        credentialStore: HostCredentialStore = HostCredentialStore()
    ) throws -> FlowerollHostClient {
        let token = try credentialStore.bearerToken(for: baseURL)
        return FlowerollHostClient(
            baseURL: baseURL,
            session: session,
            bearerToken: token
        )
    }

    func validateEndpointSecurity() throws {
        guard
            let scheme = baseURL.scheme?.lowercased(),
            let host = baseURL.host?.lowercased(),
            !scheme.isEmpty,
            !host.isEmpty
        else {
            throw HostClientSecurityError.invalidEndpoint
        }
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        if isLoopback {
            guard scheme == "http" || scheme == "https" else {
                throw HostClientSecurityError.invalidEndpoint
            }
            return
        }
        guard scheme == "https" else {
            throw HostClientSecurityError.insecureRemoteEndpoint
        }
        guard let bearerToken, !bearerToken.isEmpty else {
            throw HostClientSecurityError.missingCredential
        }
    }

    /// Observation shares only the existing paired HTTPS/auth boundary.
    func observationRequest(method: String, suffix: [String], body: Data? = nil) async throws -> Data {
        guard ["GET", "POST"].contains(method),
              suffix.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("..") }) else {
            throw URLError(.badURL)
        }
        return try await request(method: method, path: ["v1", "observations"] + suffix, body: body).data
    }

    func fetchCapabilityStatus() async throws -> HostCapabilityStatusResponse {
        let result = try await request(method: "GET", path: ["v1", "capabilities"])
        return try JSONDecoder.floweroll.decode(HostCapabilityStatusResponse.self, from: result.data)
    }

    func fetchDeveloperTaskIndex(limit: Int = 40) async throws -> HostDeveloperTaskIndexResponse {
        var components = URLComponents(
            url: url(path: ["v1", "developer", "observability", "tasks"]),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "limit", value: String(max(1, min(50, limit))))]
        guard let requestURL = components.url else { throw HostClientSecurityError.invalidEndpoint }
        let result = try await request(
            method: "GET",
            absoluteURL: requestURL,
            headers: ["X-Floweroll-Developer-Mode": "1"]
        )
        return try JSONDecoder.floweroll.decode(HostDeveloperTaskIndexResponse.self, from: result.data)
    }

    func fetchDeveloperTaskOverview(taskID: String) async throws -> HostDeveloperTaskOverview {
        let result = try await request(
            method: "GET",
            path: ["v1", "developer", "observability", "tasks", taskID],
            headers: ["X-Floweroll-Developer-Mode": "1"]
        )
        return try JSONDecoder.floweroll.decode(HostDeveloperTaskOverview.self, from: result.data)
    }

    func fetchDeveloperPlannerCall(taskID: String, callNumber: Int) async throws -> HostDeveloperPlannerCallDetail {
        let result = try await request(
            method: "GET",
            path: ["v1", "developer", "observability", "tasks", taskID, "planner-calls", String(callNumber)],
            headers: ["X-Floweroll-Developer-Mode": "1"]
        )
        return try JSONDecoder.floweroll.decode(HostDeveloperPlannerCallDetail.self, from: result.data)
    }

    /// Persist-first Task submission. `submissionID` is the durable identity of
    /// this exact user send. Retry/relaunch reuses that identity; a separate
    /// user send always receives a new one even if its content is identical.
    func submitDurably(
        text: String,
        invocationSource: String,
        parentTaskID: String? = nil,
        attachments: [PendingAttachment] = [],
        submissionID: String = UUID().uuidString,
        pendingStore: PendingSubmissionStore,
        onAttachmentEvent: (@Sendable (AttachmentUploadEvent) -> Void)? = nil
    ) async throws -> HostTask {
        let pending = try await pendingStore.create(
            text: text,
            invocationSource: invocationSource,
            parentTaskID: parentTaskID,
            attachments: attachments,
            submissionID: submissionID
        )
        return try await submitExisting(
            pending,
            pendingStore: pendingStore,
            onAttachmentEvent: onAttachmentEvent
        )
    }

    func submitExisting(
        _ pending: PendingSubmission,
        pendingStore: PendingSubmissionStore,
        onAttachmentEvent: (@Sendable (AttachmentUploadEvent) -> Void)? = nil
    ) async throws -> HostTask {
        try Task.checkCancellation()
        guard await pendingStore.canReplaySubmission(submissionID: pending.submissionID) else {
            throw CancellationError()
        }
        try await pendingStore.markAttempting(submissionID: pending.submissionID)
        do {
            var firstAttachmentError: Error?
            for attachment in pending.attachments ?? [] {
                do {
                    _ = try await uploadTaskAttachment(
                        attachment,
                        onEvent: onAttachmentEvent
                    )
                } catch {
                    firstAttachmentError = firstAttachmentError ?? error
                    onAttachmentEvent?(.init(
                        attachmentID: attachment.id,
                        state: .failed(Self.attachmentProductMessage(for: error))
                    ))
                    // One attachment failure must not prevent other independent
                    // attachment receipts from making progress.
                    continue
                }
            }
            if let firstAttachmentError { throw firstAttachmentError }

            try Task.checkCancellation()
            guard await pendingStore.canReplaySubmission(submissionID: pending.submissionID) else {
                throw CancellationError()
            }
            let body = TaskSubmissionBody(
                submissionID: pending.submissionID,
                input: TaskInput(kind: "text", text: pending.text, attachmentIDs: pending.attachments?.map(\.id)),
                invocationSource: pending.invocationSource,
                parentTaskID: pending.parentTaskID,
                clientCreatedAt: pending.createdAt
            )
            let data = try JSONEncoder.floweroll.encode(body)
            let task = try await submitTaskWithReconciliation(
                submissionID: pending.submissionID,
                body: data
            )
            try await pendingStore.markAccepted(submissionID: pending.submissionID)
            return task
        } catch {
            try? await pendingStore.markFailed(
                submissionID: pending.submissionID,
                message: Self.attachmentProductMessage(for: error)
            )
            throw error
        }
    }

    func taskForSubmissionID(_ submissionID: String) async throws -> HostTask? {
        let result = try await request(
            method: "GET",
            path: ["v1", "submissions", submissionID, "task"],
            acceptedStatuses: [200, 404]
        )
        guard result.status == 200 else { return nil }
        return try JSONDecoder.floweroll.decode(HostTask.self, from: result.data)
    }

    private func submitTaskWithReconciliation(
        submissionID: String,
        body: Data
    ) async throws -> HostTask {
        do {
            return try await postTaskSubmission(body)
        } catch {
            if error is HostProblem || error is HostClientSecurityError {
                throw error
            }
            try Task.checkCancellation()
            // The POST response is not durable truth.  The Host's unique
            // submission_id is: first read it back, then replay the exact same
            // idempotent submission at most once if it is still absent.
            if let recovered = await recoveredSubmission(submissionID) {
                return recovered
            }
            try Task.checkCancellation()
            do {
                return try await postTaskSubmission(body)
            } catch {
                if error is HostProblem || error is HostClientSecurityError {
                    throw error
                }
                if let recovered = await recoveredSubmission(submissionID) {
                    return recovered
                }
                throw MaterialsError.message(
                    "发送请求暂时没有完成，附件和内容已安全保留；稍后重试会继续同一次发送，不会重复创建任务。"
                )
            }
        }
    }

    private func postTaskSubmission(_ body: Data) async throws -> HostTask {
        let responseData = try await request(
            method: "POST",
            path: ["v1", "tasks"],
            body: body,
            acceptedStatuses: [200, 201]
        ).data
        return try JSONDecoder.floweroll.decode(HostTask.self, from: responseData)
    }

    private func recoveredSubmission(_ submissionID: String) async -> HostTask? {
        do {
            return try await taskForSubmissionID(submissionID)
        } catch {
            return nil
        }
    }

    func uploadedAttachmentReceipt(fileID: String) async throws -> TaskMaterialFile? {
        let result = try await request(
            method: "GET",
            path: ["v1", "files", fileID],
            acceptedStatuses: [200, 404]
        )
        guard result.status == 200 else { return nil }
        return try JSONDecoder.floweroll.decode(TaskMaterialFile.self, from: result.data)
    }

    func uploadedAttachmentIfVerified(
        _ attachment: PendingAttachment
    ) async throws -> TaskMaterialFile? {
        guard let receipt = try await uploadedAttachmentReceipt(fileID: attachment.id) else { return nil }
        return try verifyUploadedAttachment(receipt, expected: attachment, onEvent: nil)
    }

    func uploadTaskAttachment(
        _ attachment: PendingAttachment,
        onEvent: (@Sendable (AttachmentUploadEvent) -> Void)? = nil
    ) async throws -> TaskMaterialFile {
        try validateEndpointSecurity()
        let localURL = try attachment.verifiedFileURL()
        onEvent?(.init(attachmentID: attachment.id, state: .checkingHost))

        if AttachmentBackgroundUploadPolicy.shouldUseSystemBackgroundTransfer(baseURL: baseURL) {
            let file = try await AttachmentBackgroundUploadTransport.shared.upload(
                attachment: attachment,
                baseURL: baseURL,
                bearerToken: bearerToken,
                onEvent: onEvent
            )
            return try verifyUploadedAttachment(file, expected: attachment, onEvent: onEvent)
        }

        if let existing = try await uploadedAttachmentReceipt(fileID: attachment.id) {
            return try verifyUploadedAttachment(existing, expected: attachment, onEvent: onEvent)
        }

        return try await performAttachmentUpload(
            attachment,
            localURL: localURL,
            mayRetransmitAfterExplicitMissingReadback: true,
            onEvent: onEvent
        )
    }

    private struct ResumableUploadDescriptor: Codable, Sendable {
        let fileID: String
        let offset: Int
        let complete: Bool
        let file: TaskMaterialFile?

        enum CodingKeys: String, CodingKey {
            case fileID = "file_id"
            case offset, complete, file
        }
    }

    private struct ResumableUploadState: Sendable {
        let offset: Int
        let totalBytes: Int?
        let complete: Bool
    }

    private static let attachmentChunkBytes = 64 * 1024
    private static let attachmentRecoveryLimit = 8

    private func performAttachmentUpload(
        _ attachment: PendingAttachment,
        localURL: URL,
        mayRetransmitAfterExplicitMissingReadback: Bool,
        onEvent: (@Sendable (AttachmentUploadEvent) -> Void)?
    ) async throws -> TaskMaterialFile {
        // The old whole-file POST was fundamentally unsafe on slow mobile/tunnel
        // links: one 2 MB request could exceed the Host socket deadline.  The
        // durable transfer truth is now Host-confirmed offset, not one HTTP ACK.
        let descriptor = try await ensureResumableUpload(
            attachment,
            mayRetryCreate: mayRetransmitAfterExplicitMissingReadback,
            onEvent: onEvent
        )
        if let file = descriptor.file {
            return try verifyUploadedAttachment(file, expected: attachment, onEvent: onEvent)
        }

        var offset = descriptor.offset
        guard offset >= 0, offset <= attachment.sizeBytes else {
            throw MaterialsError.message("服务器返回了无效的附件上传位置，已停止重试。")
        }
        onEvent?(.init(
            attachmentID: attachment.id,
            state: .uploading(sentBytes: Int64(offset), totalBytes: Int64(attachment.sizeBytes))
        ))

        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        var recoveryCount = 0

        while offset < attachment.sizeBytes {
            try handle.seek(toOffset: UInt64(offset))
            let wanted = min(Self.attachmentChunkBytes, attachment.sizeBytes - offset)
            guard let chunk = try handle.read(upToCount: wanted), chunk.count == wanted else {
                throw MaterialsError.message("读取本地附件时发现文件不完整，请重新选择。")
            }
            let completesUpload = offset + chunk.count == attachment.sizeBytes

            do {
                let confirmedOffset = try await patchResumableUpload(
                    fileID: attachment.id,
                    offset: offset,
                    chunk: chunk,
                    complete: completesUpload
                )
                guard confirmedOffset >= offset, confirmedOffset <= attachment.sizeBytes else {
                    throw MaterialsError.message("服务器返回了无效的附件上传位置，已停止重试。")
                }
                guard confirmedOffset > offset else {
                    throw MaterialsError.message("附件上传没有取得进展，请稍后重试。")
                }
                offset = confirmedOffset
                recoveryCount = 0
                onEvent?(.init(
                    attachmentID: attachment.id,
                    state: .uploading(sentBytes: Int64(offset), totalBytes: Int64(attachment.sizeBytes))
                ))
            } catch {
                recoveryCount += 1
                guard recoveryCount <= Self.attachmentRecoveryLimit else {
                    throw MaterialsError.message("附件上传多次中断，已安全保留本地文件，请稍后重试。")
                }
                onEvent?(.init(attachmentID: attachment.id, state: .reconciling))
                let state: ResumableUploadState?
                do {
                    state = try await resumableUploadState(fileID: attachment.id)
                } catch {
                    throw MaterialsError.message(
                        "网络中断后暂时无法确认附件上传位置，已安全保留本地文件，请稍后重试。"
                    )
                }
                guard let state else {
                    throw MaterialsError.message("附件上传状态已丢失，已停止自动重传，请稍后重试。")
                }
                guard state.offset >= 0, state.offset <= attachment.sizeBytes else {
                    throw MaterialsError.message("服务器返回了无效的附件上传位置，已停止重试。")
                }
                offset = state.offset
                onEvent?(.init(
                    attachmentID: attachment.id,
                    state: .uploading(sentBytes: Int64(offset), totalBytes: Int64(attachment.sizeBytes))
                ))
                if state.complete {
                    offset = attachment.sizeBytes
                    break
                }
            }
        }

        onEvent?(.init(attachmentID: attachment.id, state: .reconciling))
        guard let receipt = try await uploadedAttachmentReceipt(fileID: attachment.id) else {
            // A final PATCH can succeed while its response is lost. HEAD gives
            // exact offset truth; GET is the immutable publication readback.
            if let state = try await resumableUploadState(fileID: attachment.id), state.complete,
               let retriedReceipt = try await uploadedAttachmentReceipt(fileID: attachment.id) {
                return try verifyUploadedAttachment(retriedReceipt, expected: attachment, onEvent: onEvent)
            }
            throw MaterialsError.message("附件字节已传完，但服务器尚未发布可校验记录，请稍后重试。")
        }
        return try verifyUploadedAttachment(receipt, expected: attachment, onEvent: onEvent)
    }

    private func ensureResumableUpload(
        _ attachment: PendingAttachment,
        mayRetryCreate: Bool,
        onEvent: (@Sendable (AttachmentUploadEvent) -> Void)?
    ) async throws -> ResumableUploadDescriptor {
        if let state = try await resumableUploadState(fileID: attachment.id) {
            if state.complete, let receipt = try await uploadedAttachmentReceipt(fileID: attachment.id) {
                return ResumableUploadDescriptor(
                    fileID: attachment.id,
                    offset: state.offset,
                    complete: true,
                    file: receipt
                )
            }
            return ResumableUploadDescriptor(
                fileID: attachment.id,
                offset: state.offset,
                complete: state.complete,
                file: nil
            )
        }

        do {
            return try await beginResumableUpload(attachment)
        } catch {
            onEvent?(.init(attachmentID: attachment.id, state: .reconciling))
            if let state = try? await resumableUploadState(fileID: attachment.id) {
                return ResumableUploadDescriptor(
                    fileID: attachment.id,
                    offset: state.offset,
                    complete: state.complete,
                    file: state.complete ? try await uploadedAttachmentReceipt(fileID: attachment.id) : nil
                )
            }
            guard mayRetryCreate else { throw error }
            return try await beginResumableUpload(attachment)
        }
    }

    private func beginResumableUpload(_ attachment: PendingAttachment) async throws -> ResumableUploadDescriptor {
        var request = authenticatedUploadRequest(
            method: "POST",
            url: url(path: ["v1", "files", "uploads"])
        )
        request.setValue(String(attachment.sizeBytes), forHTTPHeaderField: "Upload-Length")
        request.setValue(attachment.id, forHTTPHeaderField: "X-File-ID")
        request.setValue(
            attachment.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            forHTTPHeaderField: "X-File-Name"
        )
        request.setValue(attachment.mediaType, forHTTPHeaderField: "X-File-Media-Type")
        request.setValue(attachment.sha256, forHTTPHeaderField: "X-Content-SHA256")
        let (data, response) = try await session.data(for: request)
        let http = try checkedHTTPResponse(response, data: data, acceptedStatuses: [200, 201])
        _ = http
        return try JSONDecoder.floweroll.decode(ResumableUploadDescriptor.self, from: data)
    }

    private func resumableUploadState(fileID: String) async throws -> ResumableUploadState? {
        let request = authenticatedUploadRequest(
            method: "HEAD",
            url: url(path: ["v1", "files", "uploads", fileID])
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 { return nil }
        _ = try checkedHTTPResponse(response, data: data, acceptedStatuses: [204])
        guard let rawOffset = http.value(forHTTPHeaderField: "Upload-Offset"),
              let offset = Int(rawOffset)
        else { throw URLError(.badServerResponse) }
        let totalBytes = http.value(forHTTPHeaderField: "Upload-Length").flatMap(Int.init)
        let complete = http.value(forHTTPHeaderField: "Upload-Complete") == "?1"
        return ResumableUploadState(offset: offset, totalBytes: totalBytes, complete: complete)
    }

    private func patchResumableUpload(
        fileID: String,
        offset: Int,
        chunk: Data,
        complete: Bool
    ) async throws -> Int {
        var request = authenticatedUploadRequest(
            method: "PATCH",
            url: url(path: ["v1", "files", "uploads", fileID])
        )
        request.httpBody = chunk
        request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        request.setValue(complete ? "?1" : "?0", forHTTPHeaderField: "Upload-Complete")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 409,
           let rawOffset = http.value(forHTTPHeaderField: "Upload-Offset"),
           let serverOffset = Int(rawOffset) {
            return serverOffset
        }
        _ = try checkedHTTPResponse(response, data: data, acceptedStatuses: [204])
        guard let rawOffset = http.value(forHTTPHeaderField: "Upload-Offset"),
              let serverOffset = Int(rawOffset)
        else { throw URLError(.badServerResponse) }
        return serverOffset
    }

    private func authenticatedUploadRequest(method: String, url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func checkedHTTPResponse(
        _ response: URLResponse,
        data: Data,
        acceptedStatuses: Set<Int>
    ) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard acceptedStatuses.contains(http.statusCode) else {
            if let problem = try? JSONDecoder.floweroll.decode(HostProblem.self, from: data) {
                throw problem
            }
            throw URLError(.badServerResponse)
        }
        return http
    }

    private func verifyUploadedAttachment(
        _ file: TaskMaterialFile,
        expected attachment: PendingAttachment,
        onEvent: (@Sendable (AttachmentUploadEvent) -> Void)?
    ) throws -> TaskMaterialFile {
        guard file.id == attachment.id,
              file.sha256 == attachment.sha256,
              file.sizeBytes == attachment.sizeBytes,
              file.mediaType == attachment.mediaType,
              file.category == "input"
        else {
            throw MaterialsError.message("服务器上的附件记录与本地文件不一致，为避免覆盖已停止重试。")
        }
        onEvent?(.init(attachmentID: attachment.id, state: .uploaded))
        return file
    }

    private static func attachmentProductMessage(for error: Error) -> String {
        if let material = error as? MaterialsError, let text = material.errorDescription { return text }
        if let problem = error as? HostProblem { return problem.detail ?? problem.title ?? problem.code ?? "附件请求失败。" }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "当前没有网络，附件和发送内容已保留。"
            case .timedOut:
                return "连接超时，已保留附件并尝试核对服务器状态。"
            case .networkConnectionLost:
                return "网络连接中断，附件和发送内容已安全保留。"
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return "暂时连不上花卷 Host，发送内容已保留。"
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .clientCertificateRejected,
                 .clientCertificateRequired:
                return "安全连接失败，请检查网络或 Host 证书后重试。"
            default:
                return "网络传输没有完成，附件和发送内容已保留。"
            }
        }
        return "附件发送没有完成，已保留本地内容，请重试。"
    }

    func fetchTaskMaterials(taskID: String) async throws -> TaskMaterialManifest {
        let result = try await request(method: "GET", path: ["v1", "tasks", taskID, "materials"])
        return try JSONDecoder.floweroll.decode(TaskMaterialManifest.self, from: result.data)
    }

    func downloadTaskFile(taskID: String, file: TaskMaterialFile) async throws -> URL {
        guard file.sizeBytes > 0, file.sizeBytes <= 64 * 1024 * 1024,
              taskID.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil,
              file.id.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else {
            throw URLError(.badServerResponse)
        }

        let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent("TaskResultFiles/" + taskID + "/" + file.id, isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let name = file.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        let destination = cache.appendingPathComponent(name == "." || name == ".." || name.isEmpty ? "结果" : name)

        if (try? Self.isVerifiedTaskFile(destination, expected: file)) == true {
            return destination
        }

        let result = try await request(method: "GET", path: ["v1", "tasks", taskID, "files", file.id])
        guard result.data.count == file.sizeBytes,
              SHA256.hash(data: result.data).map({ String(format: "%02x", $0) }).joined() == file.sha256.lowercased() else {
            throw MaterialsError.message("文件下载不完整，请重新预览。")
        }
        try result.data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return destination
    }

    private static func isVerifiedTaskFile(_ url: URL, expected file: TaskMaterialFile) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.fileSize == file.sizeBytes else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == file.sha256.lowercased()
    }

    func fetchTaskIndex(
        bucket: String,
        cursor: String? = nil,
        limit: Int = 20,
        threadID: String? = nil
    ) async throws -> HostTaskIndexPage {
        var components = URLComponents(
            url: url(path: ["v1", "tasks"]),
            resolvingAgainstBaseURL: false
        )!
        var items = [
            URLQueryItem(name: "bucket", value: bucket),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let cursor {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        if let threadID, !threadID.isEmpty {
            items.append(URLQueryItem(name: "thread_id", value: threadID))
        }
        components.queryItems = items
        let result = try await request(method: "GET", absoluteURL: components.url!)
        return try JSONDecoder.floweroll.decode(HostTaskIndexPage.self, from: result.data)
    }

    func fetchTaskView(taskID: String) async throws -> HostTaskView {
        let result = try await request(
            method: "GET",
            path: ["v1", "tasks", taskID, "view"]
        )
        return try JSONDecoder.floweroll.decode(HostTaskView.self, from: result.data)
    }

    func presentationEvents(
        taskID: String,
        afterSeq: Int
    ) -> AsyncThrowingStream<HostPresentationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try validateEndpointSecurity()
                    var components = URLComponents(
                        url: url(path: ["v1", "tasks", taskID, "stream"]),
                        resolvingAgainstBaseURL: false
                    )!
                    components.queryItems = [
                        URLQueryItem(name: "after_seq", value: String(afterSeq))
                    ]
                    guard let streamURL = components.url else {
                        throw HostClientSecurityError.invalidEndpoint
                    }
                    var request = URLRequest(url: streamURL)
                    request.httpMethod = "GET"
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if let bearerToken, !bearerToken.isEmpty {
                        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
                    }

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }
                    guard (200 ... 299).contains(http.statusCode) else {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                        }
                        if let problem = try? JSONDecoder.floweroll.decode(HostProblem.self, from: data) {
                            throw problem
                        }
                        throw URLError(.badServerResponse)
                    }

                    var eventID: Int?
                    var eventType: String?
                    var dataLines: [String] = []

                    func emitFrame() throws {
                        guard !dataLines.isEmpty else {
                            eventID = nil
                            eventType = nil
                            return
                        }
                        defer {
                            eventID = nil
                            eventType = nil
                            dataLines.removeAll(keepingCapacity: true)
                        }
                        guard eventType == nil || eventType == "presentation" else {
                            return
                        }
                        let data = Data(dataLines.joined(separator: "\n").utf8)
                        let event = try JSONDecoder.floweroll.decode(HostPresentationEvent.self, from: data)
                        if let eventID, eventID != event.seq {
                            throw URLError(.cannotParseResponse)
                        }
                        continuation.yield(event)
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if line.isEmpty {
                            try emitFrame()
                            continue
                        }
                        if line.hasPrefix(":") {
                            continue
                        }
                        if line.hasPrefix("id:") {
                            // Foundation's AsyncLineSequence does not reliably
                            // surface the blank separator on every platform. A
                            // new SSE `id:` therefore also terminates any
                            // previously accumulated frame.
                            if !dataLines.isEmpty {
                                try emitFrame()
                            }
                            let raw = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                            guard let value = Int(raw) else {
                                throw URLError(.cannotParseResponse)
                            }
                            eventID = value
                        } else if line.hasPrefix("event:") {
                            eventType = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            dataLines.append(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
                            // Floweroll Host deliberately emits exactly one JSON
                            // `data:` line per PresentationEvent. Foundation's
                            // AsyncLineSequence can delay or omit the trailing
                            // blank SSE separator on a live connection; waiting
                            // for that separator (or the next `id:`) leaves the
                            // newest event buffered indefinitely. Emit as soon as
                            // the contract's single data line arrives so an
                            // ACTIVE tool event can wake device execution now.
                            try emitFrame()
                        }
                    }
                    try emitFrame()
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func fetchNextAction(
        taskID: String,
        waitSeconds: Int = 0
    ) async throws -> DeviceActionDispatch? {
        var components = URLComponents(
            url: url(path: ["v1", "tasks", taskID, "next-device-action"]),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "supports_reconciliation", value: "true")]
        if waitSeconds > 0 {
            components.queryItems?.append(URLQueryItem(name: "wait_seconds", value: String(min(20, waitSeconds))))
        }
        guard let requestURL = components.url else {
            throw HostClientSecurityError.invalidEndpoint
        }
        let result = try await request(
            method: "GET",
            absoluteURL: requestURL,
            acceptedStatuses: [200, 204]
        )
        if result.status == 204 {
            return nil
        }
        return try JSONDecoder.floweroll.decode(DeviceActionDispatch.self, from: result.data)
    }

    @discardableResult
    func submitActionResult(
        taskID: String,
        actionID: String,
        attemptID: String,
        success: Bool,
        output: [String: JSONValue],
        error: String? = nil
    ) async throws -> JSONValue {
        let body = ActionResultBody(
            attemptID: attemptID,
            success: success,
            output: output,
            error: error
        )
        let result = try await request(
            method: "POST",
            path: ["v1", "tasks", taskID, "actions", actionID, "result"],
            body: try JSONEncoder.floweroll.encode(body)
        )
        return try JSONDecoder.floweroll.decode(JSONValue.self, from: result.data)
    }

    @discardableResult
    func sendUserTurnDurably(
        taskID: String,
        text: String,
        attachments: [PendingAttachment] = [],
        eventID: String = UUID().uuidString,
        pendingStore: PendingSubmissionStore,
        onAttachmentEvent: (@Sendable (AttachmentUploadEvent) -> Void)? = nil
    ) async throws -> JSONValue {
        let pending = try await pendingStore.createUserTurn(
            taskID: taskID,
            text: text,
            attachments: attachments,
            eventID: eventID
        )
        return try await submitExistingUserTurn(
            pending,
            pendingStore: pendingStore,
            onAttachmentEvent: onAttachmentEvent
        )
    }

    @discardableResult
    func submitExistingUserTurn(
        _ pending: PendingUserTurn,
        pendingStore: PendingSubmissionStore,
        onAttachmentEvent: (@Sendable (AttachmentUploadEvent) -> Void)? = nil
    ) async throws -> JSONValue {
        try Task.checkCancellation()
        guard await pendingStore.canReplayUserTurn(eventID: pending.eventID) else {
            throw CancellationError()
        }
        try await pendingStore.markUserTurnAttempting(eventID: pending.eventID)
        do {
            var firstAttachmentError: Error?
            for attachment in pending.attachments ?? [] {
                do {
                    _ = try await uploadTaskAttachment(attachment, onEvent: onAttachmentEvent)
                } catch {
                    firstAttachmentError = firstAttachmentError ?? error
                    onAttachmentEvent?(.init(
                        attachmentID: attachment.id,
                        state: .failed(Self.attachmentProductMessage(for: error))
                    ))
                }
            }
            if let firstAttachmentError { throw firstAttachmentError }
            try Task.checkCancellation()
            guard await pendingStore.canReplayUserTurn(eventID: pending.eventID) else {
                throw CancellationError()
            }
            let result = try await postUserTurn(
                taskID: pending.taskID,
                text: pending.text,
                attachments: pending.attachments ?? [],
                eventID: pending.eventID
            )
            try await pendingStore.markUserTurnAccepted(eventID: pending.eventID)
            return result
        } catch {
            try? await pendingStore.markUserTurnFailed(
                eventID: pending.eventID,
                message: Self.attachmentProductMessage(for: error)
            )
            throw error
        }
    }

    @discardableResult
    func sendUserTurn(
        taskID: String,
        text: String,
        attachments: [PendingAttachment] = [],
        eventID: String = UUID().uuidString,
        onAttachmentEvent: (@Sendable (AttachmentUploadEvent) -> Void)? = nil
    ) async throws -> JSONValue {
        var firstAttachmentError: Error?
        for attachment in attachments {
            do {
                _ = try await uploadTaskAttachment(attachment, onEvent: onAttachmentEvent)
            } catch {
                firstAttachmentError = firstAttachmentError ?? error
                onAttachmentEvent?(.init(
                    attachmentID: attachment.id,
                    state: .failed(Self.attachmentProductMessage(for: error))
                ))
            }
        }
        if let firstAttachmentError { throw firstAttachmentError }
        return try await postUserTurn(
            taskID: taskID,
            text: text,
            attachments: attachments,
            eventID: eventID
        )
    }

    private func postUserTurn(
        taskID: String,
        text: String,
        attachments: [PendingAttachment],
        eventID: String
    ) async throws -> JSONValue {
        let body = UserTurnBody(
            eventID: eventID,
            content: .init(kind: "text", text: text, attachmentIDs: attachments.isEmpty ? nil : attachments.map(\.id))
        )
        let result = try await request(
            method: "POST",
            path: ["v1", "tasks", taskID, "turns"],
            body: try JSONEncoder.floweroll.encode(body),
            acceptedStatuses: [202]
        )
        return try JSONDecoder.floweroll.decode(JSONValue.self, from: result.data)
    }

    @discardableResult
    func respondToClarification(
        taskID: String,
        clarificationID: String,
        optionID: String? = nil,
        text: String? = nil,
        eventID: String = UUID().uuidString
    ) async throws -> JSONValue {
        let body = ClarificationResponseBody(
            eventID: eventID,
            response: .init(optionID: optionID, text: text)
        )
        let result = try await request(
            method: "POST",
            path: ["v1", "tasks", taskID, "clarifications", clarificationID, "responses"],
            body: try JSONEncoder.floweroll.encode(body),
            acceptedStatuses: [202]
        )
        return try JSONDecoder.floweroll.decode(JSONValue.self, from: result.data)
    }

    @discardableResult
    func respondToActionInput(
        taskID: String,
        inputRequestID: String,
        bindingDigest: String,
        response: [String: JSONValue],
        eventID: String = UUID().uuidString
    ) async throws -> JSONValue {
        let body = ActionInputResponseBody(
            eventID: eventID,
            bindingDigest: bindingDigest,
            response: response
        )
        let result = try await request(
            method: "POST",
            path: ["v1", "tasks", taskID, "action-inputs", inputRequestID, "responses"],
            body: try JSONEncoder.floweroll.encode(body),
            acceptedStatuses: [202]
        )
        return try JSONDecoder.floweroll.decode(JSONValue.self, from: result.data)
    }

    func fetchArtifact(taskID: String, artifactID: String) async throws -> HostArtifact {
        let result = try await request(
            method: "GET",
            path: ["v1", "tasks", taskID, "artifacts", artifactID]
        )
        return try JSONDecoder.floweroll.decode(HostArtifact.self, from: result.data)
    }

    func editArtifact(
        taskID: String,
        artifactID: String,
        expectedRevisionID: String,
        content: [String: JSONValue],
        eventID: String = UUID().uuidString
    ) async throws -> HostArtifact {
        let body = ArtifactRevisionBody(
            eventID: eventID,
            expectedRevisionID: expectedRevisionID,
            content: content
        )
        let result = try await request(
            method: "POST",
            path: ["v1", "tasks", taskID, "artifacts", artifactID, "revisions"],
            body: try JSONEncoder.floweroll.encode(body),
            acceptedStatuses: [200, 201]
        )
        return try JSONDecoder.floweroll.decode(HostArtifact.self, from: result.data)
    }

    @discardableResult
    func retryTask(taskID: String) async throws -> HostTaskRetryResponse {
        let result = try await request(
            method: "POST",
            path: ["v1", "tasks", taskID, "retry"],
            acceptedStatuses: [202]
        )
        return try JSONDecoder.floweroll.decode(HostTaskRetryResponse.self, from: result.data)
    }

    @discardableResult
    func cancelTask(
        taskID: String,
        eventID: String,
        reason: String? = nil
    ) async throws -> HostTaskCancellationResponse {
        let body = CancelBody(eventID: eventID, reason: reason)
        let result = try await request(
            method: "POST",
            path: ["v1", "tasks", taskID, "cancel"],
            body: try JSONEncoder.floweroll.encode(body),
            acceptedStatuses: [202]
        )
        return try JSONDecoder.floweroll.decode(HostTaskCancellationResponse.self, from: result.data)
    }

    private func url(path: [String]) -> URL {
        path.reduce(baseURL) { partial, component in
            partial.appendingPathComponent(component)
        }
    }

    private func request(
        method: String,
        path: [String],
        body: Data? = nil,
        acceptedStatuses: Set<Int> = Set(200 ... 299),
        headers: [String: String] = [:]
    ) async throws -> (data: Data, status: Int) {
        try await request(
            method: method,
            absoluteURL: url(path: path),
            body: body,
            acceptedStatuses: acceptedStatuses,
            headers: headers
        )
    }

    private func request(
        method: String,
        absoluteURL: URL,
        body: Data? = nil,
        acceptedStatuses: Set<Int> = Set(200 ... 299),
        headers: [String: String] = [:]
    ) async throws -> (data: Data, status: Int) {
        try validateEndpointSecurity()
        var request = URLRequest(url: absoluteURL)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard acceptedStatuses.contains(http.statusCode) else {
            if let problem = try? JSONDecoder.floweroll.decode(HostProblem.self, from: data) {
                throw problem
            }
            throw URLError(.badServerResponse)
        }
        return (data, http.statusCode)
    }
}
