import CryptoKit
import Foundation
import Observation
import SwiftUI



enum ScheduleHubAggregation {
    static func canonicalItems(_ snapshots: [ScheduleItem]) -> [ScheduleItem] {
        var byStableIdentity: [String: ScheduleItem] = [:]
        for item in snapshots {
            if let existing = byStableIdentity[item.stableIdentity] {
                if preferred(item, over: existing) {
                    byStableIdentity[item.stableIdentity] = item
                }
            } else {
                byStableIdentity[item.stableIdentity] = item
            }
        }

        var output: [ScheduleItem] = []
        var lineageIndex: [String: Int] = [:]
        for item in byStableIdentity.values.sorted(by: { $0.stableIdentity < $1.stableIdentity }) {
            guard let lineage = clean(item.explicitLineageID) else {
                output.append(item)
                continue
            }
            if let index = lineageIndex[lineage] {
                if preferred(item, over: output[index]) {
                    output[index] = item
                }
            } else {
                lineageIndex[lineage] = output.count
                output.append(item)
            }
        }
        return output.sorted { $0.stableIdentity < $1.stableIdentity }
    }

    private static func preferred(_ candidate: ScheduleItem, over existing: ScheduleItem) -> Bool {
        if candidate.truthStrength != existing.truthStrength {
            return candidate.truthStrength > existing.truthStrength
        }
        if candidate.observedAt != existing.observedAt {
            return candidate.observedAt > existing.observedAt
        }
        if candidate.sourceExists != existing.sourceExists {
            // On an otherwise exact tie, fail closed toward a terminal/missing
            // observation instead of repainting a stale upcoming item.
            return !candidate.sourceExists
        }
        let candidateSeverity = terminalTruthPriority(candidate.status)
        let existingSeverity = terminalTruthPriority(existing.status)
        if candidateSeverity != existingSeverity {
            return candidateSeverity > existingSeverity
        }
        if candidate.sourceKind.displayPriority != existing.sourceKind.displayPriority {
            return candidate.sourceKind.displayPriority < existing.sourceKind.displayPriority
        }
        return candidate.stableIdentity < existing.stableIdentity
    }

    private static func terminalTruthPriority(_ status: ScheduleItemStatus) -> Int {
        switch status {
        case .removed: return 8
        case .cancelled: return 7
        case .needsAttention: return 6
        case .overdue: return 5
        case .completed: return 4
        case .active: return 3
        case .upcoming: return 2
        case .undated: return 1
        }
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}


enum ScheduleHubPresentation {
    static let settingsEntryTitle = "我的安排"
    static let navigationTitle = "我的安排"
    static let emptyTitle = "还没有近期安排"

    static func sections(
        from snapshots: [ScheduleItem],
        now: Date,
        calendar: Calendar
    ) -> [ScheduleSection] {
        let items = ScheduleHubAggregation.canonicalItems(snapshots)
        var buckets: [ScheduleSectionKind: [ScheduleItem]] = [:]
        for item in items {
            buckets[sectionKind(for: item, now: now, calendar: calendar), default: []].append(item)
        }
        return ScheduleSectionKind.allCases.compactMap { kind in
            guard let values = buckets[kind], !values.isEmpty else { return nil }
            return ScheduleSection(kind: kind, items: values.sorted { less($0, $1, section: kind) })
        }
    }

    static func summary(
        from snapshots: [ScheduleItem],
        now: Date,
        calendar: Calendar
    ) -> ScheduleHubSummary {
        let items = ScheduleHubAggregation.canonicalItems(snapshots)
        let todayCount = items.filter {
            $0.status.isPrimaryUpcoming
                && $0.startAt.map { calendar.isDate($0, inSameDayAs: now) } == true
        }.count
        let next = items.filter {
            $0.status == .upcoming && $0.startAt.map { $0 >= now } == true
        }
        .sorted { less($0, $1, section: .later) }
        .first
        return ScheduleHubSummary(todayCount: todayCount, nextItem: next)
    }

