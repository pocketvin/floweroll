import Foundation
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

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        reconciliations += 1
        return .definitelyNotStarted
    }
}

final class DeviceReconciliationTests: XCTestCase {
    override func tearDown() {
        HomePresentationURLProtocol.reset()
        super.tearDown()
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomePresentationURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func dispatch(attemptID: String, digest: String) -> DeviceActionDispatch {
        var value = DeviceActionDispatch(
            actionID: "a",
            taskID: "t",
            actionType: "device.probe",
            payload: ["message": .string("test")],
            status: "dispatched",
            runtimeActionStatus: "reconciling",
            idempotencyKey: "key",
            attemptID: attemptID,
            attemptNumber: 1,
            attemptStatus: "FINISHED",
            dispatchDigest: digest
        )
        value.reconciliationOnly = true
        return value
    }

    func testStoppedReconciliationNeverExecutesAndReportsOnlyDefiniteAbsence() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = try DeviceActionJournal(directoryURL: folder)
        let executor = UnstartedExecutor()
        let counter = PresentationRequestCounter()

        HomePresentationURLProtocol.install { request in
            counter.record(request)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.url?.path,
                "/v1/tasks/t/actions/a/reconciliations/definitely-not-started"
            )
            return (200, Data("{}".utf8))
        }

        let client = FlowerollHostClient(
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:8765")),
            session: session()
        )
        let coordinator = DeviceExecutionCoordinator(
            client: client,
            journal: journal,
            executors: [executor]
        )

        let missing = dispatch(attemptID: "attempt-missing", digest: "digest-missing")
        let missingOutcome = try await coordinator.process(missing)
        guard case .needsReconciliation = missingOutcome else {
            return XCTFail("missing local journal must not prove native absence")
        }
        XCTAssertEqual(
            counter.count(
                method: "POST",
                path: "/v1/tasks/t/actions/a/reconciliations/definitely-not-started"
            ),
            0
        )

        let received = dispatch(attemptID: "attempt-received", digest: "digest-received")
        _ = try await journal.prepare(received)
        let receivedOutcome = try await coordinator.process(received)
        XCTAssertEqual(receivedOutcome, .completed(attemptID: received.attemptID))

        let ambiguous = dispatch(attemptID: "attempt-ambiguous", digest: "digest-ambiguous")
        _ = try await journal.prepare(ambiguous)
        _ = try await journal.markMayHaveStarted(attemptID: ambiguous.attemptID)
        let ambiguousOutcome = try await coordinator.process(ambiguous)
        XCTAssertEqual(ambiguousOutcome, .completed(attemptID: ambiguous.attemptID))

        XCTAssertEqual(
            counter.count(
                method: "POST",
                path: "/v1/tasks/t/actions/a/reconciliations/definitely-not-started"
            ),
            2
        )
        let executions = await executor.executions
        let reconciliations = await executor.reconciliations
        let ambiguousEntry = await journal.entry(attemptID: ambiguous.attemptID)
        XCTAssertEqual(executions, 0)
        XCTAssertEqual(reconciliations, 1)
        XCTAssertEqual(
            ambiguousEntry?.state,
            .received,
            "stopped reconciliation must return to unstarted proof state without executing"
        )
    }
}
