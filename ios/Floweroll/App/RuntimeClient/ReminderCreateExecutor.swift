import CryptoKit
import EventKit
import Foundation


enum ReminderExecutorError: Error, LocalizedError, Sendable {
    case invalidArguments
    case noDefaultReminderCalendar
    case savedReminderNotFound
    case savedReminderMismatch

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "提醒参数无效。"
        case .noDefaultReminderCalendar:
            return "没有可用的默认提醒事项列表。"
        case .savedReminderNotFound:
            return "提醒事项保存后没有在 EventKit 中找到。"
        case .savedReminderMismatch:
            return "提醒事项保存后的内容与执行请求不一致。"
        }
    }
}

actor ReminderCreateExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID = "reminder.create"

    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func preflight(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult? {
        guard Self.arguments(from: dispatch) != nil else {
            return .failure("invalid reminder.create arguments")
        }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            // Permission prompts are deliberately not triggered from background
            // execution. The user grants this proactively inside 小卷.
            return .failure("reminders_full_access_required")
        }
        return nil
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        guard let arguments = Self.arguments(from: dispatch) else {
            throw ReminderExecutorError.invalidArguments
        }
        let markerURL = Self.markerURL(for: dispatch.idempotencyKey)

        if let existing = try await findReminder(markerURL: markerURL) {
            return try verifiedResult(
                existing,
                arguments: arguments,
                dispatch: dispatch
            )
        }

        guard let calendar = eventStore.defaultCalendarForNewReminders() else {
            throw ReminderExecutorError.noDefaultReminderCalendar
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = calendar
        reminder.title = arguments.title
        reminder.url = markerURL
        reminder.dueDateComponents = Calendar.autoupdatingCurrent.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
            from: arguments.dueDate
        )
        reminder.addAlarm(EKAlarm(absoluteDate: arguments.dueDate))

        try eventStore.save(reminder, commit: true)

        guard let saved = try await findReminder(markerURL: markerURL) else {
            // Save may have succeeded even though subsequent read-back failed.
            // Throwing after the journal may-have-started boundary correctly
            // forces DeviceActionJournal reconciliation instead of a duplicate.
            throw ReminderExecutorError.savedReminderNotFound
        }
        return try verifiedResult(
            saved,
            arguments: arguments,
            dispatch: dispatch
        )
    }

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        guard let arguments = Self.arguments(from: dispatch) else {
            return .completed(.failure("invalid reminder.create arguments"))
        }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return .stillUnknown("reminders_full_access_required_for_reconciliation")
        }
        let markerURL = Self.markerURL(for: dispatch.idempotencyKey)
        guard let reminder = try await findReminder(markerURL: markerURL) else {
            return .definitelyNotStarted
        }
        return .completed(
            try verifiedResult(
                reminder,
                arguments: arguments,
                dispatch: dispatch
            )
        )
    }

    private func verifiedResult(
        _ reminder: ReminderSnapshot,
        arguments: ReminderArguments,
        dispatch: DeviceActionDispatch
    ) throws -> DeviceExecutionResult {
        guard
            reminder.title == arguments.title,
            let nativeDueDate = reminder.dueDate,
            abs(nativeDueDate.timeIntervalSince(arguments.dueDate)) < 1.0
        else {
            throw ReminderExecutorError.savedReminderMismatch
        }

        return .success(
            [
                "reminder_id": .string(reminder.identifier),
                "title": .string(arguments.title),
                // Return the exact dispatched wire value after native read-back
                // verified that EventKit represents the same instant.
                "due_at": .string(arguments.dueAt),
                "idempotency_marker": .string(dispatch.idempotencyKey),
                "verified": .bool(true),
            ],
            nativeCorrelationID: reminder.identifier
        )
    }

    private struct ReminderSnapshot: Sendable {
        let identifier: String
        let title: String
        let dueDate: Date?
        let markerURL: URL?
    }

    private func findReminder(markerURL: URL) async throws -> ReminderSnapshot? {
        let predicate = eventStore.predicateForReminders(in: nil)
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<ReminderSnapshot?, Never>) in
            eventStore.fetchReminders(matching: predicate) { values in
                let match = values?.first { $0.url == markerURL }
                let snapshot = match.map {
                    ReminderSnapshot(
                        identifier: $0.calendarItemIdentifier,
                        title: $0.title,
                        dueDate: $0.dueDateComponents?.date,
                        markerURL: $0.url
                    )
                }
                continuation.resume(returning: snapshot)
            }
        }
    }

    private struct ReminderArguments: Sendable {
        let title: String
        let dueAt: String
        let dueDate: Date
    }

    private static func arguments(from dispatch: DeviceActionDispatch) -> ReminderArguments? {
        guard
            let title = dispatch.payload["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty,
            let dueAt = dispatch.payload["due_at"]?.stringValue,
            let dueDate = parseISO8601(dueAt)
        else { return nil }
        return ReminderArguments(title: title, dueAt: dueAt, dueDate: dueDate)
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        let normal = ISO8601DateFormatter()
        normal.formatOptions = [.withInternetDateTime]
        return normal.date(from: raw)
    }

    private static func markerURL(for idempotencyKey: String) -> URL {
        let encoded = Data(idempotencyKey.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "floweroll://action/\(encoded)")!
    }
}


struct ReminderManagementSnapshot: Sendable {
    let reminderID: String
    let title: String
    let completed: Bool
    let dueAt: Date?
    let completionAt: Date?
    let calendarID: String
    let calendarName: String
    let calendarWritable: Bool
    let hasRecurrence: Bool
    let revision: String
    let notes: String
    let priority: Int
    let dueMode: String?
    let dueTimeZone: String?
    let alarmMode: String?
    let updateEligible: Bool
    let updateIneligibleReason: String?

    init(
        reminderID: String,
        title: String,
        completed: Bool,
        dueAt: Date?,
        completionAt: Date?,
        calendarID: String,
        calendarName: String,
        calendarWritable: Bool,
        hasRecurrence: Bool,
        revision: String,
        notes: String = "",
        priority: Int = 0,
        dueMode: String? = nil,
        dueTimeZone: String? = nil,
        alarmMode: String? = nil,
        updateEligible: Bool = false,
        updateIneligibleReason: String? = nil
    ) {
        self.reminderID = reminderID
        self.title = title
        self.completed = completed
        self.dueAt = dueAt
        self.completionAt = completionAt
        self.calendarID = calendarID
        self.calendarName = calendarName
        self.calendarWritable = calendarWritable
        self.hasRecurrence = hasRecurrence
        self.revision = revision
        self.notes = notes
        self.priority = priority
        self.dueMode = dueMode
        self.dueTimeZone = dueTimeZone
        self.alarmMode = alarmMode
        self.updateEligible = updateEligible
        self.updateIneligibleReason = updateIneligibleReason
    }

