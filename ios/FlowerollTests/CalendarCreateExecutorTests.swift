import EventKit
import XCTest
@testable import Floweroll

private func jsonNumber(_ value: JSONValue?) -> Double? {
    guard case let .number(number)? = value else { return nil }
    return number
}

@MainActor
final class CalendarCreateExecutorTests: XCTestCase {
    func payload(calendar: String = "测试") -> [String: JSONValue] {
        ["title": .string("小卷日历验收"), "start_at": .string("2030-01-02T10:00:00+08:00"),
         "end_at": .string("2030-01-02T11:00:00+08:00"), "time_zone": .string("Asia/Shanghai"),
         "calendar_name": .string(calendar), "location": .string("测试地点"), "item_id": .string("calendar")]
    }

    func dispatch(_ payload: [String: JSONValue], key: String = UUID().uuidString) -> DeviceActionDispatch {
        DeviceActionDispatch(actionID: key, taskID: "calendar-test", actionType: "calendar.create",
            payload: payload, status: "executing", runtimeActionStatus: "executing", idempotencyKey: key,
            attemptID: key, attemptNumber: 1, attemptStatus: "IN_FLIGHT", dispatchDigest: key)
    }


    private func managementDispatch(
        _ actionType: String,
        payload: [String: JSONValue],
        key: String = UUID().uuidString
    ) -> DeviceActionDispatch {
        DeviceActionDispatch(
            actionID: key, taskID: "calendar-management-test", actionType: actionType,
            payload: payload, status: "executing", runtimeActionStatus: "executing",
            idempotencyKey: key, attemptID: key, attemptNumber: 1,
            attemptStatus: "IN_FLIGHT", dispatchDigest: key
        )
    }

    private func iso8601(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    private func journalEntry(_ dispatch: DeviceActionDispatch) -> DeviceActionJournalEntry {
        DeviceActionJournalEntry(
            attemptID: dispatch.attemptID,
            actionID: dispatch.actionID,
            idempotencyKey: dispatch.idempotencyKey,
            dispatchDigest: dispatch.dispatchDigest,
            state: .mayHaveStarted,
            success: nil, result: nil, error: nil, nativeCorrelationID: nil,
            createdAt: Date(), updatedAt: Date()
        )
    }

    func testRejectInvalidTimeAndUnsupportedActions() async throws {
        XCTAssertNotNil(CalendarCreateArguments(payload()))
        for change: [String: JSONValue] in [
            ["end_at": .string("2030-01-02T09:00:00+08:00")], ["time_zone": .string("UTC")],
            ["start_at": .string("2030-01-02T10:00:00")], ["title": .string(" ")],
            ["all_day": .bool(true)], ["calendar_name": .string("")]] {
            let invalid = payload().merging(change) { _, new in new }
            XCTAssertNil(CalendarCreateArguments(invalid))
            let failure = try await CalendarCreateExecutor().preflight(dispatch(invalid))
            XCTAssertEqual(failure?.error, "calendar_create_invalid_arguments")
        }
    }

    func testNativeReadbackReplayAndUnknownRecovery() async throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw XCTSkip("Real EventKit acceptance requires the app's existing full calendar grant.")
        }
        let store = EKEventStore()
        let source = try XCTUnwrap(store.defaultCalendarForNewEvents?.source)
        let name = "小卷验收-" + UUID().uuidString
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = name; calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        let calendarID = calendar.calendarIdentifier
        // Remove only the UUID-named calendar created by this test.
        defer {
            store.reset()
            if let owned = store.calendar(withIdentifier: calendarID), owned.title == name {
                do {
                    try store.removeCalendar(owned, commit: true)
                    store.reset()
                    XCTAssertNil(store.calendar(withIdentifier: calendarID), "test calendar cleanup must read back absent")
                } catch {
                    XCTFail("test calendar cleanup failed: \(error.localizedDescription)")
                }
            }
        }
        let request = dispatch(payload(calendar: name))
        let executor = CalendarCreateExecutor()
        let failure = try await executor.preflight(request)
        XCTAssertNil(failure)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let journal = try DeviceActionJournal(directoryURL: directory)
        _ = try await journal.prepare(request)
        _ = try await journal.markMayHaveStarted(attemptID: request.attemptID)
        let result = try await executor.execute(request)
        XCTAssertTrue(result.success)
        let id = try XCTUnwrap(result.nativeCorrelationID)
        store.reset()
        let native = try XCTUnwrap(store.event(withIdentifier: id))
        XCTAssertEqual(native.title, "小卷日历验收")
        XCTAssertEqual(native.calendar.calendarIdentifier, calendarID)
        XCTAssertEqual(native.timeZone?.identifier, "Asia/Shanghai")
        XCTAssertEqual(native.location, "测试地点")
        XCTAssertFalse(native.hasRecurrenceRules)

        // Reconstruct both journal and executor after native save, before any
        // durable result or Host acknowledgement: no second event may appear.
        let recoveredJournal = try DeviceActionJournal(directoryURL: directory)
        let recoveredExecutor = CalendarCreateExecutor()
        let entry = await recoveredJournal.entry(attemptID: request.attemptID)
        let recovered = try await recoveredExecutor.reconcile(request, journalEntry: XCTUnwrap(entry))
        guard case let .completed(receipt) = recovered else { return XCTFail("saved event not reconciled") }
        XCTAssertEqual(receipt.nativeCorrelationID, id)
        let repeated = try await recoveredExecutor.execute(request)
        XCTAssertEqual(repeated.nativeCorrelationID, id)
        let predicate = store.predicateForEvents(withStart: native.startDate, end: native.endDate, calendars: [native.calendar])
        XCTAssertEqual(store.events(matching: predicate).count, 1)

        // A deleted or moved event cannot be interpreted as safe to recreate.
        try store.remove(native, span: .thisEvent, commit: true)
        let unknown = try await recoveredExecutor.reconcile(request, journalEntry: XCTUnwrap(entry))
        guard case .stillUnknown = unknown else { return XCTFail("missing receipt permits duplicate create") }
        XCTAssertTrue(store.events(matching: predicate).isEmpty)

