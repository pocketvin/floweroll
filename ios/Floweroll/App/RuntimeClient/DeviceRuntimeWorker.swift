import Foundation
import OSLog


struct DeviceRuntimeWorkerReport: Sendable, Equatable {
    let processedTaskIDs: [String]
    let changedTaskIDs: [String]
    let reconciliationTaskIDs: [String]
    let busyTaskIDs: [String]
}

actor DeviceRuntimeWorker {
    static let shared: DeviceRuntimeWorker? = {
        do {
            return DeviceRuntimeWorker(
                journal: try DeviceActionJournal(),
                executors: productionExecutors(notifyStore: NotifyUserAcceptanceStore.shared)
            )
        } catch {
            return nil
        }
    }()

    private static let logger = Logger(
        subsystem: "com.maxenceyu.floweroll",
        category: "DeviceRuntimeWorker"
    )

    private let journal: DeviceActionJournal
    private let executors: [any DeviceCapabilityExecutor]
    private var tasksInProgress = Set<String>()

    func isProcessing(taskID: String) -> Bool {
        tasksInProgress.contains(taskID)
    }

    init(
        journal: DeviceActionJournal,
        executors: [any DeviceCapabilityExecutor]
    ) {
        self.journal = journal
        self.executors = executors
    }

    private static func productionExecutors(
        notifyStore: NotifyUserAcceptanceStore?
    ) -> [any DeviceCapabilityExecutor] {
        let alarmNativeStore = SystemAlarmNativeStore()
        let alarmOwnershipStore = AlarmOwnershipStore.shared
        return [
            DeviceProbeExecutor(),
            LocationCurrentExecutor(),
            // Each executor owns its long-lived EventKit store. A single
            // non-Sendable EKEventStore must not be transferred into multiple
            // actor executors under Swift 6 strict concurrency.
            ReminderCreateExecutor(),
            ReminderQueryExecutor(),
            ReminderSetCompletionExecutor(),
            ReminderUpdateExecutor(),
            ReminderRemoveExecutor(),
            ContactsQueryExecutor(),
            ContactsCreateExecutor(),
            ContactsUpdateExecutor(),
            AlarmQueryExecutor(
                nativeStore: alarmNativeStore,
                ownershipStore: alarmOwnershipStore
            ),
            AlarmCreateExecutor(
                nativeStore: alarmNativeStore,
                ownershipStore: alarmOwnershipStore
            ),
            AlarmUpdateExecutor(
                nativeStore: alarmNativeStore,
                ownershipStore: alarmOwnershipStore
            ),
            AlarmPauseExecutor(
                nativeStore: alarmNativeStore,
                ownershipStore: alarmOwnershipStore
            ),
            AlarmResumeExecutor(
                nativeStore: alarmNativeStore,
                ownershipStore: alarmOwnershipStore
            ),
            AlarmCancelExecutor(
                nativeStore: alarmNativeStore,
                ownershipStore: alarmOwnershipStore
            ),
            AlarmReadExecutor(
                nativeStore: alarmNativeStore,
                ownershipStore: alarmOwnershipStore
            ),
            CalendarFreeBusyExecutor(),
            CalendarQueryExecutor(),
            CalendarUpdateExecutor(),
            CalendarRemoveExecutor(),
            CalendarCreateExecutor(),
            NotifyUserExecutor(acceptanceStore: notifyStore),
        ]
    }

    func supportsCapability(_ capabilityID: String) -> Bool {
        executors.contains { $0.capabilityID == capabilityID }
    }

    /// Execute one exact Task immediately. This is used by the foreground SSE
    /// wake path so a newly-planned iPhone Action does not wait for the next
    /// Task Index refresh. The actor still serializes device execution.
    func processTask(
        client: FlowerollHostClient,
        taskID: String,
        waitSeconds: Int = 0
    ) async -> DeviceRuntimeWorkerReport {
        guard tasksInProgress.insert(taskID).inserted else {
            return DeviceRuntimeWorkerReport(
                processedTaskIDs: [],
                changedTaskIDs: [],
                reconciliationTaskIDs: [],
                busyTaskIDs: [taskID]
            )
        }
        defer { tasksInProgress.remove(taskID) }

        Self.logger.notice("checking device action; task=\(String(taskID.prefix(8)), privacy: .public)")
        let coordinator = DeviceExecutionCoordinator(
            client: client,
            journal: journal,
            executors: executors
        )
        do {
            let result = try await coordinator.processNext(
                taskID: taskID,
                waitSeconds: waitSeconds
            )
            Self.logger.notice("device action result; task=\(String(taskID.prefix(8)), privacy: .public) result=\(String(describing: result), privacy: .public)")
            switch result {
            case .noAction:
                return DeviceRuntimeWorkerReport(
                    processedTaskIDs: [taskID],
                    changedTaskIDs: [],
                    reconciliationTaskIDs: [],
                    busyTaskIDs: []
                )
            case .completed, .resultReplayed, .unsupportedCapability:
                return DeviceRuntimeWorkerReport(
                    processedTaskIDs: [taskID],
                    changedTaskIDs: [taskID],
                    reconciliationTaskIDs: [],
                    busyTaskIDs: []
                )
            case .needsReconciliation:
                return DeviceRuntimeWorkerReport(
                    processedTaskIDs: [taskID],
                    changedTaskIDs: [],
                    reconciliationTaskIDs: [taskID],
                    busyTaskIDs: []
                )
            }
        } catch {
            Self.logger.error("device action failed; task=\(String(taskID.prefix(8)), privacy: .public) error_type=\(String(reflecting: type(of: error)), privacy: .public)")
            // Transport loss must not erase device journal evidence. A later
            // execution window will replay/reconcile the exact Attempt.
            return DeviceRuntimeWorkerReport(
                processedTaskIDs: [taskID],
                changedTaskIDs: [],
                reconciliationTaskIDs: [taskID],
                busyTaskIDs: []
            )
        }
    }

    /// Use one bounded iOS execution window to advance at most one device
    /// Action per Task. Task lifecycle remains Host-owned; this worker only
    /// executes Host-issued iOS Attempts and reports exact results.
    func processOnePass(
        client: FlowerollHostClient,
        tasks: [HostTaskIndexItem]
    ) async -> DeviceRuntimeWorkerReport {
        var processed: [String] = []
        var changed: [String] = []
        var reconciliation: [String] = []
        var busy: [String] = []

        Self.logger.notice("device pass started; tasks=\(tasks.count, privacy: .public)")
        for task in tasks {
            guard !Task.isCancelled else { break }
            let report = await processTask(client: client, taskID: task.taskID)
            processed.append(contentsOf: report.processedTaskIDs)
            changed.append(contentsOf: report.changedTaskIDs)
            reconciliation.append(contentsOf: report.reconciliationTaskIDs)
            busy.append(contentsOf: report.busyTaskIDs)
        }

        return DeviceRuntimeWorkerReport(
            processedTaskIDs: processed,
            changedTaskIDs: changed,
            reconciliationTaskIDs: reconciliation,
            busyTaskIDs: busy
        )
    }
}
