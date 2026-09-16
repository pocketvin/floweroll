import Foundation


struct DeviceExecutionResult: Equatable, Sendable {
    let success: Bool
    let output: [String: JSONValue]
    let error: String?
    let nativeCorrelationID: String?

    static func success(
        _ output: [String: JSONValue],
        nativeCorrelationID: String? = nil
    ) -> DeviceExecutionResult {
        DeviceExecutionResult(
            success: true,
            output: output,
            error: nil,
            nativeCorrelationID: nativeCorrelationID
        )
    }

    static func failure(
        _ error: String,
        output: [String: JSONValue] = [:],
        nativeCorrelationID: String? = nil
    ) -> DeviceExecutionResult {
        DeviceExecutionResult(
            success: false,
            output: output,
            error: error,
            nativeCorrelationID: nativeCorrelationID
        )
    }
}

enum DeviceReconciliationResult: Equatable, Sendable {
    case completed(DeviceExecutionResult)
    case definitelyNotStarted
    case stillUnknown(String?)
}

protocol DeviceCapabilityExecutor: Sendable {
    var capabilityID: String { get }

    /// Validate permission/native arguments before the journal enters the
    /// may-have-started side-effect boundary. Return a definitive failure when
    /// execution is impossible without touching the external system.
    func preflight(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult?

    /// Return only a definitive success/failure. If this throws after the
    /// coordinator persisted `mayHaveStarted`, the coordinator assumes the
    /// real-world effect may have happened and requires reconciliation.
    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult

    /// Read authoritative native state after process/network loss. Never use
    /// this method to simply repeat the side effect.
    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult
}

extension DeviceCapabilityExecutor {
    func preflight(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult? {
        nil
    }
}

struct DeviceProbeExecutor: DeviceCapabilityExecutor {
    let capabilityID = "device.probe"

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        guard let message = dispatch.payload["message"]?.stringValue else {
            return .failure("device.probe payload is missing message")
        }
        return .success(["echo": .string(message)], nativeCorrelationID: dispatch.attemptID)
    }

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        // device.probe has no external side effect. If the process died after
        // the journal boundary, reconstituting the deterministic echo is safe
        // evidence for this infrastructure-only capability.
        guard let message = dispatch.payload["message"]?.stringValue else {
            return .completed(.failure("device.probe payload is missing message"))
        }
        return .completed(
            .success(["echo": .string(message)], nativeCorrelationID: dispatch.attemptID)
        )
    }
}

enum DeviceExecutionCoordinatorOutcome: Equatable, Sendable {
    case noAction
    case completed(attemptID: String)
    case resultReplayed(attemptID: String)
    case needsReconciliation(attemptID: String, reason: String?)
    case unsupportedCapability(String)
}