    private struct AlarmFingerprint: Codable {
        let absoluteMillis: Int64?
        let relativeMillis: Int64
        let proximity: Int
        let locationTitle: String?
        let latitude: Double?
        let longitude: Double?
        let radius: Double?

        var sortKey: String {
            [
                absoluteMillis.map(String.init) ?? "~",
                String(relativeMillis),
                String(proximity),
                locationTitle ?? "",
                latitude.map { String(format: "%.8f", $0) } ?? "",
                longitude.map { String(format: "%.8f", $0) } ?? "",
                radius.map { String(format: "%.3f", $0) } ?? "",
            ].joined(separator: "|")
        }
    }

    private struct RevisionPayload: Codable {
        let reminderID: String
        let title: String
        let notes: String
        let priority: Int
        let completed: Bool
        let completionMillis: Int64?
        let calendarID: String
        let calendarWritable: Bool
        let startComponents: String?
        let dueComponents: String?
        let hasRecurrence: Bool
        let alarms: [AlarmFingerprint]
    }

    private struct DueTopology {
        let dueMode: String?
        let dueAt: Date?
        let timeZoneID: String?
        let alarmMode: String?
        let supported: Bool
        let reason: String?
    }

    static func read(_ reminder: EKReminder) -> ReminderManagementSnapshot? {
        guard let calendar = reminder.calendar else { return nil }
        let dueAt = reminder.dueDateComponents?.date
        let alarms = (reminder.alarms ?? []).map { alarm in
            AlarmFingerprint(
                absoluteMillis: alarm.absoluteDate.map(milliseconds),
                relativeMillis: Int64((alarm.relativeOffset * 1_000).rounded()),
                proximity: alarm.proximity.rawValue,
                locationTitle: alarm.structuredLocation?.title,
                latitude: alarm.structuredLocation?.geoLocation?.coordinate.latitude,
                longitude: alarm.structuredLocation?.geoLocation?.coordinate.longitude,
                radius: alarm.structuredLocation?.radius
            )
        }
        .sorted { lhs, rhs in lhs.sortKey < rhs.sortKey }
        let topology = dueTopology(reminder)
        let notes = reminder.notes ?? ""
        let payload = RevisionPayload(
            reminderID: reminder.calendarItemIdentifier,
            title: reminder.title,
            notes: notes,
            priority: reminder.priority,
            completed: reminder.isCompleted,
            completionMillis: reminder.completionDate.map(milliseconds),
            calendarID: calendar.calendarIdentifier,
            calendarWritable: calendar.allowsContentModifications,
            startComponents: componentsFingerprint(reminder.startDateComponents),
            dueComponents: componentsFingerprint(reminder.dueDateComponents),
            hasRecurrence: reminder.hasRecurrenceRules,
            alarms: alarms
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(payload) else { return nil }
        let revision = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        let eligible = calendar.allowsContentModifications && !reminder.hasRecurrenceRules && topology.supported
        let reason: String?
        if !calendar.allowsContentModifications {
            reason = "当前提醒事项列表不可修改。"
        } else if reminder.hasRecurrenceRules {
            reason = "重复提醒暂不支持直接修改。"
        } else if !topology.supported {
            reason = topology.reason ?? "当前提醒的到期时间或提醒方式较复杂，暂不自动修改。"
        } else {
            reason = nil
        }
        return ReminderManagementSnapshot(
            reminderID: reminder.calendarItemIdentifier,
            title: reminder.title,
            completed: reminder.isCompleted,
            dueAt: dueAt,
            completionAt: reminder.completionDate,
            calendarID: calendar.calendarIdentifier,
            calendarName: calendar.title,
            calendarWritable: calendar.allowsContentModifications,
            hasRecurrence: reminder.hasRecurrenceRules,
            revision: revision,
            notes: notes,
            priority: reminder.priority,
            dueMode: topology.dueMode,
            dueTimeZone: topology.timeZoneID,
            alarmMode: topology.alarmMode,
            updateEligible: eligible,
            updateIneligibleReason: reason
        )
    }

    func deviceObject() -> [String: JSONValue] {
        let removeEligible = calendarWritable && !hasRecurrence
        let removeIneligibleReason: String?
        if !calendarWritable {
            removeIneligibleReason = "当前提醒事项列表不可修改。"
        } else if hasRecurrence {
            removeIneligibleReason = "重复提醒暂不支持直接删除。"
        } else {
            removeIneligibleReason = nil
        }
        return [
            "reminder_id": .string(reminderID),
            "revision": .string(revision),
            "title": .string(title.isEmpty ? "无标题" : title),
            "completed": .bool(completed),
            "due_at": dueAt.map { .string(Self.iso8601($0)) } ?? .null,
            "completion_at": completionAt.map { .string(Self.iso8601($0)) } ?? .null,
            // Keep the accepted A21 field names for backward compatibility and
            // expose the E06 list aliases required by reminder.update.
            "calendar_id": .string(calendarID),
            "calendar_name": .string(calendarName.isEmpty ? "未命名列表" : calendarName),
            "calendar_writable": .bool(calendarWritable),
            "list_id": .string(calendarID),
            "list_name": .string(calendarName.isEmpty ? "未命名列表" : calendarName),
            "list_writable": .bool(calendarWritable),
            "has_recurrence": .bool(hasRecurrence),
            "notes": .string(notes),
            "priority": .number(Double(priority)),
            "due_mode": dueMode.map(JSONValue.string) ?? .null,
            "due_time_zone": dueTimeZone.map(JSONValue.string) ?? .null,
            "alarm_mode": alarmMode.map(JSONValue.string) ?? .null,
            "update_eligible": .bool(updateEligible),
            "update_ineligible_reason": updateIneligibleReason.map(JSONValue.string) ?? .null,
            // Shared management snapshot compatibility for the independently
            // qualified remove lane; this does not perform or authorize delete.
            "remove_eligible": .bool(removeEligible),
            "remove_ineligible_reason": removeIneligibleReason.map(JSONValue.string) ?? .null,
        ]
    }

    private static func dueTopology(_ reminder: EKReminder) -> DueTopology {
        let start = reminder.startDateComponents
        let due = reminder.dueDateComponents
        let alarms = reminder.alarms ?? []
        if start == nil, due == nil {
            guard alarms.isEmpty else {
                return .init(dueMode: nil, dueAt: nil, timeZoneID: nil, alarmMode: nil,
                             supported: false, reason: "没有到期时间但存在提醒闹铃，暂不自动修改。")
            }
            return .init(dueMode: "none", dueAt: nil, timeZoneID: "", alarmMode: "none",
                         supported: true, reason: nil)
        }
        guard let start, let due else {
            return .init(dueMode: nil, dueAt: due?.date, timeZoneID: due?.timeZone?.identifier,
                         alarmMode: nil, supported: false,
                         reason: "当前提醒的开始/到期时间结构不完整，暂不自动修改。")
        }
        guard start.calendar?.identifier == .gregorian, due.calendar?.identifier == .gregorian,
              let startZone = start.timeZone, let dueZone = due.timeZone,
              startZone.identifier == dueZone.identifier,
              start.hour != nil, due.hour != nil,
              let startDate = start.date, let dueDate = due.date,
              abs(startDate.timeIntervalSince(dueDate)) < 1.0 else {
            return .init(dueMode: nil, dueAt: due.date, timeZoneID: due.timeZone?.identifier,
                         alarmMode: nil, supported: false,
                         reason: "当前提醒使用浮动、全天或不一致的开始/到期时间，暂不自动修改。")
        }
        if alarms.isEmpty {
            return .init(dueMode: "timed", dueAt: dueDate, timeZoneID: dueZone.identifier,
                         alarmMode: "none", supported: true, reason: nil)
        }
        guard alarms.count == 1, let alarm = alarms.first,
              let absolute = alarm.absoluteDate,
              alarm.structuredLocation == nil,
              alarm.proximity == .none,
              abs(absolute.timeIntervalSince(dueDate)) < 1.0 else {
            return .init(dueMode: nil, dueAt: dueDate, timeZoneID: dueZone.identifier,
                         alarmMode: nil, supported: false,
                         reason: "当前提醒包含多个、相对、位置型或未与到期时间对齐的闹铃，暂不自动修改。")
        }
        return .init(dueMode: "timed", dueAt: dueDate, timeZoneID: dueZone.identifier,
                     alarmMode: "at_due", supported: true, reason: nil)
    }

    private static func componentsFingerprint(_ value: DateComponents?) -> String? {
        guard let value else { return nil }
        let calendarID = value.calendar.map { String(describing: $0.identifier) } ?? ""
        let timeZoneID = value.timeZone?.identifier ?? ""
        let era = value.era.map(String.init) ?? ""
        let year = value.year.map(String.init) ?? ""
        let month = value.month.map(String.init) ?? ""
        let day = value.day.map(String.init) ?? ""
        let hour = value.hour.map(String.init) ?? ""
        let minute = value.minute.map(String.init) ?? ""
        let second = value.second.map(String.init) ?? ""
        let nanosecond = value.nanosecond.map(String.init) ?? ""
        let fields = [
            calendarID, timeZoneID, era, year, month,
            day, hour, minute, second, nanosecond,
        ]
        return fields.joined(separator: "|")
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private enum ReminderManagementFailureCode: String {
    case queryInvalid = "reminder_query_invalid"
    case queryTooBroad = "reminder_query_too_broad"
    case calendarNotFound = "reminder_calendar_not_found"
    case fullAccessRequired = "reminders_full_access_required"
    case completionInvalid = "reminder_completion_invalid"
    case targetMissing = "reminder_not_found_or_stale"
    case revisionStale = "reminder_revision_stale"
    case readOnlyList = "reminder_read_only_list"
    case recurringUnsupported = "reminder_recurring_mutation_unsupported"
    case targetChanged = "reminder_target_changed"
    case updateInvalid = "reminder_update_invalid"
    case updateUnsupportedTopology = "reminder_update_unsupported_topology"
    case completionChanged = "reminder_completion_changed"
    case removeInvalid = "reminder_remove_invalid"
}

private func reminderFailure(
    _ code: ReminderManagementFailureCode,
    _ message: String
) -> DeviceExecutionResult {
    .failure(message, output: ["error_code": .string(code.rawValue)])
}

private struct ReminderQueryArguments: Sendable {
    enum Mode: String, Sendable { case exactID = "exact_id", filtered }

    let mode: Mode
    let reminderID: String?
    let status: String?
    let startDate: Date?
    let endDate: Date?
    let calendarID: String?
    let titleContains: String?
    let maxResults: Int

    var dateSemantics: String? {
        guard mode == .filtered else { return nil }
        return status == "incomplete" ? "due_date" : "completion_date"
    }

    init?(_ payload: [String: JSONValue]) {
        let allowed: Set<String> = [
            "reminder_id", "status", "start_at", "end_at",
            "calendar_id", "title_contains", "max_results",
        ]
        guard Set(payload.keys).isSubset(of: allowed) else { return nil }
        let requestedMax: Int
        if let raw = payload["max_results"] {
            guard case let .number(value) = raw, value.rounded() == value,
                  value >= 1, value <= 50 else { return nil }
            requestedMax = Int(value)
        } else {
            requestedMax = 20
        }

        if let reminderID = Self.clean(payload["reminder_id"]?.stringValue) {
            guard reminderID.count <= 512,
                  Set(payload.keys).isSubset(of: ["reminder_id", "max_results"]) else { return nil }
            mode = .exactID
            self.reminderID = reminderID
            status = nil
            startDate = nil
            endDate = nil
            calendarID = nil
            titleContains = nil
            maxResults = 1
            return
        }

        guard let status = payload["status"]?.stringValue,
              status == "incomplete" || status == "completed" else { return nil }
        let calendarID = Self.clean(payload["calendar_id"]?.stringValue)
        if let calendarID, calendarID.count > 512 { return nil }
        let title = Self.clean(payload["title_contains"]?.stringValue)
        if let title, !(2...160).contains(title.count) { return nil }
        let startRaw = payload["start_at"]?.stringValue
        let endRaw = payload["end_at"]?.stringValue
        guard (startRaw == nil) == (endRaw == nil) else { return nil }
        let start = startRaw.flatMap(Self.parseISO8601)
        let end = endRaw.flatMap(Self.parseISO8601)
        if startRaw != nil {
            guard let start, let end, end > start,
                  end.timeIntervalSince(start) <= 366 * 86_400 else { return nil }
        }
        guard calendarID != nil || start != nil else { return nil }

        mode = .filtered
        reminderID = nil
        self.status = status
        startDate = start
        endDate = end
        self.calendarID = calendarID
        titleContains = title
        maxResults = requestedMax
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let normal = ISO8601DateFormatter()
        normal.formatOptions = [.withInternetDateTime]
        return normal.date(from: raw)
    }
}

actor ReminderQueryExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID = "reminder.query"
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func preflight(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult? {
        guard ReminderQueryArguments(dispatch.payload) != nil else {
            return reminderFailure(.queryInvalid, "提醒事项查询参数无效。")
        }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return reminderFailure(.fullAccessRequired, "请先在花卷设置中允许提醒事项完整访问。")
        }
        return nil
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        guard let arguments = ReminderQueryArguments(dispatch.payload) else {
            return reminderFailure(.queryInvalid, "提醒事项查询参数无效。")
        }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return reminderFailure(.fullAccessRequired, "提醒事项权限已变化，无法读取。")
        }
        eventStore.reset()
        let snapshots: [ReminderManagementSnapshot]
        switch arguments.mode {
        case .exactID:
            if let id = arguments.reminderID,
               let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder,
               let snapshot = ReminderManagementSnapshot.read(reminder) {
                snapshots = [snapshot]
            } else {
                snapshots = []
            }
        case .filtered:
            let calendars: [EKCalendar]?
            if let calendarID = arguments.calendarID {
                guard let calendar = eventStore.calendars(for: .reminder).first(where: {
                    $0.calendarIdentifier == calendarID
                }) else {
                    return reminderFailure(.calendarNotFound, "没有找到指定的提醒事项列表。")
                }
                calendars = [calendar]
            } else {
                calendars = nil
            }
            let predicate: NSPredicate
            if arguments.status == "incomplete" {
                predicate = eventStore.predicateForIncompleteReminders(
                    withDueDateStarting: arguments.startDate,
                    ending: arguments.endDate,
                    calendars: calendars
                )
            } else {
                predicate = eventStore.predicateForCompletedReminders(
                    withCompletionDateStarting: arguments.startDate,
                    ending: arguments.endDate,
                    calendars: calendars
                )
            }
            var values = await fetchSnapshots(predicate: predicate)
            if let needle = arguments.titleContains {
                values = values.filter {
                    $0.title.range(
                        of: needle,
                        options: [.caseInsensitive, .diacriticInsensitive],
                        range: nil,
                        locale: Locale(identifier: "en_US_POSIX")
                    ) != nil
                }
            }
            snapshots = values.sorted { lhs, rhs in
                let lhsDate = arguments.status == "completed" ? lhs.completionAt : lhs.dueAt
                let rhsDate = arguments.status == "completed" ? rhs.completionAt : rhs.dueAt
                if lhsDate != rhsDate {
                    if lhsDate == nil { return false }
                    if rhsDate == nil { return true }
                    return lhsDate! < rhsDate!
                }
                if lhs.title != rhs.title { return lhs.title < rhs.title }
                return lhs.reminderID < rhs.reminderID
            }
        }
        let visible = Array(snapshots.prefix(arguments.maxResults))
        return .success([
            "query_mode": .string(arguments.mode.rawValue),
            "date_semantics": arguments.dateSemantics.map(JSONValue.string) ?? .null,
            "reminders": .array(visible.map { .object($0.deviceObject()) }),
            "truncated": .bool(snapshots.count > arguments.maxResults),
            "verified": .bool(true),
        ])
    }

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        .completed(try await execute(dispatch))
    }

