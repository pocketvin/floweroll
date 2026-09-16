import CryptoKit
import EventKit
import Foundation
import Observation


struct CalendarEventSnapshot: Sendable {
    let identifier: String?
    let revision: String?
    let title: String
    let startDate: Date
    let endDate: Date
    let timeZoneID: String?
    let isAllDay: Bool
    let location: String
    let availability: EKEventAvailability
    let calendarID: String
    let calendarName: String
    let calendarWritable: Bool
    let hasRecurrence: Bool
    let isDetached: Bool
    let hasAttendees: Bool
    let hasOrganizer: Bool
    let lastModifiedAt: Date?
    let updateEligible: Bool
    let updateIneligibleReason: String?
    let removeEligible: Bool
    let removeIneligibleReason: String?

    private struct RevisionPayload: Codable {
        let eventID: String
        let calendarItemID: String
        let calendarID: String
        let calendarWritable: Bool
        let title: String
        let startMillis: Int64
        let endMillis: Int64
        let timeZoneID: String?
        let allDay: Bool
        let location: String
        let hasRecurrence: Bool
        let isDetached: Bool
        let occurrenceMillis: Int64?
        let hasAttendees: Bool
        let hasOrganizer: Bool
        let status: Int
        let lastModifiedMillis: Int64?
    }

