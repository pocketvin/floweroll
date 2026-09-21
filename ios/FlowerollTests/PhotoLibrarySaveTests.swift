import CryptoKit
import Foundation
import XCTest
@testable import Floweroll


actor FakePhotoLibraryClient: PhotoLibraryClient {
    enum FakeError: Error { case writeFailed }

    private var statuses: [PhotoLibraryAddAuthorization]
    private let shouldFailWrite: Bool
    private(set) var requestCount = 0
    private(set) var saveCount = 0
    private(set) var savedSources: [TaskMaterialExportSource] = []

    init(
        statuses: [PhotoLibraryAddAuthorization],
        shouldFailWrite: Bool = false
    ) {
        self.statuses = statuses
        self.shouldFailWrite = shouldFailWrite
    }

    func authorizationStatus() async -> PhotoLibraryAddAuthorization {
        guard !statuses.isEmpty else { return .unknown }
        if statuses.count == 1 { return statuses[0] }
        return statuses.removeFirst()
    }

    func requestAddOnlyAuthorization() async -> PhotoLibraryAddAuthorization {
        requestCount += 1
        guard !statuses.isEmpty else { return .unknown }
        if statuses.count == 1 { return statuses[0] }
        return statuses.removeFirst()
    }

    func saveImage(source: TaskMaterialExportSource) async throws -> String? {
        saveCount += 1
        savedSources.append(source)
        if shouldFailWrite { throw FakeError.writeFailed }
        return "photo-local-id"
    }

    func counters() -> (requests: Int, saves: Int) {
        (requestCount, saveCount)
    }
}


