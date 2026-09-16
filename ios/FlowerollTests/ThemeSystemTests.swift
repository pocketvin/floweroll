import XCTest
@testable import Floweroll

@MainActor
final class ThemeSystemTests: XCTestCase {
    func testMissingPersistedChoiceFallsBackToBlush() {
        withIsolatedDefaults { defaults in
            let store = FlowerollThemeStore(defaults: defaults)
            XCTAssertEqual(store.choice, .blush)
            XCTAssertEqual(store.palette.accentRGB, 0xE78BB2)
            XCTAssertEqual(store.palette.strongAccentRGB, 0xC34A7A)
            XCTAssertEqual(store.palette.onStrongAccentRGB, 0xFFFFFF)
            XCTAssertEqual(defaults.string(forKey: FlowerollThemeStore.defaultsKey), "blush")
        }
    }

    func testKnownChoicePersistsAcrossStoreRecreation() {
        withIsolatedDefaults { defaults in
            let first = FlowerollThemeStore(defaults: defaults)
            first.select(.lavender)

            XCTAssertEqual(defaults.string(forKey: FlowerollThemeStore.defaultsKey), "lavender")

            let recreated = FlowerollThemeStore(defaults: defaults)
            XCTAssertEqual(recreated.choice, .lavender)
            XCTAssertEqual(recreated.palette, FlowerollAccentChoice.lavender.palette)
        }
    }

    func testUnknownPersistedChoiceFallsBackAndCanonicalizesToBlush() {
        withIsolatedDefaults { defaults in
            defaults.set("future-neon-theme", forKey: FlowerollThemeStore.defaultsKey)

            let store = FlowerollThemeStore(defaults: defaults)

            XCTAssertEqual(store.choice, .blush)
            XCTAssertEqual(defaults.string(forKey: FlowerollThemeStore.defaultsKey), "blush")
        }
    }

    func testThemeStoreUsesOneOwnedPersistenceKey() {
        withIsolatedDefaults { defaults in
            let store = FlowerollThemeStore(defaults: defaults)
            store.select(.sky)

            let themeKeys = defaults.dictionaryRepresentation().keys
                .filter { $0.hasPrefix("floweroll.theme.") }
            XCTAssertEqual(themeKeys, [FlowerollThemeStore.defaultsKey])
        }
    }

    func testPresetPalettesAreDeterministic() {
        let expected: [FlowerollAccentChoice: (UInt32, UInt32, UInt32)] = [
            .blush: (0xE78BB2, 0xC34A7A, 0xFFFFFF),
            .rose: (0xD96C98, 0xA83265, 0xFFFFFF),
            .coral: (0xE58A78, 0xA94435, 0xFFFFFF),
            .lavender: (0xB6A1E4, 0x66509C, 0xFFFFFF),
            .sky: (0x7DB7E8, 0x2D6C9F, 0xFFFFFF),
            .mint: (0x73C8A9, 0x24745E, 0xFFFFFF),
        ]

        XCTAssertEqual(Set(FlowerollAccentChoice.allCases), Set(expected.keys))
        for choice in FlowerollAccentChoice.allCases {
            guard let values = expected[choice] else {
                return XCTFail("missing expected palette for \(choice.rawValue)")
            }
            XCTAssertEqual(choice.palette.accentRGB, values.0, choice.rawValue)
            XCTAssertEqual(choice.palette.strongAccentRGB, values.1, choice.rawValue)
            XCTAssertEqual(choice.palette.onStrongAccentRGB, values.2, choice.rawValue)
        }
    }

