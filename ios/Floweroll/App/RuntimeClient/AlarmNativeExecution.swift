import AlarmKit
import ActivityKit
import CryptoKit
import Foundation
import SwiftUI


enum AlarmAuthorizationStatus: String, Codable, Equatable, Sendable {
    case notDetermined = "not_determined"
    case denied
    case authorized
    case unknown
}


enum AlarmWeekday: String, Codable, CaseIterable, Equatable, Sendable {
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
    case sunday

    var localeWeekday: Locale.Weekday {
        switch self {
        case .monday: return .monday
        case .tuesday: return .tuesday
        case .wednesday: return .wednesday
        case .thursday: return .thursday
        case .friday: return .friday
        case .saturday: return .saturday
        case .sunday: return .sunday
        }
    }

    init?(_ weekday: Locale.Weekday) {
        switch weekday {
        case .monday: self = .monday
        case .tuesday: self = .tuesday
        case .wednesday: self = .wednesday
        case .thursday: self = .thursday
        case .friday: self = .friday
        case .saturday: self = .saturday
        case .sunday: self = .sunday
        @unknown default: return nil
        }
    }
}


enum AlarmScheduleKind: String, Codable, Equatable, Sendable {
    case fixed
    case weekly
}


enum AlarmSoundChoice: String, Codable, CaseIterable, Equatable, Sendable {
    // Floweroll currently ships no AlarmKit-specific custom audio resource.
    // Keep this contract bounded rather than accepting an unresolved filename.
    case defaultSound = "default"

    var alertSound: AlertConfiguration.AlertSound {
        switch self {
        case .defaultSound: return .default
        }
    }
}


struct AlarmDesiredSchedule: Codable, Equatable, Sendable {
    let kind: AlarmScheduleKind
    let fireDate: Date?
    let hour: Int?
    let minute: Int?
    let weekdays: [AlarmWeekday]?

    static func fixed(_ date: Date) -> AlarmDesiredSchedule {
        AlarmDesiredSchedule(
            kind: .fixed,
            fireDate: date,
            hour: nil,
            minute: nil,
            weekdays: nil
        )
    }

    static func weekly(
        hour: Int,
        minute: Int,
        weekdays: [AlarmWeekday]
    ) -> AlarmDesiredSchedule {
        AlarmDesiredSchedule(
            kind: .weekly,
            fireDate: nil,
            hour: hour,
            minute: minute,
            weekdays: weekdays.sorted(by: Self.weekdayOrder)
        )
    }

    var isValid: Bool {
        switch kind {
        case .fixed:
            return fireDate != nil && hour == nil && minute == nil && weekdays == nil
        case .weekly:
            guard fireDate == nil,
                  let hour, (0...23).contains(hour),
                  let minute, (0...59).contains(minute),
                  let weekdays, !weekdays.isEmpty, weekdays.count <= 7
            else { return false }
            return Set(weekdays).count == weekdays.count
        }
    }

    func matches(_ native: AlarmNativeSchedule?) -> Bool {
        switch (kind, native) {
        case let (.fixed, .fixed(nativeDate)):
            guard let fireDate else { return false }
            return abs(nativeDate.timeIntervalSince(fireDate)) < 1.0
        case let (.weekly, .weekly(nativeHour, nativeMinute, nativeWeekdays)):
            guard let hour, let minute, let weekdays else { return false }
            return hour == nativeHour
                && minute == nativeMinute
                && Set(weekdays) == Set(nativeWeekdays)
        default:
            return false
        }
    }

    func isSemanticallyEquivalent(to other: AlarmDesiredSchedule) -> Bool {
        switch (kind, other.kind) {
        case (.fixed, .fixed):
            guard let fireDate, let otherFireDate = other.fireDate else { return false }
            return abs(fireDate.timeIntervalSince(otherFireDate)) < 1.0
        case (.weekly, .weekly):
            guard let hour,
                  let minute,
                  let weekdays,
                  let otherHour = other.hour,
                  let otherMinute = other.minute,
                  let otherWeekdays = other.weekdays
            else { return false }
            return hour == otherHour
                && minute == otherMinute
                && Set(weekdays) == Set(otherWeekdays)
        default:
            return false
        }
    }

    var jsonValue: JSONValue {
        switch kind {
        case .fixed:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return .object([
                "kind": .string(kind.rawValue),
                "fire_at": .string(fireDate.map(formatter.string(from:)) ?? ""),
                "timezone_semantics": .string("absolute_instant"),
            ])
        case .weekly:
            return .object([
                "kind": .string(kind.rawValue),
                "hour": .number(Double(hour ?? -1)),
                "minute": .number(Double(minute ?? -1)),
                "weekdays": .array((weekdays ?? []).map { .string($0.rawValue) }),
                "timezone_semantics": .string("device_current_timezone"),
            ])
        }
    }

