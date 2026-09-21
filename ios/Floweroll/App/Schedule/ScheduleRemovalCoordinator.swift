import CryptoKit
import Foundation
import Observation
import SwiftUI



struct ScheduleHubRemovedItemRecord: Codable, Equatable, Sendable {
    let sourceKindRaw: String
    let sourceObjectID: String
    let title: String
    let startAt: Date?
    let endAt: Date?
    let isAllDay: Bool
    let recurrenceDescription: String?
    let sourceContext: String?
    let removedAt: Date

    var stableIdentity: String { "\(sourceKindRaw):\(sourceObjectID)" }

    init(item: ScheduleItem, removedAt: Date) {
        sourceKindRaw = item.sourceKind.rawValue
        sourceObjectID = item.sourceObjectID
        title = item.title
        startAt = item.startAt
        endAt = item.endAt
        isAllDay = item.isAllDay
        recurrenceDescription = item.recurrenceDescription
        sourceContext = item.sourceContext
        self.removedAt = removedAt
    }

    init?(
        journalEntry: DeviceActionJournalEntry,
        result: [String: JSONValue]
    ) {
        guard journalEntry.success == true,
              result["deleted"]?.boolValue == true,
              result["verified"]?.boolValue == true,
              let title = result["title"]?.stringValue else { return nil }
        if let reminderID = result["requested_reminder_id"]?.stringValue {
            sourceKindRaw = ScheduleSourceKind.reminder.rawValue
            sourceObjectID = reminderID
        } else if let eventID = result["requested_event_id"]?.stringValue {
            sourceKindRaw = ScheduleSourceKind.calendar.rawValue
            sourceObjectID = eventID
        } else {
            return nil
        }
        self.title = title.isEmpty ? "无标题" : title
        startAt = nil
        endAt = nil
        isAllDay = false
        recurrenceDescription = nil
        sourceContext = "已从系统移除"
        removedAt = journalEntry.updatedAt
    }

    func scheduleItem() -> ScheduleItem? {
        guard let kind = ScheduleSourceKind(rawValue: sourceKindRaw) else { return nil }
        let target: ScheduleNavigationTarget
        switch kind {
        case .calendar:
            target = .calendar(sourceObjectID)
        case .reminder:
            target = .reminder(sourceObjectID)
        case .alarm, .other:
            target = .readOnly(sourceObjectID)
        }
        return ScheduleItem(
            sourceKind: kind,
            sourceObjectID: sourceObjectID,
            title: title,
            startAt: startAt,
            endAt: endAt,
            isAllDay: isAllDay,
            recurrenceDescription: recurrenceDescription,
            status: .removed,
            sourceExists: false,
            navigationTarget: target,
            taskCorrelation: nil,
            explicitLineageID: nil,
            truthStrength: .management,
            observedAt: removedAt,
            sourceContext: sourceContext,
            removal: nil
        )
    }
}


struct ScheduleHubRemovalHistoryStore: Sendable {
    private struct Snapshot: Codable {
        let records: [ScheduleHubRemovedItemRecord]
    }

    private struct JournalSnapshot: Codable {
        let entries: [DeviceActionJournalEntry]
    }

    private let fileURL: URL
    private let journalURL: URL?

    init(fileURL: URL? = nil, journalURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            self.journalURL = journalURL
            return
        }
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let directory = base
            .appendingPathComponent("Floweroll", isDirectory: true)
            .appendingPathComponent("ScheduleHubRemovals", isDirectory: true)
        self.fileURL = directory.appendingPathComponent("removed-items.json")
        self.journalURL = directory.appendingPathComponent("device-action-journal.json")
    }

    func load() -> [String: ScheduleHubRemovedItemRecord] {
        var values: [String: ScheduleHubRemovedItemRecord] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let snapshot = try? JSONDecoder.floweroll.decode(Snapshot.self, from: data) {
            for record in snapshot.records {
                values[record.stableIdentity] = record
            }
        }

        if let journalURL,
           let data = try? Data(contentsOf: journalURL),
           let snapshot = try? JSONDecoder.floweroll.decode(JournalSnapshot.self, from: data) {
            for entry in snapshot.entries {
                guard let result = entry.result,
                      let record = ScheduleHubRemovedItemRecord(journalEntry: entry, result: result)
                else { continue }
                if let existing = values[record.stableIdentity], existing.removedAt >= record.removedAt {
                    continue
                }
                values[record.stableIdentity] = record
            }
        }
        return Self.bounded(values)
    }

    func save(_ values: [String: ScheduleHubRemovedItemRecord]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let records = Self.bounded(values).values.sorted {
            if $0.removedAt == $1.removedAt { return $0.stableIdentity < $1.stableIdentity }
            return $0.removedAt > $1.removedAt
        }
        let data = try JSONEncoder.floweroll.encode(Snapshot(records: records))
        try data.write(to: fileURL, options: .atomic)
    }

    private static func bounded(
        _ values: [String: ScheduleHubRemovedItemRecord]
    ) -> [String: ScheduleHubRemovedItemRecord] {
        let records = values.values.sorted {
            if $0.removedAt == $1.removedAt { return $0.stableIdentity < $1.stableIdentity }
            return $0.removedAt > $1.removedAt
        }
        return Dictionary(uniqueKeysWithValues: records.prefix(200).map { ($0.stableIdentity, $0) })
    }
}