    static func read(_ event: EKEvent) -> CalendarEventSnapshot {
        let eventID = event.eventIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedID = eventID?.isEmpty == false ? eventID : nil
        let location = (event.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let timeZoneID = event.timeZone?.identifier
        let hasRecurrence = event.hasRecurrenceRules
        let hasOrganizer = event.organizer != nil
        let eligible = normalizedID != nil
            && event.calendar.allowsContentModifications
            && !event.isAllDay
            && timeZoneID != nil
            && !hasRecurrence
            && !event.isDetached
            && !event.hasAttendees
            && !hasOrganizer
            && event.status != .canceled
        let removeEligible = normalizedID != nil
            && event.calendar.allowsContentModifications
            && !hasRecurrence
            && !event.isDetached
            && !event.hasAttendees
            && !hasOrganizer
            && event.status != .canceled
        let reason: String?
        if normalizedID == nil { reason = "当前日程没有可用于精确修改的原生标识。" }
        else if !event.calendar.allowsContentModifications { reason = "当前日历不可修改。" }
        else if event.isAllDay || timeZoneID == nil { reason = "全天或浮动时间日程暂不支持直接修改。" }
        // EventKit 27 may populate occurrenceDate even for an ordinary one-off
        // event. Keep it as revision evidence, but use the documented semantic
        // recurrence/detached signals as the mutation gate.
        else if hasRecurrence || event.isDetached { reason = "重复日程或单次例外暂不支持直接修改。" }
        else if event.hasAttendees || hasOrganizer { reason = "带参会人或组织者的日程暂不自动修改。" }
        else if event.status == .canceled { reason = "已取消的日程不能作为修改目标。" }
        else { reason = nil }
        let removeReason: String?
        if normalizedID == nil { removeReason = "当前日程没有可用于精确删除的原生标识。" }
        else if !event.calendar.allowsContentModifications { removeReason = "当前日历不可修改。" }
        else if hasRecurrence || event.isDetached { removeReason = "重复日程或单次例外暂不支持删除。" }
        else if event.hasAttendees || hasOrganizer { removeReason = "带参会人或组织者的日程暂不自动删除。" }
        else if event.status == .canceled { removeReason = "已取消的日程不能作为删除目标。" }
        else { removeReason = nil }

        let revision: String?
        if let normalizedID {
            let payload = RevisionPayload(
                eventID: normalizedID,
                calendarItemID: event.calendarItemIdentifier,
                calendarID: event.calendar.calendarIdentifier,
                calendarWritable: event.calendar.allowsContentModifications,
                title: event.title ?? "",
                startMillis: Self.milliseconds(event.startDate),
                endMillis: Self.milliseconds(event.endDate),
                timeZoneID: timeZoneID,
                allDay: event.isAllDay,
                location: location,
                hasRecurrence: hasRecurrence,
                isDetached: event.isDetached,
                occurrenceMillis: event.occurrenceDate.map(Self.milliseconds),
                hasAttendees: event.hasAttendees,
                hasOrganizer: hasOrganizer,
                status: event.status.rawValue,
                lastModifiedMillis: event.lastModifiedDate.map(Self.milliseconds)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(payload) {
                revision = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            } else {
                revision = nil
            }
        } else {
            revision = nil
        }
        return .init(
            identifier: normalizedID,
            revision: revision,
            title: event.title ?? "",
            startDate: event.startDate,
            endDate: event.endDate,
            timeZoneID: timeZoneID,
            isAllDay: event.isAllDay,
            location: location,
            availability: event.availability,
            calendarID: event.calendar.calendarIdentifier,
            calendarName: event.calendar.title,
            calendarWritable: event.calendar.allowsContentModifications,
            hasRecurrence: hasRecurrence,
            isDetached: event.isDetached,
            hasAttendees: event.hasAttendees,
            hasOrganizer: hasOrganizer,
            lastModifiedAt: event.lastModifiedDate,
            updateEligible: eligible && revision != nil,
            updateIneligibleReason: reason,
            removeEligible: removeEligible && revision != nil,
            removeIneligibleReason: removeReason
        )
    }

    func deviceObject() -> [String: JSONValue] {
        [
            "event_id": identifier.map(JSONValue.string) ?? .null,
            "revision": revision.map(JSONValue.string) ?? .null,
            "title": .string(title),
            "start_at": .string(Self.iso8601(startDate)),
            "end_at": .string(Self.iso8601(endDate)),
            "time_zone": timeZoneID.map(JSONValue.string) ?? .string(""),
            "location": .string(location),
            "calendar_id": .string(calendarID),
            "calendar_name": .string(calendarName.isEmpty ? "未命名日历" : calendarName),
            "calendar_writable": .bool(calendarWritable),
            "all_day": .bool(isAllDay),
            "has_recurrence": .bool(hasRecurrence),
            "is_detached": .bool(isDetached),
            "has_attendees": .bool(hasAttendees),
            "has_organizer": .bool(hasOrganizer),
            "last_modified_at": lastModifiedAt.map { .string(Self.iso8601($0)) } ?? .null,
            "update_eligible": .bool(updateEligible),
            "update_ineligible_reason": updateIneligibleReason.map(JSONValue.string) ?? .null,
            "remove_eligible": .bool(removeEligible),
            "remove_ineligible_reason": removeIneligibleReason.map(JSONValue.string) ?? .null,
        ]
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

private struct CalendarWindow: Sendable {
    let startAt: String
    let endAt: String
    let startDate: Date
    let endDate: Date
}

enum CalendarReadError: Error, LocalizedError, Sendable {
    case invalidArguments

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "日历查询参数无效。"
        }
    }
}

actor CalendarFreeBusyExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID = "calendar.freebusy"
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func preflight(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult? {
        guard Self.window(from: dispatch) != nil else {
            return .failure("invalid calendar.freebusy arguments")
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return .failure("calendar_full_access_required")
        }
        return nil
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        guard let window = Self.window(from: dispatch) else {
            throw CalendarReadError.invalidArguments
        }
        eventStore.reset()
        let predicate = eventStore.predicateForEvents(
            withStart: window.startDate,
            end: window.endDate,
            calendars: nil
        )
        let events = eventStore.events(matching: predicate)
            .filter { $0.status != .canceled }
            .sorted { lhs, rhs in
                if lhs.startDate == rhs.startDate { return lhs.endDate < rhs.endDate }
                return lhs.startDate < rhs.startDate
            }
            .map(CalendarEventSnapshot.read)
        let busyEvents = events.filter { $0.availability != .free }
        let intervals = Self.mergedBusyIntervals(
            busyEvents,
            windowStart: window.startDate,
            windowEnd: window.endDate
        )
        return .success([
            "start_at": .string(window.startAt),
            "end_at": .string(window.endAt),
            "is_free": .bool(intervals.isEmpty),
            "event_count": .number(Double(busyEvents.count)),
            "busy_intervals": .array(intervals.map { interval in
                .object([
                    "start_at": .string(Self.iso8601(interval.start)),
                    "end_at": .string(Self.iso8601(interval.end)),
                    "all_day": .bool(interval.allDay),
                ])
            }),
            "verified": .bool(true),
        ])
    }

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        // This capability is read-only, so rereading EventKit is the
        // authoritative and safe reconciliation operation.
        .completed(try await execute(dispatch))
    }

    private struct BusyInterval: Sendable {
        var start: Date
        var end: Date
        var allDay: Bool
    }

    private static func mergedBusyIntervals(
        _ events: [CalendarEventSnapshot],
        windowStart: Date,
        windowEnd: Date
    ) -> [BusyInterval] {
        let sorted = events.compactMap { event -> BusyInterval? in
            let start = max(event.startDate, windowStart)
            let end = min(event.endDate, windowEnd)
            guard end > start else { return nil }
            return BusyInterval(start: start, end: end, allDay: event.isAllDay)
        }
        .sorted { lhs, rhs in
            if lhs.start == rhs.start { return lhs.end < rhs.end }
            return lhs.start < rhs.start
        }

        var merged: [BusyInterval] = []
        for interval in sorted {
            guard var last = merged.last else {
                merged.append(interval)
                continue
            }
            if interval.start <= last.end {
                last.end = max(last.end, interval.end)
                last.allDay = last.allDay || interval.allDay
                merged[merged.count - 1] = last
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    private static func window(from dispatch: DeviceActionDispatch) -> CalendarWindow? {
        parseWindow(payload: dispatch.payload)
    }
}

actor CalendarQueryExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID = "calendar.query"
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func preflight(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult? {
        guard Self.window(from: dispatch) != nil else {
            return .failure("invalid calendar.query arguments")
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return .failure("calendar_full_access_required")
        }
        return nil
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        guard let window = Self.window(from: dispatch) else {
            throw CalendarReadError.invalidArguments
        }
        let requestedMax = dispatch.payload["max_results"]?.numberValue.map(Int.init) ?? 50
        let maxResults = min(100, max(1, requestedMax))
        eventStore.reset()
        let predicate = eventStore.predicateForEvents(
            withStart: window.startDate,
            end: window.endDate,
            calendars: nil
        )
        let events = eventStore.events(matching: predicate)
            .filter { $0.status != .canceled }
            .sorted { lhs, rhs in
                if lhs.startDate == rhs.startDate { return lhs.endDate < rhs.endDate }
                return lhs.startDate < rhs.startDate
            }
            .map(CalendarEventSnapshot.read)
        let visible = Array(events.prefix(maxResults))
        let encoded: [JSONValue] = visible.map { .object($0.deviceObject()) }
        return .success([
            "start_at": .string(window.startAt),
            "end_at": .string(window.endAt),
            "events": .array(encoded),
            "truncated": .bool(events.count > maxResults),
            "verified": .bool(true),
        ])
    }

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        .completed(try await execute(dispatch))
    }

    private static func window(from dispatch: DeviceActionDispatch) -> CalendarWindow? {
        parseWindow(payload: dispatch.payload)
    }
}


private enum CalendarUpdateFailureCode: String {
    case invalid = "calendar_update_invalid"
    case targetMissing = "calendar_event_not_found_or_stale"
    case revisionStale = "calendar_update_revision_stale"
    case calendarChanged = "calendar_update_calendar_changed"
    case readOnlyCalendar = "calendar_update_read_only_calendar"
    case unsupportedTarget = "calendar_update_unsupported_target"
    case fullAccessRequired = "calendar_full_access_required"
}

private func calendarUpdateFailure(
    _ code: CalendarUpdateFailureCode,
    _ message: String
) -> DeviceExecutionResult {
    .failure(message, output: ["error_code": .string(code.rawValue)])
}

private struct CalendarUpdateArguments: Sendable {
    let eventID: String
    let expectedRevision: String
    let expectedCalendarID: String
    let title: String
    let startDate: Date
    let endDate: Date
    let timeZone: TimeZone
    let timeZoneID: String
    let location: String

    init?(_ payload: [String: JSONValue]) {
        let required: Set<String> = [
            "event_id", "expected_revision", "expected_calendar_id", "title",
            "start_at", "end_at", "time_zone", "location",
        ]
        guard Set(payload.keys) == required,
              let eventID = payload["event_id"]?.stringValue,
              eventID == eventID.trimmingCharacters(in: .whitespacesAndNewlines),
              !eventID.isEmpty, eventID.count <= 512,
              let revision = payload["expected_revision"]?.stringValue,
              revision.count == 64, revision.allSatisfy({ $0.isHexDigit }),
              let calendarID = payload["expected_calendar_id"]?.stringValue,
              calendarID == calendarID.trimmingCharacters(in: .whitespacesAndNewlines),
              !calendarID.isEmpty, calendarID.count <= 512,
              let title = payload["title"]?.stringValue,
              title == title.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title.count <= 160,
              let startRaw = payload["start_at"]?.stringValue,
              startRaw == startRaw.trimmingCharacters(in: .whitespacesAndNewlines), startRaw.count <= 40,
              let endRaw = payload["end_at"]?.stringValue,
              endRaw == endRaw.trimmingCharacters(in: .whitespacesAndNewlines), endRaw.count <= 40,
              let zoneID = payload["time_zone"]?.stringValue,
              zoneID == zoneID.trimmingCharacters(in: .whitespacesAndNewlines),
              !zoneID.isEmpty, zoneID.count <= 64,
              let zone = TimeZone(identifier: zoneID),
              let start = parseCalendarISO8601(startRaw),
              let end = parseCalendarISO8601(endRaw),
              end > start, end.timeIntervalSince(start) <= 7 * 86_400,
              Self.offset(in: startRaw) == zone.secondsFromGMT(for: start),
              Self.offset(in: endRaw) == zone.secondsFromGMT(for: end),
              let location = payload["location"]?.stringValue,
              location == location.trimmingCharacters(in: .whitespacesAndNewlines), location.count <= 500 else {
            return nil
        }
        self.eventID = eventID
        expectedRevision = revision.lowercased()
        expectedCalendarID = calendarID
        self.title = title
        startDate = start
        endDate = end
        timeZone = zone
        timeZoneID = zoneID
        self.location = location
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

private enum CalendarUpdateReadbackError: Error, LocalizedError {
    case missing
    case mismatch

    var errorDescription: String? {
        switch self {
        case .missing: return "日程可能已经修改，但暂时无法按原生 ID 读回；不会再次写入。"
        case .mismatch: return "日程保存后的原生读回与完整目标状态不一致；不会再次写入。"
        }
    }
}

actor CalendarUpdateExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID = "calendar.update"
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func preflight(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult? {
        guard let arguments = CalendarUpdateArguments(dispatch.payload) else {
            return calendarUpdateFailure(.invalid, "日程修改参数无效。")
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return calendarUpdateFailure(.fullAccessRequired, "请先在花卷设置中允许日历完整访问。")
        }
        eventStore.reset()
        guard let event = eventStore.event(withIdentifier: arguments.eventID) else {
            return calendarUpdateFailure(.targetMissing, "这个日程已经不存在或原生标识已变化，请重新查询。")
        }
        let snapshot = CalendarEventSnapshot.read(event)
        if let failure = Self.preconditionFailure(snapshot, arguments: arguments, requireRevision: true) {
            return failure
        }
        return nil
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        guard let arguments = CalendarUpdateArguments(dispatch.payload) else {
            return calendarUpdateFailure(.invalid, "日程修改参数无效。")
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return calendarUpdateFailure(.fullAccessRequired, "日历权限已变化，尚未写入。")
        }
        eventStore.reset()
        guard let event = eventStore.event(withIdentifier: arguments.eventID) else {
            return calendarUpdateFailure(.targetMissing, "这个日程已经不存在或原生标识已变化；没有写入。")
        }
        let snapshot = CalendarEventSnapshot.read(event)
        if let failure = Self.preconditionFailure(snapshot, arguments: arguments, requireRevision: false) {
            return failure
        }
        if Self.desiredStateMatches(snapshot, arguments: arguments) {
            return Self.verifiedResult(snapshot, requestedID: arguments.eventID, applied: false)
        }
        guard snapshot.revision == arguments.expectedRevision else {
            return calendarUpdateFailure(.revisionStale, "日程已发生变化，请重新查询后再修改。")
        }

        event.title = arguments.title
        event.startDate = arguments.startDate
        event.endDate = arguments.endDate
        event.timeZone = arguments.timeZone
        event.location = arguments.location.isEmpty ? nil : arguments.location
        // One and only one V1 save. There is no suspension between the final
        // fresh revision guard and this EventKit side-effect boundary.
        try eventStore.save(event, span: .thisEvent, commit: true)
        guard event.eventIdentifier == arguments.eventID else {
            throw CalendarUpdateReadbackError.missing
        }
        eventStore.reset()
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              let readback = eventStore.event(withIdentifier: arguments.eventID) else {
            throw CalendarUpdateReadbackError.missing
        }
        let final = CalendarEventSnapshot.read(readback)
        guard final.identifier == arguments.eventID,
              final.calendarID == arguments.expectedCalendarID,
              final.calendarWritable, final.updateEligible,
              Self.desiredStateMatches(final, arguments: arguments) else {
            throw CalendarUpdateReadbackError.mismatch
        }
        return Self.verifiedResult(final, requestedID: arguments.eventID, applied: true)
    }

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        guard let arguments = CalendarUpdateArguments(dispatch.payload) else {
            return .completed(calendarUpdateFailure(.invalid, "日程修改参数无效。"))
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return .stillUnknown("需要恢复日历完整访问后才能核对这次修改；不会再次写入。")
        }
        eventStore.reset()
        guard let event = eventStore.event(withIdentifier: arguments.eventID) else {
            return .stillUnknown("日程当前无法按原生 ID 找到；无法判断之前的修改是否曾经提交，不会再次写入。")
        }
        let snapshot = CalendarEventSnapshot.read(event)
        guard snapshot.identifier == arguments.eventID,
              snapshot.calendarID == arguments.expectedCalendarID,
              snapshot.calendarWritable, snapshot.updateEligible,
              Self.desiredStateMatches(snapshot, arguments: arguments) else {
            return .stillUnknown("日程当前状态或归属与完整目标不一致；不会盲目再次写入。")
        }
        return .completed(Self.verifiedResult(snapshot, requestedID: arguments.eventID, applied: nil))
    }

    private nonisolated static func preconditionFailure(
        _ snapshot: CalendarEventSnapshot,
        arguments: CalendarUpdateArguments,
        requireRevision: Bool
    ) -> DeviceExecutionResult? {
        guard snapshot.identifier == arguments.eventID else {
            return calendarUpdateFailure(.targetMissing, "日程缺少当前可用的原生标识，请重新查询。")
        }
        guard snapshot.calendarID == arguments.expectedCalendarID else {
            return calendarUpdateFailure(.calendarChanged, "日程已经移动到其他日历，请重新查询。")
        }
        guard snapshot.calendarWritable else {
            return calendarUpdateFailure(.readOnlyCalendar, "这个日程所在日历当前不可修改。")
        }
        guard snapshot.updateEligible else {
            return calendarUpdateFailure(
                .unsupportedTarget,
                snapshot.updateIneligibleReason ?? "这个日程包含当前版本不支持自动修改的复杂属性。"
            )
        }
        if requireRevision, snapshot.revision != arguments.expectedRevision {
            return calendarUpdateFailure(.revisionStale, "日程已发生变化，请重新查询后再修改。")
        }
        return nil
    }

    private nonisolated static func desiredStateMatches(
        _ snapshot: CalendarEventSnapshot,
        arguments: CalendarUpdateArguments
    ) -> Bool {
        snapshot.title == arguments.title
            && snapshot.location == arguments.location
            && snapshot.timeZoneID == arguments.timeZoneID
            && abs(snapshot.startDate.timeIntervalSince(arguments.startDate)) < 1.0
            && abs(snapshot.endDate.timeIntervalSince(arguments.endDate)) < 1.0
    }

    private nonisolated static func verifiedResult(
        _ snapshot: CalendarEventSnapshot,
        requestedID: String,
        applied: Bool?
    ) -> DeviceExecutionResult {
        var output = snapshot.deviceObject()
        output["requested_event_id"] = .string(requestedID)
        output["verified"] = .bool(true)
        if let applied { output["applied"] = .bool(applied) }
        return .success(output, nativeCorrelationID: snapshot.identifier)
    }
}


private enum CalendarRemoveFailureCode: String {
    case invalid = "calendar_remove_invalid"
    case targetMissing = "calendar_event_not_found_or_stale"
    case revisionStale = "calendar_remove_revision_stale"
    case calendarChanged = "calendar_remove_calendar_changed"
    case readOnlyCalendar = "calendar_remove_read_only_calendar"
    case unsupportedTarget = "calendar_remove_unsupported_target"
    case fullAccessRequired = "calendar_full_access_required"
}

private func calendarRemoveFailure(
    _ code: CalendarRemoveFailureCode,
    _ message: String
) -> DeviceExecutionResult {
    .failure(message, output: ["error_code": .string(code.rawValue)])
}

private struct CalendarRemoveArguments: Sendable {
    let eventID: String
    let expectedRevision: String
    let expectedCalendarID: String
    let expectedTitle: String

    init?(_ payload: [String: JSONValue]) {
        guard Set(payload.keys) == ["event_id", "expected_revision", "expected_calendar_id", "expected_title"],
              let eventID = payload["event_id"]?.stringValue,
              eventID == eventID.trimmingCharacters(in: .whitespacesAndNewlines),
              !eventID.isEmpty, eventID.count <= 512,
              let revision = payload["expected_revision"]?.stringValue,
              revision.count == 64, revision.allSatisfy({ $0.isHexDigit }),
              let calendarID = payload["expected_calendar_id"]?.stringValue,
              calendarID == calendarID.trimmingCharacters(in: .whitespacesAndNewlines),
              !calendarID.isEmpty, calendarID.count <= 512,
              let title = payload["expected_title"]?.stringValue,
              title == title.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title.count <= 160 else { return nil }
        self.eventID = eventID
        expectedRevision = revision.lowercased()
        expectedCalendarID = calendarID
        expectedTitle = title
    }
}

private enum CalendarRemoveReadbackError: Error, LocalizedError {
    case permissionChanged
    case stillPresent

    var errorDescription: String? {
        switch self {
        case .permissionChanged:
            return "日程删除可能已经提交，但权限在读回前发生变化；不会再次删除。"
        case .stillPresent:
            return "日程删除调用已经返回，但精确 ID 仍可读到；不会再次删除。"
        }
    }
}

actor CalendarRemoveExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID = "calendar.remove"
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func preflight(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult? {
        guard let arguments = CalendarRemoveArguments(dispatch.payload) else {
            return calendarRemoveFailure(.invalid, "日程删除参数无效。")
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return calendarRemoveFailure(.fullAccessRequired, "请先在花卷设置中允许日历完整访问。")
        }
        eventStore.reset()
        guard let event = eventStore.event(withIdentifier: arguments.eventID) else {
            return calendarRemoveFailure(.targetMissing, "这个日程已经不存在或原生标识已变化，请重新查询。")
        }
        return Self.preconditionFailure(
            CalendarEventSnapshot.read(event),
            arguments: arguments
        )
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        guard let arguments = CalendarRemoveArguments(dispatch.payload) else {
            return calendarRemoveFailure(.invalid, "日程删除参数无效。")
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return calendarRemoveFailure(.fullAccessRequired, "日历权限已变化，尚未删除。")
        }
        eventStore.reset()
        guard let event = eventStore.event(withIdentifier: arguments.eventID) else {
            return calendarRemoveFailure(.targetMissing, "这个日程已经不存在或原生标识已变化；没有删除。")
        }
        let snapshot = CalendarEventSnapshot.read(event)
        if let failure = Self.preconditionFailure(snapshot, arguments: arguments) {
            return failure
        }

        // Destructive V1 has exactly one native remove. There is deliberately
        // no suspension between the final fresh identity/revision guard and it.
        try eventStore.remove(event, span: .thisEvent, commit: true)

        // Immediate absence after a successful synchronous remove return is the
        // only positive deletion proof. If this readback cannot be performed,
        // throw so DeviceActionJournal keeps the attempt ambiguous.
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CalendarRemoveReadbackError.permissionChanged
        }
        eventStore.reset()
        guard eventStore.event(withIdentifier: arguments.eventID) == nil else {
            throw CalendarRemoveReadbackError.stillPresent
        }
        return .success(
            [
                "requested_event_id": .string(arguments.eventID),
                "calendar_id": .string(arguments.expectedCalendarID),
                "title": .string(arguments.expectedTitle),
                "deleted": .bool(true),
                "verified": .bool(true),
                "verification": .string("immediate_exact_id_absence"),
            ],
            nativeCorrelationID: arguments.eventID
        )
    }

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        guard let arguments = CalendarRemoveArguments(dispatch.payload) else {
            return .completed(calendarRemoveFailure(.invalid, "日程删除参数无效。"))
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return .stillUnknown("恢复日历完整访问后才能核对这次删除；不会再次删除。")
        }
        eventStore.reset()
        if let event = eventStore.event(withIdentifier: arguments.eventID) {
            let snapshot = CalendarEventSnapshot.read(event)
            if snapshot.identifier == arguments.eventID,
               snapshot.calendarID == arguments.expectedCalendarID,
               snapshot.title == arguments.expectedTitle,
               snapshot.revision == arguments.expectedRevision {
                return .stillUnknown("原日程当前仍存在，但无法证明先前删除调用从未提交；不会自动再次删除。")
            }
            return .stillUnknown("原生 ID 当前指向的日程状态已经变化，无法安全判断先前删除结果；不会再次删除。")
        }
        // Missing exact ID after process loss is not enough to distinguish our
        // delete from sync re-identification or an external/user deletion.
        return .stillUnknown("原日程当前无法按精确 ID 找到；删除提交与同步重标识无法区分，不会再次删除。")
    }

    private nonisolated static func preconditionFailure(
        _ snapshot: CalendarEventSnapshot,
        arguments: CalendarRemoveArguments
    ) -> DeviceExecutionResult? {
        guard snapshot.identifier == arguments.eventID else {
            return calendarRemoveFailure(.targetMissing, "日程缺少当前可用的原生标识，请重新查询。")
        }
        guard snapshot.calendarID == arguments.expectedCalendarID else {
            return calendarRemoveFailure(.calendarChanged, "日程已经移动到其他日历，请重新查询。")
        }
        guard snapshot.title == arguments.expectedTitle else {
            return calendarRemoveFailure(.revisionStale, "日程标题已发生变化，请重新查询后再删除。")
        }
        guard snapshot.calendarWritable else {
            return calendarRemoveFailure(.readOnlyCalendar, "这个日程所在日历当前不可修改。")
        }
        guard snapshot.removeEligible else {
            return calendarRemoveFailure(
                .unsupportedTarget,
                snapshot.removeIneligibleReason ?? "这个日程包含当前版本不安全删除的属性。"
            )
        }
        guard snapshot.revision == arguments.expectedRevision else {
            return calendarRemoveFailure(.revisionStale, "日程已发生变化，请重新查询后再删除。")
        }
        return nil
    }
}


@MainActor
@Observable
final class CalendarPermissionModel {
    private(set) var status = EKEventStore.authorizationStatus(for: .event)
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
        case .writeOnly: return "仅写入"
        case .authorized: return "已允许"
        @unknown default: return "未知"
        }
    }