    private func fetchSnapshots(
        predicate: NSPredicate
    ) async -> [ReminderManagementSnapshot] {
        await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                let snapshots = (reminders ?? []).compactMap(ReminderManagementSnapshot.read)
                continuation.resume(returning: snapshots)
            }
        }
    }
}

private struct ReminderCompletionArguments: Sendable {
    let reminderID: String
    let expectedRevision: String
    let completed: Bool

    init?(_ payload: [String: JSONValue]) {
        guard Set(payload.keys) == ["reminder_id", "expected_revision", "completed"],
              let reminderID = payload["reminder_id"]?.stringValue,
              reminderID == reminderID.trimmingCharacters(in: .whitespacesAndNewlines),
              !reminderID.isEmpty, reminderID.count <= 512,
              let revision = payload["expected_revision"]?.stringValue,
              revision.count == 64,
              revision.allSatisfy({ $0.isHexDigit }),
              let completed = payload["completed"]?.boolValue else { return nil }
        self.reminderID = reminderID
        expectedRevision = revision.lowercased()
        self.completed = completed
    }
}

private enum ReminderCompletionReadbackError: Error, LocalizedError {
    case missing
    case mismatch

    var errorDescription: String? {
        switch self {
        case .missing: return "提醒状态可能已经更新，但暂时无法按原生 ID 读回；不会再次写入。"
        case .mismatch: return "提醒状态保存后的原生读回与目标状态不一致；不会再次写入。"
        }
    }
}