    func testEveryStrongAccentMeetsNormalTextContrastAgainstItsForeground() {
        for choice in FlowerollAccentChoice.allCases {
            let palette = choice.palette
            let ratio = Self.contrastRatio(
                foreground: palette.onStrongAccentRGB,
                background: palette.strongAccentRGB
            )
            XCTAssertGreaterThanOrEqual(
                ratio,
                4.5,
                "\(choice.rawValue) strong accent must keep ordinary white text readable"
            )
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "ThemeSystemTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    private static func contrastRatio(foreground: UInt32, background: UInt32) -> Double {
        let foregroundLuminance = relativeLuminance(foreground)
        let backgroundLuminance = relativeLuminance(background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ rgb: UInt32) -> Double {
        let red = linearized(Double((rgb >> 16) & 0xFF) / 255.0)
        let green = linearized(Double((rgb >> 8) & 0xFF) / 255.0)
        let blue = linearized(Double(rgb & 0xFF) / 255.0)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    private static func linearized(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}


private enum ScheduleHubTestStep: Sendable {
    case items([ScheduleItem])
    case failure(String)
}


private enum ScheduleHubTestFailure: Error, LocalizedError, Sendable {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(value): return value
        }
    }
}


private actor ScheduleHubTestSequenceSource: ScheduleHubSource {
    nonisolated let kind: ScheduleSourceKind
    private var steps: [ScheduleHubTestStep]

    init(kind: ScheduleSourceKind, steps: [ScheduleHubTestStep]) {
        self.kind = kind
        self.steps = steps
    }

    func load(window: ScheduleHubWindow, now: Date, calendar: Calendar) async throws -> [ScheduleItem] {
        _ = window
        _ = now
        _ = calendar
        guard !steps.isEmpty else { return [] }
        let step = steps.removeFirst()
        switch step {
        case let .items(items): return items
        case let .failure(message): throw ScheduleHubTestFailure.message(message)
        }
    }
}


private enum ScheduleRemovalTestError: Error, Sendable {
    case ambiguous
}


private actor ScheduleRemovalSuccessExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID: String
    private var executions = 0

    init(capabilityID: String) {
        self.capabilityID = capabilityID
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        executions += 1
        return .success([
            "deleted": .bool(true),
            "verified": .bool(true),
        ], nativeCorrelationID: dispatch.attemptID)
    }

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        _ = dispatch
        _ = journalEntry
        return .stillUnknown("unexpected reconciliation")
    }

    func executionCount() -> Int { executions }
}


private actor ScheduleRemovalAmbiguousExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID: String
    private var executions = 0
    private var reconciliations = 0

    init(capabilityID: String) {
        self.capabilityID = capabilityID
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        _ = dispatch
        executions += 1
        throw ScheduleRemovalTestError.ambiguous
    }

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        _ = dispatch
        _ = journalEntry
        reconciliations += 1
        return .stillUnknown("仍无法确认")
    }

    func executionCount() -> Int { executions }
    func reconciliationCount() -> Int { reconciliations }
}


@MainActor
final class ScheduleHubTests: XCTestCase {
    func testAggregationCombinesCalendarAlarmAndReminder() {
        let now = date("2026-09-14T08:00:00+08:00")
        let values = [
            item(.calendar, id: "cal-1", title: "面试", at: date("2026-09-14T15:00:00+08:00"), observedAt: now),
            item(.alarm, id: "alarm-1", title: "晚间闹钟", at: date("2026-09-14T22:00:00+08:00"), observedAt: now),
            item(.reminder, id: "rem-1", title: "提交材料", at: date("2026-09-14T09:30:00+08:00"), observedAt: now),
        ]
        let canonical = ScheduleHubAggregation.canonicalItems(values)
        XCTAssertEqual(canonical.count, 3)
        XCTAssertEqual(Set(canonical.map(\.sourceKind)), [.calendar, .alarm, .reminder])
    }

    func testAggregationAllowsAnEmptySource() async {
        let now = date("2026-09-14T08:00:00+08:00")
        let calendarSource = ScheduleHubTestSequenceSource(kind: .calendar, steps: [.items([])])
        let alarmSource = ScheduleHubTestSequenceSource(
            kind: .alarm,
            steps: [.items([item(.alarm, id: "a", title: "闹钟", at: date("2026-09-14T10:00:00+08:00"), observedAt: now)])]
        )
        let model = ScheduleHubModel(sources: [calendarSource, alarmSource])
        await model.refresh(now: now, calendar: calendar())
        XCTAssertEqual(model.items.map(\.sourceKind), [.alarm])
    }

