import Foundation
import XCTest
@testable import Floweroll


final class BackgroundAttachmentUploadTests: XCTestCase {
    func testOnlyRemoteHTTPSUsesSystemBackgroundTransfer() throws {
        XCTAssertTrue(AttachmentBackgroundUploadPolicy.shouldUseSystemBackgroundTransfer(
            baseURL: try XCTUnwrap(URL(string: "https://host.example"))
        ))
        for raw in [
            "http://127.0.0.1:8765",
            "http://localhost:8765",
            "https://localhost:8765",
            "http://host.example",
        ] {
            XCTAssertFalse(AttachmentBackgroundUploadPolicy.shouldUseSystemBackgroundTransfer(
                baseURL: try XCTUnwrap(URL(string: raw))
            ), raw)
        }
    }

    func testExistingSystemTaskRecoveryResumesSuspendedWithoutDuplicatingRunningTransfer() {
        XCTAssertEqual(
            AttachmentBackgroundUploadPolicy.existingTaskDisposition(for: .running),
            .reuse
        )
        XCTAssertEqual(
            AttachmentBackgroundUploadPolicy.existingTaskDisposition(for: .suspended),
            .resume
        )
        XCTAssertEqual(
            AttachmentBackgroundUploadPolicy.existingTaskDisposition(for: .canceling),
            .reuse
        )
        XCTAssertEqual(
            AttachmentBackgroundUploadPolicy.existingTaskDisposition(for: .completed),
            .replace
        )
    }