actor ReminderSetCompletionExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID = "reminder.set_completion"
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func preflight(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult? {
        guard let arguments = ReminderCompletionArguments(dispatch.payload) else {
            return reminderFailure(.completionInvalid, "提醒完成状态参数无效。")
        }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return reminderFailure(.fullAccessRequired, "请先在花卷设置中允许提醒事项完整访问。")
        }
        eventStore.reset()
        guard let reminder = eventStore.calendarItem(withIdentifier: arguments.reminderID) as? EKReminder else {
            return reminderFailure(.targetMissing, "这个提醒事项已经不存在或原生标识已变化，请重新查询。")
        }
        guard let snapshot = ReminderManagementSnapshot.read(reminder) else {
            return reminderFailure(.targetChanged, "这个提醒事项当前缺少有效的列表归属，请重新查询。")
        }
        guard snapshot.calendarWritable else {
            return reminderFailure(.readOnlyList, "这个提醒事项所在列表当前不可修改。")
        }
        guard !snapshot.hasRecurrence else {
            return reminderFailure(.recurringUnsupported, "当前版本不会修改重复提醒事项的完成状态。")
        }
        guard snapshot.revision == arguments.expectedRevision else {
            return reminderFailure(.revisionStale, "提醒事项已发生变化，请重新查询后再修改。")
        }
        return nil
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        guard let arguments = ReminderCompletionArguments(dispatch.payload) else {
            return reminderFailure(.completionInvalid, "提醒完成状态参数无效。")
        }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return reminderFailure(.fullAccessRequired, "提醒事项权限已变化，尚未写入。")
        }
        eventStore.reset()
        guard let reminder = eventStore.calendarItem(withIdentifier: arguments.reminderID) as? EKReminder else {
            return reminderFailure(.targetMissing, "这个提醒事项已经不存在或原生标识已变化，尚未写入。")
        }
        guard let fresh = ReminderManagementSnapshot.read(reminder) else {
            return reminderFailure(.targetChanged, "这个提醒事项当前缺少有效的列表归属，尚未写入。")
        }
        guard fresh.calendarWritable else {
            return reminderFailure(.readOnlyList, "这个提醒事项所在列表已变为不可修改，尚未写入。")
        }
        guard !fresh.hasRecurrence else {
            return reminderFailure(.recurringUnsupported, "这个提醒事项现在属于重复提醒，尚未写入。")
        }
        if fresh.completed == arguments.completed {
            return Self.verifiedResult(fresh, requestedID: arguments.reminderID, applied: false)
        }
        guard fresh.revision == arguments.expectedRevision else {
            return reminderFailure(.revisionStale, "提醒事项在执行前又发生了变化，尚未写入。")
        }

        reminder.isCompleted = arguments.completed
        // Exactly one EventKit save. Any thrown error after the journal's
        // may-have-started boundary remains ambiguous and is reconciled by read.
        try eventStore.save(reminder, commit: true)
        let postSaveID = reminder.calendarItemIdentifier
        eventStore.reset()
        guard let readback = eventStore.calendarItem(withIdentifier: postSaveID) as? EKReminder else {
            throw ReminderCompletionReadbackError.missing
        }
        guard let snapshot = ReminderManagementSnapshot.read(readback) else {
            throw ReminderCompletionReadbackError.mismatch
        }
        guard Self.readbackMatchesV1(snapshot, desired: arguments.completed) else {
            throw ReminderCompletionReadbackError.mismatch
        }
        return Self.verifiedResult(snapshot, requestedID: arguments.reminderID, applied: true)
    }

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        guard let arguments = ReminderCompletionArguments(dispatch.payload) else {
            return .completed(reminderFailure(.completionInvalid, "提醒完成状态参数无效。"))
        }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return .stillUnknown("恢复提醒事项访问后才能核对这次完成状态修改。")
        }
        eventStore.reset()
        guard let reminder = eventStore.calendarItem(withIdentifier: arguments.reminderID) as? EKReminder else {
            return .stillUnknown("原提醒事项当前无法按精确 ID 找到；不会盲目再次写入。")
        }
        guard let snapshot = ReminderManagementSnapshot.read(reminder) else {
            return .stillUnknown("提醒事项当前缺少有效的列表归属，无法确认原修改结果。")
        }
        guard Self.readbackMatchesV1(snapshot, desired: arguments.completed) else {
            return .stillUnknown("提醒事项当前状态或属性与目标不一致；不会盲目再次写入。")
        }
        return .completed(Self.verifiedResult(snapshot, requestedID: arguments.reminderID, applied: nil))
    }

    nonisolated static func readbackMatchesV1(
        _ snapshot: ReminderManagementSnapshot,
        desired: Bool
    ) -> Bool {
        snapshot.completed == desired
            && snapshot.calendarWritable
            && !snapshot.hasRecurrence
    }

    private static func verifiedResult(
        _ snapshot: ReminderManagementSnapshot,
        requestedID: String,
        applied: Bool?
    ) -> DeviceExecutionResult {
        var output = snapshot.deviceObject()
        output["requested_reminder_id"] = .string(requestedID)
        output["verified"] = .bool(true)
        if let applied { output["applied"] = .bool(applied) }
        return .success(output, nativeCorrelationID: snapshot.reminderID)
    }
}