actor ScheduleHubRemovalCoordinator {
    private let journal: DeviceActionJournal
    private let executors: [String: any DeviceCapabilityExecutor]

    init(
        journal: DeviceActionJournal,
        executors: [any DeviceCapabilityExecutor]
    ) {
        self.journal = journal
        self.executors = Dictionary(uniqueKeysWithValues: executors.map { ($0.capabilityID, $0) })
    }

    static func makeDefault(for sourceKind: ScheduleSourceKind) throws -> ScheduleHubRemovalCoordinator {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("Floweroll", isDirectory: true)
            .appendingPathComponent("ScheduleHubRemovals", isDirectory: true)
        let journal = try DeviceActionJournal(directoryURL: directory)
        let executor: any DeviceCapabilityExecutor
        switch sourceKind {
        case .calendar:
            executor = CalendarRemoveExecutor()
        case .reminder:
            executor = ReminderRemoveExecutor()
        case .alarm, .other:
            throw ScheduleHubRemovalConfigurationError.unsupportedSource
        }
        return ScheduleHubRemovalCoordinator(journal: journal, executors: [executor])
    }

    func remove(_ descriptor: ScheduleRemovalDescriptor) async throws -> ScheduleHubRemovalOutcome {
        guard descriptor.eligible else {
            return .failed(descriptor.ineligibleReason ?? "这个安排当前不能安全移除。")
        }
        guard let actionType = descriptor.actionType,
              let dispatch = descriptor.dispatch,
              let executor = executors[actionType] else {
            return .failed("这个安排当前没有可用的原生移除能力。")
        }

        if let existing = await journal.entry(attemptID: dispatch.attemptID),
           existing.state != .received {
            return try await resume(dispatch, executor: executor)
        }

        if let failure = try await executor.preflight(dispatch) {
            return .failed(failure.error ?? "移除前检查失败。")
        }

        let decision = try await journal.prepare(dispatch)
        switch decision {
        case .execute:
            return try await executeFresh(dispatch, executor: executor)
        case .reconcile, .replayResult:
            return try await resume(dispatch, executor: executor)
        }
    }

    private func resume(
        _ dispatch: DeviceActionDispatch,
        executor: any DeviceCapabilityExecutor
    ) async throws -> ScheduleHubRemovalOutcome {
        switch try await journal.prepare(dispatch) {
        case .execute:
            return try await executeFresh(dispatch, executor: executor)

        case let .reconcile(entry):
            let reconciled: DeviceReconciliationResult
            do {
                reconciled = try await executor.reconcile(dispatch, journalEntry: entry)
            } catch {
                return .needsReconciliation("移除结果暂时无法确认；小卷不会自动再次删除。")
            }
            switch reconciled {
            case let .completed(result):
                if result.success {
                    _ = try await journal.recordResult(
                        attemptID: dispatch.attemptID,
                        success: true,
                        result: result.output,
                        error: nil,
                        nativeCorrelationID: result.nativeCorrelationID
                    )
                    _ = try await journal.markResultDelivered(attemptID: dispatch.attemptID)
                    return .removed
                }
                _ = try await journal.markDefinitelyNotStarted(attemptID: dispatch.attemptID)
                return .failed(result.error ?? "移除失败。")

            case .definitelyNotStarted:
                _ = try await journal.markDefinitelyNotStarted(attemptID: dispatch.attemptID)
                return .failed("上一次移除已确认没有开始。请刷新后再试。")

            case .resumeAuthorizedOperation:
                // A settings deletion cannot take over another capability's
                // partly executed transaction or silently repeat a deletion.
                return .needsReconciliation("移除结果需要核对；不会自动再次删除。")

            case let .stillUnknown(reason):
                return .needsReconciliation(
                    reason ?? "移除结果暂时无法确认；小卷不会自动再次删除。"
                )
            }

        case let .replayResult(entry):
            if entry.success == true,
               entry.result?["deleted"]?.boolValue == true,
               entry.result?["verified"]?.boolValue == true {
                return .removed
            }
            return .failed(entry.error ?? "上一次移除没有完成。")
        }
    }

    private func executeFresh(
        _ dispatch: DeviceActionDispatch,
        executor: any DeviceCapabilityExecutor
    ) async throws -> ScheduleHubRemovalOutcome {
        _ = try await journal.markMayHaveStarted(attemptID: dispatch.attemptID)
        let result: DeviceExecutionResult
        do {
            result = try await executor.execute(dispatch)
        } catch {
            return .needsReconciliation("移除结果暂时无法确认；小卷不会自动再次删除。")
        }

        guard result.success else {
            _ = try await journal.markDefinitelyNotStarted(attemptID: dispatch.attemptID)
            return .failed(result.error ?? "移除失败。")
        }

        _ = try await journal.recordResult(
            attemptID: dispatch.attemptID,
            success: true,
            result: result.output,
            error: nil,
            nativeCorrelationID: result.nativeCorrelationID
        )
        _ = try await journal.markResultDelivered(attemptID: dispatch.attemptID)
        return .removed
    }
}