        let missing = try await executor.preflight(dispatch(payload(calendar: name + "-missing")))
        XCTAssertEqual(missing?.success, false)
    }

    func testCalendarQueryUpdateNoopStaleRecurringAndReconciliation() async throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw XCTSkip("Calendar update integration requires the app's existing full Calendar grant.")
        }
        let store = EKEventStore()
        store.reset()
        let source = try XCTUnwrap(store.defaultCalendarForNewEvents?.source)
        let name = "小卷CalendarUpdate验收-" + UUID().uuidString
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = name
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        let calendarID = calendar.calendarIdentifier
        defer {
            store.reset()
            if let owned = store.calendar(withIdentifier: calendarID), owned.title == name {
                do { try store.removeCalendar(owned, commit: true) }
                catch { XCTFail("calendar update fixture cleanup failed: \(error.localizedDescription)") }
            }
        }

        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let start = Date().addingTimeInterval(7_200)
        let end = start.addingTimeInterval(3_600)
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = "小卷 Calendar Update 原始标题"
        event.startDate = start
        event.endDate = end
        event.timeZone = zone
        event.location = "杭州"
        try store.save(event, span: .thisEvent, commit: true)
        let eventID = try XCTUnwrap(event.eventIdentifier)

        let query = CalendarQueryExecutor()
        let queryRequest = managementDispatch(
            "calendar.query",
            payload: [
                "start_at": .string(iso8601(start.addingTimeInterval(-600), timeZone: zone)),
                "end_at": .string(iso8601(end.addingTimeInterval(600), timeZone: zone)),
                "max_results": .number(50),
            ]
        )
        let queryPreflight = try await query.preflight(queryRequest)
        XCTAssertNil(queryPreflight)
        let queryResult = try await query.execute(queryRequest)
        XCTAssertTrue(queryResult.success)
        let events = try XCTUnwrap(queryResult.output["events"]?.arrayValue)
        let row = try XCTUnwrap(events.compactMap(\.objectValue).first { $0["event_id"]?.stringValue == eventID })
        XCTAssertEqual(row["calendar_id"]?.stringValue, calendarID)
        XCTAssertEqual(row["calendar_writable"]?.boolValue, true)
        XCTAssertEqual(row["time_zone"]?.stringValue, zone.identifier)
        XCTAssertEqual(row["update_eligible"]?.boolValue, true)
        XCTAssertEqual(row["has_recurrence"]?.boolValue, false)
        XCTAssertEqual(row["has_attendees"]?.boolValue, false)
        XCTAssertEqual(row["has_organizer"]?.boolValue, false)
        let revision = try XCTUnwrap(row["revision"]?.stringValue)
        XCTAssertEqual(revision.count, 64)

        let desiredStart = start.addingTimeInterval(1_800)
        let desiredEnd = end.addingTimeInterval(1_800)
        let updatePayload: [String: JSONValue] = [
            "event_id": .string(eventID),
            "expected_revision": .string(revision),
            "expected_calendar_id": .string(calendarID),
            "title": .string("小卷 Calendar Update 新标题"),
            "start_at": .string(iso8601(desiredStart, timeZone: zone)),
            "end_at": .string(iso8601(desiredEnd, timeZone: zone)),
            "time_zone": .string(zone.identifier),
            "location": .string("上海"),
        ]
        let updateRequest = managementDispatch("calendar.update", payload: updatePayload)
        let executor = CalendarUpdateExecutor()
        let updatePreflight = try await executor.preflight(updateRequest)
        XCTAssertNil(updatePreflight)
        let updated = try await executor.execute(updateRequest)
        XCTAssertTrue(updated.success)
        XCTAssertEqual(updated.output["requested_event_id"]?.stringValue, eventID)
        XCTAssertEqual(updated.output["applied"]?.boolValue, true)
        XCTAssertEqual(updated.output["title"]?.stringValue, "小卷 Calendar Update 新标题")
        XCTAssertEqual(updated.output["location"]?.stringValue, "上海")
        XCTAssertEqual(updated.output["update_eligible"]?.boolValue, true)

        store.reset()
        let native = try XCTUnwrap(store.event(withIdentifier: eventID))
        XCTAssertEqual(native.title, "小卷 Calendar Update 新标题")
        XCTAssertEqual(native.location, "上海")
        XCTAssertEqual(native.timeZone?.identifier, zone.identifier)
        XCTAssertLessThan(abs(native.startDate.timeIntervalSince(desiredStart)), 1.0)
        XCTAssertLessThan(abs(native.endDate.timeIntervalSince(desiredEnd)), 1.0)
        let modifiedBeforeNoop = native.lastModifiedDate

        let freshRevision = try XCTUnwrap(updated.output["revision"]?.stringValue)
        var noopPayload = updatePayload
        noopPayload["expected_revision"] = .string(freshRevision)
        let noopRequest = managementDispatch("calendar.update", payload: noopPayload)
        let noopPreflight = try await executor.preflight(noopRequest)
        XCTAssertNil(noopPreflight)
        let noop = try await executor.execute(noopRequest)
        XCTAssertTrue(noop.success)
        XCTAssertEqual(noop.output["applied"]?.boolValue, false)
        store.reset()
        XCTAssertEqual(store.event(withIdentifier: eventID)?.lastModifiedDate, modifiedBeforeNoop)

        let reconciled = try await executor.reconcile(updateRequest, journalEntry: journalEntry(updateRequest))
        guard case let .completed(receipt) = reconciled else {
            return XCTFail("calendar desired state should reconcile read-only")
        }
        XCTAssertTrue(receipt.success)
        store.reset()
        XCTAssertEqual(store.event(withIdentifier: eventID)?.lastModifiedDate, modifiedBeforeNoop)

        let staleSnapshot = CalendarEventSnapshot.read(try XCTUnwrap(store.event(withIdentifier: eventID)))
        var stalePayload = noopPayload
        stalePayload["expected_revision"] = .string(try XCTUnwrap(staleSnapshot.revision))
        stalePayload["title"] = .string("不应覆盖外部修改")
        let staleRequest = managementDispatch("calendar.update", payload: stalePayload)
        let externallyChanged = try XCTUnwrap(store.event(withIdentifier: eventID))
        externallyChanged.location = "外部修改"
        try store.save(externallyChanged, span: .thisEvent, commit: true)
        let staleFailure = try await executor.preflight(staleRequest)
        XCTAssertEqual(staleFailure?.success, false)
        XCTAssertEqual(staleFailure?.output["error_code"]?.stringValue, "calendar_update_revision_stale")
        store.reset()
        XCTAssertEqual(store.event(withIdentifier: eventID)?.location, "外部修改")

        let recurring = EKEvent(eventStore: store)
        recurring.calendar = try XCTUnwrap(store.calendar(withIdentifier: calendarID))
        recurring.title = "小卷 Calendar Update 重复事件"
        recurring.startDate = desiredStart.addingTimeInterval(10_800)
        recurring.endDate = desiredEnd.addingTimeInterval(10_800)
        recurring.timeZone = zone
        recurring.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 3)))
        try store.save(recurring, span: .thisEvent, commit: true)
        let recurringID = try XCTUnwrap(recurring.eventIdentifier)
        let recurringSnapshot = CalendarEventSnapshot.read(recurring)
        XCTAssertFalse(recurringSnapshot.updateEligible)
        var recurringPayload = updatePayload
        recurringPayload["event_id"] = .string(recurringID)
        recurringPayload["expected_revision"] = .string(try XCTUnwrap(recurringSnapshot.revision))
        recurringPayload["title"] = .string("不应修改重复事件")
        let recurringFailure = try await executor.preflight(
            managementDispatch("calendar.update", payload: recurringPayload)
        )
        XCTAssertEqual(recurringFailure?.success, false)
        XCTAssertEqual(recurringFailure?.output["error_code"]?.stringValue, "calendar_update_unsupported_target")
    }

    func testCalendarRemoveExactOwnedTargetAndAmbiguousRecovery() async throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw XCTSkip("Calendar remove integration requires the app's existing full Calendar grant.")
        }
        let store = EKEventStore()
        store.reset()
        let source = try XCTUnwrap(store.defaultCalendarForNewEvents?.source)
        let name = "小卷CalendarRemove验收-" + UUID().uuidString
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = name
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        let calendarID = calendar.calendarIdentifier
        defer {
            store.reset()
            if let owned = store.calendar(withIdentifier: calendarID), owned.title == name {
                do { try store.removeCalendar(owned, commit: true) }
                catch { XCTFail("calendar remove fixture cleanup failed: \(error.localizedDescription)") }
            }
        }

        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let start = Date().addingTimeInterval(5_400)
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = "小卷 Calendar Remove"
        event.startDate = start
        event.endDate = start.addingTimeInterval(1_800)
        event.timeZone = zone
        try store.save(event, span: .thisEvent, commit: true)
        let eventID = try XCTUnwrap(event.eventIdentifier)
        let snapshot = CalendarEventSnapshot.read(event)
        XCTAssertTrue(snapshot.removeEligible)
        let revision = try XCTUnwrap(snapshot.revision)
        let payload: [String: JSONValue] = [
            "event_id": .string(eventID),
            "expected_revision": .string(revision),
            "expected_calendar_id": .string(calendarID),
            "expected_title": .string("小卷 Calendar Remove"),
        ]
        let request = managementDispatch("calendar.remove", payload: payload)
        let executor = CalendarRemoveExecutor()
        let removePreflight = try await executor.preflight(request)
        XCTAssertNil(removePreflight)
        let removed = try await executor.execute(request)
        XCTAssertTrue(removed.success)
        XCTAssertEqual(removed.output["deleted"]?.boolValue, true)
        XCTAssertEqual(removed.output["verified"]?.boolValue, true)
        XCTAssertEqual(removed.output["verification"]?.stringValue, "immediate_exact_id_absence")
        store.reset()
        XCTAssertNil(store.event(withIdentifier: eventID))

        // After mayHaveStarted/process loss, absence is intentionally not
        // promoted to success: EventKit IDs can disappear through sync changes.
        let recovery = try await executor.reconcile(request, journalEntry: journalEntry(request))
        guard case .stillUnknown = recovery else {
            return XCTFail("post-crash exact-ID absence must remain unknown for destructive EventKit remove")
        }
        store.reset()
        XCTAssertNil(store.event(withIdentifier: eventID), "reconciliation must never repeat the remove")

        let stale = EKEvent(eventStore: store)
        stale.calendar = try XCTUnwrap(store.calendar(withIdentifier: calendarID))
        stale.title = "小卷 Calendar Remove Stale"
        stale.startDate = start.addingTimeInterval(7_200)
        stale.endDate = stale.startDate.addingTimeInterval(1_800)
        stale.timeZone = zone
        try store.save(stale, span: .thisEvent, commit: true)
        let staleID = try XCTUnwrap(stale.eventIdentifier)
        let staleSnapshot = CalendarEventSnapshot.read(stale)
        var stalePayload: [String: JSONValue] = [
            "event_id": .string(staleID),
            "expected_revision": .string(try XCTUnwrap(staleSnapshot.revision)),
            "expected_calendar_id": .string(calendarID),
            "expected_title": .string(stale.title),
        ]
        stale.location = "外部修改"
        try store.save(stale, span: .thisEvent, commit: true)
        let staleFailure = try await executor.preflight(managementDispatch("calendar.remove", payload: stalePayload))
        XCTAssertEqual(staleFailure?.output["error_code"]?.stringValue, "calendar_remove_revision_stale")
        store.reset()
        XCTAssertNotNil(store.event(withIdentifier: staleID), "stale preflight must not delete")

        let recurring = EKEvent(eventStore: store)
        recurring.calendar = try XCTUnwrap(store.calendar(withIdentifier: calendarID))
        recurring.title = "小卷 Calendar Remove Recurring"
        recurring.startDate = start.addingTimeInterval(14_400)
        recurring.endDate = recurring.startDate.addingTimeInterval(1_800)
        recurring.timeZone = zone
        recurring.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 3)))
        try store.save(recurring, span: .thisEvent, commit: true)
        let recurringSnapshot = CalendarEventSnapshot.read(recurring)
        XCTAssertFalse(recurringSnapshot.removeEligible)
        stalePayload = [
            "event_id": .string(try XCTUnwrap(recurring.eventIdentifier)),
            "expected_revision": .string(try XCTUnwrap(recurringSnapshot.revision)),
            "expected_calendar_id": .string(calendarID),
            "expected_title": .string(recurring.title),
        ]
        let recurringFailure = try await executor.preflight(managementDispatch("calendar.remove", payload: stalePayload))
        XCTAssertEqual(recurringFailure?.output["error_code"]?.stringValue, "calendar_remove_unsupported_target")
    }

}


