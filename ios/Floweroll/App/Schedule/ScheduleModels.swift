import CryptoKit
import Foundation
import Observation
import SwiftUI



enum ScheduleSourceKind: String, CaseIterable, Hashable, Sendable {
    case calendar
    case reminder
    case alarm
    case other

    var displayName: String {
        switch self {
        case .calendar: return "日历"
        case .reminder: return "提醒"
        case .alarm: return "闹钟"
        case .other: return "安排"
        }
    }

    var systemImage: String {
        switch self {
        case .calendar: return "calendar"
        case .reminder: return "checklist"
        case .alarm: return "alarm"
        case .other: return "clock"
        }
    }

    var displayPriority: Int {
        switch self {
        case .calendar: return 0
        case .reminder: return 1
        case .alarm: return 2
        case .other: return 3
        }
    }
}


enum ScheduleItemStatus: String, Equatable, Sendable {
    case upcoming
    case active
    case completed
    case cancelled
    case removed
    case overdue
    case needsAttention
    case undated

    var displayName: String {
        switch self {
        case .upcoming: return "即将开始"
        case .active: return "进行中"
        case .completed: return "已完成"
        case .cancelled: return "已取消"
        case .removed: return "已移除"
        case .overdue: return "已逾期"
        case .needsAttention: return "需确认"
        case .undated: return "未定时间"
        }
    }

    var isPrimaryUpcoming: Bool {
        self == .upcoming || self == .active
    }
}


enum ScheduleTruthStrength: Int, Comparable, Sendable {
    case cached = 0
    case taskProjection = 1
    case management = 2
    case freshReadback = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}


enum ScheduleNavigationTarget: Equatable, Sendable {
    case alarm(UUID)
    case calendar(String)
    case reminder(String)
    case readOnly(String)
}


struct ScheduleTaskCorrelation: Equatable, Sendable {
    let taskID: String
    let actionID: String?
}


struct ScheduleRemovalDescriptor: Equatable, Sendable {
    let sourceKind: ScheduleSourceKind
    let sourceObjectID: String
    let expectedRevision: String
    let expectedContainerID: String
    let expectedTitle: String
    let eligible: Bool
    let ineligibleReason: String?

    var actionType: String? {
        switch sourceKind {
        case .calendar: return "calendar.remove"
        case .reminder: return "reminder.remove"
        case .alarm, .other: return nil
        }
    }

    var actionTitle: String {
        switch sourceKind {
        case .calendar: return "移除这个日程"
        case .reminder: return "移除这个提醒"
        case .alarm: return "移除这个闹钟"
        case .other: return "移除这个安排"
        }
    }

    var confirmationMessage: String {
        switch sourceKind {
        case .calendar:
            return "这会从系统日历中删除这个日程。小卷不会自动恢复它。"
        case .reminder:
            return "这会从系统提醒事项中删除这个提醒。小卷不会自动恢复它。"
        case .alarm, .other:
            return "这会移除这个安排。"
        }
    }

    var payload: [String: JSONValue]? {
        switch sourceKind {
        case .calendar:
            return [
                "event_id": .string(sourceObjectID),
                "expected_revision": .string(expectedRevision),
                "expected_calendar_id": .string(expectedContainerID),
                "expected_title": .string(expectedTitle),
            ]
        case .reminder:
            return [
                "reminder_id": .string(sourceObjectID),
                "expected_revision": .string(expectedRevision),
                "expected_list_id": .string(expectedContainerID),
                "expected_title": .string(expectedTitle),
            ]
        case .alarm, .other:
            return nil
        }
    }

    var attemptID: String? {
        guard let actionType else { return nil }
        let material = [
            actionType,
            sourceObjectID,
            expectedRevision,
            expectedContainerID,
            expectedTitle,
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "settings.schedule.remove.\(digest)"
    }

    var dispatch: DeviceActionDispatch? {
        guard let actionType, let payload, let attemptID else { return nil }
        return DeviceActionDispatch(
            actionID: attemptID,
            taskID: "settings-schedule-hub",
            actionType: actionType,
            payload: payload,
            status: "executing",
            runtimeActionStatus: "executing",
            idempotencyKey: attemptID,
            attemptID: attemptID,
            attemptNumber: 1,
            attemptStatus: "IN_FLIGHT",
            dispatchDigest: attemptID
        )
    }
}


enum ScheduleHubRemovalOutcome: Equatable, Sendable {
    case removed
    case failed(String)
    case needsReconciliation(String)
}


enum ScheduleHubRemovalConfigurationError: Error, Sendable {
    case unsupportedSource
}


struct ScheduleItem: Identifiable, Equatable, Sendable {
    let sourceKind: ScheduleSourceKind
    let sourceObjectID: String
    let title: String
    let startAt: Date?
    let endAt: Date?
    let isAllDay: Bool
    let recurrenceDescription: String?
    let status: ScheduleItemStatus
    let sourceExists: Bool
    let navigationTarget: ScheduleNavigationTarget
    let taskCorrelation: ScheduleTaskCorrelation?
    let explicitLineageID: String?
    let truthStrength: ScheduleTruthStrength
    let observedAt: Date
    let sourceContext: String?
    let removal: ScheduleRemovalDescriptor?

    var id: String { stableIdentity }
    var stableIdentity: String { "\(sourceKind.rawValue):\(sourceObjectID)" }
}


enum ScheduleSectionKind: Int, CaseIterable, Identifiable, Sendable {
    case today
    case tomorrow
    case later
    case undated
    case attention
    case past

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .today: return "今天"
        case .tomorrow: return "明天"
        case .later: return "之后"
        case .undated: return "未定时间"
        case .attention: return "需关注"
        case .past: return "过去与失效"
        }
    }
}


struct ScheduleSection: Identifiable, Equatable, Sendable {
    let kind: ScheduleSectionKind
    let items: [ScheduleItem]
    var id: ScheduleSectionKind { kind }
}


struct ScheduleHubSummary: Equatable, Sendable {
    let todayCount: Int
    let nextItem: ScheduleItem?

    static let empty = ScheduleHubSummary(todayCount: 0, nextItem: nil)
}


struct ScheduleHubWindow: Equatable, Sendable {
    let calendarStart: Date
    let reminderStart: Date
    let end: Date

    init(now: Date, calendar: Calendar, futureDays: Int = 90, reminderLookbackDays: Int = 30) {
        let today = calendar.startOfDay(for: now)
        calendarStart = today
        reminderStart = calendar.date(byAdding: .day, value: -reminderLookbackDays, to: today) ?? today
        end = calendar.date(byAdding: .day, value: futureDays, to: today) ?? now.addingTimeInterval(Double(futureDays) * 86_400)
    }
}


enum ScheduleHubSourceError: Error, LocalizedError, Sendable {
    case unavailable(ScheduleSourceKind, String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(kind, message):
            return "\(kind.displayName)暂时无法刷新：\(message)"
        }
    }
}


protocol ScheduleHubSource: Sendable {
    var kind: ScheduleSourceKind { get }
    func load(window: ScheduleHubWindow, now: Date, calendar: Calendar) async throws -> [ScheduleItem]
}
