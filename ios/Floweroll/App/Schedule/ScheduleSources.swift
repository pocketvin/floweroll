import CryptoKit
import Foundation
import Observation
import SwiftUI



private enum ScheduleHubISO8601 {
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = fractional.date(from: raw) { return value }
        let normal = ISO8601DateFormatter()
        normal.formatOptions = [.withInternetDateTime]
        return normal.date(from: raw)
    }
}


private enum ScheduleHubDispatch {
    static func make(actionType: String, payload: [String: JSONValue]) -> DeviceActionDispatch {
        let id = "schedule-hub.\(UUID().uuidString)"
        return DeviceActionDispatch(
            actionID: id,
            taskID: "schedule-hub-read",
            actionType: actionType,
            payload: payload,
            status: "executing",
            runtimeActionStatus: "executing",
            idempotencyKey: id,
            attemptID: id,
            attemptNumber: 1,
            attemptStatus: "IN_FLIGHT",
            dispatchDigest: id
        )
    }
}


struct ScheduleHubCalendarSource: ScheduleHubSource {
    let kind: ScheduleSourceKind = .calendar

    func load(window: ScheduleHubWindow, now: Date, calendar: Calendar) async throws -> [ScheduleItem] {
        let dispatch = ScheduleHubDispatch.make(
            actionType: "calendar.query",
            payload: [
                "start_at": .string(ScheduleHubISO8601.string(window.calendarStart)),
                "end_at": .string(ScheduleHubISO8601.string(window.end)),
                "max_results": .number(100),
            ]
        )
        let executor = CalendarQueryExecutor()
        if let failure = try await executor.preflight(dispatch) {
            throw ScheduleHubSourceError.unavailable(.calendar, failure.error ?? "权限或查询条件不可用")
        }
        let result = try await executor.execute(dispatch)
        guard result.success, let rows = result.output["events"]?.arrayValue else {
            throw ScheduleHubSourceError.unavailable(.calendar, result.error ?? "读取失败")
        }
        return rows.compactMap { value in
            guard let object = value.objectValue,
                  let eventID = object["event_id"]?.stringValue,
                  let start = ScheduleHubISO8601.date(object["start_at"]?.stringValue),
                  let end = ScheduleHubISO8601.date(object["end_at"]?.stringValue)
            else { return nil }
            let rawTitle = object["title"]?.stringValue ?? ""
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let status: ScheduleItemStatus
            if end <= now { status = .completed }
            else if start <= now { status = .active }
            else { status = .upcoming }
            let removeEligible = object["remove_eligible"]?.boolValue ?? false
            let revision = object["revision"]?.stringValue ?? ""
            let calendarID = object["calendar_id"]?.stringValue ?? ""
            let removal = ScheduleRemovalDescriptor(
                sourceKind: .calendar,
                sourceObjectID: eventID,
                expectedRevision: revision,
                expectedContainerID: calendarID,
                expectedTitle: rawTitle,
                eligible: removeEligible && !revision.isEmpty && !calendarID.isEmpty && !rawTitle.isEmpty,
                ineligibleReason: object["remove_ineligible_reason"]?.stringValue
                    ?? (rawTitle.isEmpty ? "无标题日程暂不支持从小卷直接移除。" : nil)
            )
            return ScheduleItem(
                sourceKind: .calendar,
                sourceObjectID: eventID,
                title: title.isEmpty ? "无标题日程" : title,
                startAt: start,
                endAt: end,
                isAllDay: object["all_day"]?.boolValue ?? false,
                recurrenceDescription: nil,
                status: status,
                sourceExists: true,
                navigationTarget: .calendar(eventID),
                taskCorrelation: nil,
                explicitLineageID: nil,
                truthStrength: .freshReadback,
                observedAt: now,
                sourceContext: object["location"]?.stringValue,
                removal: removal
            )
        }
    }
}


struct ScheduleHubReminderSource: ScheduleHubSource {
    let kind: ScheduleSourceKind = .reminder

