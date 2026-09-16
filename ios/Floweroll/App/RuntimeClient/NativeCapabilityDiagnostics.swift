import AlarmKit
import EventKit
import Foundation
import Observation


@MainActor
@Observable
final class NativeCapabilityDiagnostics {
    private(set) var isRunningReminderTest = false
    private(set) var reminderTestMessage: String?
    private(set) var isRunningAlarmTest = false
    private(set) var alarmTestMessage: String?
    private(set) var isRunningCalendarTest = false
    private(set) var calendarTestMessage: String?

    func runReminderSmokeTest() async {
        guard !isRunningReminderTest else { return }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            reminderTestMessage = "请先允许提醒事项完整访问。"
            return
        }

        isRunningReminderTest = true
        defer { isRunningReminderTest = false }

        do {
            let now = Date()
            let dueDate = now.addingTimeInterval(120)
            let stamp = String(Int(now.timeIntervalSince1970))
            let idempotencyKey = "native-reminder-smoke-v1-\(stamp)"
            let dispatch = DeviceActionDispatch(
                actionID: "native-reminder-smoke-action-\(stamp)",
                taskID: "native-reminder-smoke-task-\(stamp)",
                actionType: "reminder.create",
                payload: [
                    "title": .string("小卷真机测试提醒 \(stamp.suffix(4))"),
                    "due_at": .string(Self.iso8601(dueDate)),
                ],
                status: "dispatched",
                runtimeActionStatus: "executing",
                idempotencyKey: idempotencyKey,
                attemptID: "native-reminder-smoke-attempt-\(stamp)",
                attemptNumber: 1,
                attemptStatus: "IN_FLIGHT",
                dispatchDigest: "native-diagnostic-\(stamp)"
            )

            let journal = try DeviceActionJournal(directoryURL: try Self.diagnosticsDirectory())
            let executor = ReminderCreateExecutor()
            let decision = try await journal.prepare(dispatch)
            guard case .execute = decision else {
                reminderTestMessage = "测试 Journal 已有同一 Attempt，未重复执行。"
                return
            }
            if let failure = try await executor.preflight(dispatch) {
                _ = try await journal.recordPreflightFailure(
                    attemptID: dispatch.attemptID,
                    error: failure.error ?? "preflight failed",
                    result: failure.output
                )
                reminderTestMessage = "提醒事项 preflight 失败：\(failure.error ?? "未知原因")"
                return
            }

            _ = try await journal.markMayHaveStarted(attemptID: dispatch.attemptID)
            let first = try await executor.execute(dispatch)
            guard first.success else {
                _ = try await journal.recordResult(
                    attemptID: dispatch.attemptID,
                    success: false,
                    result: first.output,
                    error: first.error,
                    nativeCorrelationID: first.nativeCorrelationID
                )
                reminderTestMessage = "提醒事项创建失败：\(first.error ?? "未知原因")"
                return
            }
            _ = try await journal.recordResult(
                attemptID: dispatch.attemptID,
                success: true,
                result: first.output,
                nativeCorrelationID: first.nativeCorrelationID
            )

            // Journal must now refuse a second native execution of this Attempt.
            let replay = try await journal.prepare(dispatch)
            guard case .replayResult = replay else {
                reminderTestMessage = "失败：DeviceActionJournal 未阻止重复执行。"
                return
            }

            // Independently exercise the EventKit idempotency marker/read-back.
            // Calling the executor with the exact same dispatch must return the
            // existing Reminder instead of creating a second native object.
            let second = try await executor.execute(dispatch)
            guard
                second.success,
                let firstID = first.nativeCorrelationID,
                firstID == second.nativeCorrelationID
            else {
                reminderTestMessage = "失败：EventKit read-back/idempotency 校验不一致。"
                return
            }

            let timeText = DateFormatter.localizedString(
                from: dueDate,
                dateStyle: .none,
                timeStyle: .short
            )
            reminderTestMessage = "通过：已创建 \(timeText) 测试提醒；read-back ID 一致，重复调用未新建第二条。"
        } catch {
            reminderTestMessage = "真机提醒测试失败：\(String(describing: error))"
        }
    }

    func runAlarmSmokeTest() async {
        guard !isRunningAlarmTest else { return }
        guard AlarmManager.shared.authorizationState == .authorized else {
            alarmTestMessage = "请先允许闹钟访问。"
            return
        }

        isRunningAlarmTest = true
        defer { isRunningAlarmTest = false }

        do {
            let now = Date()
            let fireDate = now.addingTimeInterval(90)
            let stamp = String(Int(now.timeIntervalSince1970))
            let dispatch = DeviceActionDispatch(
                actionID: "native-alarm-smoke-action-\(stamp)",
                taskID: "native-alarm-smoke-task-\(stamp)",
                actionType: "alarm.create",
                payload: [
                    "title": .string("小卷真机测试闹钟"),
                    "fire_at": .string(Self.iso8601(fireDate)),
                ],
                status: "dispatched",
                runtimeActionStatus: "executing",
                idempotencyKey: "native-alarm-smoke-v1-\(stamp)",
                attemptID: "native-alarm-smoke-attempt-\(stamp)",
                attemptNumber: 1,
                attemptStatus: "IN_FLIGHT",
                dispatchDigest: "native-alarm-diagnostic-\(stamp)"
            )

            let journal = try DeviceActionJournal(directoryURL: try Self.diagnosticsDirectory())
            let executor = AlarmCreateExecutor()
            let decision = try await journal.prepare(dispatch)
            guard case .execute = decision else {
                alarmTestMessage = "测试 Journal 已有同一 Attempt，未重复执行。"
                return
            }
            if let failure = try await executor.preflight(dispatch) {
                _ = try await journal.recordPreflightFailure(
                    attemptID: dispatch.attemptID,
                    error: failure.error ?? "preflight failed",
                    result: failure.output
                )
                alarmTestMessage = "闹钟 preflight 失败：\(failure.error ?? "未知原因")"
                return
            }

            _ = try await journal.markMayHaveStarted(attemptID: dispatch.attemptID)
            let first = try await executor.execute(dispatch)
            guard first.success else {
                _ = try await journal.recordResult(
                    attemptID: dispatch.attemptID,
                    success: false,
                    result: first.output,
                    error: first.error,
                    nativeCorrelationID: first.nativeCorrelationID
                )
                alarmTestMessage = "闹钟创建失败：\(first.error ?? "未知原因")"
                return
            }
            _ = try await journal.recordResult(
                attemptID: dispatch.attemptID,
                success: true,
                result: first.output,
                nativeCorrelationID: first.nativeCorrelationID
            )

            let replay = try await journal.prepare(dispatch)
            guard case .replayResult = replay else {
                alarmTestMessage = "失败：DeviceActionJournal 未阻止重复执行。"
                return
            }

            let second = try await executor.execute(dispatch)
            guard
                second.success,
                let firstID = first.nativeCorrelationID,
                firstID == second.nativeCorrelationID
            else {
                alarmTestMessage = "失败：AlarmKit read-back/idempotency 校验不一致。"
                return
            }

            let timeText = DateFormatter.localizedString(
                from: fireDate,
                dateStyle: .none,
                timeStyle: .medium
            )
            alarmTestMessage = "通过：已创建 \(timeText) 测试闹钟；Alarm ID 一致，重复调用未新建第二个。请等待约 90 秒确认系统闹钟实际响起。"
        } catch {
            alarmTestMessage = "真机闹钟测试失败：\(String(describing: error))"
        }
    }

    func runCalendarFreeBusySmokeTest() async {
        guard !isRunningCalendarTest else { return }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            calendarTestMessage = "请先允许日历完整访问。"
            return
        }

        isRunningCalendarTest = true
        defer { isRunningCalendarTest = false }

        do {
            let calendar = Calendar.autoupdatingCurrent
            let startOfToday = calendar.startOfDay(for: Date())
            guard
                let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
                let start = calendar.date(bySettingHour: 13, minute: 0, second: 0, of: tomorrow),
                let end = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: tomorrow)
            else {
                calendarTestMessage = "无法计算明天下午测试时间窗口。"
                return
            }
            let stamp = String(Int(Date().timeIntervalSince1970))
            let dispatch = DeviceActionDispatch(
                actionID: "native-calendar-smoke-action-\(stamp)",
                taskID: "native-calendar-smoke-task-\(stamp)",
                actionType: "calendar.freebusy",
                payload: [
                    "start_at": .string(Self.iso8601(start)),
                    "end_at": .string(Self.iso8601(end)),
                ],
                status: "dispatched",
                runtimeActionStatus: "executing",
                idempotencyKey: "native-calendar-smoke-v1-\(stamp)",
                attemptID: "native-calendar-smoke-attempt-\(stamp)",
                attemptNumber: 1,
                attemptStatus: "IN_FLIGHT",
                dispatchDigest: "native-calendar-diagnostic-\(stamp)"
            )
            let journal = try DeviceActionJournal(directoryURL: try Self.diagnosticsDirectory())
            let executor = CalendarFreeBusyExecutor()
            let decision = try await journal.prepare(dispatch)
            guard case .execute = decision else {
                calendarTestMessage = "测试 Journal 已存在同一日历读取 Attempt。"
                return
            }
            if let failure = try await executor.preflight(dispatch) {
                _ = try await journal.recordPreflightFailure(
                    attemptID: dispatch.attemptID,
                    error: failure.error ?? "preflight failed",
                    result: failure.output
                )
                calendarTestMessage = "日历 preflight 失败：\(failure.error ?? "未知原因")"
                return
            }
            _ = try await journal.markMayHaveStarted(attemptID: dispatch.attemptID)
            let result = try await executor.execute(dispatch)
            _ = try await journal.recordResult(
                attemptID: dispatch.attemptID,
                success: result.success,
                result: result.output,
                error: result.error,
                nativeCorrelationID: result.nativeCorrelationID
            )
            guard result.success else {
                calendarTestMessage = "日历读取失败：\(result.error ?? "未知原因")"
                return
            }
            let free: Bool
            if case let .bool(value)? = result.output["is_free"] { free = value } else { free = false }
            let intervalCount: Int
            if case let .array(values)? = result.output["busy_intervals"] { intervalCount = values.count } else { intervalCount = 0 }
            calendarTestMessage = free
                ? "通过：明天 13:00–18:00 当前没有忙碌区间。"
                : "通过：明天 13:00–18:00 检测到 \(intervalCount) 个合并后的忙碌区间；没有读取标题到诊断结果。"
        } catch {
            calendarTestMessage = "真机日历测试失败：\(String(describing: error))"
        }
    }

    private static func diagnosticsDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("Floweroll", isDirectory: true)
            .appendingPathComponent("NativeCapabilityDiagnostics", isDirectory: true)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