@MainActor
final class ReminderManagementExecutorTests: XCTestCase {
    private func dispatch(
        _ actionType: String,
        payload: [String: JSONValue],
        key: String = UUID().uuidString
    ) -> DeviceActionDispatch {
        DeviceActionDispatch(
            actionID: key,
            taskID: "reminder-management-test",
            actionType: actionType,
            payload: payload,
            status: "executing",
            runtimeActionStatus: "executing",
            idempotencyKey: key,
            attemptID: key,
            attemptNumber: 1,
            attemptStatus: "IN_FLIGHT",
            dispatchDigest: key
        )
    }

    private func dueComponents(_ date: Date) -> DateComponents {
        Calendar.autoupdatingCurrent.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
            from: date
        )
    }


    private func iso8601(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    private func createOwnedList(in store: EKEventStore) throws -> EKCalendar {
        let source = try XCTUnwrap(store.defaultCalendarForNewReminders()?.source)
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = "小卷Reminder验收-" + UUID().uuidString
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return calendar
    }

    private func createReminder(
        in store: EKEventStore,
        calendar: EKCalendar,
        title: String,
        due: Date,
        recurring: Bool = false
    ) throws -> EKReminder {
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = title
        reminder.startDateComponents = dueComponents(due)
        reminder.dueDateComponents = dueComponents(due)
        reminder.addAlarm(EKAlarm(absoluteDate: due))
        if recurring {
            reminder.addRecurrenceRule(
                EKRecurrenceRule(
                    recurrenceWith: .daily,
                    interval: 1,
                    end: EKRecurrenceEnd(occurrenceCount: 3)
                )
            )
        }
        try store.save(reminder, commit: true)
        return reminder
    }

    private func cleanupOwnedList(_ calendarID: String, title: String) {
        let store = EKEventStore()
        store.reset()
        guard let calendar = store.calendar(withIdentifier: calendarID), calendar.title == title else { return }
        do {
            try store.removeCalendar(calendar, commit: true)
            store.reset()
            XCTAssertNil(store.calendar(withIdentifier: calendarID), "owned Reminder list cleanup must read back absent")
        } catch {
            XCTFail("owned Reminder list cleanup failed: \(error.localizedDescription)")
        }
    }

    func testReminderCompletionReadbackGuardRejectsMismatch() {
        let base = ReminderManagementSnapshot(
            reminderID: "r1",
            title: "fixture",
            completed: true,
            dueAt: nil,
            completionAt: Date(),
            calendarID: "list",
            calendarName: "list",
            calendarWritable: true,
            hasRecurrence: false,
            revision: String(repeating: "a", count: 64)
        )
        XCTAssertTrue(ReminderSetCompletionExecutor.readbackMatchesV1(base, desired: true))
        XCTAssertFalse(ReminderSetCompletionExecutor.readbackMatchesV1(base, desired: false))
        XCTAssertFalse(
            ReminderSetCompletionExecutor.readbackMatchesV1(
                ReminderManagementSnapshot(
                    reminderID: base.reminderID, title: base.title, completed: true,
                    dueAt: nil, completionAt: base.completionAt, calendarID: base.calendarID,
                    calendarName: base.calendarName, calendarWritable: false,
                    hasRecurrence: false, revision: base.revision
                ),
                desired: true
            )
        )
        XCTAssertFalse(
            ReminderSetCompletionExecutor.readbackMatchesV1(
                ReminderManagementSnapshot(
                    reminderID: base.reminderID, title: base.title, completed: true,
                    dueAt: nil, completionAt: base.completionAt, calendarID: base.calendarID,
                    calendarName: base.calendarName, calendarWritable: true,
                    hasRecurrence: true, revision: base.revision
                ),
                desired: true
            )
        )
    }

    func testReminderPermissionFailsClosedWhenNotFullAccess() async throws {
        guard EKEventStore.authorizationStatus(for: .reminder) != .fullAccess else {
            throw XCTSkip("Run this test after Simulator Reminder permission is revoked/reset.")
        }
        let request = dispatch(
            "reminder.query",
            payload: ["reminder_id": .string("does-not-matter")]
        )
        let failure = try await ReminderQueryExecutor().preflight(request)
        XCTAssertEqual(failure?.success, false)
        XCTAssertEqual(failure?.output["error_code"]?.stringValue, "reminders_full_access_required")

        let mutation = dispatch(
            "reminder.set_completion",
            payload: [
                "reminder_id": .string("does-not-matter"),
                "expected_revision": .string(String(repeating: "a", count: 64)),
                "completed": .bool(true),
            ]
        )
        let mutationFailure = try await ReminderSetCompletionExecutor().preflight(mutation)
        XCTAssertEqual(mutationFailure?.success, false)
        XCTAssertEqual(
            mutationFailure?.output["error_code"]?.stringValue,
            "reminders_full_access_required"
        )
    }

    func testReminderQueryCompletionStaleRecurringAndReconciliation() async throws {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            throw XCTSkip("Real Reminder management tests require the app's existing full Reminder grant.")
        }

        let store = EKEventStore()
        let calendar = try createOwnedList(in: store)
        let calendarID = calendar.calendarIdentifier
        let calendarTitle = calendar.title
        defer { cleanupOwnedList(calendarID, title: calendarTitle) }

        let due = Date().addingTimeInterval(3600)
        let first = try createReminder(
            in: store,
            calendar: calendar,
            title: "小卷 Reminder Query Alpha",
            due: due
        )
        _ = try createReminder(
            in: store,
            calendar: calendar,
            title: "小卷 Reminder Query Beta",
            due: due.addingTimeInterval(120)
        )
        let recurring = try createReminder(
            in: store,
            calendar: calendar,
            title: "小卷 Reminder Recurring",
            due: due.addingTimeInterval(240),
            recurring: true
        )
        let firstID = first.calendarItemIdentifier
        let recurringID = recurring.calendarItemIdentifier

        let query = ReminderQueryExecutor()
        let exactRequest = dispatch(
            "reminder.query",
            payload: ["reminder_id": .string(firstID)]
        )
        let exactPreflight = try await query.preflight(exactRequest)
        XCTAssertNil(exactPreflight)
        let exact = try await query.execute(exactRequest)
        XCTAssertTrue(exact.success)
        XCTAssertEqual(exact.output["query_mode"]?.stringValue, "exact_id")
        let exactRows = try XCTUnwrap(exact.output["reminders"]?.arrayValue)
        XCTAssertEqual(exactRows.count, 1)
        let exactRow = try XCTUnwrap(exactRows[0].objectValue)
        XCTAssertEqual(exactRow["reminder_id"]?.stringValue, firstID)
        XCTAssertEqual(exactRow["calendar_id"]?.stringValue, calendarID)
        XCTAssertEqual(exactRow["has_recurrence"]?.boolValue, false)
        let firstRevision = try XCTUnwrap(exactRow["revision"]?.stringValue)
        XCTAssertEqual(firstRevision.count, 64)

        let filteredRequest = dispatch(
            "reminder.query",
            payload: [
                "status": .string("incomplete"),
                "calendar_id": .string(calendarID),
                "title_contains": .string("Query"),
                "max_results": .number(1),
            ]
        )
        let filtered = try await query.execute(filteredRequest)
        XCTAssertTrue(filtered.success)
        XCTAssertEqual(filtered.output["query_mode"]?.stringValue, "filtered")
        XCTAssertEqual(filtered.output["date_semantics"]?.stringValue, "due_date")
        XCTAssertEqual(filtered.output["reminders"]?.arrayValue?.count, 1)
        XCTAssertEqual(filtered.output["truncated"]?.boolValue, true)

        let completion = ReminderSetCompletionExecutor()
        let completeRequest = dispatch(
            "reminder.set_completion",
            payload: [
                "reminder_id": .string(firstID),
                "expected_revision": .string(firstRevision),
                "completed": .bool(true),
            ]
        )
        let completePreflight = try await completion.preflight(completeRequest)
        XCTAssertNil(completePreflight)
        let completed = try await completion.execute(completeRequest)
        XCTAssertTrue(completed.success)
        XCTAssertEqual(completed.output["completed"]?.boolValue, true)
        XCTAssertEqual(completed.output["applied"]?.boolValue, true)

        store.reset()
        let postComplete = try XCTUnwrap(
            store.calendarItem(withIdentifier: firstID) as? EKReminder
        )
        XCTAssertTrue(postComplete.isCompleted)
        let completionDateBeforeReconcile = try XCTUnwrap(postComplete.completionDate)
        let completedSnapshot = try XCTUnwrap(ReminderManagementSnapshot.read(postComplete))

        let noopRequest = dispatch(
            "reminder.set_completion",
            payload: [
                "reminder_id": .string(postComplete.calendarItemIdentifier),
                "expected_revision": .string(completedSnapshot.revision),
                "completed": .bool(true),
            ]
        )
        let noopPreflight = try await completion.preflight(noopRequest)
        XCTAssertNil(noopPreflight)
        let noop = try await completion.execute(noopRequest)
        XCTAssertTrue(noop.success)
        XCTAssertEqual(noop.output["applied"]?.boolValue, false)

        let mayHaveStarted = DeviceActionJournalEntry(
            attemptID: completeRequest.attemptID,
            actionID: completeRequest.actionID,
            idempotencyKey: completeRequest.idempotencyKey,
            dispatchDigest: completeRequest.dispatchDigest,
            state: .mayHaveStarted,
            success: nil,
            result: nil,
            error: nil,
            nativeCorrelationID: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        let reconciled = try await completion.reconcile(
            completeRequest,
            journalEntry: mayHaveStarted
        )
        guard case let .completed(receipt) = reconciled else {
            return XCTFail("desired completion state should reconcile without a second save")
        }
        XCTAssertTrue(receipt.success)
        store.reset()
        let postReconcile = try XCTUnwrap(
            store.calendarItem(withIdentifier: firstID) as? EKReminder
        )
        XCTAssertEqual(postReconcile.completionDate, completionDateBeforeReconcile)

        let uncompleteSnapshot = try XCTUnwrap(ReminderManagementSnapshot.read(postReconcile))
        let uncompleteRequest = dispatch(
            "reminder.set_completion",
            payload: [
                "reminder_id": .string(postReconcile.calendarItemIdentifier),
                "expected_revision": .string(uncompleteSnapshot.revision),
                "completed": .bool(false),
            ]
        )
        let uncompleted = try await completion.execute(uncompleteRequest)
        XCTAssertTrue(uncompleted.success)
        XCTAssertEqual(uncompleted.output["completed"]?.boolValue, false)
        XCTAssertEqual(uncompleted.output["applied"]?.boolValue, true)
        store.reset()
        let postUncomplete = try XCTUnwrap(
            store.calendarItem(withIdentifier: firstID) as? EKReminder
        )
        XCTAssertFalse(postUncomplete.isCompleted)
        XCTAssertNil(postUncomplete.completionDate)

        let oppositeUnknown = try await completion.reconcile(
            completeRequest,
            journalEntry: mayHaveStarted
        )
        guard case .stillUnknown = oppositeUnknown else {
            return XCTFail("opposite state after may-have-started must stay unknown and must not blind-save")
        }
        store.reset()
        XCTAssertFalse(
            try XCTUnwrap(store.calendarItem(withIdentifier: firstID) as? EKReminder).isCompleted
        )

        let freshForStale = try XCTUnwrap(ReminderManagementSnapshot.read(postUncomplete))
        let staleRequest = dispatch(
            "reminder.set_completion",
            payload: [
                "reminder_id": .string(postUncomplete.calendarItemIdentifier),
                "expected_revision": .string(freshForStale.revision),
                "completed": .bool(true),
            ]
        )
        store.reset()
        let externallyChanged = try XCTUnwrap(
            store.calendarItem(withIdentifier: firstID) as? EKReminder
        )
        externallyChanged.title += " changed"
        try store.save(externallyChanged, commit: true)
        let staleFailure = try await completion.preflight(staleRequest)
        XCTAssertEqual(staleFailure?.success, false)
        XCTAssertEqual(staleFailure?.output["error_code"]?.stringValue, "reminder_revision_stale")
        store.reset()
        let staleReadback = try XCTUnwrap(
            store.calendarItem(withIdentifier: firstID) as? EKReminder
        )
        XCTAssertFalse(staleReadback.isCompleted, "stale revision rejection must happen before save")

        store.reset()
        let deletedTarget = try createReminder(
            in: store,
            calendar: try XCTUnwrap(store.calendar(withIdentifier: calendarID)),
            title: "小卷 Reminder Deleted Target",
            due: due.addingTimeInterval(360)
        )
        let deletedSnapshot = try XCTUnwrap(ReminderManagementSnapshot.read(deletedTarget))
        let deletedRequest = dispatch(
            "reminder.set_completion",
            payload: [
                "reminder_id": .string(deletedTarget.calendarItemIdentifier),
                "expected_revision": .string(deletedSnapshot.revision),
                "completed": .bool(true),
            ]
        )
        try store.remove(deletedTarget, commit: true)
        let deletedFailure = try await completion.preflight(deletedRequest)
        XCTAssertEqual(deletedFailure?.success, false)
        XCTAssertEqual(deletedFailure?.output["error_code"]?.stringValue, "reminder_not_found_or_stale")
        let deletedUnknown = try await completion.reconcile(
            deletedRequest,
            journalEntry: DeviceActionJournalEntry(
                attemptID: deletedRequest.attemptID,
                actionID: deletedRequest.actionID,
                idempotencyKey: deletedRequest.idempotencyKey,
                dispatchDigest: deletedRequest.dispatchDigest,
                state: .mayHaveStarted,
                success: nil, result: nil, error: nil, nativeCorrelationID: nil,
                createdAt: Date(), updatedAt: Date()
            )
        )
        guard case .stillUnknown = deletedUnknown else {
            return XCTFail("missing target after may-have-started must remain unknown")
        }

        store.reset()
        let recurringReadback = try XCTUnwrap(
            store.calendarItem(withIdentifier: recurringID) as? EKReminder
        )
        let recurringSnapshot = try XCTUnwrap(ReminderManagementSnapshot.read(recurringReadback))
        let recurringRequest = dispatch(
            "reminder.set_completion",
            payload: [
                "reminder_id": .string(recurringReadback.calendarItemIdentifier),
                "expected_revision": .string(recurringSnapshot.revision),
                "completed": .bool(true),
            ]
        )
        let recurringFailure = try await completion.preflight(recurringRequest)
        XCTAssertEqual(recurringFailure?.success, false)
        XCTAssertEqual(
            recurringFailure?.output["error_code"]?.stringValue,
            "reminder_recurring_mutation_unsupported"
        )
        XCTAssertFalse(recurringReadback.isCompleted)
    }

    func testReminderQueryUpdateNoopStaleTopologyAndReconciliation() async throws {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            throw XCTSkip("Reminder update integration requires the app's existing full Reminder grant.")
        }
        let store = EKEventStore()
        store.reset()
        let calendar = try createOwnedList(in: store)
        let calendarID = calendar.calendarIdentifier
        let calendarTitle = calendar.title
        defer { cleanupOwnedList(calendarID, title: calendarTitle) }

        let due = Date().addingTimeInterval(5_400)
        let reminder = try createReminder(
            in: store, calendar: calendar,
            title: "小卷 Reminder Update 原始标题", due: due
        )
        reminder.notes = "旧备注"
        reminder.priority = 3
        try store.save(reminder, commit: true)
        let reminderID = reminder.calendarItemIdentifier

        let query = ReminderQueryExecutor()
        let exactRequest = dispatch("reminder.query", payload: ["reminder_id": .string(reminderID)])
        let exactPreflightForUpdate = try await query.preflight(exactRequest)
        XCTAssertNil(exactPreflightForUpdate)
        let exact = try await query.execute(exactRequest)
        XCTAssertTrue(exact.success)
        let rows = try XCTUnwrap(exact.output["reminders"]?.arrayValue)
        let row = try XCTUnwrap(rows.first?.objectValue)
        XCTAssertEqual(row["reminder_id"]?.stringValue, reminderID)
        XCTAssertEqual(row["calendar_id"]?.stringValue, calendarID)
        XCTAssertEqual(row["list_id"]?.stringValue, calendarID)
        XCTAssertEqual(row["list_writable"]?.boolValue, true)
        XCTAssertEqual(row["notes"]?.stringValue, "旧备注")
        XCTAssertEqual(jsonNumber(row["priority"]), 3)
        XCTAssertEqual(row["due_mode"]?.stringValue, "timed")
        XCTAssertEqual(row["alarm_mode"]?.stringValue, "at_due")
        XCTAssertEqual(row["update_eligible"]?.boolValue, true)
        let revision = try XCTUnwrap(row["revision"]?.stringValue)
        let zoneID = try XCTUnwrap(row["due_time_zone"]?.stringValue)
        let zone = try XCTUnwrap(TimeZone(identifier: zoneID))

        let desiredDue = due.addingTimeInterval(1_200)
        let updatePayload: [String: JSONValue] = [
            "reminder_id": .string(reminderID),
            "expected_revision": .string(revision),
            "expected_list_id": .string(calendarID),
            "title": .string("小卷 Reminder Update 新标题"),
            "notes": .string("新备注"),
            "priority": .number(7),
            "due_mode": .string("timed"),
            "due_at": .string(iso8601(desiredDue, timeZone: zone)),
            "due_time_zone": .string(zoneID),
            "alarm_mode": .string("at_due"),
        ]
        let updateRequest = dispatch("reminder.update", payload: updatePayload)
        let executor = ReminderUpdateExecutor()
        let updatePreflight = try await executor.preflight(updateRequest)
        XCTAssertNil(updatePreflight)
        let updated = try await executor.execute(updateRequest)
        XCTAssertTrue(updated.success)
        XCTAssertEqual(updated.output["requested_reminder_id"]?.stringValue, reminderID)
        XCTAssertEqual(updated.output["title"]?.stringValue, "小卷 Reminder Update 新标题")
        XCTAssertEqual(updated.output["notes"]?.stringValue, "新备注")
        XCTAssertEqual(jsonNumber(updated.output["priority"]), 7)
        XCTAssertEqual(updated.output["completion_preserved"]?.boolValue, true)
        XCTAssertEqual(updated.output["completed"]?.boolValue, false)
        XCTAssertEqual(updated.output["applied"]?.boolValue, true)

        store.reset()
        let native = try XCTUnwrap(store.calendarItem(withIdentifier: reminderID) as? EKReminder)
        XCTAssertEqual(native.title, "小卷 Reminder Update 新标题")
        XCTAssertEqual(native.notes, "新备注")
        XCTAssertEqual(native.priority, 7)
        XCTAssertFalse(native.isCompleted)
        XCTAssertLessThan(abs(try XCTUnwrap(native.dueDateComponents?.date).timeIntervalSince(desiredDue)), 1.0)
        XCTAssertLessThan(abs(try XCTUnwrap(native.startDateComponents?.date).timeIntervalSince(desiredDue)), 1.0)
        XCTAssertEqual(native.alarms?.count, 1)
        XCTAssertLessThan(abs(try XCTUnwrap(native.alarms?.first?.absoluteDate).timeIntervalSince(desiredDue)), 1.0)
        let modifiedBeforeNoop = native.lastModifiedDate

        let freshRevision = try XCTUnwrap(updated.output["revision"]?.stringValue)
        var noopPayload = updatePayload
        noopPayload["expected_revision"] = .string(freshRevision)
        let noopRequest = dispatch("reminder.update", payload: noopPayload)
        let noopPreflight = try await executor.preflight(noopRequest)
        XCTAssertNil(noopPreflight)
        let noop = try await executor.execute(noopRequest)
        XCTAssertTrue(noop.success)
        XCTAssertEqual(noop.output["applied"]?.boolValue, false)
        store.reset()
        XCTAssertEqual(
            (store.calendarItem(withIdentifier: reminderID) as? EKReminder)?.lastModifiedDate,
            modifiedBeforeNoop
        )

        let reconciled = try await executor.reconcile(
            updateRequest,
            journalEntry: DeviceActionJournalEntry(
                attemptID: updateRequest.attemptID, actionID: updateRequest.actionID,
                idempotencyKey: updateRequest.idempotencyKey, dispatchDigest: updateRequest.dispatchDigest,
                state: .mayHaveStarted, success: nil, result: nil, error: nil, nativeCorrelationID: nil,
                createdAt: Date(), updatedAt: Date()
            )
        )
        guard case let .completed(receipt) = reconciled else {
            return XCTFail("reminder desired state should reconcile read-only")
        }
        XCTAssertTrue(receipt.success)
        XCTAssertEqual(receipt.output["applied"], nil)

        store.reset()
        let staleNative = try XCTUnwrap(store.calendarItem(withIdentifier: reminderID) as? EKReminder)
        let staleSnapshot = try XCTUnwrap(ReminderManagementSnapshot.read(staleNative))
        var stalePayload = noopPayload
        stalePayload["expected_revision"] = .string(staleSnapshot.revision)
        stalePayload["title"] = .string("不应覆盖外部修改")
        let staleRequest = dispatch("reminder.update", payload: stalePayload)
        staleNative.notes = "外部修改"
        try store.save(staleNative, commit: true)
        let staleFailure = try await executor.preflight(staleRequest)
        XCTAssertEqual(staleFailure?.success, false)
        XCTAssertEqual(staleFailure?.output["error_code"]?.stringValue, "reminder_revision_stale")
        store.reset()
        XCTAssertEqual(
            (store.calendarItem(withIdentifier: reminderID) as? EKReminder)?.notes,
            "外部修改"
        )

        let unsupported = try createReminder(
            in: store,
            calendar: try XCTUnwrap(store.calendar(withIdentifier: calendarID)),
            title: "小卷 Reminder Update 复杂闹铃",
            due: desiredDue.addingTimeInterval(3_600)
        )
        unsupported.addAlarm(EKAlarm(absoluteDate: desiredDue.addingTimeInterval(3_660)))
        try store.save(unsupported, commit: true)
        let unsupportedSnapshot = try XCTUnwrap(ReminderManagementSnapshot.read(unsupported))
        XCTAssertFalse(unsupportedSnapshot.updateEligible)
        var unsupportedPayload = updatePayload
        unsupportedPayload["reminder_id"] = .string(unsupported.calendarItemIdentifier)
        unsupportedPayload["expected_revision"] = .string(unsupportedSnapshot.revision)
        unsupportedPayload["expected_list_id"] = .string(calendarID)
        let unsupportedFailure = try await executor.preflight(
            dispatch("reminder.update", payload: unsupportedPayload)
        )
        XCTAssertEqual(unsupportedFailure?.success, false)
        XCTAssertEqual(unsupportedFailure?.output["error_code"]?.stringValue, "reminder_update_unsupported_topology")

        var invalidPayload = updatePayload
        invalidPayload["completed"] = .bool(true)
        let invalid = try await executor.preflight(dispatch("reminder.update", payload: invalidPayload))
        XCTAssertEqual(invalid?.success, false)
        XCTAssertEqual(invalid?.output["error_code"]?.stringValue, "reminder_update_invalid")
    }

    func testReminderRemoveExactOwnedTargetAndAmbiguousRecovery() async throws {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            throw XCTSkip("Reminder remove integration requires the app's existing full Reminder grant.")
        }
        let store = EKEventStore()
        store.reset()
        let calendar = try createOwnedList(in: store)
        let calendarID = calendar.calendarIdentifier
        let calendarTitle = calendar.title
        defer { cleanupOwnedList(calendarID, title: calendarTitle) }

        let due = Date().addingTimeInterval(3_600)
        let reminder = try createReminder(
            in: store, calendar: calendar, title: "小卷 Reminder Remove", due: due
        )
        let reminderID = reminder.calendarItemIdentifier
        let snapshot = try XCTUnwrap(ReminderManagementSnapshot.read(reminder))
        XCTAssertEqual(snapshot.deviceObject()["remove_eligible"]?.boolValue, true)
        let payload: [String: JSONValue] = [
            "reminder_id": .string(reminderID),
            "expected_revision": .string(snapshot.revision),
            "expected_list_id": .string(calendarID),
            "expected_title": .string("小卷 Reminder Remove"),
        ]
        let request = dispatch("reminder.remove", payload: payload)
        let executor = ReminderRemoveExecutor()
        let removePreflight = try await executor.preflight(request)
        XCTAssertNil(removePreflight)
        let removed = try await executor.execute(request)
        XCTAssertTrue(removed.success)
        XCTAssertEqual(removed.output["deleted"]?.boolValue, true)
        XCTAssertEqual(removed.output["verified"]?.boolValue, true)
        XCTAssertEqual(removed.output["verification"]?.stringValue, "immediate_exact_id_absence")
        store.reset()
        XCTAssertNil(store.calendarItem(withIdentifier: reminderID))

        let entry = DeviceActionJournalEntry(
            attemptID: request.attemptID, actionID: request.actionID,
            idempotencyKey: request.idempotencyKey, dispatchDigest: request.dispatchDigest,
            state: .mayHaveStarted, success: nil, result: nil, error: nil, nativeCorrelationID: nil,
            createdAt: Date(), updatedAt: Date()
        )
        let recovery = try await executor.reconcile(request, journalEntry: entry)
        guard case .stillUnknown = recovery else {
            return XCTFail("post-crash Reminder exact-ID absence must remain unknown")
        }
        store.reset()
        XCTAssertNil(store.calendarItem(withIdentifier: reminderID), "reconciliation must not repeat the remove")

        let stale = try createReminder(
            in: store,
            calendar: try XCTUnwrap(store.calendar(withIdentifier: calendarID)),
            title: "小卷 Reminder Remove Stale",
            due: due.addingTimeInterval(7_200)
        )
        let staleSnapshot = try XCTUnwrap(ReminderManagementSnapshot.read(stale))
        let stalePayload: [String: JSONValue] = [
            "reminder_id": .string(stale.calendarItemIdentifier),
            "expected_revision": .string(staleSnapshot.revision),
            "expected_list_id": .string(calendarID),
            "expected_title": .string(stale.title),
        ]
        stale.notes = "外部修改"
        try store.save(stale, commit: true)
        let staleFailure = try await executor.preflight(dispatch("reminder.remove", payload: stalePayload))
        XCTAssertEqual(staleFailure?.output["error_code"]?.stringValue, "reminder_revision_stale")
        store.reset()
        XCTAssertNotNil(store.calendarItem(withIdentifier: stale.calendarItemIdentifier), "stale preflight must not delete")

        let recurring = try createReminder(
            in: store,
            calendar: try XCTUnwrap(store.calendar(withIdentifier: calendarID)),
            title: "小卷 Reminder Remove Recurring",
            due: due.addingTimeInterval(14_400),
            recurring: true
        )
        let recurringSnapshot = try XCTUnwrap(ReminderManagementSnapshot.read(recurring))
        XCTAssertEqual(recurringSnapshot.deviceObject()["remove_eligible"]?.boolValue, false)
        let recurringPayload: [String: JSONValue] = [
            "reminder_id": .string(recurring.calendarItemIdentifier),
            "expected_revision": .string(recurringSnapshot.revision),
            "expected_list_id": .string(calendarID),
            "expected_title": .string(recurring.title),
        ]
        let recurringFailure = try await executor.preflight(dispatch("reminder.remove", payload: recurringPayload))
        XCTAssertEqual(recurringFailure?.output["error_code"]?.stringValue, "reminder_recurring_mutation_unsupported")
    }

}