    private static func weekdayOrder(_ lhs: AlarmWeekday, _ rhs: AlarmWeekday) -> Bool {
        guard let left = AlarmWeekday.allCases.firstIndex(of: lhs),
              let right = AlarmWeekday.allCases.firstIndex(of: rhs)
        else { return lhs.rawValue < rhs.rawValue }
        return left < right
    }
}


enum AlarmNativeSchedule: Equatable, Sendable {
    case fixed(Date)
    case weekly(hour: Int, minute: Int, weekdays: [AlarmWeekday])
    case relativeOnce(hour: Int, minute: Int)
    case unsupported
}


enum AlarmNativeState: String, Codable, Equatable, Sendable {
    case scheduled
    case countdown
    case paused
    case alerting
    case unknown
}


struct AlarmNativeRecord: Equatable, Sendable {
    let id: UUID
    let schedule: AlarmNativeSchedule?
    let state: AlarmNativeState
}


enum AlarmNativeStoreError: Error, Equatable, Sendable {
    case maximumLimitReached
    case unsupportedSchedule
    case nativeFailure(String)
}


struct AlarmNativeScheduleRequest: Equatable, Sendable {
    let id: UUID
    let title: String
    let taskID: String
    let actionID: String
    let idempotencyKey: String
    let schedule: AlarmDesiredSchedule
    let sound: AlarmSoundChoice
}


protocol AlarmNativeStore: Sendable {
    func authorizationStatus() async -> AlarmAuthorizationStatus
    func alarms() async throws -> [AlarmNativeRecord]
    func schedule(_ request: AlarmNativeScheduleRequest) async throws -> AlarmNativeRecord
    func cancel(id: UUID) async throws
    func pause(id: UUID) async throws
    func resume(id: UUID) async throws
    nonisolated func alarmUpdates() -> AsyncStream<[AlarmNativeRecord]>
}