    func load(window: ScheduleHubWindow, now: Date, calendar: Calendar) async throws -> [ScheduleItem] {
        let dispatch = ScheduleHubDispatch.make(
            actionType: "reminder.query",
            payload: [
                "status": .string("incomplete"),
                "start_at": .string(ScheduleHubISO8601.string(window.reminderStart)),
                "end_at": .string(ScheduleHubISO8601.string(window.end)),
                "max_results": .number(50),
            ]
        )
        let executor = ReminderQueryExecutor()
        if let failure = try await executor.preflight(dispatch) {
            throw ScheduleHubSourceError.unavailable(.reminder, failure.error ?? "权限或查询条件不可用")
        }
        let result = try await executor.execute(dispatch)
        guard result.success, let rows = result.output["reminders"]?.arrayValue else {
            throw ScheduleHubSourceError.unavailable(.reminder, result.error ?? "读取失败")
        }
        return rows.compactMap { value in
            guard let object = value.objectValue,
                  let reminderID = object["reminder_id"]?.stringValue
            else { return nil }
            let due = ScheduleHubISO8601.date(object["due_at"]?.stringValue)
            let completed = object["completed"]?.boolValue ?? false
            let status: ScheduleItemStatus
            if completed { status = .completed }
            else if let due, due < now { status = .overdue }
            else if due == nil { status = .undated }
            else { status = .upcoming }
            let title = object["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let recurring = object["has_recurrence"]?.boolValue ?? false
            let displayTitle = title?.isEmpty == false ? title! : "无标题"
            let removeEligible = object["remove_eligible"]?.boolValue ?? false
            let revision = object["revision"]?.stringValue ?? ""
            let listID = object["list_id"]?.stringValue ?? object["calendar_id"]?.stringValue ?? ""
            let removal = ScheduleRemovalDescriptor(
                sourceKind: .reminder,
                sourceObjectID: reminderID,
                expectedRevision: revision,
                expectedContainerID: listID,
                expectedTitle: displayTitle,
                eligible: removeEligible && !revision.isEmpty && !listID.isEmpty,
                ineligibleReason: object["remove_ineligible_reason"]?.stringValue
            )
            return ScheduleItem(
                sourceKind: .reminder,
                sourceObjectID: reminderID,
                title: (title?.isEmpty == false ? title! : "无标题提醒"),
                startAt: due,
                endAt: nil,
                isAllDay: false,
                recurrenceDescription: recurring ? "重复提醒 · 按系统当前到期时间显示" : nil,
                status: status,
                sourceExists: true,
                navigationTarget: .reminder(reminderID),
                taskCorrelation: nil,
                explicitLineageID: nil,
                truthStrength: .freshReadback,
                observedAt: now,
                sourceContext: object["calendar_name"]?.stringValue,
                removal: removal
            )
        }
    }
}


struct ScheduleHubAlarmSource: ScheduleHubSource {
    let kind: ScheduleSourceKind = .alarm
    private let nativeStore: any AlarmNativeStore
    private let ownershipStore: AlarmOwnershipStore?

    init(
        nativeStore: any AlarmNativeStore = SystemAlarmNativeStore(),
        ownershipStore: AlarmOwnershipStore? = AlarmOwnershipStore.shared
    ) {
        self.nativeStore = nativeStore
        self.ownershipStore = ownershipStore
    }

    func load(window: ScheduleHubWindow, now: Date, calendar: Calendar) async throws -> [ScheduleItem] {
        _ = window
        guard await nativeStore.authorizationStatus() == .authorized else {
            throw ScheduleHubSourceError.unavailable(.alarm, "尚未获得闹钟访问权限")
        }
        guard let ownershipStore else {
            throw ScheduleHubSourceError.unavailable(.alarm, "本地闹钟归属记录不可用")
        }
        let snapshots = try await AlarmReadbackService.enumerateOwned(
            nativeStore: nativeStore,
            ownershipStore: ownershipStore
        )
        return snapshots.compactMap { snapshot in
            guard let ownership = snapshot.ownership else { return nil }
            let fireAt = ScheduleAlarmOccurrence.nextOccurrence(
                schedule: ownership.schedule,
                after: now,
                calendar: calendar
            )
            let sourceExists = snapshot.native != nil && ownership.lifecycle != .missing
            let status: ScheduleItemStatus
            if ownership.lifecycle == .cancelled {
                status = .cancelled
            } else if !sourceExists {
                status = .removed
            } else if ownership.pendingSettingsMutation != nil {
                status = .needsAttention
            } else {
                switch snapshot.native?.state {
                case .alerting, .countdown:
                    status = .active
                case .paused, .unknown:
                    status = .needsAttention
                case .scheduled:
                    if let fireAt, ownership.schedule.kind == .fixed, fireAt < now {
                        status = .overdue
                    } else {
                        status = fireAt == nil ? .needsAttention : .upcoming
                    }
                case nil:
                    status = .removed
                }
            }
            return ScheduleItem(
                sourceKind: .alarm,
                sourceObjectID: snapshot.alarmID.uuidString,
                title: ownership.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "小卷闹钟" : ownership.title,
                startAt: fireAt,
                endAt: nil,
                isAllDay: false,
                recurrenceDescription: ScheduleAlarmOccurrence.recurrenceDescription(ownership.schedule),
                status: status,
                sourceExists: sourceExists,
                navigationTarget: .alarm(snapshot.alarmID),
                taskCorrelation: ScheduleTaskCorrelation(taskID: ownership.taskID, actionID: ownership.actionID),
                explicitLineageID: "task:\(ownership.taskID):action:\(ownership.actionID)",
                truthStrength: .freshReadback,
                observedAt: ownership.lastObservedAt,
                sourceContext: alarmStateDescription(snapshot.native?.state, sourceExists: sourceExists),
                removal: nil
            )
        }
    }

    private func alarmStateDescription(_ state: AlarmNativeState?, sourceExists: Bool) -> String {
        guard sourceExists, let state else { return "已从系统移除" }
        switch state {
        case .scheduled: return "已计划"
        case .countdown: return "倒计时中"
        case .paused: return "已暂停"
        case .alerting: return "正在响铃"
        case .unknown: return "状态待确认"
        }
    }
}


struct ScheduleHubSourceLoadOutcome: Sendable {
    let kind: ScheduleSourceKind
    let items: [ScheduleItem]?
    let errorMessage: String?
}