private struct ReminderUpdateArguments: Sendable {
    let reminderID: String
    let expectedRevision: String
    let expectedListID: String
    let title: String
    let notes: String
    let priority: Int
    let dueMode: String
    let dueAt: Date?
    let dueAtRaw: String
    let dueTimeZone: TimeZone?
    let dueTimeZoneID: String
    let alarmMode: String

    init?(_ payload: [String: JSONValue]) {
        let required: Set<String> = [
            "reminder_id", "expected_revision", "expected_list_id", "title", "notes",
            "priority", "due_mode", "due_at", "due_time_zone", "alarm_mode",
        ]
        guard Set(payload.keys) == required,
              let reminderID = payload["reminder_id"]?.stringValue,
              reminderID == reminderID.trimmingCharacters(in: .whitespacesAndNewlines),
              !reminderID.isEmpty, reminderID.count <= 512,
              let revision = payload["expected_revision"]?.stringValue,
              revision.count == 64, revision.allSatisfy({ $0.isHexDigit }),
              let listID = payload["expected_list_id"]?.stringValue,
              listID == listID.trimmingCharacters(in: .whitespacesAndNewlines),
              !listID.isEmpty, listID.count <= 512,
              let title = payload["title"]?.stringValue,
              title == title.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title.count <= 160,
              let notes = payload["notes"]?.stringValue, notes.count <= 4_000,
              case let .number(priorityNumber) = payload["priority"],
              priorityNumber.rounded() == priorityNumber, priorityNumber >= 0, priorityNumber <= 9,
              let dueMode = payload["due_mode"]?.stringValue,
              dueMode == "none" || dueMode == "timed",
              let dueAtRaw = payload["due_at"]?.stringValue,
              let dueZoneID = payload["due_time_zone"]?.stringValue,
              let alarmMode = payload["alarm_mode"]?.stringValue,
              alarmMode == "none" || alarmMode == "at_due" else { return nil }
        self.reminderID = reminderID
        expectedRevision = revision.lowercased()
        expectedListID = listID
        self.title = title
        self.notes = notes
        priority = Int(priorityNumber)
        self.dueMode = dueMode
        self.alarmMode = alarmMode
        self.dueAtRaw = dueAtRaw
        dueTimeZoneID = dueZoneID
        if dueMode == "none" {
            guard dueAtRaw.isEmpty, dueZoneID.isEmpty, alarmMode == "none" else { return nil }
            dueAt = nil
            dueTimeZone = nil
        } else {
            guard !dueAtRaw.isEmpty,
                  dueAtRaw == dueAtRaw.trimmingCharacters(in: .whitespacesAndNewlines),
                  dueAtRaw.count <= 40,
                  !dueZoneID.isEmpty,
                  dueZoneID == dueZoneID.trimmingCharacters(in: .whitespacesAndNewlines),
                  dueZoneID.count <= 64,
                  let zone = TimeZone(identifier: dueZoneID),
                  let due = Self.parseInstant(dueAtRaw),
                  Self.offset(in: dueAtRaw) == zone.secondsFromGMT(for: due) else { return nil }
            dueAt = due
            dueTimeZone = zone
        }
    }