actor SystemAlarmNativeStore: AlarmNativeStore {
    func authorizationStatus() async -> AlarmAuthorizationStatus {
        await AlarmSystemBridge.authorizationStatus()
    }

    func alarms() async throws -> [AlarmNativeRecord] {
        try await AlarmSystemBridge.alarms()
    }

    func schedule(_ request: AlarmNativeScheduleRequest) async throws -> AlarmNativeRecord {
        try await AlarmSystemBridge.schedule(request)
    }

    func cancel(id: UUID) async throws {
        try await AlarmSystemBridge.cancel(id: id)
    }

    func pause(id: UUID) async throws {
        try await AlarmSystemBridge.pause(id: id)
    }

    func resume(id: UUID) async throws {
        try await AlarmSystemBridge.resume(id: id)
    }

    nonisolated func alarmUpdates() -> AsyncStream<[AlarmNativeRecord]> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                for await alarms in AlarmManager.shared.alarmUpdates {
                    guard !Task.isCancelled else { break }
                    continuation.yield(alarms.map(AlarmSystemBridge.nativeRecord))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}


private struct FlowerollAlarmMetadata: AlarmMetadata {
    let title: String
    let taskID: String
    let actionID: String
    let idempotencyKey: String
}


@MainActor
private enum AlarmSystemBridge {
    static func authorizationStatus() -> AlarmAuthorizationStatus {
        switch AlarmManager.shared.authorizationState {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .unknown
        }
    }

    static func alarms() throws -> [AlarmNativeRecord] {
        do {
            return try AlarmManager.shared.alarms.map(nativeRecord)
        } catch {
            throw AlarmNativeStoreError.nativeFailure(String(describing: error))
        }
    }

    static func schedule(_ request: AlarmNativeScheduleRequest) async throws -> AlarmNativeRecord {
        let titleResource = LocalizedStringResource(String.LocalizationValue(request.title))
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: titleResource)
        } else {
            let stopButton = AlarmButton(
                text: "停止",
                textColor: .white,
                systemImageName: "stop.fill"
            )
            alert = AlarmPresentation.Alert(
                title: titleResource,
                stopButton: stopButton
            )
        }
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alert),
            metadata: FlowerollAlarmMetadata(
                title: request.title,
                taskID: request.taskID,
                actionID: request.actionID,
                idempotencyKey: request.idempotencyKey
            ),
            tintColor: .blue
        )
        let nativeSchedule = try schedule(request.schedule)
        let configuration = AlarmManager.AlarmConfiguration<FlowerollAlarmMetadata>.alarm(
            schedule: nativeSchedule,
            attributes: attributes,
            sound: request.sound.alertSound
        )
        do {
            return nativeRecord(
                try await AlarmManager.shared.schedule(
                    id: request.id,
                    configuration: configuration
                )
            )
        } catch let error as AlarmManager.AlarmError where error == .maximumLimitReached {
            throw AlarmNativeStoreError.maximumLimitReached
        } catch {
            throw AlarmNativeStoreError.nativeFailure(String(describing: error))
        }
    }

    static func cancel(id: UUID) throws {
        do {
            try AlarmManager.shared.cancel(id: id)
        } catch {
            throw AlarmNativeStoreError.nativeFailure(String(describing: error))
        }
    }

    static func pause(id: UUID) throws {
        do {
            try AlarmManager.shared.pause(id: id)
        } catch {
            throw AlarmNativeStoreError.nativeFailure(String(describing: error))
        }
    }

    static func resume(id: UUID) throws {
        do {
            try AlarmManager.shared.resume(id: id)
        } catch {
            throw AlarmNativeStoreError.nativeFailure(String(describing: error))
        }
    }

    private static func schedule(_ desired: AlarmDesiredSchedule) throws -> Alarm.Schedule {
        switch desired.kind {
        case .fixed:
            guard desired.isValid, let fireDate = desired.fireDate else {
                throw AlarmNativeStoreError.unsupportedSchedule
            }
            return .fixed(fireDate)
        case .weekly:
            guard desired.isValid,
                  let hour = desired.hour,
                  let minute = desired.minute,
                  let weekdays = desired.weekdays
            else {
                throw AlarmNativeStoreError.unsupportedSchedule
            }
            return .relative(
                .init(
                    time: .init(hour: hour, minute: minute),
                    repeats: .weekly(weekdays.map(\.localeWeekday))
                )
            )
        }
    }

    static func nativeRecord(_ alarm: Alarm) -> AlarmNativeRecord {
        AlarmNativeRecord(
            id: alarm.id,
            schedule: alarm.schedule.map(nativeSchedule),
            state: nativeState(alarm.state)
        )
    }

    private static func nativeSchedule(_ schedule: Alarm.Schedule) -> AlarmNativeSchedule {
        switch schedule {
        case let .fixed(date):
            return .fixed(date)
        case let .relative(relative):
            switch relative.repeats {
            case .never:
                return .relativeOnce(
                    hour: relative.time.hour,
                    minute: relative.time.minute
                )
            case let .weekly(days):
                let mapped = days.compactMap(AlarmWeekday.init)
                guard mapped.count == days.count else { return .unsupported }
                return .weekly(
                    hour: relative.time.hour,
                    minute: relative.time.minute,
                    weekdays: mapped.sorted {
                        AlarmWeekday.allCases.firstIndex(of: $0) ?? 0
                            < AlarmWeekday.allCases.firstIndex(of: $1) ?? 0
                    }
                )
            @unknown default:
                return .unsupported
            }
        @unknown default:
            return .unsupported
        }
    }

    private static func nativeState(_ state: Alarm.State) -> AlarmNativeState {
        switch state {
        case .scheduled: return .scheduled
        case .countdown: return .countdown
        case .paused: return .paused
        case .alerting: return .alerting
        @unknown default: return .unknown
        }
    }
}


enum AlarmOwnershipLifecycle: String, Codable, Equatable, Sendable {
    case accepted
    case missing
    case cancelled
}


enum AlarmSettingsMutationOperation: String, Codable, Equatable, Sendable {
    case update
    case cancel
    case pause
    case resume
}


enum AlarmSettingsMutationIntentState: String, Codable, Equatable, Sendable {
    case pending
    case ambiguous
}


enum AlarmSettingsMutationResolution: String, Codable, Equatable, Sendable {
    case failed
    case completed
    case definitelyNotStarted = "definitely_not_started"
}


enum AlarmReplacementPhase: String, Codable, Equatable, Sendable {
    case removingOriginal
    case schedulingReplacement
    case restoringOriginal
}

struct AlarmSettingsMutationIntent: Codable, Equatable, Sendable {
    let mutationID: String
    let operation: AlarmSettingsMutationOperation
    let alarmID: UUID
    let createdAt: Date
    let beforeTitle: String
    let beforeSchedule: AlarmDesiredSchedule
    let beforeSound: AlarmSoundChoice
    let beforeNativeState: AlarmNativeState?
    let requestedTitle: String?
    let requestedSchedule: AlarmDesiredSchedule?
    let requestedSound: AlarmSoundChoice?
    var state: AlarmSettingsMutationIntentState
    var lastObservedNativeState: AlarmNativeState?
    var lastObservedAt: Date?
    var detail: String?
    // Optional for compatibility with installed pre-transaction ledgers.
    var replacementPhase: AlarmReplacementPhase? = nil
    var replacementAttempts: Int? = nil
}