    func refresh() {
        status = EKEventStore.authorizationStatus(for: .event)
    }

    func requestFullAccess() async {
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        let store = EKEventStore()
        do {
            let granted = try await store.requestFullAccessToEvents()
            store.reset()
            refresh()
            if granted && status == .fullAccess {
                errorMessage = nil
            } else if granted {
                errorMessage = "系统返回已允许，但当前日历授权状态仍是 \(statusLabel)。"
            } else {
                errorMessage = "没有获得日历完整访问权限。"
            }
        } catch {
            refresh()
            errorMessage = "日历授权失败：\(error.localizedDescription)"
        }
    }
}

private func parseWindow(payload: [String: JSONValue]) -> CalendarWindow? {
    guard
        let startAt = payload["start_at"]?.stringValue,
        let endAt = payload["end_at"]?.stringValue,
        let startDate = parseCalendarISO8601(startAt),
        let endDate = parseCalendarISO8601(endAt),
        endDate > startDate
    else { return nil }
    return CalendarWindow(
        startAt: startAt,
        endAt: endAt,
        startDate: startDate,
        endDate: endDate
    )
}

private func parseCalendarISO8601(_ raw: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: raw) { return date }
    let normal = ISO8601DateFormatter()
    normal.formatOptions = [.withInternetDateTime]
    return normal.date(from: raw)
}

private extension JSONValue {
    var numberValue: Double? {
        guard case let .number(value) = self else { return nil }
        return value
    }
}

private extension CalendarFreeBusyExecutor {
    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private extension CalendarQueryExecutor {
    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