    static func timeText(_ item: ScheduleItem, now: Date, calendar: Calendar) -> String {
        guard let date = item.startAt else { return "待定" }
        if item.isAllDay {
            return calendar.isDate(date, inSameDayAs: now) || isTomorrow(date, after: now, calendar: calendar)
                ? "全天"
                : date.formatted(.dateTime.month().day()) + " 全天"
        }
        if calendar.isDate(date, inSameDayAs: now) || isTomorrow(date, after: now, calendar: calendar) {
            return date.formatted(.dateTime.hour().minute())
        }
        return date.formatted(.dateTime.month().day().hour().minute())
    }

    private static func sectionKind(
        for item: ScheduleItem,
        now: Date,
        calendar: Calendar
    ) -> ScheduleSectionKind {
        switch item.status {
        case .completed, .cancelled, .removed:
            return .past
        case .overdue, .needsAttention:
            return .attention
        case .undated:
            return .undated
        case .upcoming, .active:
            guard let date = item.startAt else { return .undated }
            if calendar.isDate(date, inSameDayAs: now) { return .today }
            if isTomorrow(date, after: now, calendar: calendar) { return .tomorrow }
            return .later
        }
    }

    private static func isTomorrow(_ date: Date, after now: Date, calendar: Calendar) -> Bool {
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return false }
        return calendar.isDate(date, inSameDayAs: tomorrow)
    }

    private static func less(_ lhs: ScheduleItem, _ rhs: ScheduleItem, section: ScheduleSectionKind) -> Bool {
        if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
        if lhs.startAt != rhs.startAt {
            switch (lhs.startAt, rhs.startAt) {
            case let (a?, b?): return section == .past ? a > b : a < b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): break
            }
        }
        if lhs.sourceKind.displayPriority != rhs.sourceKind.displayPriority {
            return lhs.sourceKind.displayPriority < rhs.sourceKind.displayPriority
        }
        let leftTitle = normalizedTitle(lhs.title)
        let rightTitle = normalizedTitle(rhs.title)
        if leftTitle != rightTitle { return leftTitle < rightTitle }
        return lhs.stableIdentity < rhs.stableIdentity
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}


enum ScheduleAlarmOccurrence {
    static func nextOccurrence(
        schedule: AlarmDesiredSchedule,
        after now: Date,
        calendar: Calendar
    ) -> Date? {
        switch schedule.kind {
        case .fixed:
            return schedule.fireDate
        case .weekly:
            guard let hour = schedule.hour,
                  let minute = schedule.minute,
                  let weekdays = schedule.weekdays,
                  !weekdays.isEmpty else { return nil }
            let allowed = Set(weekdays)
            let startOfToday = calendar.startOfDay(for: now)
            for offset in 0...7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday),
                      let weekday = alarmWeekday(for: day, calendar: calendar),
                      allowed.contains(weekday),
                      let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
                else { continue }
                if candidate > now { return candidate }
            }
            return nil
        }
    }

    static func recurrenceDescription(_ schedule: AlarmDesiredSchedule) -> String? {
        guard schedule.kind == .weekly,
              let hour = schedule.hour,
              let minute = schedule.minute,
              let weekdays = schedule.weekdays,
              !weekdays.isEmpty else { return nil }
        let days = weekdays.map(weekdayText).joined(separator: "、")
        return String(format: "每周 %@ · %02d:%02d", days, hour, minute)
    }

    private static func alarmWeekday(for date: Date, calendar: Calendar) -> AlarmWeekday? {
        switch calendar.component(.weekday, from: date) {
        case 1: return .sunday
        case 2: return .monday
        case 3: return .tuesday
        case 4: return .wednesday
        case 5: return .thursday
        case 6: return .friday
        case 7: return .saturday
        default: return nil
        }
    }

    private static func weekdayText(_ day: AlarmWeekday) -> String {
        switch day {
        case .monday: return "周一"
        case .tuesday: return "周二"
        case .wednesday: return "周三"
        case .thursday: return "周四"
        case .friday: return "周五"
        case .saturday: return "周六"
        case .sunday: return "周日"
        }
    }
}