struct AlarmSettingsMutationOutcome: Codable, Equatable, Sendable {
    let mutationID: String
    let operation: AlarmSettingsMutationOperation
    let resolution: AlarmSettingsMutationResolution
    let resolvedAt: Date
    let detail: String?
}


struct AlarmOwnershipRecord: Codable, Equatable, Sendable {
    let alarmID: UUID
    let taskID: String
    let actionID: String
    let idempotencyKey: String
    var title: String
    var schedule: AlarmDesiredSchedule
    var sound: AlarmSoundChoice?
    let acceptedAt: Date
    var lifecycle: AlarmOwnershipLifecycle
    var lastNativeState: AlarmNativeState?
    var lastObservedAt: Date
    var lastMutationAt: Date?
    var lastMutationTaskID: String?
    var lastMutationActionID: String?
    var cancelledAt: Date?
    var cancelledByActionID: String?
    var pendingSettingsMutation: AlarmSettingsMutationIntent?
    var lastSettingsMutationOutcome: AlarmSettingsMutationOutcome?

    var effectiveSound: AlarmSoundChoice { sound ?? .defaultSound }
}


enum AlarmOwnershipStoreError: Error, Equatable, Sendable {
    case identityConflict
    case unknownAlarm
    case settingsMutationAlreadyPending
    case settingsMutationIdentityConflict
    case recordNotRemovable
}


