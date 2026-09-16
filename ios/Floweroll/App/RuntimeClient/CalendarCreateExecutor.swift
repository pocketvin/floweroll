import CryptoKit
import EventKit
import Foundation

struct CalendarCreateArguments: Sendable {
    let title: String
    let start: Date
    let end: Date
    let timeZone: TimeZone
    let location: String?
    let calendarName: String?
    let itemID: String?

    init?(_ payload: [String: JSONValue]) {
        let limits = ["title": 160, "start_at": 40, "end_at": 40, "time_zone": 64,
                      "location": 500, "calendar_name": 200, "item_id": 64]
        for (key, value) in payload {
            guard let limit = limits[key], let text = value.stringValue,
                  !text.isEmpty, text == text.trimmingCharacters(in: .whitespacesAndNewlines),
                  text.count <= limit else { return nil }
        }
        guard let title = payload["title"]?.stringValue,
              let rawStart = payload["start_at"]?.stringValue,
              let rawEnd = payload["end_at"]?.stringValue,
              let zoneID = payload["time_zone"]?.stringValue,
              let zone = TimeZone(identifier: zoneID),
              let start = Self.parse(rawStart, in: zone),
              let end = Self.parse(rawEnd, in: zone),
              end > start, end.timeIntervalSince(start) <= 7 * 86400 else { return nil }
        self.title = title
        self.start = start
        self.end = end
        self.timeZone = zone
        self.location = payload["location"]?.stringValue
        self.calendarName = payload["calendar_name"]?.stringValue
        self.itemID = payload["item_id"]?.stringValue
    }

    private static func parse(_ text: String, in zone: TimeZone) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) else { return nil }
        // Validate the offset as well as the instant: an accidental UTC value
        // labelled Asia/Shanghai must not silently create an eight-hour shift.
        let offset: Int
        if text.hasSuffix("Z") {
            offset = 0
        } else {
            let suffix = String(text.suffix(6))
            let chars = Array(suffix)
            guard chars.count == 6, chars[0] == "+" || chars[0] == "-", chars[3] == ":",
                  let hours = Int(String(chars[1...2])), let minutes = Int(String(chars[4...5])),
                  hours <= 23, minutes < 60 else { return nil }
            offset = (hours * 3600 + minutes * 60) * (chars[0] == "-" ? -1 : 1)
        }
        return zone.secondsFromGMT(for: date) == offset ? date : nil
    }
}

enum CalendarCreateError: Error, LocalizedError {
    case unavailableCalendar
    case ambiguousCalendar
    case unreadableResult
    case mismatchedResult
    case duplicateMarker

    var errorDescription: String? {
        switch self {
        case .unavailableCalendar: return "没有找到可写入的目标日历，请在花卷设置中检查日历权限与账号。"
        case .ambiguousCalendar: return "有多个同名日历，尚未写入；请先明确目标日历。"
        case .unreadableResult: return "日程可能已经保存，暂时无法读回；不会再次创建。"
        case .mismatchedResult: return "找到的日程内容已经变化，无法确认与本次安排一致。"
        case .duplicateMarker: return "发现多个对应日程，需要核对后继续；不会再添加。"
        }
    }
}