actor DeviceExecutionCoordinator {
    private let client: FlowerollHostClient
    private let journal: DeviceActionJournal
    private let executors: [String: any DeviceCapabilityExecutor]

    init(
        client: FlowerollHostClient,
        journal: DeviceActionJournal,
        executors: [any DeviceCapabilityExecutor]
    ) {
        self.client = client
        self.journal = journal
        self.executors = Dictionary(
            uniqueKeysWithValues: executors.map { ($0.capabilityID, $0) }
        )
    }

    /// Process at most one Host device Action. This is intentionally a small
    /// deterministic boundary; a later background scheduler/App Intent may call
    /// it repeatedly while iOS grants execution time.
    func processNext(
        taskID: String,
        waitSeconds: Int = 0
    ) async throws -> DeviceExecutionCoordinatorOutcome {
        guard let dispatch = try await client.fetchNextAction(
            taskID: taskID,
            waitSeconds: waitSeconds
        ) else {
            return .noAction
        }
        return try await process(dispatch)
    }

    func process(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionCoordinatorOutcome {
        guard let executor = executors[dispatch.actionType] else {
            if dispatch.reconciliationOnly == true {
                return .needsReconciliation(attemptID: dispatch.attemptID, reason: "本机暂时无法核对这项操作")
            }
            // Receiving a dispatch has no native side effect. Therefore an
            // unavailable local executor is a definitive pre-execution failure,
            // not UNKNOWN; report it so the Host does not strand IN_FLIGHT work.
            _ = try await client.submitActionResult(
                taskID: dispatch.taskID,
                actionID: dispatch.actionID,
                attemptID: dispatch.attemptID,
                success: false,
                output: [:],
                error: "unsupported iPhone capability: \(dispatch.actionType)"
            )
            return .unsupportedCapability(dispatch.actionType)
        }

        if dispatch.reconciliationOnly == true,
           await journal.entry(attemptID: dispatch.attemptID) == nil {
            return .needsReconciliation(attemptID: dispatch.attemptID, reason: "缺少本机执行记录，需要核对原操作")
        }
        let decision = try await journal.prepare(dispatch)
        switch decision {
        case .execute:
            if dispatch.reconciliationOnly == true {
                // The Host has stopped this task. Even a locally received but
                // unstarted dispatch cannot cross the side-effect boundary.
                return .needsReconciliation(attemptID: dispatch.attemptID, reason: "任务已停止，原操作尚未执行")
            }
            return try await executeFresh(
                dispatch,
                executor: executor
            )

        case let .reconcile(entry):
            let reconciled: DeviceReconciliationResult
            do {
                reconciled = try await executor.reconcile(
                    dispatch,
                    journalEntry: entry
                )
            } catch {
                return .needsReconciliation(
                    attemptID: dispatch.attemptID,
                    reason: String(describing: error)
                )
            }

            switch reconciled {
            case let .completed(result):
                _ = try await journal.recordResult(
                    attemptID: dispatch.attemptID,
                    success: result.success,
                    result: result.output,
                    error: result.error,
                    nativeCorrelationID: result.nativeCorrelationID
                )
                try await deliverDurableResult(
                    dispatch: dispatch,
                    result: result
                )
                return .completed(attemptID: dispatch.attemptID)

            case .definitelyNotStarted:
                if dispatch.reconciliationOnly == true {
                    return .needsReconciliation(attemptID: dispatch.attemptID, reason: "原操作未完成，保持停止状态")
                }
                _ = try await journal.markDefinitelyNotStarted(
                    attemptID: dispatch.attemptID
                )
                return try await executeFresh(
                    dispatch,
                    executor: executor
                )

            case let .stillUnknown(reason):
                return .needsReconciliation(
                    attemptID: dispatch.attemptID,
                    reason: reason
                )
            }

        case let .replayResult(entry):
            guard let success = entry.success, let result = entry.result else {
                throw DeviceActionJournalError.invalidTransition
            }
            let durable = DeviceExecutionResult(
                success: success,
                output: result,
                error: entry.error,
                nativeCorrelationID: entry.nativeCorrelationID
            )
            try await deliverDurableResult(
                dispatch: dispatch,
                result: durable
            )
            return .resultReplayed(attemptID: dispatch.attemptID)
        }
    }

    private func executeFresh(
        _ dispatch: DeviceActionDispatch,
        executor: any DeviceCapabilityExecutor
    ) async throws -> DeviceExecutionCoordinatorOutcome {
        do {
            if let failure = try await executor.preflight(dispatch) {
                guard failure.success == false else {
                    throw DeviceActionJournalError.invalidTransition
                }
                _ = try await journal.recordPreflightFailure(
                    attemptID: dispatch.attemptID,
                    error: failure.error ?? "device preflight failed",
                    result: failure.output
                )
                try await deliverDurableResult(dispatch: dispatch, result: failure)
                return .completed(attemptID: dispatch.attemptID)
            }
        } catch let journalError as DeviceActionJournalError {
            throw journalError
        } catch {
            let failure = DeviceExecutionResult.failure(
                "device preflight failed: \(String(describing: error))"
            )
            _ = try await journal.recordPreflightFailure(
                attemptID: dispatch.attemptID,
                error: failure.error ?? "device preflight failed"
            )
            try await deliverDurableResult(dispatch: dispatch, result: failure)
            return .completed(attemptID: dispatch.attemptID)
        }

        _ = try await journal.markMayHaveStarted(attemptID: dispatch.attemptID)
        let result: DeviceExecutionResult
        do {
            result = try await executor.execute(dispatch)
        } catch {
            // Once mayHaveStarted is durable, an arbitrary thrown error is not
            // proof that the side effect failed. Leave the journal ambiguous so
            // the next execution window must call reconcile instead of retrying.
            return .needsReconciliation(
                attemptID: dispatch.attemptID,
                reason: String(describing: error)
            )
        }

        _ = try await journal.recordResult(
            attemptID: dispatch.attemptID,
            success: result.success,
            result: result.output,
            error: result.error,
            nativeCorrelationID: result.nativeCorrelationID
        )
        try await deliverDurableResult(dispatch: dispatch, result: result)
        return .completed(attemptID: dispatch.attemptID)
    }

    private func deliverDurableResult(
        dispatch: DeviceActionDispatch,
        result: DeviceExecutionResult
    ) async throws {
        _ = try await client.submitActionResult(
            taskID: dispatch.taskID,
            actionID: dispatch.actionID,
            attemptID: dispatch.attemptID,
            success: result.success,
            output: result.output,
            error: result.error
        )
        _ = try await journal.markResultDelivered(attemptID: dispatch.attemptID)
    }
}