actor AlarmOwnershipStore {
    private struct Snapshot: Codable {
        var records: [AlarmOwnershipRecord]
    }

    static let shared: AlarmOwnershipStore? = try? AlarmOwnershipStore()

    private let fileURL: URL
    private var records: [UUID: AlarmOwnershipRecord]

    init(directoryURL: URL? = nil) throws {
        let directory = try directoryURL ?? Self.defaultDirectoryURL()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        fileURL = directory.appendingPathComponent("alarm-ownership.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder.floweroll.decode(Snapshot.self, from: data)
            records = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.alarmID, $0) })
        } else {
            records = [:]
        }
    }

    func record(alarmID: UUID) -> AlarmOwnershipRecord? {
        records[alarmID]
    }

    func allRecords() -> [AlarmOwnershipRecord] {
        records.values.sorted { $0.alarmID.uuidString < $1.alarmID.uuidString }
    }

    @discardableResult
    func recordAccepted(
        alarmID: UUID,
        dispatch: DeviceActionDispatch,
        title: String,
        schedule: AlarmDesiredSchedule,
        sound: AlarmSoundChoice = .defaultSound,
        nativeState: AlarmNativeState?,
        acceptedAt: Date = Date()
    ) throws -> AlarmOwnershipRecord {
        if var existing = records[alarmID] {
            guard existing.taskID == dispatch.taskID,
                  existing.actionID == dispatch.actionID,
                  existing.idempotencyKey == dispatch.idempotencyKey,
                  existing.title == title,
                  existing.schedule.isSemanticallyEquivalent(to: schedule),
                  existing.effectiveSound == sound
            else {
                throw AlarmOwnershipStoreError.identityConflict
            }
            existing.sound = sound
            existing.lastNativeState = nativeState
            existing.lastObservedAt = acceptedAt
            try commit(existing)
            return existing
        }
        let record = AlarmOwnershipRecord(
            alarmID: alarmID,
            taskID: dispatch.taskID,
            actionID: dispatch.actionID,
            idempotencyKey: dispatch.idempotencyKey,
            title: title,
            schedule: schedule,
            sound: sound,
            acceptedAt: acceptedAt,
            lifecycle: .accepted,
            lastNativeState: nativeState,
            lastObservedAt: acceptedAt,
            lastMutationAt: acceptedAt,
            lastMutationTaskID: dispatch.taskID,
            lastMutationActionID: dispatch.actionID,
            cancelledAt: nil,
            cancelledByActionID: nil,
            pendingSettingsMutation: nil,
            lastSettingsMutationOutcome: nil
        )
        try commit(record)
        return record
    }

    @discardableResult
    func recordUpdated(
        alarmID: UUID,
        taskID: String,
        actionID: String,
        title: String,
        schedule: AlarmDesiredSchedule,
        sound: AlarmSoundChoice,
        nativeState: AlarmNativeState?,
        now: Date = Date()
    ) throws -> AlarmOwnershipRecord {
        guard var record = records[alarmID] else {
            throw AlarmOwnershipStoreError.unknownAlarm
        }
        record.title = title
        record.schedule = schedule
        record.sound = sound
        record.lifecycle = .accepted
        record.lastNativeState = nativeState
        record.lastObservedAt = now
        record.lastMutationAt = now
        record.lastMutationTaskID = taskID
        record.lastMutationActionID = actionID
        record.cancelledAt = nil
        record.cancelledByActionID = nil
        try commit(record)
        return record
    }

    @discardableResult
    func recordObservation(
        alarmID: UUID,
        nativeState: AlarmNativeState?,
        isMissing: Bool,
        now: Date = Date()
    ) throws -> AlarmOwnershipRecord {
        guard var record = records[alarmID] else {
            throw AlarmOwnershipStoreError.unknownAlarm
        }
        record.lastNativeState = nativeState
        record.lastObservedAt = now
        if isMissing, record.lifecycle != .cancelled {
            record.lifecycle = .missing
        } else if !isMissing, record.lifecycle == .missing {
            record.lifecycle = .accepted
        }
        try commit(record)
        return record
    }

    @discardableResult
    func recordNativeState(
        alarmID: UUID,
        taskID: String? = nil,
        actionID: String,
        nativeState: AlarmNativeState,
        now: Date = Date()
    ) throws -> AlarmOwnershipRecord {
        guard var record = records[alarmID] else {
            throw AlarmOwnershipStoreError.unknownAlarm
        }
        record.lifecycle = .accepted
        record.lastNativeState = nativeState
        record.lastObservedAt = now
        record.lastMutationAt = now
        record.lastMutationTaskID = taskID
        record.lastMutationActionID = actionID
        try commit(record)
        return record
    }

    @discardableResult
    func markCancelled(
        alarmID: UUID,
        taskID: String? = nil,
        actionID: String,
        now: Date = Date()
    ) throws -> AlarmOwnershipRecord {
        guard var record = records[alarmID] else {
            throw AlarmOwnershipStoreError.unknownAlarm
        }
        record.lifecycle = .cancelled
        record.lastNativeState = nil
        record.lastObservedAt = now
        record.lastMutationAt = now
        record.lastMutationTaskID = taskID
        record.lastMutationActionID = actionID
        record.cancelledAt = now
        record.cancelledByActionID = actionID
        try commit(record)
        return record
    }

    func removeMissingRecord(alarmID: UUID) throws {
        guard let record = records[alarmID] else {
            throw AlarmOwnershipStoreError.unknownAlarm
        }
        guard record.lifecycle == .missing,
              record.pendingSettingsMutation == nil
        else {
            throw AlarmOwnershipStoreError.recordNotRemovable
        }
        try removeRecord(alarmID: alarmID)
    }

    func pendingSettingsMutations() -> [AlarmSettingsMutationIntent] {
        records.values.compactMap(\.pendingSettingsMutation).sorted {
            if $0.createdAt == $1.createdAt { return $0.mutationID < $1.mutationID }
            return $0.createdAt < $1.createdAt
        }
    }

    @discardableResult
    func beginSettingsMutation(
        alarmID: UUID,
        mutationID: String,
        operation: AlarmSettingsMutationOperation,
        beforeNativeState: AlarmNativeState?,
        requestedTitle: String? = nil,
        requestedSchedule: AlarmDesiredSchedule? = nil,
        requestedSound: AlarmSoundChoice? = nil,
        now: Date = Date()
    ) throws -> AlarmSettingsMutationIntent {
        guard var record = records[alarmID], record.lifecycle != .cancelled else {
            throw AlarmOwnershipStoreError.unknownAlarm
        }
        if let pending = record.pendingSettingsMutation {
            guard pending.mutationID == mutationID else {
                throw AlarmOwnershipStoreError.settingsMutationAlreadyPending
            }
            return pending
        }
        if operation == .update {
            guard requestedTitle != nil, requestedSchedule != nil, requestedSound != nil else {
                throw AlarmOwnershipStoreError.settingsMutationIdentityConflict
            }
        } else if requestedTitle != nil || requestedSchedule != nil || requestedSound != nil {
            throw AlarmOwnershipStoreError.settingsMutationIdentityConflict
        }
        let intent = AlarmSettingsMutationIntent(
            mutationID: mutationID,
            operation: operation,
            alarmID: alarmID,
            createdAt: now,
            beforeTitle: record.title,
            beforeSchedule: record.schedule,
            beforeSound: record.effectiveSound,
            beforeNativeState: beforeNativeState,
            requestedTitle: requestedTitle,
            requestedSchedule: requestedSchedule,
            requestedSound: requestedSound,
            state: .pending,
            lastObservedNativeState: beforeNativeState,
            lastObservedAt: now,
            detail: nil
        )
        record.pendingSettingsMutation = intent
        try commit(record)
        return intent
    }

    @discardableResult
    func markSettingsMutationAmbiguous(
        alarmID: UUID,
        mutationID: String,
        nativeState: AlarmNativeState?,
        detail: String,
        now: Date = Date()
    ) throws -> AlarmSettingsMutationIntent {
        guard var record = records[alarmID],
              var pending = record.pendingSettingsMutation,
              pending.mutationID == mutationID
        else { throw AlarmOwnershipStoreError.settingsMutationIdentityConflict }
        pending.state = .ambiguous
        pending.lastObservedNativeState = nativeState
        pending.lastObservedAt = now
        pending.detail = detail
        record.pendingSettingsMutation = pending
        record.lastObservedAt = now
        record.lastNativeState = nativeState
        try commit(record)
        return pending
    }

    @discardableResult
    func resolveSettingsMutationNotStarted(
        alarmID: UUID,
        mutationID: String,
        nativeState: AlarmNativeState?,
        detail: String? = nil,
        now: Date = Date()
    ) throws -> AlarmOwnershipRecord {
        guard var record = records[alarmID],
              let pending = record.pendingSettingsMutation,
              pending.mutationID == mutationID
        else { throw AlarmOwnershipStoreError.settingsMutationIdentityConflict }
        record.lastObservedAt = now
        record.lastNativeState = nativeState
        record.lastSettingsMutationOutcome = AlarmSettingsMutationOutcome(
            mutationID: mutationID,
            operation: pending.operation,
            resolution: .definitelyNotStarted,
            resolvedAt: now,
            detail: detail
        )
        record.pendingSettingsMutation = nil
        try commit(record)
        return record
    }

    @discardableResult
    func completeSettingsUpdate(
        alarmID: UUID,
        mutationID: String,
        nativeState: AlarmNativeState?,
        now: Date = Date()
    ) throws -> AlarmOwnershipRecord {
        guard var record = records[alarmID],
              let pending = record.pendingSettingsMutation,
              pending.mutationID == mutationID,
              pending.operation == .update,
              let title = pending.requestedTitle,
              let schedule = pending.requestedSchedule,
              let sound = pending.requestedSound
        else { throw AlarmOwnershipStoreError.settingsMutationIdentityConflict }
        record.title = title
        record.schedule = schedule
        record.sound = sound
        record.lifecycle = .accepted
        record.lastNativeState = nativeState
        record.lastObservedAt = now
        record.lastMutationAt = now
        record.lastMutationTaskID = nil
        record.lastMutationActionID = mutationID
        record.cancelledAt = nil
        record.cancelledByActionID = nil
        record.lastSettingsMutationOutcome = AlarmSettingsMutationOutcome(
            mutationID: mutationID,
            operation: .update,
            resolution: .completed,
            resolvedAt: now,
            detail: nil
        )
        record.pendingSettingsMutation = nil
        try commit(record)
        return record
    }

    @discardableResult
    func completeSettingsCancel(
        alarmID: UUID,
        mutationID: String,
        now: Date = Date()
    ) throws -> AlarmOwnershipRecord {
        guard var record = records[alarmID],
              let pending = record.pendingSettingsMutation,
              pending.mutationID == mutationID,
              pending.operation == .cancel
        else { throw AlarmOwnershipStoreError.settingsMutationIdentityConflict }
        record.lifecycle = .cancelled
        record.lastNativeState = nil
        record.lastObservedAt = now
        record.lastMutationAt = now
        record.lastMutationTaskID = nil
        record.lastMutationActionID = mutationID
        record.cancelledAt = now
        record.cancelledByActionID = mutationID
        record.lastSettingsMutationOutcome = AlarmSettingsMutationOutcome(
            mutationID: mutationID,
            operation: .cancel,
            resolution: .completed,
            resolvedAt: now,
            detail: nil
        )
        record.pendingSettingsMutation = nil
        try commit(record)
        return record
    }

    @discardableResult
    func completeSettingsLifecycle(
        alarmID: UUID,
        mutationID: String,
        nativeState: AlarmNativeState,
        now: Date = Date()
    ) throws -> AlarmOwnershipRecord {
        guard var record = records[alarmID],
              let pending = record.pendingSettingsMutation,
              pending.mutationID == mutationID,
              pending.operation == .pause || pending.operation == .resume
        else { throw AlarmOwnershipStoreError.settingsMutationIdentityConflict }
        record.lifecycle = .accepted
        record.lastNativeState = nativeState
        record.lastObservedAt = now
        record.lastMutationAt = now
        record.lastMutationTaskID = nil
        record.lastMutationActionID = mutationID
        record.lastSettingsMutationOutcome = AlarmSettingsMutationOutcome(
            mutationID: mutationID,
            operation: pending.operation,
            resolution: .completed,
            resolvedAt: now,
            detail: nil
        )
        record.pendingSettingsMutation = nil
        try commit(record)
        return record
    }

    @discardableResult
    func advanceReplacement(
        alarmID: UUID, mutationID: String, phase: AlarmReplacementPhase,
        countAttempt: Bool = false
    ) throws -> AlarmSettingsMutationIntent {
        guard var record = records[alarmID], record.lifecycle != .cancelled,
              var intent = record.pendingSettingsMutation,
              intent.mutationID == mutationID, intent.operation == .update
        else { throw AlarmOwnershipStoreError.settingsMutationIdentityConflict }
        if intent.replacementPhase != phase { intent.replacementAttempts = 0 }
        intent.replacementPhase = phase
        if countAttempt {
            guard (intent.replacementAttempts ?? 0) < 3 else {
                throw AlarmOwnershipStoreError.settingsMutationIdentityConflict
            }
            intent.replacementAttempts = (intent.replacementAttempts ?? 0) + 1
        }
        record.pendingSettingsMutation = intent
        try commit(record)
        return intent
    }

    @discardableResult
    func finishReplacementFailure(
        alarmID: UUID, mutationID: String, nativeState: AlarmNativeState?,
        detail: String, now: Date = Date()
    ) throws -> AlarmOwnershipRecord {
        guard var record = records[alarmID], record.lifecycle != .cancelled,
              let intent = record.pendingSettingsMutation,
              intent.operation == .update, intent.mutationID == mutationID
        else { throw AlarmOwnershipStoreError.settingsMutationIdentityConflict }
        record.title = intent.beforeTitle
        record.schedule = intent.beforeSchedule
        record.sound = intent.beforeSound
        record.lifecycle = nativeState == nil ? .missing : .accepted
        record.lastNativeState = nativeState
        record.lastObservedAt = now
        record.lastSettingsMutationOutcome = AlarmSettingsMutationOutcome(
            mutationID: mutationID, operation: .update, resolution: .failed,
            resolvedAt: now, detail: detail
        )
        record.pendingSettingsMutation = nil
        try commit(record)
        return record
    }

    private func commit(_ record: AlarmOwnershipRecord) throws {
        var nextRecords = records
        nextRecords[record.alarmID] = record
        try persist(nextRecords)
        records = nextRecords
    }

    private func removeRecord(alarmID: UUID) throws {
        var nextRecords = records
        nextRecords.removeValue(forKey: alarmID)
        try persist(nextRecords)
        records = nextRecords
    }

    /// Persist the candidate snapshot before publishing it to in-memory state.
    /// If the atomic write fails, callers keep observing the last durable
    /// ownership truth rather than a mutation that exists only for this process.
    private func persist(_ candidateRecords: [UUID: AlarmOwnershipRecord]) throws {
        let snapshot = Snapshot(
            records: candidateRecords.values.sorted { $0.alarmID.uuidString < $1.alarmID.uuidString }
        )
        try JSONEncoder.floweroll.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    private static func defaultDirectoryURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("Floweroll", isDirectory: true)
            .appendingPathComponent("RuntimeClient", isDirectory: true)
    }
}