    private static func parseInstant(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let normal = ISO8601DateFormatter()
        normal.formatOptions = [.withInternetDateTime]
        return normal.date(from: raw)
    }

    private static func offset(in raw: String) -> Int? {
        if raw.hasSuffix("Z") { return 0 }
        guard raw.count >= 6 else { return nil }
        let suffix = String(raw.suffix(6))
        let chars = Array(suffix)
        guard chars.count == 6, (chars[0] == "+" || chars[0] == "-"), chars[3] == ":",
              let hours = Int(String(chars[1...2])), let minutes = Int(String(chars[4...5])),
              hours <= 23, minutes < 60 else { return nil }
        let value = hours * 3_600 + minutes * 60
        return chars[0] == "-" ? -value : value
    }
}

private enum ReminderUpdateReadbackError: Error, LocalizedError {
    case missing
    case mismatch
    case completionChanged

    var errorDescription: String? {
        switch self {
        case .missing: return "提醒事项可能已经修改，但暂时无法按原生 ID 读回；不会再次写入。"
        case .mismatch: return "提醒事项保存后的原生读回与完整目标状态不一致；不会再次写入。"
        case .completionChanged: return "修改期间提醒事项的完成状态发生了变化，无法确认来源；不会再次写入。"
        }
    }
}

actor ReminderUpdateExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID = "reminder.update"
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    private struct CompletionState: Sendable {
        let completed: Bool
        let completionAt: Date?
    }

    func preflight(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult? {
        guard let arguments = ReminderUpdateArguments(dispatch.payload) else {
            return reminderFailure(.updateInvalid, "提醒事项修改参数无效。")
        }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return reminderFailure(.fullAccessRequired, "请先在花卷设置中允许提醒事项完整访问。")
        }
        eventStore.reset()
        guard let reminder = eventStore.calendarItem(withIdentifier: arguments.reminderID) as? EKReminder,
              let snapshot = ReminderManagementSnapshot.read(reminder) else {
            return reminderFailure(.targetMissing, "这个提醒事项已经不存在或原生标识已变化，请重新查询。")
        }
        if let failure = Self.preconditionFailure(snapshot, arguments: arguments, requireRevision: true) {
            return failure
        }
        return nil
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        guard let arguments = ReminderUpdateArguments(dispatch.payload) else {
            return reminderFailure(.updateInvalid, "提醒事项修改参数无效。")
        }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return reminderFailure(.fullAccessRequired, "提醒事项权限已变化，尚未写入。")
        }
        eventStore.reset()
        guard let reminder = eventStore.calendarItem(withIdentifier: arguments.reminderID) as? EKReminder,
              let snapshot = ReminderManagementSnapshot.read(reminder) else {
            return reminderFailure(.targetMissing, "这个提醒事项已经不存在或原生标识已变化；没有写入。")
        }
        if let failure = Self.preconditionFailure(snapshot, arguments: arguments, requireRevision: false) {
            return failure
        }
        let protectedCompletion = CompletionState(completed: snapshot.completed, completionAt: snapshot.completionAt)
        if Self.desiredStateMatches(snapshot, arguments: arguments) {
            return Self.verifiedResult(
                snapshot,
                requestedID: arguments.reminderID,
                protectedCompletion: protectedCompletion,
                applied: false
            )
        }
        guard snapshot.revision == arguments.expectedRevision else {
            return reminderFailure(.revisionStale, "提醒事项已发生变化，请重新查询后再修改。")
        }

        reminder.title = arguments.title
        reminder.notes = arguments.notes.isEmpty ? nil : arguments.notes
        reminder.priority = arguments.priority
        for alarm in reminder.alarms ?? [] { reminder.removeAlarm(alarm) }
        if arguments.dueMode == "none" {
            reminder.startDateComponents = nil
            reminder.dueDateComponents = nil
        } else {
            guard let due = arguments.dueAt, let zone = arguments.dueTimeZone else {
                return reminderFailure(.updateInvalid, "提醒事项到期时间参数无效。")
            }
            let components = Self.dateComponents(for: due, timeZone: zone)
            reminder.startDateComponents = components
            reminder.dueDateComponents = components
            if arguments.alarmMode == "at_due" {
                reminder.addAlarm(EKAlarm(absoluteDate: due))
            }
        }

        // No suspension is allowed between the final fresh guard above and this
        // single native save. Once invoked, any ambiguous failure is reconciled
        // read-only by DeviceActionJournal and is never blindly saved again.
        try eventStore.save(reminder, commit: true)
        guard reminder.calendarItemIdentifier == arguments.reminderID else {
            throw ReminderUpdateReadbackError.missing
        }
        eventStore.reset()
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess,
              let readback = eventStore.calendarItem(withIdentifier: arguments.reminderID) as? EKReminder,
              let final = ReminderManagementSnapshot.read(readback) else {
            throw ReminderUpdateReadbackError.missing
        }
        guard final.calendarID == arguments.expectedListID,
              final.calendarWritable, !final.hasRecurrence, final.updateEligible,
              Self.desiredStateMatches(final, arguments: arguments) else {
            throw ReminderUpdateReadbackError.mismatch
        }
        guard Self.completionMatches(final, protected: protectedCompletion) else {
            throw ReminderUpdateReadbackError.completionChanged
        }
        return Self.verifiedResult(
            final,
            requestedID: arguments.reminderID,
            protectedCompletion: protectedCompletion,
            applied: true
        )
    }

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        guard let arguments = ReminderUpdateArguments(dispatch.payload) else {
            return .completed(reminderFailure(.updateInvalid, "提醒事项修改参数无效。"))
        }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return .stillUnknown("需要恢复提醒事项完整访问后才能核对这次修改；不会再次写入。")
        }
        eventStore.reset()
        guard let reminder = eventStore.calendarItem(withIdentifier: arguments.reminderID) as? EKReminder,
              let snapshot = ReminderManagementSnapshot.read(reminder) else {
            return .stillUnknown("提醒事项当前无法按原生 ID 找到；无法判断之前的修改是否曾经提交，不会再次写入。")
        }
        guard snapshot.calendarID == arguments.expectedListID,
              snapshot.calendarWritable, !snapshot.hasRecurrence, snapshot.updateEligible,
              Self.desiredStateMatches(snapshot, arguments: arguments) else {
            return .stillUnknown("提醒事项当前状态或归属与完整目标不一致；不会盲目再次写入。")
        }
        let currentCompletion = CompletionState(completed: snapshot.completed, completionAt: snapshot.completionAt)
        return .completed(Self.verifiedResult(
            snapshot,
            requestedID: arguments.reminderID,
            protectedCompletion: currentCompletion,
            applied: nil
        ))
    }

    private nonisolated static func preconditionFailure(
        _ snapshot: ReminderManagementSnapshot,
        arguments: ReminderUpdateArguments,
        requireRevision: Bool
    ) -> DeviceExecutionResult? {
        guard snapshot.calendarID == arguments.expectedListID else {
            return reminderFailure(.targetChanged, "提醒事项已移动到其他列表，请重新查询。")
        }
        guard snapshot.calendarWritable else {
            return reminderFailure(.readOnlyList, "这个提醒事项所在列表当前不可修改。")
        }
        guard !snapshot.hasRecurrence else {
            return reminderFailure(.recurringUnsupported, "当前版本不会修改重复提醒事项。")
        }
        guard snapshot.updateEligible else {
            return reminderFailure(
                .updateUnsupportedTopology,
                snapshot.updateIneligibleReason ?? "这个提醒事项当前的到期时间或提醒方式较复杂，暂不自动修改。"
            )
        }
        if requireRevision, snapshot.revision != arguments.expectedRevision {
            return reminderFailure(.revisionStale, "提醒事项已发生变化，请重新查询后再修改。")
        }
        return nil
    }

    private nonisolated static func desiredStateMatches(
        _ snapshot: ReminderManagementSnapshot,
        arguments: ReminderUpdateArguments
    ) -> Bool {
        guard snapshot.title == arguments.title,
              snapshot.notes == arguments.notes,
              snapshot.priority == arguments.priority,
              snapshot.dueMode == arguments.dueMode,
              snapshot.alarmMode == arguments.alarmMode else { return false }
        if arguments.dueMode == "none" {
            return snapshot.dueAt == nil && snapshot.dueTimeZone == ""
        }
        guard let expectedDue = arguments.dueAt,
              let actualDue = snapshot.dueAt,
              abs(actualDue.timeIntervalSince(expectedDue)) < 1.0 else { return false }
        return snapshot.dueTimeZone == arguments.dueTimeZoneID
    }

    private nonisolated static func completionMatches(
        _ snapshot: ReminderManagementSnapshot,
        protected: CompletionState
    ) -> Bool {
        guard snapshot.completed == protected.completed else { return false }
        switch (snapshot.completionAt, protected.completionAt) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return abs(lhs.timeIntervalSince(rhs)) < 1.0
        default: return false
        }
    }

    private nonisolated static func dateComponents(for date: Date, timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = calendar.dateComponents(
            [.era, .year, .month, .day, .hour, .minute, .second], from: date
        )
        components.calendar = calendar
        components.timeZone = timeZone
        return components
    }

    private nonisolated static func verifiedResult(
        _ snapshot: ReminderManagementSnapshot,
        requestedID: String,
        protectedCompletion: CompletionState,
        applied: Bool?
    ) -> DeviceExecutionResult {
        var output = snapshot.deviceObject()
        output["requested_reminder_id"] = .string(requestedID)
        output["completion_preserved"] = .bool(completionMatches(snapshot, protected: protectedCompletion))
        output["verified"] = .bool(true)
        if let applied { output["applied"] = .bool(applied) }
        return .success(output, nativeCorrelationID: snapshot.reminderID)
    }
}


