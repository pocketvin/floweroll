import XCTest
@testable import Floweroll

private actor UnstartedExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID = "device.probe"
    private(set) var executions = 0
    private(set) var reconciliations = 0
    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        executions += 1
        return .success([:])
    }
    func reconcile(_ dispatch: DeviceActionDispatch, journalEntry: DeviceActionJournalEntry) async throws -> DeviceReconciliationResult {
        reconciliations += 1
        return .definitelyNotStarted
    }
}

final class DeviceReconciliationTests: XCTestCase {
    func testReadOnlyEnvelopeNeverExecutesWithMissingReceivedOrAmbiguousJournal() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = try DeviceActionJournal(directoryURL: folder)
        let executor = UnstartedExecutor()
        let client = FlowerollHostClient(baseURL: URL(string: "http://127.0.0.1:1")!)
        let coordinator = DeviceExecutionCoordinator(client: client, journal: journal, executors: [executor])
        var dispatch = DeviceActionDispatch(actionID: "a", taskID: "t", actionType: "device.probe",
            payload: ["message": .string("test")], status: "dispatched", runtimeActionStatus: "reconciling",
            idempotencyKey: "key", attemptID: "attempt", attemptNumber: 1,
            attemptStatus: "FINISHED", dispatchDigest: "digest")
        dispatch.reconciliationOnly = true
        for state in 0..<3 {
            if state == 1 { _ = try await journal.prepare(dispatch) }
            if state == 2 { _ = try await journal.markMayHaveStarted(attemptID: dispatch.attemptID) }
            let outcome = try await coordinator.process(dispatch)
            guard case .needsReconciliation = outcome else { return XCTFail("read-only dispatch resumed execution") }
        }
        let executions = await executor.executions
        let reconciliations = await executor.reconciliations
        XCTAssertEqual(executions, 0)
        XCTAssertEqual(reconciliations, 1)
        let entry = await journal.entry(attemptID: dispatch.attemptID)
        XCTAssertEqual(entry?.state, .mayHaveStarted)
    }
}
