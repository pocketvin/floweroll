@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import PDFKit
import PhotosUI
import SwiftUI
import UIKit
import XCTest
@testable import Floweroll


private final class MaterialMockState: @unchecked Sendable {
    private let lock = NSLock()
    var beginCount = 0
    var headCount = 0
    var patchCount = 0
    var getCount = 0
    var hostHasFile = false
    var hostOffset = 0
    var failPatchesRemaining = 0
    var persistBeforeFailure = false
    var permanentlyFailFileIDs = Set<String>()
    var acceptedSubmissionIDs: [String] = []
    var taskPostCount = 0
    var submissionReadbackCount = 0
    var cancelCount = 0
    var taskPersisted = false
    var failTaskPostsRemaining = 0
    var persistTaskBeforeFailure = false

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}


private final class MaterialUploadEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AttachmentUploadEvent] = []

    func append(_ event: AttachmentUploadEvent) {
        lock.lock(); values.append(event); lock.unlock()
    }

    func snapshot() -> [AttachmentUploadEvent] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}


private struct MaterialMockResponse {
    let status: Int
    let data: Data
    let headers: [String: String]

    init(_ status: Int, _ data: Data = Data(), headers: [String: String] = [:]) {
        self.status = status
        self.data = data
        self.headers = headers
    }
}