private struct ReminderRemoveArguments: Sendable {
    let reminderID: String
    let expectedRevision: String
    let expectedListID: String
    let expectedTitle: String

    init?(_ payload: [String: JSONValue]) {
        guard Set(payload.keys) == ["reminder_id", "expected_revision", "expected_list_id", "expected_title"],
              let reminderID = payload["reminder_id"]?.stringValue,
              reminderID == reminderID.trimmingCharacters(in: .whitespacesAndNewlines),
              !reminderID.isEmpty, reminderID.count <= 512,
              let revision = payload["expected_revision"]?.stringValue,
              revision.count == 64, revision.allSatisfy({ $0.isHexDigit }),
              let listID = payload["expected_list_id"]?.stringValue,
              listID == listID.trimmingCharacters(in: .whitespacesAndNewlines),
              !listID.isEmpty, listID.count <= 512,
              let title = payload["expected_title"]?.stringValue,
              title == title.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title.count <= 160 else { return nil }
        self.reminderID = reminderID
        expectedRevision = revision.lowercased()
        expectedListID = listID
        expectedTitle = title
    }
}

private enum ReminderRemoveReadbackError: Error, LocalizedError {
    case permissionChanged
    case stillPresent

    var errorDescription: String? {
        switch self {
        case .permissionChanged:
            return "提醒事项删除可能已经提交，但权限在读回前发生变化；不会再次删除。"
        case .stillPresent:
            return "提醒事项删除调用已经返回，但精确 ID 仍可读到；不会再次删除。"
        }
    }
}