actor CalendarCreateExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID = "calendar.create"
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func preflight(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult? {
        guard let arguments = CalendarCreateArguments(dispatch.payload) else {
            return .failure("calendar_create_invalid_arguments")
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return .failure("请先在花卷设置中允许日历完整访问，以便添加后核对结果。")
        }
        eventStore.reset()
        do { _ = try targetCalendar(arguments) }
        catch { return .failure(error.localizedDescription) }
        return nil
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        guard let arguments = CalendarCreateArguments(dispatch.payload) else {
            return .failure("calendar_create_invalid_arguments")
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return .failure("日历权限已变化，尚未添加日程。")
        }
        eventStore.reset()
        if let existing = try findEvent(dispatch, arguments: arguments) {
            return try verifiedResult(existing, dispatch: dispatch, arguments: arguments)
        }
        let calendar: EKCalendar
        do { calendar = try targetCalendar(arguments) }
        catch { return .failure(error.localizedDescription) }
        let calendarID = calendar.calendarIdentifier
        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = arguments.title
        event.startDate = arguments.start
        event.endDate = arguments.end
        event.timeZone = arguments.timeZone
        event.isAllDay = false
        event.location = arguments.location
        event.url = Self.markerURL(dispatch.idempotencyKey)
        // No suspension between marker lookup and native save. The actor
        // serializes concurrent device tasks using this executor instance.
        try eventStore.save(event, span: .thisEvent, commit: true)
        let identifier = event.eventIdentifier
        eventStore.reset()
        guard let identifier, let saved = eventStore.event(withIdentifier: identifier),
              saved.calendar.calendarIdentifier == calendarID else {
            throw CalendarCreateError.unreadableResult
        }
        return try verifiedResult(saved, dispatch: dispatch, arguments: arguments)
    }

    func reconcile(_ dispatch: DeviceActionDispatch,
                   journalEntry: DeviceActionJournalEntry) async throws -> DeviceReconciliationResult {
        guard let arguments = CalendarCreateArguments(dispatch.payload),
              EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return .stillUnknown("需要恢复日历访问后核对已有日程。")
        }
        eventStore.reset()
        guard let event = try findEvent(dispatch, arguments: arguments) else {
            // A missing result is NOT proof that save never ran. It may have
            // moved outside this window, been deleted or become inaccessible.
            // Preserve mayHaveStarted; never recreate automatically.
            return .stillUnknown(CalendarCreateError.unreadableResult.localizedDescription)
        }
        return .completed(try verifiedResult(event, dispatch: dispatch, arguments: arguments))
    }

    private func targetCalendar(_ arguments: CalendarCreateArguments) throws -> EKCalendar {
        if let name = arguments.calendarName {
            let matches = eventStore.calendars(for: .event).filter { $0.title == name }
            guard matches.count <= 1 else { throw CalendarCreateError.ambiguousCalendar }
            guard let calendar = matches.first, calendar.allowsContentModifications else {
                throw CalendarCreateError.unavailableCalendar
            }
            return calendar
        }
        guard let calendar = eventStore.defaultCalendarForNewEvents, calendar.allowsContentModifications else {
            throw CalendarCreateError.unavailableCalendar
        }
        return calendar
    }

    private func findEvent(_ dispatch: DeviceActionDispatch, arguments: CalendarCreateArguments) throws -> EKEvent? {
        let predicate = eventStore.predicateForEvents(
            withStart: arguments.start.addingTimeInterval(-86400),
            end: arguments.end.addingTimeInterval(86400), calendars: nil)
        let marker = Self.markerURL(dispatch.idempotencyKey)
        let matches = eventStore.events(matching: predicate).filter { $0.url == marker }
        guard matches.count <= 1 else { throw CalendarCreateError.duplicateMarker }
        return matches.first
    }

    private func verifiedResult(_ event: EKEvent, dispatch: DeviceActionDispatch,
                                arguments: CalendarCreateArguments) throws -> DeviceExecutionResult {
        guard let id = event.eventIdentifier, !id.isEmpty,
              event.url == Self.markerURL(dispatch.idempotencyKey),
              event.title == arguments.title, !event.isAllDay, !event.hasRecurrenceRules,
              abs(event.startDate.timeIntervalSince(arguments.start)) < 1,
              abs(event.endDate.timeIntervalSince(arguments.end)) < 1,
              event.timeZone?.identifier == arguments.timeZone.identifier,
              (event.location?.isEmpty == false ? event.location : nil) == arguments.location,
              arguments.calendarName == nil || event.calendar.title == arguments.calendarName else {
            throw CalendarCreateError.mismatchedResult
        }
        var output: [String: JSONValue] = [
            "event_id": .string(id), "title": .string(event.title),
            "start_at": .string(ISO8601DateFormatter().string(from: event.startDate)),
            "end_at": .string(ISO8601DateFormatter().string(from: event.endDate)),
            "time_zone": .string(event.timeZone!.identifier),
            "calendar_id": .string(event.calendar.calendarIdentifier),
            "calendar_name": .string(event.calendar.title), "all_day": .bool(false),
            "idempotency_marker": .string(dispatch.idempotencyKey), "verified": .bool(true),
        ]
        if let location = event.location, !location.isEmpty { output["location"] = .string(location) }
        if let itemID = arguments.itemID { output["item_id"] = .string(itemID) }
        return .success(output, nativeCorrelationID: id)
    }

    static func markerURL(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(string: "floweroll://calendar-action/\(hash)")!
    }
}