private final class MaterialURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> MaterialMockResponse)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.resourceUnavailable) }
            let result = try handler(request)
            var headers = ["Content-Type": "application/json"]
            result.headers.forEach { headers[$0.key] = $0.value }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: result.status, httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !result.data.isEmpty { client?.urlProtocol(self, didLoad: result.data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}


final class MaterialAttachmentStabilityTests: XCTestCase {
    override func tearDown() {
        MaterialURLProtocol.handler = nil
        super.tearDown()
    }

    @MainActor
    func testAdmittedHomeSubmissionReadbackUsesExactDurableIdentity() async throws {
        let suiteName = "MaterialAttachmentStabilityTests.admitted-home.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)
        MaterialURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/submissions/submission-admitted/task")
            return MaterialMockResponse(
                200,
                try Self.taskJSON(
                    submissionID: "submission-admitted",
                    taskID: "task-admitted",
                    threadID: "thread-admitted"
                )
            )
        }
        let store = RuntimeTaskStore(
            defaults: defaults,
            session: makeSession(),
            pendingStore: nil,
            deviceWorker: nil
        )
        let task = await store.admittedTaskForSubmissionID("submission-admitted")
        XCTAssertEqual(task?.taskID, "task-admitted")
        XCTAssertEqual(task?.submissionID, "submission-admitted")
    }

    @MainActor
    func testPendingHomeSubmissionIdentityReusesOldestExactDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try PendingSubmissionStore(directoryURL: directory)
        let attachment = PendingAttachment(
            id: "same-file", name: "资料.docx", mediaType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            sizeBytes: 10, sha256: String(repeating: "a", count: 64), storedName: "same-file.docx"
        )
        _ = try await journal.create(
            text: "同一草稿", invocationSource: "ios_home_in_app", attachments: [attachment],
            submissionID: "submission-old", createdAt: Date(timeIntervalSince1970: 10)
        )
        _ = try await journal.create(
            text: "同一草稿", invocationSource: "ios_home_in_app", attachments: [attachment],
            submissionID: "submission-new", createdAt: Date(timeIntervalSince1970: 20)
        )
        let suiteName = "MaterialAttachmentStabilityTests.pending-home.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RuntimeTaskStore(defaults: defaults, pendingStore: journal, deviceWorker: nil)
        let restored = await store.pendingHomeSubmission(matching: "同一草稿", attachments: [attachment])
        XCTAssertEqual(restored?.submissionID, "submission-old")
    }

    func testSiblingTaskSenderCanConvergeAfterAcknowledgementWithoutFalseCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try PendingSubmissionStore(directoryURL: directory)
        let pending = try await journal.create(text: "同一次发送", invocationSource: "test", submissionID: "same-send")
        MaterialURLProtocol.handler = { request in
            let payload = try JSONSerialization.jsonObject(with: Self.requestBody(request)) as! [String: Any]
            XCTAssertEqual(payload["submission_id"] as? String, "same-send")
            return MaterialMockResponse(201, try Self.taskJSON(submissionID: "same-send"))
        }
        let client = FlowerollHostClient(baseURL: URL(string: "http://localhost")!, session: makeSession())
        let first = try await client.submitExisting(pending, pendingStore: journal)
        let sibling = try await client.submitExisting(pending, pendingStore: journal)
        XCTAssertEqual(first.taskID, sibling.taskID)
        XCTAssertEqual(first.submissionID, sibling.submissionID)
        let remaining = await journal.pending()
        XCTAssertTrue(remaining.isEmpty)

        // An explicit later stop revokes even an acknowledged replay identity.
        _ = try await journal.discard(submissionID: pending.submissionID)
        MaterialURLProtocol.handler = { _ in
            XCTFail("Discard must win over a prior acknowledgement")
            return MaterialMockResponse(503)
        }
        do {
            _ = try await client.submitExisting(pending, pendingStore: journal)
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testSiblingUserTurnSenderCanConvergeAfterAcknowledgementWithoutFalseCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try PendingSubmissionStore(directoryURL: directory)
        let pending = try await journal.createUserTurn(taskID: "task", text: "同一次补充", eventID: "same-turn")
        MaterialURLProtocol.handler = { request in
            let payload = try JSONSerialization.jsonObject(with: Self.requestBody(request)) as! [String: Any]
            XCTAssertEqual(payload["event_id"] as? String, "same-turn")
            return MaterialMockResponse(202, Data("{}".utf8))
        }
        let client = FlowerollHostClient(baseURL: URL(string: "http://localhost")!, session: makeSession())
        _ = try await client.submitExistingUserTurn(pending, pendingStore: journal)
        _ = try await client.submitExistingUserTurn(pending, pendingStore: journal)
        let remaining = await journal.pendingUserTurns()
        XCTAssertTrue(remaining.isEmpty)
        _ = try await journal.discardUserTurn(eventID: pending.eventID)
        let replayAllowed = await journal.canReplayUserTurn(eventID: pending.eventID)
        XCTAssertFalse(replayAllowed)
    }

    func testDiscardedSubmissionSnapshotCannotBeReplayedByRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try PendingSubmissionStore(directoryURL: directory)
        let stale = try await journal.create(text: "已取消", invocationSource: "test", submissionID: "discarded")
        _ = try await journal.discard(submissionID: stale.submissionID)
        MaterialURLProtocol.handler = { _ in
            XCTFail("Discarded submission must never reach the network")
            return MaterialMockResponse(503)
        }
        let client = FlowerollHostClient(baseURL: URL(string: "http://localhost")!, session: makeSession())
        do {
            _ = try await client.submitExisting(stale, pendingStore: journal)
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let reopened = try PendingSubmissionStore(directoryURL: directory)
        let pending = await reopened.pending()
        XCTAssertTrue(pending.isEmpty)
    }

    func testDiscardedUserTurnSnapshotCannotBeReplayedByRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try PendingSubmissionStore(directoryURL: directory)
        let stale = try await journal.createUserTurn(taskID: "task", text: "已取消补充", eventID: "discarded-turn")
        _ = try await journal.discardUserTurn(eventID: stale.eventID)
        MaterialURLProtocol.handler = { _ in
            XCTFail("Discarded user turn must never reach the network")
            return MaterialMockResponse(503)
        }
        let client = FlowerollHostClient(baseURL: URL(string: "http://localhost")!, session: makeSession())
        do {
            _ = try await client.submitExistingUserTurn(stale, pendingStore: journal)
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let reopened = try PendingSubmissionStore(directoryURL: directory)
        let pending = await reopened.pendingUserTurns()
        XCTAssertTrue(pending.isEmpty)
    }

    func testUserTurnTransportFailurePreservesExactEventForRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try PendingSubmissionStore(directoryURL: directory)
        let stale = try await journal.createUserTurn(taskID: "task", text: "补充资料", eventID: "same-event")
        MaterialURLProtocol.handler = { _ in throw URLError(.networkConnectionLost) }
        let client = FlowerollHostClient(baseURL: URL(string: "http://localhost")!, session: makeSession())
        do {
            _ = try await client.submitExistingUserTurn(stale, pendingStore: journal)
            XCTFail("Expected transport failure")
        } catch {}
        let reopened = try PendingSubmissionStore(directoryURL: directory)
        let pending = await reopened.pendingUserTurns()
        XCTAssertEqual(pending.map(\.eventID), ["same-event"])
        MaterialURLProtocol.handler = { request in
            let payload = try JSONSerialization.jsonObject(with: Self.requestBody(request)) as! [String: Any]
            XCTAssertEqual(payload["event_id"] as? String, "same-event")
            return MaterialMockResponse(202, Data("{}".utf8))
        }
        _ = try await client.submitExistingUserTurn(try XCTUnwrap(pending.first), pendingStore: reopened)
        let remaining = await reopened.pendingUserTurns()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAckLostButHostHasFileUsesReadbackWithoutRetransmit() async throws {
        let attachment = try makeAttachment(id: "ack-lost-file", bytes: Data("ack lost fixture".utf8))
        defer { try? FileManager.default.removeItem(at: try attachment.fileURL()) }
        let state = MaterialMockState()
        state.failPatchesRemaining = 1
        state.persistBeforeFailure = true
        let session = makeSession()
        MaterialURLProtocol.handler = { request in
            try Self.handleFileRequest(request, attachment: attachment, state: state)
        }
        let client = FlowerollHostClient(baseURL: URL(string: "http://localhost")!, session: session)

        let receipt = try await client.uploadTaskAttachment(attachment)

        XCTAssertEqual(receipt.id, attachment.id)
        XCTAssertEqual(state.withLock { state.patchCount }, 1, "ACK loss must reconcile Host offset, not retransmit the committed chunk")
        XCTAssertGreaterThanOrEqual(state.withLock { state.headCount }, 2)
        XCTAssertGreaterThanOrEqual(state.withLock { state.getCount }, 2)
    }

    func testHostExplicitlyMissingAfterTransportLossRetransmitsExactlyOnce() async throws {
        let attachment = try makeAttachment(id: "missing-retry-file", bytes: Data("retry fixture".utf8))
        defer { try? FileManager.default.removeItem(at: try attachment.fileURL()) }
        let state = MaterialMockState()
        state.failPatchesRemaining = 1
        state.persistBeforeFailure = false
        let session = makeSession()
        MaterialURLProtocol.handler = { request in
            try Self.handleFileRequest(request, attachment: attachment, state: state)
        }
        let client = FlowerollHostClient(baseURL: URL(string: "http://localhost")!, session: session)

        let receipt = try await client.uploadTaskAttachment(attachment)

        XCTAssertEqual(receipt.sha256, attachment.sha256)
        XCTAssertEqual(state.withLock { state.patchCount }, 2, "an uncommitted chunk is retried only after HEAD confirms the old offset")
        XCTAssertGreaterThanOrEqual(state.withLock { state.headCount }, 2)
    }

    @MainActor
    func testDraftPreuploadStartsBeforeSendAndDurableSubmitReusesExactHostFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("draft-preupload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pendingStore = try PendingSubmissionStore(directoryURL: directory)
        let attachment = try makeAttachment(
            id: "draft-preupload-file",
            bytes: Data(repeating: 0x51, count: 96 * 1024)
        )
        defer { try? FileManager.default.removeItem(at: try attachment.fileURL()) }
        let state = MaterialMockState()
        MaterialURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasPrefix("/v1/files/") || path == "/v1/files/uploads" {
                return try Self.handleFileRequest(request, attachment: attachment, state: state)
            }
            if request.httpMethod == "POST", path == "/v1/tasks" {
                let body = try Self.requestBody(request)
                let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                let submissionID = json["submission_id"] as! String
                return try state.withLock {
                    state.taskPostCount += 1
                    state.acceptedSubmissionIDs.append(submissionID)
                    return MaterialMockResponse(201, try Self.taskJSON(submissionID: submissionID))
                }
            }
            return MaterialMockResponse(404, Data("{}".utf8))
        }
        let suite = "MaterialAttachmentStabilityTests.preupload.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)
        let store = RuntimeTaskStore(
            defaults: defaults,
            session: makeSession(),
            pendingStore: pendingStore,
            deviceWorker: nil
        )

        store.preuploadAttachment(attachment)
        for _ in 0..<300 {
            if store.attachmentUploadStates[attachment.id] == .uploaded { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(store.attachmentUploadStates[attachment.id], .uploaded)
        let preSendPatchCount = state.withLock { state.patchCount }
        XCTAssertGreaterThan(preSendPatchCount, 0, "draft bytes must upload before Send")
        XCTAssertEqual(state.withLock { state.taskPostCount }, 0, "pre-upload must not create a Task")

        let task = try await store.makeClient().submitDurably(
            text: "发送已经预上传的照片",
            invocationSource: "test",
            attachments: [attachment],
            submissionID: "draft-preupload-submission",
            pendingStore: pendingStore
        )

        XCTAssertEqual(task.submissionID, "draft-preupload-submission")
        XCTAssertEqual(state.withLock { state.taskPostCount }, 1)
        XCTAssertEqual(
            state.withLock { state.patchCount },
            preSendPatchCount,
            "Send must bind/reuse the exact uploaded file instead of retransmitting bytes"
        )
        XCTAssertGreaterThanOrEqual(state.withLock { state.getCount }, 2)
    }

    @MainActor
    func testCancelledNewSubmissionWithoutHostAdmissionIsDiscardedAndCannotReplay() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancel-before-admission-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pendingStore = try PendingSubmissionStore(directoryURL: directory)
        _ = try await pendingStore.create(
            text: "不要真的发送", invocationSource: "ios_new_task", submissionID: "cancel-before-admission"
        )
        MaterialURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "GET", path == "/v1/submissions/cancel-before-admission/task" {
                let data = try Data(contentsOf: directory.appendingPathComponent("pending-submissions.json"))
                let snapshot = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                XCTAssertEqual((snapshot["submissions"] as? [[String: Any]])?.count, 0,
                               "Cancellation must remove replay eligibility before Host readback")
                return MaterialMockResponse(404, Data("{}".utf8))
            }
            return MaterialMockResponse(404, Data("{}".utf8))
        }
        let suite = "MaterialAttachmentStabilityTests.cancel-before.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)
        let store = RuntimeTaskStore(
            defaults: defaults, session: makeSession(), pendingStore: pendingStore, deviceWorker: nil
        )

        let outcome = await store.reconcileCancelledSubmission(submissionID: "cancel-before-admission")

        XCTAssertEqual(outcome, .stoppedBeforeAdmission)
        let pendingAfterCancel = await pendingStore.pending()
        XCTAssertTrue(pendingAfterCancel.isEmpty)
        let reopened = try PendingSubmissionStore(directoryURL: directory)
        let pendingAfterReopen = await reopened.pending()
        XCTAssertTrue(pendingAfterReopen.isEmpty, "cancelled send must not revive after App relaunch")
    }

    @MainActor
    func testCancelledNewSubmissionAlreadyAdmittedCancelsExactTaskAndDiscardsOutbox() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancel-after-admission-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pendingStore = try PendingSubmissionStore(directoryURL: directory)
        _ = try await pendingStore.create(
            text: "刚刚发送又取消", invocationSource: "ios_new_task", submissionID: "cancel-after-admission"
        )
        let state = MaterialMockState()
        let cancelResponse = HostTaskCancellationResponse(
            accepted: .bool(true),
            task: .init(
                taskID: "task-cancel-after-admission",
                submissionID: "cancel-after-admission",
                threadID: "thread-cancel-after-admission",
                parentTaskID: nil,
                goal: "刚刚发送又取消",
                status: "cancelled",
                currentStep: 0,
                cancelRequestedAt: "2026-09-13T15:00:01Z",
                cancelReason: "用户取消尚在发送中的新任务",
                cancellationPending: false,
                createdAt: "2026-09-13T15:00:00Z",
                updatedAt: "2026-09-13T15:00:01Z"
            )
        )
        MaterialURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "GET", path == "/v1/submissions/cancel-after-admission/task" {
                return MaterialMockResponse(200, try Self.taskJSON(
                    submissionID: "cancel-after-admission",
                    taskID: "task-cancel-after-admission",
                    threadID: "thread-cancel-after-admission"
                ))
            }
            if request.httpMethod == "POST", path == "/v1/tasks/task-cancel-after-admission/cancel" {
                return try state.withLock {
                    state.cancelCount += 1
                    return MaterialMockResponse(202, try JSONEncoder.floweroll.encode(cancelResponse))
                }
            }
            if request.httpMethod == "GET", path == "/v1/tasks/task-cancel-after-admission/view" {
                return MaterialMockResponse(503, Data(#"{"code":"TEMPORARY_READBACK_FAILURE"}"#.utf8))
            }
            if request.httpMethod == "GET", path == "/v1/tasks" {
                return MaterialMockResponse(200, try JSONEncoder.floweroll.encode(
                    HostTaskIndexPage(items: [], nextCursor: nil)
                ))
            }
            return MaterialMockResponse(404, Data("{}".utf8))
        }
        let suite = "MaterialAttachmentStabilityTests.cancel-after.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)
        let store = RuntimeTaskStore(
            defaults: defaults, session: makeSession(), pendingStore: pendingStore, deviceWorker: nil
        )

        let outcome = await store.reconcileCancelledSubmission(submissionID: "cancel-after-admission")

        guard case let .cancelledAdmittedTask(cancellation) = outcome else {
            return XCTFail("expected exact admitted Task cancellation, got \(outcome)")
        }
        XCTAssertEqual(cancellation.taskID, "task-cancel-after-admission")
        XCTAssertEqual(cancellation.status, "cancelled")
        XCTAssertFalse(cancellation.cancellationPending)
        XCTAssertEqual(state.withLock { state.cancelCount }, 1)
        XCTAssertEqual(state.withLock { state.taskPostCount }, 0, "cancel reconciliation must never create another Task")
        let pendingAfterCancel = await pendingStore.pending()
        XCTAssertTrue(pendingAfterCancel.isEmpty)
    }

    func testSubmissionAckLostUsesSubmissionReadbackWithoutDuplicateTaskPost() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("submission-ack-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pendingStore = try PendingSubmissionStore(directoryURL: directory)
        let state = MaterialMockState()
        state.failTaskPostsRemaining = 1
        state.persistTaskBeforeFailure = true
        MaterialURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path == "/v1/tasks" {
                let body = try Self.requestBody(request)
                let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                let sid = json["submission_id"] as! String
                return try state.withLock {
                    state.taskPostCount += 1
                    if state.failTaskPostsRemaining > 0 {
                        state.failTaskPostsRemaining -= 1
                        if state.persistTaskBeforeFailure { state.taskPersisted = true }
                        throw URLError(.networkConnectionLost)
                    }
                    state.taskPersisted = true
                    return MaterialMockResponse(201, try Self.taskJSON(submissionID: sid))
                }
            }
            if request.httpMethod == "GET", path == "/v1/submissions/submission-ack/task" {
                return state.withLock {
                    state.submissionReadbackCount += 1
                    guard state.taskPersisted else { return MaterialMockResponse(404) }
                    return MaterialMockResponse(200, try! Self.taskJSON(submissionID: "submission-ack"))
                }
            }
            return MaterialMockResponse(404)
        }
        let client = FlowerollHostClient(baseURL: URL(string: "http://localhost")!, session: makeSession())

        let task = try await client.submitDurably(
            text: "识别照片", invocationSource: "test", submissionID: "submission-ack",
            pendingStore: pendingStore
        )

        XCTAssertEqual(task.submissionID, "submission-ack")
        XCTAssertEqual(state.withLock { state.taskPostCount }, 1)
        XCTAssertGreaterThanOrEqual(state.withLock { state.submissionReadbackCount }, 1)
        let remaining = await pendingStore.pending()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSubmissionMissingAfterFirstTransportLossRetriesSameIDOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("submission-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pendingStore = try PendingSubmissionStore(directoryURL: directory)
        let state = MaterialMockState()
        state.failTaskPostsRemaining = 1
        MaterialURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path == "/v1/tasks" {
                let body = try Self.requestBody(request)
                let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                let sid = json["submission_id"] as! String
                return try state.withLock {
                    state.taskPostCount += 1
                    if state.failTaskPostsRemaining > 0 {
                        state.failTaskPostsRemaining -= 1
                        throw URLError(.networkConnectionLost)
                    }
                    state.taskPersisted = true
                    return MaterialMockResponse(201, try Self.taskJSON(submissionID: sid))
                }
            }
            if request.httpMethod == "GET", path == "/v1/submissions/submission-retry/task" {
                return state.withLock {
                    state.submissionReadbackCount += 1
                    guard state.taskPersisted else { return MaterialMockResponse(404) }
                    return MaterialMockResponse(200, try! Self.taskJSON(submissionID: "submission-retry"))
                }
            }
            return MaterialMockResponse(404)
        }
        let client = FlowerollHostClient(baseURL: URL(string: "http://localhost")!, session: makeSession())

        let task = try await client.submitDurably(
            text: "识别照片", invocationSource: "test", submissionID: "submission-retry",
            pendingStore: pendingStore
        )

        XCTAssertEqual(task.submissionID, "submission-retry")
        XCTAssertEqual(state.withLock { state.taskPostCount }, 2)
        XCTAssertGreaterThanOrEqual(state.withLock { state.submissionReadbackCount }, 1)
        let remaining = await pendingStore.pending()
        XCTAssertTrue(remaining.isEmpty)
    }

    @MainActor
    func testFailedPendingADoesNotBlockIndependentBAndDiscardDoesNotRevive() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-isolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pendingStore = try PendingSubmissionStore(directoryURL: directory)
        let broken = try makeAttachment(id: "pending-a-file", bytes: Data("A bytes".utf8))
        defer { try? FileManager.default.removeItem(at: try broken.fileURL()) }
        _ = try await pendingStore.create(
            text: "A should fail", invocationSource: "test", attachments: [broken], submissionID: "submission-A"
        )
        _ = try await pendingStore.create(
            text: "B should pass", invocationSource: "test", submissionID: "submission-B"
        )

        let state = MaterialMockState()
        state.permanentlyFailFileIDs = [broken.id]
        MaterialURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasPrefix("/v1/files/") || path == "/v1/files" {
                return try Self.handleFileRequest(request, attachment: broken, state: state)
            }
            if path == "/v1/tasks", request.httpMethod == "POST" {
                let body = try Self.requestBody(request)
                let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                let submissionID = json["submission_id"] as! String
                state.withLock { state.acceptedSubmissionIDs.append(submissionID) }
                return MaterialMockResponse(201, try Self.taskJSON(submissionID: submissionID))
            }
            return MaterialMockResponse(200, Data("{\"items\":[],\"next_cursor\":null}".utf8))
        }
        let defaults = UserDefaults(suiteName: "MaterialAttachmentStabilityTests.\(UUID().uuidString)")!
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)
        let store = RuntimeTaskStore(
            defaults: defaults,
            session: makeSession(),
            pendingStore: pendingStore,
            deviceWorker: nil
        )

        await store.retryPendingSubmissions()
        let remaining = await pendingStore.pending()
        XCTAssertEqual(remaining.map(\.submissionID), ["submission-A"])
        XCTAssertNotNil(remaining.first?.lastErrorMessage)
        XCTAssertEqual(state.withLock { state.acceptedSubmissionIDs }, ["submission-B"])

        await store.discardPendingSubmission(submissionID: "submission-A")
        let reloaded = try PendingSubmissionStore(directoryURL: directory)
        let reloadedPending = await reloaded.pending()
        XCTAssertTrue(reloadedPending.isEmpty, "discarded submission must not revive after process restart")
    }

    func testBuild1LegacyPendingJournalIsQuarantinedInsteadOfReplayed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = #"{"submissions":[{"submissionID":"legacy-A","text":"旧发送","invocationSource":"ios_new_task","parentTaskID":null,"createdAt":"2026-09-12T08:00:00Z","attachments":[]}]}"#
        let activeURL = directory.appendingPathComponent("pending-submissions.json")
        try Data(legacy.utf8).write(to: activeURL, options: .atomic)

        let store = try PendingSubmissionStore(directoryURL: directory)
        let pending = await store.pending()

        XCTAssertTrue(pending.isEmpty, "ambiguous Build 1 failures must never auto-replay after upgrade")
        let quarantine = directory.appendingPathComponent("pending-submissions-build1-quarantine.json")
        XCTAssertEqual(try Data(contentsOf: quarantine), Data(legacy.utf8))
        let activeObject = try JSONSerialization.jsonObject(with: Data(contentsOf: activeURL)) as! [String: Any]
        XCTAssertEqual(activeObject["schema"] as? Int, 3)
        XCTAssertEqual((activeObject["submissions"] as? [Any])?.count, 0)
        XCTAssertEqual((activeObject["user_turns"] as? [Any])?.count, 0)
    }

    func testSchema2PendingSurvivesStoreReopenForKillRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-schema2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = #"{"schema":2,"submissions":[{"submissionID":"schema2-A","text":"重启后继续","invocationSource":"ios_new_task","parentTaskID":null,"createdAt":"2026-09-15T08:00:00Z","attachments":[],"attemptCount":0}]}"#
        let activeURL = directory.appendingPathComponent("pending-submissions.json")
        try Data(legacy.utf8).write(to: activeURL, options: .atomic)

        let reopened = try PendingSubmissionStore(directoryURL: directory)
        let pending = await reopened.pending()
        let turns = await reopened.pendingUserTurns()
        XCTAssertEqual(pending.map(\.submissionID), ["schema2-A"])
        XCTAssertEqual(pending.first?.text, "重启后继续")
        XCTAssertTrue(turns.isEmpty)
        let migrated = try JSONSerialization.jsonObject(with: Data(contentsOf: activeURL)) as! [String: Any]
        XCTAssertEqual(migrated["schema"] as? Int, 3)
        XCTAssertEqual((migrated["user_turns"] as? [Any])?.count, 0)
    }

    func testPendingUserTurnSurvivesRestartWithExactEventIdentityAndAttachments() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-user-turn-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let attachment = PendingAttachment(
            id: "turn-file", name: "资料.txt", mediaType: "text/plain", sizeBytes: 12,
            sha256: String(repeating: "a", count: 64), storedName: "turn-file.txt"
        )
        let first = try PendingSubmissionStore(directoryURL: directory)
        _ = try await first.createUserTurn(
            taskID: "task-A", text: "继续处理这个附件", attachments: [attachment], eventID: "event-A"
        )
        try await first.markUserTurnFailed(eventID: "event-A", message: "offline")

        let reopened = try PendingSubmissionStore(directoryURL: directory)
        let pending = await reopened.pendingUserTurns()
        XCTAssertEqual(pending.map(\.eventID), ["event-A"])
        XCTAssertEqual(pending.first?.taskID, "task-A")
        XCTAssertEqual(pending.first?.text, "继续处理这个附件")
        XCTAssertEqual(pending.first?.attachments, [attachment])
        XCTAssertEqual(pending.first?.lastErrorMessage, "offline")
        do {
            _ = try await reopened.createUserTurn(
                taskID: "task-A", text: "不同内容", attachments: [attachment], eventID: "event-A"
            )
            XCTFail("same event_id with different payload must be rejected")
        } catch PendingSubmissionStoreError.duplicateUserTurnID {
            // Expected exact-id immutability.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSendIntentIsPersistedBeforeWaitingForAttachmentTransport() throws {
        let sourceURL = try ProductSourceFiles.iosRoot()
            .appendingPathComponent("Floweroll/App/RuntimeClient/RuntimeTaskStore.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        for signature in [
            "func submit(\n        text: String,",
            "func submitFollowUp(\n        text: String,",
        ] {
            let start = try XCTUnwrap(source.range(of: signature))
            let tail = source[start.lowerBound...]
            let persisted = try XCTUnwrap(tail.range(of: "pendingStore.create("))
            let handoff = try XCTUnwrap(tail.range(of: "beginUserInitiatedOutboxContinuation("))
            let recovery = try XCTUnwrap(tail.range(of: "scheduleRecoveryTask(reason:"))
            let attachmentWait = try XCTUnwrap(tail.range(of: "prepareAttachmentsForSubmission(attachments)"))
            let submitExisting = try XCTUnwrap(tail.range(of: "client.submitExisting("))
            XCTAssertLessThan(persisted.lowerBound, handoff.lowerBound)
            XCTAssertLessThan(handoff.lowerBound, recovery.lowerBound)
            XCTAssertLessThan(recovery.lowerBound, attachmentWait.lowerBound)
            XCTAssertLessThan(attachmentWait.lowerBound, submitExisting.lowerBound)
        }

        let userTurnStart = try XCTUnwrap(source.range(of: "func sendUserTurn(taskID:"))
        let userTurn = source[userTurnStart.lowerBound...]
        let persistedTurn = try XCTUnwrap(userTurn.range(of: "pendingStore.createUserTurn("))
        let handoffTurn = try XCTUnwrap(userTurn.range(of: "beginUserInitiatedOutboxContinuation("))
        let attachmentTurn = try XCTUnwrap(userTurn.range(of: "prepareAttachmentsForSubmission(attachments)"))
        let submitTurn = try XCTUnwrap(userTurn.range(of: "client.submitExistingUserTurn("))
        XCTAssertLessThan(persistedTurn.lowerBound, handoffTurn.lowerBound)
        XCTAssertLessThan(handoffTurn.lowerBound, attachmentTurn.lowerBound)
        XCTAssertLessThan(attachmentTurn.lowerBound, submitTurn.lowerBound)
    }

    @MainActor
    func testRecoveredSubmissionClearsComposerReferenceButKeepsThumbnailBytes() throws {
        let draft = TaskAttachmentDraft()
        let marker = "recovered-draft-\(UUID().uuidString)"
        try draft.add(data: Data(marker.utf8), name: marker + ".txt", mediaType: "text/plain")
        let item = try XCTUnwrap(draft.items.last(where: { $0.name == marker + ".txt" }))
        let localURL = try item.fileURL()
        defer {
            draft.discard([item.id])
            try? FileManager.default.removeItem(at: localURL)
        }

        TaskAttachmentDraft.clearAcceptedReferences([item.id])

        XCTAssertFalse(draft.items.contains(where: { $0.id == item.id }))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: localURL.path),
            "accepted message thumbnail bytes stay local even after composer reference clears"
        )
    }

    func testSameContentCreatesIndependentSubmissionIdentities() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PendingSubmissionStore(directoryURL: directory)
        _ = try await store.create(text: "相同内容", invocationSource: "test", submissionID: "A")
        _ = try await store.create(text: "相同内容", invocationSource: "test", submissionID: "B")
        let pending = await store.pending()
        XCTAssertEqual(Set(pending.map(\.submissionID)), ["A", "B"])
    }

    func testOrdinaryPhotoSessionOnePhotoWaitsForFinishThenDeliversOnce() {
        var session = TaskAttachmentPhotoSession()
        let first = Data("photo-one".utf8)
        var delivered: [Data] = []

        XCTAssertTrue(session.append(first))
        XCTAssertEqual(session.count, 1)
        XCTAssertTrue(delivered.isEmpty, "ordinary capture must not publish into the draft before Done")
        XCTAssertTrue(session.finish { delivered.append($0) })

        XCTAssertEqual(delivered, [first])
        XCTAssertTrue(session.isEmpty)
    }

    func testOrdinaryPhotoSessionThreePhotosFinishInCaptureOrderWithDistinctBytes() {
        var session = TaskAttachmentPhotoSession()
        let captures = [
            Data("photo-one".utf8),
            Data("photo-two".utf8),
            Data("photo-three".utf8),
        ]
        captures.forEach { XCTAssertTrue(session.append($0)) }
        var delivered: [Data] = []

        XCTAssertTrue(session.finish { delivered.append($0) })

        XCTAssertEqual(delivered, captures)
        XCTAssertEqual(Set(delivered).count, 3)
    }

    func testOrdinaryPhotoSessionDeleteLastOnlyRemovesLatestCapture() {
        var session = TaskAttachmentPhotoSession()
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        let third = Data("third".utf8)
        [first, second, third].forEach { XCTAssertTrue(session.append($0)) }

        XCTAssertEqual(session.deleteLast(), third)
        var delivered: [Data] = []
        XCTAssertTrue(session.finish { delivered.append($0) })
        XCTAssertEqual(delivered, [first, second])
    }

    func testOrdinaryPhotoSessionCancelAfterTwoShotsDeliversNothing() {
        var session = TaskAttachmentPhotoSession()
        XCTAssertTrue(session.append(Data("first".utf8)))
        XCTAssertTrue(session.append(Data("second".utf8)))
        var delivered: [Data] = []

        session.cancel()
        XCTAssertFalse(session.finish { delivered.append($0) })

        XCTAssertTrue(session.isEmpty)
        XCTAssertTrue(delivered.isEmpty)
    }

    func testOrdinaryPhotoSessionCannotFinishAtZeroPhotos() {
        var session = TaskAttachmentPhotoSession()
        var callbackCount = 0

        XCTAssertFalse(session.finish { _ in callbackCount += 1 })
        XCTAssertEqual(callbackCount, 0)
    }

    func testOrdinaryPhotoSessionHasBoundedTenPhotoCapacityAndDeleteReopensShutterCapacity() {
        var session = TaskAttachmentPhotoSession()
        XCTAssertEqual(TaskAttachmentPhotoSession.maximumPhotoCount, 10)
        XCTAssertEqual(TaskAttachmentCaptureLimits.maximumPhotoCount, 10)
        XCTAssertEqual(TaskAttachmentCaptureLimits.maximumDocumentPageCount, 10)
        XCTAssertEqual(session.capacity, 10)
        for index in 0..<TaskAttachmentPhotoSession.maximumPhotoCount {
            XCTAssertTrue(session.append(Data("photo-\(index)".utf8)))
        }

        XCTAssertEqual(session.count, 10)
        XCTAssertFalse(session.canCaptureMore)
        XCTAssertFalse(session.append(Data("eleventh".utf8)))
        XCTAssertEqual(session.count, 10)

        XCTAssertNotNil(session.deleteLast())
        XCTAssertTrue(session.canCaptureMore)
        XCTAssertTrue(session.append(Data("replacement".utf8)))
        XCTAssertEqual(session.count, 10)
        var delivered: [Data] = []
        XCTAssertTrue(session.finish { delivered.append($0) })
        XCTAssertEqual(delivered.count, 10)
        XCTAssertEqual(delivered.last, Data("replacement".utf8))
    }

    func testOrdinaryPhotoSessionCustomCapacityBlocksThirdCaptureAndDeleteReopensSlot() {
        var session = TaskAttachmentPhotoSession(maximumPhotoCount: 2)
        XCTAssertEqual(session.capacity, 2)
        XCTAssertTrue(session.append(Data("one".utf8)))
        XCTAssertTrue(session.append(Data("two".utf8)))
        XCTAssertFalse(session.canCaptureMore)
        XCTAssertFalse(session.append(Data("three".utf8)))
        XCTAssertEqual(session.count, 2)

        XCTAssertEqual(session.deleteLast(), Data("two".utf8))
        XCTAssertTrue(session.canCaptureMore)
        XCTAssertTrue(session.append(Data("replacement".utf8)))
        XCTAssertFalse(session.canCaptureMore)
        var delivered: [Data] = []
        XCTAssertTrue(session.finish { delivered.append($0) })
        XCTAssertEqual(delivered, [Data("one".utf8), Data("replacement".utf8)])
    }

    func testOrdinaryPhotoSessionCapacityClampsToGlobalComposerBound() {
        XCTAssertEqual(TaskAttachmentPhotoSession(maximumPhotoCount: 99).capacity, 10)
        XCTAssertEqual(TaskAttachmentPhotoSession(maximumPhotoCount: 0).capacity, 0)
        XCTAssertEqual(TaskAttachmentPhotoSession(maximumPhotoCount: -3).capacity, 0)
    }

    func testOrdinaryPhotoSessionFailedCaptureKeepsEarlierSuccessfulPhotos() {
        var session = TaskAttachmentPhotoSession()
        let first = Data("successful-first".utf8)
        XCTAssertTrue(session.append(first))

        XCTAssertFalse(session.append(nil), "a failed photo callback must not mutate the successful capture buffer")
        XCTAssertEqual(session.count, 1)
        var delivered: [Data] = []
        XCTAssertTrue(session.finish { delivered.append($0) })
        XCTAssertEqual(delivered, [first])
    }

    @MainActor
    func testImageAttachmentProcessorAutomaticallyCompressesCameraPhoto() throws {
        let targetBytes = 120 * 1024
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1_600, height: 1_200))
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_600, height: 1_200))
            for y in stride(from: 0, to: 1_200, by: 8) {
                for x in stride(from: 0, to: 1_600, by: 8) {
                    let seed = (x &* 31) ^ (y &* 17) ^ ((x + y) &* 13)
                    UIColor(
                        red: CGFloat(seed & 0xFF) / 255.0,
                        green: CGFloat((seed >> 3) & 0xFF) / 255.0,
                        blue: CGFloat((seed >> 7) & 0xFF) / 255.0,
                        alpha: 1
                    ).setFill()
                    context.fill(CGRect(x: x, y: y, width: 8, height: 8))
                }
            }
        }
        let source = try XCTUnwrap(image.jpegData(compressionQuality: 1.0))
        XCTAssertGreaterThan(source.count, targetBytes, "fixture must require automatic compression")

        let compressed = try TaskImageAttachmentProcessor.compressedJPEG(
            from: source,
            maxBytes: targetBytes,
            maxPixelDimension: 1_600
        )

        XCTAssertLessThanOrEqual(compressed.count, targetBytes)
        XCTAssertNotNil(UIImage(data: compressed))
    }

    @MainActor
    func testDraftAddImageStoresAutomaticallyCompressedJPEGInsideUploadLimit() throws {
        let draft = TaskAttachmentDraft()
        if !draft.items.isEmpty { draft.clearSubmitted(Set(draft.items.map(\.id))) }
        defer { draft.discard(Set(draft.items.map(\.id))) }

        let image = UIGraphicsImageRenderer(size: CGSize(width: 2_400, height: 1_800)).image { context in
            UIColor(white: 0.94, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2_400, height: 1_800))
            for index in 0..<500 {
                let x = CGFloat((index * 97) % 2_360)
                let y = CGFloat((index * 53) % 1_760)
                UIColor(
                    hue: CGFloat((index * 37) % 255) / 255.0,
                    saturation: 0.9,
                    brightness: 0.85,
                    alpha: 1
                ).setFill()
                context.fill(CGRect(x: x, y: y, width: 40, height: 40))
            }
        }
        let source = try XCTUnwrap(image.jpegData(compressionQuality: 1.0))
        let attachment = try draft.addImage(source, name: "自动压缩")

        XCTAssertEqual(attachment.mediaType, "image/jpeg")
        XCTAssertLessThanOrEqual(attachment.sizeBytes, TaskImageAttachmentProcessor.targetStoredBytes)
        XCTAssertLessThanOrEqual(attachment.sizeBytes, TaskImageAttachmentProcessor.maximumStoredBytes)
        XCTAssertNotNil(UIImage(data: try attachment.verifiedData()))
    }

    @MainActor
    func testDocumentCaptureSheetUsesFlowerollManualCameraController() {
        let sheet = TaskAttachmentCaptureSheet(
            mode: .document,
            photoCapacity: TaskAttachmentDraft.maximumItemCount,
            onPhoto: { _ in },
            onDocumentPDF: { _ in },
            onError: { _ in }
        )

        let controller = sheet.makeProductCaptureViewController()

        XCTAssertTrue(
            controller is TaskAttachmentCaptureViewController,
            "document scanning must stay in Floweroll's Chinese manual shutter UI rather than system auto-scan UI"
        )
        _ = controller.view
        XCTAssertNotNil(
            Self.findSubview(
                in: controller.view,
                accessibilityIdentifier: "attachment.scan.document-guide"
            ),
            "document mode must expose a scan-specific framing guide instead of looking identical to ordinary camera"
        )
        let statusView = Self.findSubview(
            in: controller.view,
            accessibilityIdentifier: "attachment.scan.live-status"
        )
        XCTAssertNotNil(statusView, "document mode must expose a live edge-recognition state")
        XCTAssertEqual(
            (statusView as? UILabel)?.text,
            "把整张纸放进框内",
            "the scanner must start with a stable fixed-guide instruction instead of a moving-corner prompt"
        )
    }

    func testDocumentLiveDetectionRequiresStableHitsAndRejectsJitter() {
        let page = DocumentRectangleCorners(
            topLeft: CGPoint(x: 0.15, y: 0.90),
            topRight: CGPoint(x: 0.85, y: 0.88),
            bottomLeft: CGPoint(x: 0.18, y: 0.12),
            bottomRight: CGPoint(x: 0.82, y: 0.10)
        )
        let shifted = DocumentRectangleCorners(
            topLeft: CGPoint(x: 0.28, y: 0.89),
            topRight: CGPoint(x: 0.95, y: 0.85),
            bottomLeft: CGPoint(x: 0.30, y: 0.13),
            bottomRight: CGPoint(x: 0.92, y: 0.11)
        )
        var state = DocumentLiveDetectionState()

        XCTAssertTrue(page.isPlausibleDocument)
        XCTAssertFalse(page.isGeometricallyClose(to: shifted))
        XCTAssertEqual(state.phase, .searching)
        state.ingest(page)
        XCTAssertEqual(state.phase, .locking)
        state.ingest(page)
        state.ingest(page)
        XCTAssertEqual(state.phase, .locking, "three hits are not enough to present a green lock")
        state.ingest(page)
        XCTAssertEqual(state.phase, .detected)

        state.ingest(nil)
        state.ingest(nil)
        state.ingest(nil)
        XCTAssertEqual(state.phase, .detected, "brief Vision misses must not make the stable green frame flicker")
        state.ingest(page)
        XCTAssertEqual(state.phase, .detected)

        state.ingest(shifted)
        XCTAssertEqual(state.phase, .locking, "a large geometry jump must leave green state instead of following a wandering corner")
        state.ingest(shifted)
        state.ingest(shifted)
        state.ingest(shifted)
        XCTAssertEqual(state.phase, .detected)
    }

    func testDocumentLiveDetectionRejectsSmallOrOffCenterRectangles() {
        let tooSmall = DocumentRectangleCorners(
            topLeft: CGPoint(x: 0.42, y: 0.62),
            topRight: CGPoint(x: 0.60, y: 0.62),
            bottomLeft: CGPoint(x: 0.42, y: 0.40),
            bottomRight: CGPoint(x: 0.60, y: 0.40)
        )
        let offCenter = DocumentRectangleCorners(
            topLeft: CGPoint(x: 0.01, y: 0.92),
            topRight: CGPoint(x: 0.46, y: 0.90),
            bottomLeft: CGPoint(x: 0.01, y: 0.15),
            bottomRight: CGPoint(x: 0.44, y: 0.13)
        )
        var state = DocumentLiveDetectionState()

        XCTAssertFalse(tooSmall.isPlausibleDocument)
        XCTAssertFalse(offCenter.isPlausibleDocument)
        for _ in 0..<6 { state.ingest(tooSmall) }
        XCTAssertEqual(state.phase, .searching)
        for _ in 0..<6 { state.ingest(offCenter) }
        XCTAssertEqual(state.phase, .searching)
    }

    func testDocumentScanUIUsesStableFixedGuideWithoutMovingCornerOverlay() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Floweroll/App/RuntimeClient/TaskAttachmentCapture.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("attachment.scan.document-guide"))
        XCTAssertTrue(source.contains("已识别纸张 · 可拍摄，拍后自动拉直四角"))
        XCTAssertFalse(source.contains("documentCornerLayer"))
        XCTAssertFalse(source.contains("documentOutlineLayer"))
        XCTAssertFalse(source.contains("layerPointConverted"))
    }

    @MainActor
    func testDocumentScanProcessorCapsOnePDFAtTenPages() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let page = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let tenPagePDF = try DocumentScanProcessor.pdfData(
            pages: Array(repeating: page, count: TaskAttachmentCaptureLimits.maximumDocumentPageCount)
        )
        XCTAssertEqual(PDFDocument(data: tenPagePDF)?.pageCount, 10)
        XCTAssertThrowsError(try DocumentScanProcessor.pdfData(pages: Array(repeating: page, count: 11))) { error in
            XCTAssertTrue(error.localizedDescription.contains("最多 10 页"))
        }
    }

    @MainActor
    func testManualScanProcessorProducesEnhancedPageAndMultipagePDF() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1200)).image { context in
            UIColor(white: 0.18, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 900, height: 1200))
            UIColor.white.setFill()
            context.fill(CGRect(x: 90, y: 120, width: 720, height: 940))
            UIColor.black.setStroke()
            let path = UIBezierPath(rect: CGRect(x: 90, y: 120, width: 720, height: 940))
            path.lineWidth = 8
            path.stroke()
        }
        let sourceData = try XCTUnwrap(source.jpegData(compressionQuality: 0.92))
        let result = try DocumentScanProcessor.processPageResult(sourceData)
        XCTAssertTrue(
            result.wasPerspectiveCorrected,
            "the synthetic page has an obvious document rectangle and must exercise auto-crop/perspective correction"
        )
        XCTAssertLessThanOrEqual(result.data.count, DocumentScanProcessor.maximumPageJPEGBytes)
        let pageImage = try XCTUnwrap(UIImage(data: result.data))
        XCTAssertLessThanOrEqual(max(pageImage.size.width, pageImage.size.height), 2_400)
        XCTAssertNotEqual(pageImage.size, source.size, "perspective correction should rebuild the document canvas")
        let pdf = try DocumentScanProcessor.pdfData(pages: [result.data, result.data])
        XCTAssertTrue(pdf.starts(with: Data("%PDF-".utf8)))
        XCTAssertEqual(PDFDocument(data: pdf)?.pageCount, 2)
        XCTAssertLessThanOrEqual(pdf.count, TaskImageAttachmentProcessor.maximumStoredBytes)
    }

    func testURLSessionProgressDelegateReportsRealByteCounts() {
        let recorder = MaterialUploadEventRecorder()
        let delegate = AttachmentUploadProgressDelegate(attachmentID: "progress-file") {
            recorder.append($0)
        }
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.uploadTask(with: URLRequest(url: URL(string: "http://localhost/v1/files")!), from: Data())

        delegate.urlSession(
            session,
            task: task,
            didSendBodyData: 256,
            totalBytesSent: 768,
            totalBytesExpectedToSend: 1024
        )

        let event = recorder.snapshot().last
        XCTAssertEqual(event?.attachmentID, "progress-file")
        XCTAssertEqual(event?.state, .uploading(sentBytes: 768, totalBytes: 1024))
        XCTAssertEqual(event?.state.fraction, 0.75)
        session.invalidateAndCancel()
    }

    @MainActor
    func testPhysicalProductionCameraAndTwoPageScanOnRealDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("requires physical iPhone camera")
        #else
        XCTAssertEqual(
            AVCaptureDevice.authorizationStatus(for: .video),
            .authorized,
            "the real product bundle must already have camera permission for physical acceptance"
        )
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("no foreground UIWindowScene")
        }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds

        let draft = TaskAttachmentDraft()
        let baselineIDs = Set(draft.items.map(\.id))
        var photoCallbacks: [Data] = []
        var cameraError: String?
        let photoController = TaskAttachmentCaptureViewController(
            mode: .photo,
            onPhoto: { bytes in
                photoCallbacks.append(bytes)
                do { try draft.addImage(bytes, name: "物理连拍-\(photoCallbacks.count)") }
                catch { cameraError = error.localizedDescription }
            },
            onDocumentPDF: { _ in },
            onError: { cameraError = $0 }
        )
        window.rootViewController = photoController
        window.makeKeyAndVisible()
        _ = photoController.view
        try await Task.sleep(for: .seconds(2))
        addRenderedAttachment(view: photoController.view, name: "physical-camera-before-shutter")
        let initialDone = try XCTUnwrap(
            findView(identifier: "attachment.capture.done", in: photoController.view) as? UIButton
        )
        XCTAssertFalse(initialDone.isEnabled)

        for expectedCount in 1...3 {
            photoController.perform(NSSelectorFromString("shutterTapped"))
            try await waitUntil(timeout: 12) {
                self.captureCountText(in: photoController.view) == "已拍 \(expectedCount) 张" || cameraError != nil
            }
            XCTAssertNil(cameraError)
            XCTAssertEqual(photoCallbacks.count, 0, "photos must remain session-local until Done")
        }
        let latestPreview = try XCTUnwrap(
            findView(identifier: "attachment.capture.latest-preview", in: photoController.view) as? UIImageView
        )
        XCTAssertFalse(latestPreview.isHidden)
        XCTAssertNotNil(latestPreview.image)
        addRenderedAttachment(view: photoController.view, name: "physical-camera-three-photos-before-done")
        photoController.perform(NSSelectorFromString("doneTapped"))
        try await waitUntil(timeout: 8) { photoCallbacks.count == 3 || cameraError != nil }
        XCTAssertNil(cameraError)
        XCTAssertEqual(photoCallbacks.count, 3)
        XCTAssertEqual(Set(photoCallbacks.map { SHA256.hash(data: $0).description }).count, 3)
        XCTAssertTrue(photoCallbacks.allSatisfy { UIImage(data: $0) != nil })

        let newItems = draft.items.filter { !baselineIDs.contains($0.id) }
        defer { draft.discard(Set(newItems.map(\.id))) }
        XCTAssertEqual(newItems.count, 3)
        XCTAssertEqual(newItems.map(\.name), ["物理连拍-1.jpg", "物理连拍-2.jpg", "物理连拍-3.jpg"])
        XCTAssertEqual(Set(newItems.map(\.id)).count, 3)
        XCTAssertEqual(Set(newItems.map(\.sha256)).count, 3)
        let storedBytes = try newItems.map { try Data(contentsOf: $0.fileURL()) }
        XCTAssertEqual(Set(storedBytes.map { SHA256.hash(data: $0).description }).count, 3)
        photoController.viewWillDisappear(false)

        var cancelledCallbacks = 0
        var cancelError: String?
        let cancelController = TaskAttachmentCaptureViewController(
            mode: .photo,
            onPhoto: { _ in cancelledCallbacks += 1 },
            onDocumentPDF: { _ in },
            onError: { cancelError = $0 }
        )
        window.rootViewController = cancelController
        _ = cancelController.view
        try await Task.sleep(for: .seconds(2))
        for expectedCount in 1...2 {
            cancelController.perform(NSSelectorFromString("shutterTapped"))
            try await waitUntil(timeout: 12) {
                self.captureCountText(in: cancelController.view) == "已拍 \(expectedCount) 张" || cancelError != nil
            }
            XCTAssertNil(cancelError)
        }
        cancelController.perform(NSSelectorFromString("cancelTapped"))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(cancelledCallbacks, 0)
        XCTAssertEqual(draft.items.filter { !baselineIDs.contains($0.id) }.count, 3)
        cancelController.viewWillDisappear(false)

        var pdfData: Data?
        var scanError: String?
        let scanController = TaskAttachmentCaptureViewController(
            mode: .document,
            onPhoto: { _ in },
            onDocumentPDF: { pdfData = $0 },
            onError: { scanError = $0 }
        )
        window.rootViewController = scanController
        _ = scanController.view
        try await Task.sleep(for: .seconds(2))
        addRenderedAttachment(view: scanController.view, name: "physical-scan-before-shutter")
        scanController.perform(NSSelectorFromString("shutterTapped"))
        try await Task.sleep(for: .seconds(3))
        scanController.perform(NSSelectorFromString("shutterTapped"))
        try await Task.sleep(for: .seconds(3))
        addRenderedAttachment(view: scanController.view, name: "physical-scan-two-pages")
        scanController.perform(NSSelectorFromString("doneTapped"))
        try await waitUntil(timeout: 8) { pdfData != nil || scanError != nil }
        XCTAssertNil(scanError)
        let pdf = try XCTUnwrap(pdfData)
        XCTAssertEqual(PDFDocument(data: pdf)?.pageCount, 2)
        scanController.viewWillDisappear(false)
        window.isHidden = true
        #endif
    }

    @MainActor
    func testPhysicalPhotosPickerCanPresentOnRealDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("requires physical iPhone PhotosUI service")
        #else
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("no foreground UIWindowScene")
        }
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 8
        let picker = PHPickerViewController(configuration: configuration)
        let root = UIViewController()
        root.view.backgroundColor = .systemBackground
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.present(picker, animated: false)
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(root.presentedViewController === picker)
        XCTAssertNotNil(picker.view.window)
        addRenderedAttachment(view: picker.view, name: "physical-photos-picker-presented")
        picker.dismiss(animated: false)
        window.isHidden = true
        #endif
    }

    @MainActor
    private func captureCountText(in root: UIView) -> String? {
        (findView(identifier: "attachment.capture.page-count", in: root) as? UILabel)?.text
    }

    @MainActor
    private func findView(identifier: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        for child in root.subviews {
            if let match = findView(identifier: identifier, in: child) { return match }
        }
        return nil
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval,
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline {
                XCTFail("physical acceptance operation timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @MainActor
    private func addRenderedAttachment(view: UIView, name: String) {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let size = view.bounds.size.width > 1 && view.bounds.size.height > 1
            ? view.bounds.size
            : CGSize(width: 390, height: 844)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testPhysicalRealHostUploadTransport() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("requires paired physical iPhone + real Host")
        #else
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: RuntimeTaskStore.endpointDefaultsKey),
              let endpoint = URL(string: raw),
              !raw.isEmpty else {
            throw XCTSkip("physical app has no paired Host endpoint")
        }
        let client = try FlowerollHostClient.paired(baseURL: endpoint)
        let bytes = Data(repeating: 0x41, count: 2 * 1024 * 1024)
        let attachment = try makeAttachment(
            id: "a12physical" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            bytes: bytes
        )
        defer { try? FileManager.default.removeItem(at: try attachment.fileURL()) }
        let recorder = MaterialUploadEventRecorder()

        let receipt = try await client.uploadTaskAttachment(attachment) { event in
            recorder.append(event)
        }

        XCTAssertEqual(receipt.id, attachment.id)
        XCTAssertEqual(receipt.sha256, attachment.sha256)
        XCTAssertEqual(receipt.sizeBytes, attachment.sizeBytes)
        let events = recorder.snapshot()
        XCTAssertTrue(events.contains { event in
            if case let .uploading(sent, total) = event.state {
                return total == Int64(attachment.sizeBytes) && sent >= 0
            }
            return false
        })
        XCTAssertEqual(events.last?.state, .uploaded)
        let requireReconciliation = ProcessInfo.processInfo.environment["A12_REQUIRE_RECONCILIATION"] == "1"
        if requireReconciliation {
            XCTAssertTrue(events.contains { $0.state == .reconciling })
        }
        #endif
    }

    @MainActor
    func testPhysicalRealHostUploadRecoveryProbe() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("requires paired physical iPhone + fault proxy")
        #else
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: RuntimeTaskStore.endpointDefaultsKey),
              let endpoint = URL(string: raw),
              !raw.isEmpty else {
            throw XCTSkip("physical app has no paired Host endpoint")
        }
        let client = try FlowerollHostClient.paired(baseURL: endpoint)
        let bytes = Data(repeating: 0x52, count: 192 * 1024)
        let attachment = try makeAttachment(
            id: "a12recovery" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            bytes: bytes
        )
        defer { try? FileManager.default.removeItem(at: try attachment.fileURL()) }
        let recorder = MaterialUploadEventRecorder()

        let receipt = try await client.uploadTaskAttachment(attachment) { event in
            recorder.append(event)
        }

        XCTAssertEqual(receipt.id, attachment.id)
        XCTAssertEqual(receipt.sha256, attachment.sha256)
        XCTAssertEqual(receipt.sizeBytes, attachment.sizeBytes)
        let events = recorder.snapshot()
        XCTAssertTrue(
            events.contains { $0.state == .reconciling },
            "fault proxy must force at least one Host-offset reconciliation"
        )
        let progress = events.compactMap { event -> Int64? in
            if case let .uploading(sent, total) = event.state,
               total == Int64(attachment.sizeBytes) {
                return sent
            }
            return nil
        }
        XCTAssertGreaterThan(progress.count, 2)
        XCTAssertEqual(progress, progress.sorted(), "Host-confirmed upload progress must never move backwards")
        XCTAssertTrue(progress.contains { $0 > 0 && $0 < Int64(attachment.sizeBytes) })
        XCTAssertEqual(progress.last, Int64(attachment.sizeBytes))
        XCTAssertEqual(events.last?.state, .uploaded)
        #endif
    }

    @MainActor
    func testDurableTaskAdmissionReturnsBeforeReadbackAndProjectsHomeTask() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("durable-admission-boundary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pendingStore = try PendingSubmissionStore(directoryURL: directory)
        let suite = "MaterialAttachmentStabilityTests.durable-admission.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)

        MaterialURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path == "/v1/tasks" {
                let body = try Self.requestBody(request)
                let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                let submissionID = json["submission_id"] as! String
                return MaterialMockResponse(201, try Self.taskJSON(
                    submissionID: submissionID,
                    taskID: "task-admission-boundary",
                    threadID: "thread-admission-boundary"
                ))
            }
            // Deliberately fail every post-admission readback/index request. A
            // durable POST must still be a successful send boundary for Home.
            return MaterialMockResponse(503, Data("{}".utf8))
        }

        let store = RuntimeTaskStore(
            defaults: defaults,
            session: makeSession(),
            pendingStore: pendingStore,
            deviceWorker: nil
        )

        let task = try await store.submit(
            text: "发送后立即清空输入框",
            submissionID: "durable-admission-boundary"
        )

        XCTAssertEqual(task.taskID, "task-admission-boundary")
        XCTAssertEqual(store.currentHomeThreadID, "thread-admission-boundary")
        XCTAssertTrue(store.homeThreadTasks.contains { $0.taskID == task.taskID })
        XCTAssertFalse(store.isSubmitting)

        // Let the intentionally failing background convergence run. It must not
        // retract the already-admitted local Home projection.
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(store.homeThreadTasks.contains { $0.taskID == task.taskID })
    }

    @MainActor
    func testPhysicalRealHostSubmissionAckRecovery() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("requires paired physical iPhone + task ACK-loss proxy")
        #else
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: RuntimeTaskStore.endpointDefaultsKey),
              let endpoint = URL(string: raw),
              !raw.isEmpty else {
            throw XCTSkip("physical app has no paired Host endpoint")
        }
        let client = try FlowerollHostClient.paired(baseURL: endpoint)
        let bytes = Data(repeating: 0x53, count: 48 * 1024)
        let attachment = try makeAttachment(
            id: "a12submissionfile" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            bytes: bytes
        )
        defer { try? FileManager.default.removeItem(at: try attachment.fileURL()) }
        let pendingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("a12-submission-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: pendingDirectory) }
        let pendingStore = try PendingSubmissionStore(directoryURL: pendingDirectory)
        let submissionID = "a12submission" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        let task = try await client.submitDurably(
            text: "物理验收：验证附件发送 ACK 丢失后按同一 submission 恢复。",
            invocationSource: "a12_physical_submission_recovery",
            attachments: [attachment],
            submissionID: submissionID,
            pendingStore: pendingStore
        )

        XCTAssertEqual(task.submissionID, submissionID)
        let remaining = await pendingStore.pending()
        XCTAssertTrue(remaining.isEmpty)
        let readback = try await client.taskForSubmissionID(submissionID)
        XCTAssertEqual(readback?.taskID, task.taskID)
        XCTAssertEqual(readback?.submissionID, submissionID)
        #endif
    }

    @MainActor
    func testPhysicalUserMessageAttachmentThumbnailRendersOnRealDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("requires physical iPhone rendering")
        #else
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("no foreground UIWindowScene")
        }
        let id = "a12messagepreview" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let url = try PendingAttachment.directory().appendingPathComponent(id + ".jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 160)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
            UIColor.white.setFill()
            context.fill(CGRect(x: 28, y: 28, width: 184, height: 104))
        }
        let bytes = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        try bytes.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let file = TaskMaterialFile(
            id: id,
            name: "真机消息缩略图.jpg",
            mediaType: "image/jpeg",
            sizeBytes: bytes.count,
            sha256: digest,
            category: "input",
            metadata: [:]
        )
        let controller = UIHostingController(rootView: TaskMessageAttachmentStrip(files: [file]))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(600))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        XCTAssertNotNil(controller.view.window)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        addRenderedAttachment(view: controller.view, name: "physical-user-message-image-attachment")
        window.isHidden = true
        #endif
    }

    @MainActor
    func testNetworkErrorsAreStructuredChineseProductMessages() {
        let timeout = RuntimeTaskStore.userMessage(for: URLError(.timedOut))
        XCTAssertTrue(timeout.contains("连接超时"))
        XCTAssertFalse(timeout.contains("-1001"))
        let lost = RuntimeTaskStore.userMessage(for: URLError(.networkConnectionLost))
        XCTAssertTrue(lost.contains("网络连接中断"))
        XCTAssertFalse(lost.contains("operation cannot be completed"))
    }

    @MainActor
    private static func findSubview(
        in root: UIView,
        accessibilityIdentifier: String
    ) -> UIView? {
        if root.accessibilityIdentifier == accessibilityIdentifier { return root }
        for child in root.subviews {
            if let match = findSubview(in: child, accessibilityIdentifier: accessibilityIdentifier) {
                return match
            }
        }
        return nil
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MaterialURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeAttachment(id: String, bytes: Data) throws -> PendingAttachment {
        let storedName = id + ".txt"
        let url = try PendingAttachment.directory().appendingPathComponent(storedName)
        try bytes.write(to: url, options: .atomic)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return PendingAttachment(
            id: id, name: id + ".txt", mediaType: "text/plain",
            sizeBytes: bytes.count, sha256: digest, storedName: storedName
        )
    }

    private static func handleFileRequest(
        _ request: URLRequest,
        attachment: PendingAttachment,
        state: MaterialMockState
    ) throws -> MaterialMockResponse {
        let path = request.url?.path ?? ""
        let uploadPath = "/v1/files/uploads/\(attachment.id)"

        if request.httpMethod == "GET", path == "/v1/files/\(attachment.id)" {
            return state.withLock {
                state.getCount += 1
                guard state.hostHasFile else { return MaterialMockResponse(404, Data("{}".utf8)) }
                return MaterialMockResponse(200, receiptJSON(attachment))
            }
        }
        if request.httpMethod == "HEAD", path == uploadPath {
            return state.withLock {
                state.headCount += 1
                guard state.beginCount > 0 || state.hostHasFile else {
                    return MaterialMockResponse(404)
                }
                return MaterialMockResponse(204, headers: [
                    "Upload-Offset": String(state.hostOffset),
                    "Upload-Length": String(attachment.sizeBytes),
                    "Upload-Complete": state.hostHasFile ? "?1" : "?0",
                ])
            }
        }
        if request.httpMethod == "POST", path == "/v1/files/uploads" {
            return try state.withLock {
                state.beginCount += 1
                if state.permanentlyFailFileIDs.contains(attachment.id) {
                    throw URLError(.networkConnectionLost)
                }
                let body = try JSONSerialization.data(withJSONObject: [
                    "file_id": attachment.id,
                    "offset": state.hostOffset,
                    "complete": state.hostHasFile,
                    "file": state.hostHasFile
                        ? try JSONSerialization.jsonObject(with: receiptJSON(attachment))
                        : NSNull(),
                ])
                return MaterialMockResponse(201, body)
            }
        }
        if request.httpMethod == "PATCH", path == uploadPath {
            let body = try requestBody(request)
            return try state.withLock {
                state.patchCount += 1
                if state.permanentlyFailFileIDs.contains(attachment.id) {
                    throw URLError(.networkConnectionLost)
                }
                let requestedOffset = Int(request.value(forHTTPHeaderField: "Upload-Offset") ?? "") ?? -1
                if requestedOffset != state.hostOffset {
                    return MaterialMockResponse(409, Data("{}".utf8), headers: [
                        "Upload-Offset": String(state.hostOffset),
                    ])
                }
                if state.failPatchesRemaining > 0 {
                    state.failPatchesRemaining -= 1
                    if state.persistBeforeFailure {
                        state.hostOffset += body.count
                        if state.hostOffset == attachment.sizeBytes {
                            state.hostHasFile = true
                        }
                    }
                    throw URLError(.networkConnectionLost)
                }
                state.hostOffset += body.count
                if request.value(forHTTPHeaderField: "Upload-Complete") == "?1",
                   state.hostOffset == attachment.sizeBytes {
                    state.hostHasFile = true
                }
                return MaterialMockResponse(204, headers: [
                    "Upload-Offset": String(state.hostOffset),
                    "Upload-Complete": state.hostHasFile ? "?1" : "?0",
                ])
            }
        }
        return MaterialMockResponse(404, Data("{}".utf8))
    }

    private static func receiptJSON(_ attachment: PendingAttachment) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "id": attachment.id,
            "name": attachment.name,
            "media_type": attachment.mediaType,
            "size_bytes": attachment.sizeBytes,
            "sha256": attachment.sha256,
            "category": "input",
            "metadata": [:],
        ])
    }

    private static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var output = Data(); let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 16_384)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 16_384)
                if count <= 0 { break }
                output.append(buffer, count: count)
            }
            return output
        }
        return Data()
    }

    private static func taskJSON(
        submissionID: String,
        taskID: String? = nil,
        threadID: String? = nil
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "task_id": taskID ?? "task-\(submissionID)",
            "submission_id": submissionID,
            "thread_id": threadID ?? "thread-\(submissionID)",
            "parent_task_id": NSNull(),
            "goal": submissionID,
            "status": "active",
            "current_step": 0,
            "idempotent_replay": false,
            "created_at": "2026-09-12T08:00:00Z",
            "updated_at": "2026-09-12T08:00:00Z",
        ])
    }
}