    func testSourceFailureDoesNotEraseOtherSources() async {
        let now = date("2026-09-14T08:00:00+08:00")
        let calendarItem = item(.calendar, id: "cal", title: "会议", at: date("2026-09-14T11:00:00+08:00"), observedAt: now)
        let good = ScheduleHubTestSequenceSource(kind: .calendar, steps: [.items([calendarItem])])
        let failed = ScheduleHubTestSequenceSource(kind: .reminder, steps: [.failure("fixture unavailable")])
        let model = ScheduleHubModel(sources: [good, failed])
        await model.refresh(now: now, calendar: calendar())
        XCTAssertEqual(model.items, [calendarItem])
        XCTAssertNotNil(model.sourceErrors[.reminder])
        XCTAssertNil(model.sourceErrors[.calendar])
    }

    func testFreshTruthReplacesStaleCacheForSameSource() async {
        let firstNow = date("2026-09-14T08:00:00+08:00")
        let secondNow = date("2026-09-14T08:05:00+08:00")
        let source = ScheduleHubTestSequenceSource(kind: .calendar, steps: [
            .items([item(.calendar, id: "same", title: "旧标题", at: date("2026-09-14T10:00:00+08:00"), strength: .cached, observedAt: firstNow)]),
            .items([item(.calendar, id: "same", title: "新标题", at: date("2026-09-14T10:30:00+08:00"), strength: .freshReadback, observedAt: secondNow)]),
        ])
        let model = ScheduleHubModel(sources: [source])
        await model.refresh(now: firstNow, calendar: calendar())
        XCTAssertEqual(model.items.first?.title, "旧标题")
        await model.refresh(now: secondNow, calendar: calendar())
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items.first?.title, "新标题")
        XCTAssertEqual(model.items.first?.startAt, date("2026-09-14T10:30:00+08:00"))
    }

    func testSameSourceSnapshotsDedupeByStableIdentityForAllThreeSources() {
        let old = date("2026-09-14T08:00:00+08:00")
        let fresh = date("2026-09-14T08:01:00+08:00")
        var values: [ScheduleItem] = []
        for source in [ScheduleSourceKind.alarm, .calendar, .reminder] {
            values.append(item(source, id: "same", title: "旧", at: date("2026-09-14T10:00:00+08:00"), strength: .cached, observedAt: old))
            values.append(item(source, id: "same", title: "新", at: date("2026-09-14T10:00:00+08:00"), strength: .freshReadback, observedAt: fresh))
        }
        let canonical = ScheduleHubAggregation.canonicalItems(values)
        XCTAssertEqual(canonical.count, 3)
        XCTAssertEqual(canonical.filter { $0.title == "新" }.count, 3)
    }

    func testSameTitleAndTimeDifferentSourcesNeverMergeWithoutExplicitLineage() {
        let now = date("2026-09-14T08:00:00+08:00")
        let at = date("2026-09-14T15:00:00+08:00")
        let calendarItem = item(.calendar, id: "cal", title: "15:00 面试", at: at, observedAt: now)
        let reminder = item(.reminder, id: "rem", title: "15:00 面试", at: at, observedAt: now)
        XCTAssertEqual(ScheduleHubAggregation.canonicalItems([calendarItem, reminder]).count, 2)
    }

    func testExplicitCrossSourceLineageCanMergeOnlyWhenProvided() {
        let now = date("2026-09-14T08:00:00+08:00")
        let at = date("2026-09-14T15:00:00+08:00")
        let weaker = item(.calendar, id: "cal", title: "安排", at: at, strength: .taskProjection, observedAt: now, lineage: "task:t:action:a")
        let stronger = item(.reminder, id: "rem", title: "安排", at: at, strength: .freshReadback, observedAt: now, lineage: "task:t:action:a")
        let result = ScheduleHubAggregation.canonicalItems([weaker, stronger])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.sourceKind, .reminder)
    }

    func testSectionsSortTodayTomorrowLaterAndSameDayTimesAscending() {
        let now = date("2026-09-14T08:00:00+08:00")
        let values = [
            item(.calendar, id: "today-late", title: "晚", at: date("2026-09-14T18:00:00+08:00"), observedAt: now),
            item(.calendar, id: "later", title: "后天", at: date("2026-09-16T09:00:00+08:00"), observedAt: now),
            item(.reminder, id: "tomorrow", title: "明天", at: date("2026-09-15T09:00:00+08:00"), observedAt: now),
            item(.alarm, id: "today-early", title: "早", at: date("2026-09-14T09:00:00+08:00"), observedAt: now),
        ]
        let sections = ScheduleHubPresentation.sections(from: values, now: now, calendar: calendar())
        XCTAssertEqual(sections.map(\.kind), [.today, .tomorrow, .later])
        XCTAssertEqual(sections[0].items.map(\.sourceObjectID), ["today-early", "today-late"])
    }

    func testAllDaySortsBeforeTimedAndTieBreakerIsStable() {
        let now = date("2026-09-14T08:00:00+08:00")
        let midnight = date("2026-09-14T00:00:00+08:00")
        let at = date("2026-09-14T10:00:00+08:00")
        let values = [
            item(.alarm, id: "z", title: "同刻", at: at, observedAt: now),
            item(.calendar, id: "b", title: "同刻", at: at, observedAt: now),
            item(.calendar, id: "all-day", title: "全天", at: midnight, allDay: true, observedAt: now),
        ]
        let today = try! XCTUnwrap(ScheduleHubPresentation.sections(from: values, now: now, calendar: calendar()).first)
        XCTAssertEqual(today.items.map(\.sourceObjectID), ["all-day", "b", "z"])
    }

    func testUndatedItemsAreSeparatedFromTimedTimeline() {
        let now = date("2026-09-14T08:00:00+08:00")
        let undated = item(.reminder, id: "u", title: "未定", at: nil, status: .undated, observedAt: now)
        let timed = item(.calendar, id: "t", title: "定时", at: date("2026-09-14T10:00:00+08:00"), observedAt: now)
        let sections = ScheduleHubPresentation.sections(from: [undated, timed], now: now, calendar: calendar())
        XCTAssertEqual(sections.map(\.kind), [.today, .undated])
    }

    func testTimezoneAndCrossMidnightGroupingUsesLocalCalendarNotStringOrder() {
        var shanghai = calendar("Asia/Shanghai")
        shanghai.locale = Locale(identifier: "zh_CN")
        let now = date("2026-09-13T15:30:00Z") // Shanghai 23:30 on Sep 13.
        let afterMidnight = item(.calendar, id: "midnight", title: "凌晨", at: date("2026-09-13T16:30:00Z"), observedAt: now)
        let beforeMidnight = item(.calendar, id: "before", title: "今晚", at: date("2026-09-13T15:45:00Z"), observedAt: now)
        let sections = ScheduleHubPresentation.sections(from: [afterMidnight, beforeMidnight], now: now, calendar: shanghai)
        XCTAssertEqual(sections.map(\.kind), [.today, .tomorrow])
        XCTAssertEqual(sections[0].items.first?.sourceObjectID, "before")
        XCTAssertEqual(sections[1].items.first?.sourceObjectID, "midnight")
    }

    func testEquivalentUTCInstantSortsDeterministicallyBySourceThenIdentity() {
        let now = date("2026-09-14T08:00:00+08:00")
        let utc = date("2026-09-14T02:00:00Z")
        let offset = date("2026-09-14T10:00:00+08:00")
        XCTAssertEqual(utc, offset)
        let values = [
            item(.alarm, id: "alarm", title: "同刻", at: utc, observedAt: now),
            item(.calendar, id: "calendar", title: "同刻", at: offset, observedAt: now),
        ]
        let section = ScheduleHubPresentation.sections(from: values, now: now, calendar: calendar()).first!
        XCTAssertEqual(section.items.map(\.sourceKind), [.calendar, .alarm])
    }

    func testInactiveStatusesNeverMasqueradeAsUpcoming() {
        let now = date("2026-09-14T08:00:00+08:00")
        let future = date("2026-09-14T12:00:00+08:00")
        let values = [
            item(.calendar, id: "completed", title: "完成", at: future, status: .completed, observedAt: now),
            item(.calendar, id: "cancelled", title: "取消", at: future, status: .cancelled, observedAt: now),
            item(.alarm, id: "removed", title: "移除", at: future, status: .removed, sourceExists: false, observedAt: now),
            item(.reminder, id: "overdue", title: "逾期", at: date("2026-09-14T07:00:00+08:00"), status: .overdue, observedAt: now),
            item(.alarm, id: "attention", title: "待确认", at: future, status: .needsAttention, observedAt: now),
            item(.calendar, id: "upcoming", title: "正常", at: future, status: .upcoming, observedAt: now),
        ]
        let sections = ScheduleHubPresentation.sections(from: values, now: now, calendar: calendar())
        XCTAssertEqual(sections.first(where: { $0.kind == .today })?.items.map(\.sourceObjectID), ["upcoming"])
        XCTAssertEqual(Set(sections.first(where: { $0.kind == .attention })!.items.map(\.sourceObjectID)), ["overdue", "attention"])
        XCTAssertEqual(Set(sections.first(where: { $0.kind == .past })!.items.map(\.sourceObjectID)), ["completed", "cancelled", "removed"])
    }

    func testWeeklyAlarmOccurrenceTodayLaterTodayPassedAndNextWeek() {
        let cal = calendar()
        let schedule = AlarmDesiredSchedule.weekly(hour: 10, minute: 0, weekdays: [.monday])
        let mondayMorning = date("2026-09-14T09:00:00+08:00")
        let mondayLate = date("2026-09-14T11:00:00+08:00")
        XCTAssertEqual(
            ScheduleAlarmOccurrence.nextOccurrence(schedule: schedule, after: mondayMorning, calendar: cal),
            date("2026-09-14T10:00:00+08:00")
        )
        XCTAssertEqual(
            ScheduleAlarmOccurrence.nextOccurrence(schedule: schedule, after: mondayLate, calendar: cal),
            date("2026-09-21T10:00:00+08:00")
        )
        XCTAssertEqual(ScheduleAlarmOccurrence.recurrenceDescription(schedule), "每周 周一 · 10:00")
    }

    func testSummaryCountsTodayAndPicksExactNextItem() {
        let now = date("2026-09-14T08:00:00+08:00")
        let values = [
            item(.calendar, id: "later", title: "第二项", at: date("2026-09-14T11:00:00+08:00"), observedAt: now),
            item(.reminder, id: "next", title: "第一项", at: date("2026-09-14T09:00:00+08:00"), observedAt: now),
            item(.alarm, id: "removed", title: "不算", at: date("2026-09-14T08:30:00+08:00"), status: .removed, sourceExists: false, observedAt: now),
        ]
        let summary = ScheduleHubPresentation.summary(from: values, now: now, calendar: calendar())
        XCTAssertEqual(summary.todayCount, 2)
        XCTAssertEqual(summary.nextItem?.sourceObjectID, "next")
    }

    func testSettingsCopyEmptyStateAndNavigationTargetsRemainExact() {
        XCTAssertEqual(ScheduleHubPresentation.settingsEntryTitle, "我的安排")
        XCTAssertEqual(ScheduleHubPresentation.navigationTitle, "我的安排")
        XCTAssertEqual(ScheduleHubPresentation.emptyTitle, "还没有近期安排")
        let alarmID = UUID()
        let now = date("2026-09-14T08:00:00+08:00")
        XCTAssertEqual(item(.alarm, id: alarmID.uuidString, title: "A", at: now, observedAt: now, navigation: .alarm(alarmID)).navigationTarget, .alarm(alarmID))
        XCTAssertEqual(item(.calendar, id: "event-exact", title: "C", at: now, observedAt: now, navigation: .calendar("event-exact")).navigationTarget, .calendar("event-exact"))
        XCTAssertEqual(item(.reminder, id: "rem-exact", title: "R", at: now, observedAt: now, navigation: .reminder("rem-exact")).navigationTarget, .reminder("rem-exact"))
    }

    func testScheduleRemovalDescriptorUsesExactNativeIdentityAndStableAttempt() throws {
        let descriptor = ScheduleRemovalDescriptor(
            sourceKind: .calendar,
            sourceObjectID: "event-123",
            expectedRevision: String(repeating: "a", count: 64),
            expectedContainerID: "calendar-456",
            expectedTitle: "面试",
            eligible: true,
            ineligibleReason: nil
        )
        let payload = try XCTUnwrap(descriptor.payload)
        XCTAssertEqual(descriptor.actionType, "calendar.remove")
        XCTAssertEqual(payload["event_id"]?.stringValue, "event-123")
        XCTAssertEqual(payload["expected_revision"]?.stringValue, String(repeating: "a", count: 64))
        XCTAssertEqual(payload["expected_calendar_id"]?.stringValue, "calendar-456")
        XCTAssertEqual(payload["expected_title"]?.stringValue, "面试")
        XCTAssertEqual(descriptor.attemptID, descriptor.attemptID)
        XCTAssertTrue(descriptor.attemptID?.hasPrefix("settings.schedule.remove.") == true)
    }

    func testScheduleRemovalVerifiedSuccessReplaysWithoutSecondDelete() async throws {
        let directory = temporaryRemovalDirectory("success")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DeviceActionJournal(directoryURL: directory)
        let executor = ScheduleRemovalSuccessExecutor(capabilityID: "reminder.remove")
        let coordinator = ScheduleHubRemovalCoordinator(journal: journal, executors: [executor])
        let descriptor = ScheduleRemovalDescriptor(
            sourceKind: .reminder,
            sourceObjectID: "reminder-123",
            expectedRevision: String(repeating: "b", count: 64),
            expectedContainerID: "list-456",
            expectedTitle: "交材料",
            eligible: true,
            ineligibleReason: nil
        )

        let first = try await coordinator.remove(descriptor)
        let replay = try await coordinator.remove(descriptor)
        XCTAssertEqual(first, .removed)
        XCTAssertEqual(replay, .removed)
        let executionCount = await executor.executionCount()
        XCTAssertEqual(executionCount, 1)
    }

    func testScheduleRemovalAmbiguousAttemptReconcilesWithoutBlindRetry() async throws {
        let directory = temporaryRemovalDirectory("ambiguous")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DeviceActionJournal(directoryURL: directory)
        let executor = ScheduleRemovalAmbiguousExecutor(capabilityID: "calendar.remove")
        let coordinator = ScheduleHubRemovalCoordinator(journal: journal, executors: [executor])
        let descriptor = ScheduleRemovalDescriptor(
            sourceKind: .calendar,
            sourceObjectID: "event-ambiguous",
            expectedRevision: String(repeating: "c", count: 64),
            expectedContainerID: "calendar-ambiguous",
            expectedTitle: "需要确认",
            eligible: true,
            ineligibleReason: nil
        )

        let first = try await coordinator.remove(descriptor)
        guard case .needsReconciliation = first else {
            return XCTFail("expected ambiguous result after native throw")
        }
        let second = try await coordinator.remove(descriptor)
        guard case .needsReconciliation = second else {
            return XCTFail("expected read-only reconciliation on retry")
        }
        let executionCount = await executor.executionCount()
        let reconciliationCount = await executor.reconciliationCount()
        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(reconciliationCount, 1)
    }

    func testVerifiedRemovalMovesReminderIntoPastAndSurvivesRefreshAndRelaunch() async throws {
        let directory = temporaryRemovalDirectory("history")
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyStore = ScheduleHubRemovalHistoryStore(
            fileURL: directory.appendingPathComponent("removed-items.json"),
            journalURL: nil
        )
        let now = date("2026-09-14T08:00:00+08:00")
        let removedAt = date("2026-09-14T08:05:00+08:00")
        let reminder = item(
            .reminder,
            id: "rem-history",
            title: "删除后仍可回看",
            at: date("2026-09-14T10:00:00+08:00"),
            observedAt: now
        )
        let source = ScheduleHubTestSequenceSource(
            kind: .reminder,
            steps: [.items([reminder]), .items([])]
        )
        let model = ScheduleHubModel(sources: [source], removalHistoryStore: historyStore)

        await model.refresh(now: now, calendar: calendar())
        XCTAssertEqual(model.items.first?.status, .upcoming)

        model.recordVerifiedRemoval(reminder, at: removedAt, calendar: calendar())
        var past = try XCTUnwrap(model.sections.first(where: { $0.kind == .past }))
        XCTAssertEqual(past.items.map(\.sourceObjectID), ["rem-history"])
        XCTAssertEqual(past.items.first?.status, .removed)
        XCTAssertEqual(past.items.first?.sourceExists, false)

        await model.refresh(now: removedAt, calendar: calendar())
        past = try XCTUnwrap(model.sections.first(where: { $0.kind == .past }))
        XCTAssertEqual(past.items.map(\.sourceObjectID), ["rem-history"])

        let reopenedSource = ScheduleHubTestSequenceSource(kind: .reminder, steps: [.items([])])
        let reopened = ScheduleHubModel(sources: [reopenedSource], removalHistoryStore: historyStore)
        await reopened.refresh(now: removedAt, calendar: calendar())
        let reopenedPast = try XCTUnwrap(reopened.sections.first(where: { $0.kind == .past }))
        XCTAssertEqual(reopenedPast.items.map(\.sourceObjectID), ["rem-history"])
        XCTAssertEqual(reopenedPast.items.first?.title, "删除后仍可回看")
    }

    func testVerifiedLegacyRemovalJournalBackfillsAlreadyDeletedReminder() async throws {
        let directory = temporaryRemovalDirectory("legacy-journal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DeviceActionJournal(directoryURL: directory)
        let descriptor = ScheduleRemovalDescriptor(
            sourceKind: .reminder,
            sourceObjectID: "rem-already-deleted",
            expectedRevision: String(repeating: "d", count: 64),
            expectedContainerID: "list-already-deleted",
            expectedTitle: "刚刚删掉的提醒",
            eligible: true,
            ineligibleReason: nil
        )
        let dispatch = try XCTUnwrap(descriptor.dispatch)
        _ = try await journal.prepare(dispatch)
        _ = try await journal.markMayHaveStarted(attemptID: dispatch.attemptID)
        _ = try await journal.recordResult(
            attemptID: dispatch.attemptID,
            success: true,
            result: [
                "requested_reminder_id": .string("rem-already-deleted"),
                "list_id": .string("list-already-deleted"),
                "title": .string("刚刚删掉的提醒"),
                "deleted": .bool(true),
                "verified": .bool(true),
            ]
        )
        _ = try await journal.markResultDelivered(attemptID: dispatch.attemptID)

        let historyStore = ScheduleHubRemovalHistoryStore(
            fileURL: directory.appendingPathComponent("removed-items.json"),
            journalURL: directory.appendingPathComponent("device-action-journal.json")
        )
        let source = ScheduleHubTestSequenceSource(kind: .reminder, steps: [.items([])])
        let model = ScheduleHubModel(sources: [source], removalHistoryStore: historyStore)
        await model.refresh(now: Date(), calendar: calendar())

        let past = try XCTUnwrap(model.sections.first(where: { $0.kind == .past }))
        XCTAssertEqual(past.items.map(\.sourceObjectID), ["rem-already-deleted"])
        XCTAssertEqual(past.items.first?.title, "刚刚删掉的提醒")
        XCTAssertEqual(past.items.first?.status, .removed)
    }

    private func temporaryRemovalDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("schedule-hub-removal-tests", isDirectory: true)
            .appendingPathComponent("\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }

    private func item(
        _ source: ScheduleSourceKind,
        id: String,
        title: String,
        at: Date?,
        allDay: Bool = false,
        status: ScheduleItemStatus = .upcoming,
        sourceExists: Bool = true,
        strength: ScheduleTruthStrength = .freshReadback,
        observedAt: Date,
        lineage: String? = nil,
        navigation: ScheduleNavigationTarget? = nil
    ) -> ScheduleItem {
        let route: ScheduleNavigationTarget
        if let navigation {
            route = navigation
        } else {
            switch source {
            case .alarm: route = .readOnly(id)
            case .calendar: route = .calendar(id)
            case .reminder: route = .reminder(id)
            case .other: route = .readOnly(id)
            }
        }
        return ScheduleItem(
            sourceKind: source,
            sourceObjectID: id,
            title: title,
            startAt: at,
            endAt: nil,
            isAllDay: allDay,
            recurrenceDescription: nil,
            status: status,
            sourceExists: sourceExists,
            navigationTarget: route,
            taskCorrelation: nil,
            explicitLineageID: lineage,
            truthStrength: strength,
            observedAt: observedAt,
            sourceContext: nil,
            removal: nil
        )
    }

    private func calendar(_ timezone: String = "Asia/Shanghai") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: timezone)!
        value.locale = Locale(identifier: "zh_CN")
        return value
    }

    private func date(_ raw: String) -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = fractional.date(from: raw) { return value }
        let normal = ISO8601DateFormatter()
        normal.formatOptions = [.withInternetDateTime]
        return normal.date(from: raw)!
    }
}