enum AlarmIdentity {
    static func stableAlarmID(for idempotencyKey: String) -> UUID {
        let digest = SHA256.hash(data: Data(idempotencyKey.utf8))
        let bytes = Array(digest.prefix(16))
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: value)!
    }
}


enum AlarmFailureCode: String, Sendable {
    case ownershipStoreUnavailable = "alarm_ownership_store_unavailable"
    case usageDescriptionMissing = "alarm_usage_description_missing"
    case invalidArguments = "alarm_invalid_arguments"
    case authorizationNotDetermined = "alarm_authorization_not_determined"
    case authorizationDenied = "alarm_authorization_denied"
    case authorizationUnknown = "alarm_authorization_unknown"
    case idempotencyConflict = "alarm_idempotency_conflict"
    case nativeIDConflict = "alarm_native_id_conflict"
    case maximumLimitReached = "alarm_maximum_limit_reached"
    case nativeScheduleFailed = "alarm_native_schedule_failed"
    case readFailed = "alarm_read_failed"
    case readbackMissing = "alarm_readback_missing"
    case readbackMismatch = "alarm_readback_mismatch"
    case unknownTarget = "alarm_unknown_target"
    case foreignTarget = "alarm_foreign_target"
    case invalidNativeState = "alarm_invalid_native_state"
    case settingsMutationPending = "alarm_settings_mutation_pending"
    case updateFailed = "alarm_update_failed"
    case pauseFailed = "alarm_pause_failed"
    case resumeFailed = "alarm_resume_failed"
    case queryFailed = "alarm_query_failed"
    case cancelFailed = "alarm_cancel_failed"
    case stillPresentAfterCancel = "alarm_still_present_after_cancel"
    case directUpdateUnsupported = "alarm_direct_update_unsupported"
}