actor ReminderRemoveExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID = "reminder.remove"
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func preflight(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult? {
        guard let arguments = ReminderRemoveArguments(dispatch.payload) else {
            return reminderFailure(.removeInvalid, "提醒事项删除参数无效。")
        }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return reminderFailure(.fullAccessRequired, "请先在花卷设置中允许提醒事项完整访问。")
        }
        eventStore.reset()
        guard let reminder = eventStore.calendarItem(withIdentifier: arguments.reminderID) as? EKReminder else {
            return reminderFailure(.targetMissing, "这个提醒事项已经不存在或原生标识已变化，请重新查询。")
        }
        guard let snapshot = ReminderManagementSnapshot.read(reminder) else {
            return reminderFailure(.targetChanged, "这个提醒事项当前缺少有效的列表归属，请重新查询。")
        }
        return Self.preconditionFailure(snapshot, arguments: arguments)
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        guard let arguments = ReminderRemoveArguments(dispatch.payload) else {
            return reminderFailure(.removeInvalid, "提醒事项删除参数无效。")
        }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return reminderFailure(.fullAccessRequired, "提醒事项权限已变化，尚未删除。")
        }
        eventStore.reset()
        guard let reminder = eventStore.calendarItem(withIdentifier: arguments.reminderID) as? EKReminder else {
            return reminderFailure(.targetMissing, "这个提醒事项已经不存在或原生标识已变化；没有删除。")
        }
        guard let snapshot = ReminderManagementSnapshot.read(reminder) else {
            return reminderFailure(.targetChanged, "这个提醒事项当前缺少有效的列表归属；没有删除。")
        }
        if let failure = Self.preconditionFailure(snapshot, arguments: arguments) {
            return failure
        }

        // Exactly one destructive native call, after a fresh exact-ID/revision
        // check and with no suspension between that guard and commit.
        try eventStore.remove(reminder, commit: true)

        // A successful return plus immediate exact-ID absence is the only
        // positive proof. Any uncertainty after remove must remain journalled as
        // UNKNOWN rather than being converted into a retryable failure.
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            throw ReminderRemoveReadbackError.permissionChanged
        }
        eventStore.reset()
        guard eventStore.calendarItem(withIdentifier: arguments.reminderID) == nil else {
            throw ReminderRemoveReadbackError.stillPresent
        }
        return .success(
            [
                "requested_reminder_id": .string(arguments.reminderID),
                "list_id": .string(arguments.expectedListID),
                "title": .string(arguments.expectedTitle),
                "deleted": .bool(true),
                "verified": .bool(true),
                "verification": .string("immediate_exact_id_absence"),
            ],
            nativeCorrelationID: arguments.reminderID
        )
    }

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        guard let arguments = ReminderRemoveArguments(dispatch.payload) else {
            return .completed(reminderFailure(.removeInvalid, "提醒事项删除参数无效。"))
        }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return .stillUnknown("恢复提醒事项完整访问后才能核对这次删除；不会再次删除。")
        }
        eventStore.reset()
        if let reminder = eventStore.calendarItem(withIdentifier: arguments.reminderID) as? EKReminder,
           let snapshot = ReminderManagementSnapshot.read(reminder) {
            let title = Self.displayTitle(snapshot)
            if snapshot.reminderID == arguments.reminderID,
               snapshot.calendarID == arguments.expectedListID,
               title == arguments.expectedTitle,
               snapshot.revision == arguments.expectedRevision {
                return .stillUnknown("原提醒事项当前仍存在，但无法证明先前删除调用从未提交；不会自动再次删除。")
            }
            return .stillUnknown("原生 ID 当前指向的提醒事项状态已经变化，无法安全判断先前删除结果；不会再次删除。")
        }
        // EventKit Reminder identifiers are not durable across all sync/provider
        // transitions, so post-crash absence alone is not deletion proof.
        return .stillUnknown("原提醒事项当前无法按精确 ID 找到；删除提交与同步重标识无法区分，不会再次删除。")
    }

    private nonisolated static func displayTitle(_ snapshot: ReminderManagementSnapshot) -> String {
        snapshot.title.isEmpty ? "无标题" : snapshot.title
    }

    private nonisolated static func preconditionFailure(
        _ snapshot: ReminderManagementSnapshot,
        arguments: ReminderRemoveArguments
    ) -> DeviceExecutionResult? {
        guard snapshot.reminderID == arguments.reminderID else {
            return reminderFailure(.targetMissing, "提醒事项缺少当前可用的原生标识，请重新查询。")
        }
        guard snapshot.calendarID == arguments.expectedListID else {
            return reminderFailure(.targetChanged, "提醒事项已经移动到其他列表，请重新查询。")
        }
        guard displayTitle(snapshot) == arguments.expectedTitle else {
            return reminderFailure(.revisionStale, "提醒事项标题已发生变化，请重新查询后再删除。")
        }
        guard snapshot.calendarWritable else {
            return reminderFailure(.readOnlyList, "这个提醒事项所在列表当前不可修改。")
        }
        guard !snapshot.hasRecurrence else {
            return reminderFailure(.recurringUnsupported, "当前版本不会删除重复提醒事项或整个重复系列。")
        }
        guard snapshot.revision == arguments.expectedRevision else {
            return reminderFailure(.revisionStale, "提醒事项已发生变化，请重新查询后再删除。")
        }
        return nil
    }
}


@MainActor
@Observable
final class ReminderPermissionModel {
    private(set) var status = EKEventStore.authorizationStatus(for: .reminder)
    private(set) var isRequesting = false
    private(set) var errorMessage: String?

    var hasFullAccess: Bool {
        status == .fullAccess
    }

    var statusLabel: String {
        switch status {
        case .fullAccess: return "已允许"
        case .notDetermined: return "尚未请求"
        case .denied: return "已拒绝"
        case .restricted: return "受系统限制"
        case .writeOnly: return "仅写入（提醒事项需要完整访问）"
        case .authorized: return "已允许"
        @unknown default: return "未知"
        }
    }

    func refresh() {
        status = EKEventStore.authorizationStatus(for: .reminder)
    }

    func requestFullAccess() async {
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }

        let store = EKEventStore()
        do {
            // Use EventKit's native async API instead of wrapping the callback
            // ourselves. After the sheet returns, reset this store before any
            // later fetch/create operation so EventKit observes the new grant.
            let granted = try await store.requestFullAccessToReminders()
            store.reset()
            refresh()
            if granted && status == .fullAccess {
                errorMessage = nil
            } else if granted {
                errorMessage = "系统返回已允许，但当前授权状态仍是 \(statusLabel)。请返回上一页再进入一次；如果仍不更新，小卷会继续显示诊断状态。"
            } else {
                errorMessage = "没有获得提醒事项访问权限。"
            }
        } catch {
            refresh()
            errorMessage = "提醒事项授权失败：\(error.localizedDescription)"
        }
    }
}