@MainActor
final class PhotoLibrarySaveTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() async throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoLibrarySaveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func imageFixture(
        mediaType: String = "image/jpeg",
        category: String = "output"
    ) throws -> (TaskMaterialFile, URL) {
        let directory = try makeDirectory()
        let data = Data("not-real-image-but-byte-verified-test-fixture".utf8)
        let ext = mediaType == "image/png" ? "png" : "jpg"
        let url = directory.appendingPathComponent("fixture.\(ext)")
        try data.write(to: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (
            TaskMaterialFile(
                id: "artifact-image",
                name: "验收图片.\(ext)",
                mediaType: mediaType,
                sizeBytes: data.count,
                sha256: digest,
                category: category,
                metadata: [:]
            ),
            url
        )
    }

    private func manifest(output: TaskMaterialFile) -> TaskMaterialManifest {
        TaskMaterialManifest(
            inputs: [],
            initialInputIDs: nil,
            outputs: [output],
            progressiveOutputs: nil,
            inputProvenance: nil,
            plan: nil,
            workSummary: nil
        )
    }

    private func resolver(url: URL) -> TaskMaterialLocalFileResolver {
        TaskMaterialLocalFileResolver { _, _ in url }
    }

    func testEligibilityIsVerifiedOutputJPEGOrPNGOnly() throws {
        let (jpeg, _) = try imageFixture(mediaType: "image/jpeg")
        XCTAssertNotNil(TaskPhotoSavePolicy.eligibleOutput(sourceArtifactID: jpeg.id, manifest: manifest(output: jpeg)))

        let (png, _) = try imageFixture(mediaType: "image/png")
        XCTAssertNotNil(TaskPhotoSavePolicy.eligibleOutput(sourceArtifactID: png.id, manifest: manifest(output: png)))

        let pdf = TaskMaterialFile(
            id: "pdf", name: "x.pdf", mediaType: "application/pdf", sizeBytes: 4,
            sha256: String(repeating: "a", count: 64), category: "output", metadata: [:]
        )
        XCTAssertNil(TaskPhotoSavePolicy.eligibleOutput(sourceArtifactID: pdf.id, manifest: manifest(output: pdf)))

        let inputManifest = TaskMaterialManifest(
            inputs: [jpeg], initialInputIDs: nil, outputs: [], progressiveOutputs: nil,
            inputProvenance: nil, plan: nil, workSummary: nil
        )
        XCTAssertNil(TaskPhotoSavePolicy.eligibleOutput(sourceArtifactID: jpeg.id, manifest: inputManifest))
    }

    func testAuthorizedExplicitSaveCompletesOneSystemWrite() async throws {
        let (file, url) = try imageFixture()
        let operationDirectory = try makeDirectory()
        let operationStore = try TaskPhotoSaveOperationStore(directoryURL: operationDirectory)
        let photoLibrary = FakePhotoLibraryClient(statuses: [.authorized])
        let coordinator = TaskPhotoSaveCoordinator(operationStore: operationStore, photoLibrary: photoLibrary)

        await coordinator.save(
            taskID: "task-photo",
            sourceArtifactID: file.id,
            manifest: manifest(output: file),
            resolver: resolver(url: url)
        )

        XCTAssertEqual(coordinator.feedback, .init(kind: .success, message: "已保存到照片"))
        let counters = await photoLibrary.counters()
        XCTAssertEqual(counters.requests, 0)
        XCTAssertEqual(counters.saves, 1)
        let records = await operationStore.recordsForTask("task-photo")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].state, .completedSystemWrite)
        XCTAssertEqual(records[0].nativeLocalIdentifier, "photo-local-id")
        XCTAssertEqual(records[0].authorizationScope, "add_only")
    }

    func testNotDeterminedRequestsAddOnlyOnlyOnExplicitSave() async throws {
        let (file, url) = try imageFixture()
        let operationStore = try TaskPhotoSaveOperationStore(directoryURL: makeDirectory())
        let photoLibrary = FakePhotoLibraryClient(statuses: [.notDetermined, .authorized])
        let coordinator = TaskPhotoSaveCoordinator(operationStore: operationStore, photoLibrary: photoLibrary)

        let before = await photoLibrary.counters()
        XCTAssertEqual(before.requests, 0)
        await coordinator.save(
            taskID: "task-photo-request",
            sourceArtifactID: file.id,
            manifest: manifest(output: file),
            resolver: resolver(url: url)
        )

        let after = await photoLibrary.counters()
        XCTAssertEqual(after.requests, 1)
        XCTAssertEqual(after.saves, 1)
        let requestRecords = await operationStore.recordsForTask("task-photo-request")
        XCTAssertEqual(requestRecords.first?.state, .completedSystemWrite)
    }

    func testDeniedRestrictedAndUnexpectedLimitedNeverCrossWriteBoundary() async throws {
        for authorization in [
            PhotoLibraryAddAuthorization.denied,
            .restricted,
            .limited,
            .unknown,
        ] {
            let (file, url) = try imageFixture()
            let store = try TaskPhotoSaveOperationStore(directoryURL: makeDirectory())
            let client = FakePhotoLibraryClient(statuses: [authorization])
            let coordinator = TaskPhotoSaveCoordinator(operationStore: store, photoLibrary: client)

            await coordinator.save(
                taskID: "task-\(authorization.rawValue)",
                sourceArtifactID: file.id,
                manifest: manifest(output: file),
                resolver: resolver(url: url)
            )

            let counters = await client.counters()
            XCTAssertEqual(counters.saves, 0, "authorization=\(authorization)")
            let records = await store.recordsForTask("task-\(authorization.rawValue)")
            XCTAssertEqual(records.first?.state, .definitelyNotStarted)
            XCTAssertEqual(coordinator.feedback?.kind, .failure)
        }
    }

    func testPhotoKitExplicitFailureIsDefinitelyFailedAndRetryIsNewOperation() async throws {
        let (file, url) = try imageFixture()
        let store = try TaskPhotoSaveOperationStore(directoryURL: makeDirectory())
        let failingClient = FakePhotoLibraryClient(statuses: [.authorized], shouldFailWrite: true)
        let failingCoordinator = TaskPhotoSaveCoordinator(operationStore: store, photoLibrary: failingClient)

        await failingCoordinator.save(
            taskID: "task-retry",
            sourceArtifactID: file.id,
            manifest: manifest(output: file),
            resolver: resolver(url: url)
        )
        let firstRecords = await store.recordsForTask("task-retry")
        XCTAssertEqual(firstRecords.count, 1)
        XCTAssertEqual(firstRecords[0].state, .definitelyFailed)

        let successClient = FakePhotoLibraryClient(statuses: [.authorized])
        let successCoordinator = TaskPhotoSaveCoordinator(operationStore: store, photoLibrary: successClient)
        await successCoordinator.save(
            taskID: "task-retry",
            sourceArtifactID: file.id,
            manifest: manifest(output: file),
            resolver: resolver(url: url)
        )
        let finalRecords = await store.recordsForTask("task-retry")
        XCTAssertEqual(finalRecords.count, 2)
        XCTAssertNotEqual(finalRecords[0].saveOperationID, finalRecords[1].saveOperationID)
        XCTAssertEqual(Set(finalRecords.map(\.state)), [.definitelyFailed, .completedSystemWrite])
    }

    func testRelaunchRecoversInFlightAsUnknownWithoutAutomaticResave() async throws {
        let (file, url) = try imageFixture()
        let directory = try makeDirectory()
        let first = try TaskPhotoSaveOperationStore(directoryURL: directory)
        let operation = try await first.prepare(taskID: "task-ambiguous", file: file)
        _ = try await first.markVerified(operation.saveOperationID)
        _ = try await first.markInFlight(operation.saveOperationID, authorizationScope: "add_only")

        let recovered = try TaskPhotoSaveOperationStore(directoryURL: directory, recoveryDate: Date(timeIntervalSince1970: 1_000))
        let recoveredRecords = await recovered.recordsForTask("task-ambiguous")
        XCTAssertEqual(recoveredRecords.first?.state, .unknownMayHaveCommitted)

        let client = FakePhotoLibraryClient(statuses: [.authorized])
        let coordinator = TaskPhotoSaveCoordinator(operationStore: recovered, photoLibrary: client)
        await coordinator.loadRecoveredState(taskID: "task-ambiguous")
        XCTAssertEqual(coordinator.feedback?.kind, .unknown)
        let beforeRetryCounters = await client.counters()
        XCTAssertEqual(beforeRetryCounters.saves, 0)

        await coordinator.save(
            taskID: "task-ambiguous",
            sourceArtifactID: file.id,
            manifest: manifest(output: file),
            resolver: resolver(url: url)
        )
        let afterRetryCounters = await client.counters()
        XCTAssertEqual(afterRetryCounters.saves, 1)
        let records = await recovered.recordsForTask("task-ambiguous")
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.state)), [.unknownMayHaveCommitted, .completedSystemWrite])
    }
}