final class LocationCurrentVerifierTests: XCTestCase {
    func testAcceptsFreshBoundedSample() {
        let receivedAt = Date()
        let sample = LocationCurrentSample(
            latitude: 35.0,
            longitude: 139.0,
            horizontalAccuracy: 25,
            timestamp: receivedAt.addingTimeInterval(-2)
        )
        guard case let .accepted(ageMilliseconds) = LocationCurrentVerifier.verify(
            sample,
            receivedAt: receivedAt
        ) else {
            return XCTFail("fresh sample should be accepted")
        }
        XCTAssertGreaterThanOrEqual(ageMilliseconds, 1_900)
        XCTAssertLessThanOrEqual(ageMilliseconds, 2_100)
    }

    func testRejectsStaleOrUnusableAccuracy() {
        let receivedAt = Date()
        let stale = LocationCurrentSample(
            latitude: 35.0,
            longitude: 139.0,
            horizontalAccuracy: 20,
            timestamp: receivedAt.addingTimeInterval(-61)
        )
        guard case .temporarilyUnavailable = LocationCurrentVerifier.verify(
            stale,
            receivedAt: receivedAt
        ) else {
            return XCTFail("stale location must not be accepted")
        }

        let inaccurate = LocationCurrentSample(
            latitude: 35.0,
            longitude: 139.0,
            horizontalAccuracy: 10_001,
            timestamp: receivedAt
        )
        guard case .temporarilyUnavailable = LocationCurrentVerifier.verify(
            inaccurate,
            receivedAt: receivedAt
        ) else {
            return XCTFail("abnormal horizontal accuracy must not be accepted")
        }
    }