func alarmPermissionFailure(
    _ status: AlarmAuthorizationStatus
) -> DeviceExecutionResult? {
    let code: AlarmFailureCode
    let userAction: String
    switch status {
    case .authorized:
        return nil
    case .notDetermined:
        code = .authorizationNotDetermined
        userAction = "request_alarm_authorization_in_foreground"
    case .denied:
        code = .authorizationDenied
        userAction = "open_app_settings_for_alarm_authorization"
    case .unknown:
        code = .authorizationUnknown
        userAction = "refresh_alarm_authorization_in_foreground"
    }
    return .failure(
        code.rawValue,
        output: [
            "error_code": .string(code.rawValue),
            "authorization_status": .string(status.rawValue),
            "user_action": .string(userAction),
        ]
    )
}


func alarmFailure(
    _ code: AlarmFailureCode,
    extra: [String: JSONValue] = [:]
) -> DeviceExecutionResult {
    var output = extra
    output["error_code"] = .string(code.rawValue)
    return .failure(code.rawValue, output: output)
}


struct AlarmReadbackSnapshot: Equatable, Sendable {
    let alarmID: UUID
    let ownership: AlarmOwnershipRecord?
    let native: AlarmNativeRecord?

    var ownershipSource: String {
        ownership == nil ? "alarm_manager_current_client" : "ownership_ledger"
    }
}