    func testBackgroundSessionIsImmediateSystemOwnedAndSingleConnection() {
        let configuration = AttachmentBackgroundUploadPolicy.configuration()
        XCTAssertEqual(configuration.identifier, AttachmentBackgroundUploadPolicy.sessionIdentifier)
        XCTAssertTrue(configuration.sessionSendsLaunchEvents)
        XCTAssertFalse(configuration.isDiscretionary)
        XCTAssertEqual(configuration.httpMaximumConnectionsPerHost, 1)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 30 * 60)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(AttachmentBackgroundUploadPolicy.chunkBytes, 12 * 1024 * 1024)
    }

    func testDurableTaskDescriptionContainsTransferIdentityButNeverCredential() throws {
        let attachment = PendingAttachment(
            id: "background-upload-id",
            name: "资料.pdf",
            mediaType: "application/pdf",
            sizeBytes: 1024,
            sha256: String(repeating: "a", count: 64),
            storedName: "background-upload-id.pdf"
        )
        let job = BackgroundAttachmentUploadJob(
            attachment: attachment,
            endpoint: "https://host.example",
            operation: .chunk,
            offset: 256,
            recoveryCount: 2,
            bodyFileName: "chunk.body",
            laneID: "lane-one"
        )
        let encoded = try job.encodedDescription()
        XCTAssertEqual(BackgroundAttachmentUploadJob.decode(encoded), job)
        XCTAssertTrue(encoded.contains("background-upload-id"))
        XCTAssertTrue(encoded.contains("lane-one"))
        XCTAssertFalse(encoded.lowercased().contains("authorization"))
        XCTAssertFalse(encoded.lowercased().contains("bearer"))
        XCTAssertFalse(encoded.contains("secret-token"))

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "laneID")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyDescription = try XCTUnwrap(String(data: legacyData, encoding: .utf8))
        let legacyJob = try XCTUnwrap(BackgroundAttachmentUploadJob.decode(legacyDescription))
        XCTAssertNil(legacyJob.laneID, "installed tasks from builds before lane fencing must remain decodable")
    }

    private func progressJob(operation: BackgroundAttachmentUploadJob.Operation = .chunk, offset: Int = 256) -> BackgroundAttachmentUploadJob {
        BackgroundAttachmentUploadJob(
            attachment: PendingAttachment(id: "progress-id", name: "test.txt", mediaType: "text/plain",
                sizeBytes: 1024, sha256: String(repeating: "a", count: 64), storedName: "progress-id.txt"),
            endpoint: "https://host.example", operation: operation, offset: offset,
            recoveryCount: 0, bodyFileName: "chunk.body"
        )
    }

    func testSuccessfulBeginCannotResetRepeatedTransferFailureBudget() {
        let attachment = progressJob().attachment
        let job = BackgroundAttachmentUploadJob(attachment: attachment, endpoint: "https://host.example",
            operation: .begin, offset: 256, recoveryCount: 3, bodyFileName: "begin.body")
        XCTAssertEqual(job.nextRecoveryCount(confirmedOffset: 256), 3)
        XCTAssertEqual(job.nextRecoveryCount(confirmedOffset: 0), 3)
        XCTAssertEqual(job.nextRecoveryCount(confirmedOffset: 512), 0)
    }

    func testLiveByteProgressAdvancesBeforeTheHostFinalReceipt() {
        let job = progressJob(offset: 0)
        XCTAssertEqual(job.progressState(totalBytesSent: 128), .uploading(sentBytes: 128, totalBytes: 1024))
        XCTAssertEqual(job.progressState(totalBytesSent: 768), .uploading(sentBytes: 768, totalBytes: 1024))
    }

    func testRecoveredTaskUsesNativeBytesPlusPreviouslyCommittedPrefix() {
        XCTAssertEqual(progressJob().progressState(totalBytesSent: 512), .uploading(sentBytes: 768, totalBytes: 1024))
        XCTAssertEqual(progressJob().progressState(totalBytesSent: -1), .uploading(sentBytes: 256, totalBytes: 1024))
    }

    func testAllSocketBytesStillRequireVerifiedHostReceipt() {
        XCTAssertEqual(progressJob().progressState(totalBytesSent: 768), .reconciling)
        XCTAssertEqual(progressJob().progressState(totalBytesSent: Int64.max), .reconciling)
        XCTAssertEqual(progressJob(operation: .begin).progressState(totalBytesSent: 100), .reconciling)
    }

    func testForegroundRefreshAndByteCallbackAreWiredToTheSameProjection() throws {
        let root = try ProductSourceFiles.iosRoot().appendingPathComponent("Floweroll/App/RuntimeClient")
        let transport = try String(contentsOf: root.appendingPathComponent("AttachmentBackgroundUploadTransport.swift"), encoding: .utf8)
        let store = try String(contentsOf: root.appendingPathComponent("RuntimeTaskStore.swift"), encoding: .utf8)
        XCTAssertTrue(transport.contains("didSendBodyData bytesSent:"))
        XCTAssertTrue(transport.contains("progressState(totalBytesSent: task.countOfBytesSent)"))
        XCTAssertTrue(transport.contains("progressState(totalBytesSent: totalBytesSent)"))
        XCTAssertTrue(store.contains("AttachmentBackgroundUploadTransport.shared.refreshProgress()"))
    }

    func testImmediateUploadLaneBlocksBackgroundUntilLastOwnerReleases() throws {
        var state = BackgroundAttachmentUploadLaneState()
        let oldLane = try XCTUnwrap(state.beginBackground(attachmentID: "shared"))
        XCTAssertTrue(
            state.isCurrentBackgroundLane(attachmentID: "shared", laneID: oldLane)
        )

        state.beginImmediate(attachmentID: "shared")
        state.beginImmediate(attachmentID: "shared")
        XCTAssertEqual(state.immediateOwnerCount(attachmentID: "shared"), 2)
        XCTAssertFalse(
            state.isCurrentBackgroundLane(attachmentID: "shared", laneID: oldLane)
        )
        XCTAssertNil(
            state.adoptBackgroundJob(attachmentID: "shared", laneID: oldLane),
            "handoff-retired callbacks must never resurrect their background lane"
        )

        state.endImmediate(attachmentID: "shared")
        XCTAssertNil(state.beginBackground(attachmentID: "shared"))
        state.endImmediate(attachmentID: "shared")

        let freshLane = try XCTUnwrap(state.beginBackground(attachmentID: "shared"))
        XCTAssertNotEqual(freshLane, oldLane)
        XCTAssertEqual(
            state.prepareDiscoveredExistingTask(
                attachmentID: "shared",
                provisionalLaneID: freshLane,
                existingLaneID: oldLane,
                replaceExisting: false
            ),
            .replaceStale(laneID: freshLane)
        )

        let completedDisposition = state.prepareDiscoveredExistingTask(
            attachmentID: "shared",
            provisionalLaneID: freshLane,
            existingLaneID: freshLane,
            replaceExisting: true
        )
        guard case let .replaceStale(replacementLane) = completedDisposition else {
            return XCTFail("completed system task must be detached from the fresh transfer lane")
        }
        XCTAssertNotEqual(replacementLane, freshLane)
        XCTAssertFalse(
            state.isCurrentBackgroundLane(attachmentID: "shared", laneID: freshLane)
        )
        XCTAssertTrue(
            state.finishBackground(attachmentID: "shared", laneID: replacementLane)
        )
        XCTAssertFalse(
            state.isCurrentBackgroundLane(attachmentID: "shared", laneID: replacementLane)
        )

        var cancelState = BackgroundAttachmentUploadLaneState()
        let cancelledLane = try XCTUnwrap(cancelState.beginBackground(attachmentID: "cancelled"))
        cancelState.beginImmediate(attachmentID: "cancelled")
        cancelState.endImmediate(attachmentID: "cancelled")
        XCTAssertNil(
            cancelState.adoptBackgroundJob(attachmentID: "cancelled", laneID: cancelledLane)
        )
    }

    func testBackgroundTransferOwnsBytesButNotZeroByteControlPlane() throws {
        let appRoot = try ProductSourceFiles.iosRoot().appendingPathComponent("Floweroll/App/RuntimeClient")
        let client = try String(contentsOf: appRoot.appendingPathComponent("FlowerollHostClient.swift"), encoding: .utf8)
        let transport = try String(contentsOf: appRoot.appendingPathComponent("AttachmentBackgroundUploadTransport.swift"), encoding: .utf8)
        let remoteBranch = try XCTUnwrap(client.range(of: "shouldUseSystemBackgroundTransfer(baseURL: baseURL)"))
        let remoteTail = String(client[remoteBranch.lowerBound...])
        XCTAssertLessThan(
            try XCTUnwrap(remoteTail.range(of: "ensureResumableUpload(")).lowerBound,
            try XCTUnwrap(remoteTail.range(of: "AttachmentBackgroundUploadTransport.shared.uploadBytes(")).lowerBound
        )
        XCTAssertTrue(transport.contains("func uploadBytes("))
        XCTAssertTrue(transport.contains("try self.scheduleChunk("))
        XCTAssertFalse(transport.contains("func scheduleBegin("))
        XCTAssertTrue(transport.contains("job.operation == .begin"), "legacy zero-byte background begin tasks must be retired during upgrade")
    }

    func testHomeExplicitSendPersistsBeforeImmediateUploadAndAdmission() throws {
        let root = try ProductSourceFiles.iosRoot().appendingPathComponent("Floweroll/App/RuntimeClient")
        let coordinator = try String(
            contentsOf: root.appendingPathComponent("SystemEntryRuntimeCoordinator.swift"),
            encoding: .utf8
        )
        let client = try String(
            contentsOf: root.appendingPathComponent("FlowerollHostClient.swift"),
            encoding: .utf8
        )
        let transport = try String(
            contentsOf: root.appendingPathComponent("AttachmentBackgroundUploadTransport.swift"),
            encoding: .utf8
        )
        let homeSubmit = try XCTUnwrap(coordinator.range(of: "private func submitHomeTask("))
        let tail = String(coordinator[homeSubmit.lowerBound...])
        let persisted = try XCTUnwrap(tail.range(of: "pendingStore.create("))
        let immediate = try XCTUnwrap(tail.range(of: "executionMode: .immediateResumable"))
        let admit = try XCTUnwrap(tail.range(of: "client.submitExisting(pending"))
        XCTAssertLessThan(persisted.lowerBound, immediate.lowerBound)
        XCTAssertLessThan(immediate.lowerBound, admit.lowerBound)
        XCTAssertTrue(client.contains("beginImmediateUploadHandoff("))
        XCTAssertTrue(client.contains("endImmediateUploadHandoff(attachmentID: attachment.id)"))
        XCTAssertTrue(client.contains("defer {"))
        XCTAssertTrue(transport.contains("laneState.beginBackground(attachmentID: attachment.id)"))
        XCTAssertTrue(transport.contains("laneState.prepareDiscoveredExistingTask("))
        XCTAssertTrue(transport.contains("replaceExisting: existingDisposition == .replace"))
        XCTAssertTrue(transport.contains("laneState.finishBackground(attachmentID: attachmentID, laneID: laneID)"))
        XCTAssertTrue(transport.contains("laneState.isCurrentBackgroundLane("))
        XCTAssertTrue(transport.contains("let values = claimImmediateUploadOwnership(attachmentID: attachmentID)"))
        XCTAssertTrue(transport.contains("defer { self.endImmediateUploadHandoff(attachmentID: attachmentID) }"))
        XCTAssertTrue(transport.contains("task.taskDescription = nil"))
        XCTAssertTrue(transport.contains("task.cancel()"))
    }

    func testHomeExistingSystemOwnerAttachmentTurnUsesImmediateUploadBeforeAdmission() throws {
        let root = try ProductSourceFiles.iosRoot().appendingPathComponent("Floweroll/App/RuntimeClient")
        let coordinator = try String(
            contentsOf: root.appendingPathComponent("SystemEntryRuntimeCoordinator.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(
            coordinator.range(of: "func enqueuePreparedHomeInputWithoutNewExecutionWindow(")
        )
        let end = try XCTUnwrap(
            coordinator.range(of: "private func submitHomeTask(", range: start.upperBound..<coordinator.endIndex)
        )
        let scope = String(coordinator[start.lowerBound..<end.lowerBound])

        let persisted = try XCTUnwrap(scope.range(of: "pendingStore.createUserTurn("))
        let recovery = try XCTUnwrap(scope.range(of: "home_joined_existing_user_turn_persisted"))
        let immediate = try XCTUnwrap(scope.range(of: "executionMode: .immediateResumable"))
        let admitted = try XCTUnwrap(scope.range(of: "client.submitExistingUserTurn(pending"))
        XCTAssertLessThan(persisted.lowerBound, recovery.lowerBound)
        XCTAssertLessThan(recovery.lowerBound, immediate.lowerBound)
        XCTAssertLessThan(immediate.lowerBound, admitted.lowerBound)
        XCTAssertFalse(scope.contains("Task { try? await client.uploadTaskAttachment(attachment) }"))
    }

    func testProductSourceUsesBackgroundFileUploadWithoutBGCPT() throws {
        let appRoot = try ProductSourceFiles.iosRoot().appendingPathComponent("Floweroll/App")
        let transport = try String(
            contentsOf: appRoot.appendingPathComponent("RuntimeClient/AttachmentBackgroundUploadTransport.swift"),
            encoding: .utf8
        )
        let app = try String(
            contentsOf: appRoot.appendingPathComponent("FlowerollApp.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(transport.contains("URLSessionConfiguration.background(withIdentifier:"))
        XCTAssertTrue(transport.contains("uploadTask(with: request, fromFile: bodyURL)"))
        XCTAssertTrue(transport.contains("X-Floweroll-Background-Upload"))
        XCTAssertTrue(app.contains("@UIApplicationDelegateAdaptor(FlowerollAppDelegate.self)"))
        XCTAssertTrue(transport.contains("handleEventsForBackgroundURLSession"))
        XCTAssertTrue(transport.contains("recoverDurableWorkNow("))
        XCTAssertTrue(transport.contains("background_attachment_events_finished"))
        XCTAssertFalse(transport.contains("BGContinuedProcessingTaskRequest("))
        XCTAssertFalse(transport.contains("pushTokenUpdates"))
    }
}


extension BackgroundAttachmentUploadTests {
    func testWaiterCancelledBeforeRegistrationCompletesWithoutHanging() async {
        let waiter = BackgroundAttachmentUploadWaiter()
        waiter.finish(.failure(CancellationError()))
        do {
            let _: Void = try await withCheckedThrowingContinuation { continuation in
                XCTAssertFalse(waiter.install(continuation))
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCancellingOneWaiterDoesNotCancelAnotherAndLateCompletionIsSafe() async {
        let cancelled = BackgroundAttachmentUploadWaiter()
        let other = BackgroundAttachmentUploadWaiter()
        cancelled.finish(.failure(CancellationError()))
        XCTAssertTrue(cancelled.isFinished)
        XCTAssertFalse(other.isFinished)
        do {
            let _: Void = try await withCheckedThrowingContinuation { continuation in
                XCTAssertTrue(other.install(continuation))
                other.finish(.failure(URLError(.timedOut)))
                other.finish(.failure(CancellationError()))
            }
            XCTFail("Expected timeout")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        catch { XCTFail("Unexpected error: \(error)") }
    }
}


extension BackgroundAttachmentUploadTests {
    @MainActor
    func testBackgroundWakeCompletionDoesNotWaitIndefinitelyForHost() async throws {
        let completed = expectation(description: "system callback completed")
        let cancelled = expectation(description: "slow recovery cancelled")
        var completionCount = 0
        var deferredCount = 0
        BackgroundUploadWakeCompletion.run(budget: .milliseconds(20)) {
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled.fulfill() }
        } onDeferredRecovery: {
            deferredCount += 1
        } completion: {
            completionCount += 1
            completed.fulfill()
        }
        await fulfillment(of: [completed, cancelled], timeout: 2)
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(deferredCount, 1)
    }

    @MainActor
    func testBackgroundWakeRecoveryFinishingFirstCompletesOnlyOnce() async throws {
        let completed = expectation(description: "system callback completed")
        var completionCount = 0
        var deferredCount = 0
        BackgroundUploadWakeCompletion.run(budget: .milliseconds(20)) {
            // Host admission was immediately available.
        } onDeferredRecovery: {
            deferredCount += 1
        } completion: {
            completionCount += 1
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(deferredCount, 0)
    }
}