    func testFutureTimestampStaysUnknown() {
        let receivedAt = Date()
        let future = LocationCurrentSample(
            latitude: 35.0,
            longitude: 139.0,
            horizontalAccuracy: 20,
            timestamp: receivedAt.addingTimeInterval(6)
        )
        guard case .unknown = LocationCurrentVerifier.verify(future, receivedAt: receivedAt) else {
            return XCTFail("future timestamp outside tolerance must stay unknown")
        }
    }

    func testBackgroundLocationAllowsAlwaysAuthorization() {
        let failure = LocationCurrentEnvironmentPolicy.failure(
            isForeground: false,
            servicesEnabled: true,
            authorization: .always
        )
        XCTAssertNil(failure)
    }

    func testForegroundLocationStillAllowsWhenInUseAuthorization() {
        let failure = LocationCurrentEnvironmentPolicy.failure(
            isForeground: true,
            servicesEnabled: true,
            authorization: .whenInUse
        )
        XCTAssertNil(failure)
    }

    func testBackgroundLocationRequiresBackgroundAuthorizationWhenOnlyWhenInUse() {
        let failure = LocationCurrentEnvironmentPolicy.failure(
            isForeground: false,
            servicesEnabled: true,
            authorization: .whenInUse
        )
        XCTAssertEqual(failure?.status, "PERMISSION_REQUIRED")
        XCTAssertEqual(failure?.reasonCode, "location_background_authorization_required")
        XCTAssertEqual(failure?.userAction, "request_always_authorization_in_foreground")
    }

    func testLocationServicesDisabledStillFailsWithAlwaysAuthorization() {
        let failure = LocationCurrentEnvironmentPolicy.failure(
            isForeground: false,
            servicesEnabled: false,
            authorization: .always
        )
        XCTAssertEqual(failure?.status, "SERVICES_DISABLED")
    }
}