enum AlarmReadbackService {
    static func read(
        alarmID: UUID,
        nativeStore: any AlarmNativeStore,
        ownershipStore: AlarmOwnershipStore
    ) async throws -> AlarmReadbackSnapshot? {
        guard var ownership = await ownershipStore.record(alarmID: alarmID) else {
            return nil
        }
        let native = try await nativeStore.alarms().first { $0.id == alarmID }
        ownership = try await ownershipStore.recordObservation(
            alarmID: alarmID,
            nativeState: native?.state,
            isMissing: native == nil
        )
        return AlarmReadbackSnapshot(
            alarmID: alarmID,
            ownership: ownership,
            native: native
        )
    }

    static func enumerate(
        nativeStore: any AlarmNativeStore,
        ownershipStore: AlarmOwnershipStore?,
        maxResults: Int = 100
    ) async throws -> [AlarmReadbackSnapshot] {
        let native = try await nativeStore.alarms()
        let ownership = await ownershipStore?.allRecords() ?? []
        var ids = Set(native.map(\.id))
        ids.formUnion(ownership.map(\.alarmID))
        let nativeByID = Dictionary(uniqueKeysWithValues: native.map { ($0.id, $0) })
        let ownershipByID = Dictionary(uniqueKeysWithValues: ownership.map { ($0.alarmID, $0) })
        return ids.sorted { $0.uuidString < $1.uuidString }
            .prefix(max(0, maxResults))
            .map {
                AlarmReadbackSnapshot(
                    alarmID: $0,
                    ownership: ownershipByID[$0],
                    native: nativeByID[$0]
                )
            }
    }

    /// Product management surface: only durable Floweroll-owned alarms are eligible.
    static func enumerateOwned(
        nativeStore: any AlarmNativeStore,
        ownershipStore: AlarmOwnershipStore?,
        maxResults: Int = 100
    ) async throws -> [AlarmReadbackSnapshot] {
        guard let ownershipStore else { return [] }
        let native = try await nativeStore.alarms()
        let nativeByID = Dictionary(uniqueKeysWithValues: native.map { ($0.id, $0) })
        var output: [AlarmReadbackSnapshot] = []
        for record in await ownershipStore.allRecords()
            .filter({ $0.lifecycle != .cancelled })
            .prefix(max(0, maxResults))
        {
            let nativeRecord = nativeByID[record.alarmID]
            let reconciled = try await ownershipStore.recordObservation(
                alarmID: record.alarmID,
                nativeState: nativeRecord?.state,
                isMissing: nativeRecord == nil
            )
            output.append(
                AlarmReadbackSnapshot(
                    alarmID: record.alarmID,
                    ownership: reconciled,
                    native: nativeRecord
                )
            )
        }
        return output.sorted { $0.alarmID.uuidString < $1.alarmID.uuidString }
    }
}
