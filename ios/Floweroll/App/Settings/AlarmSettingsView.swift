import AVFAudio
import AVFoundation
import ContactsUI
import SwiftUI
import UserNotifications


// MARK: - Settings and preserved developer console

enum FlowerollAlarmPresentationCopy {
    static let settingsDescription = "在这里查看和管理由小卷创建的闹钟，包括时间、重复日期、声音和当前状态。"
    static let managementDescription = "在这里查看、修改、暂停、继续或取消由小卷创建的闹钟。"
    static let emptyDescription = "通过小卷创建的闹钟会显示在这里。"
    static let missingDescription = "系统里已经找不到这个闹钟。它可能已经响过、被取消或在其他地方被删除。当前不能继续修改，可以删除这条记录。"

    static let userFacingStrings = [
        settingsDescription,
        managementDescription,
        emptyDescription,
        missingDescription,
    ]
}

enum FlowerollAlarmCancelPresentationPolicy {
    static func shouldDismiss(
        cancelRequested: Bool,
        alarmID: UUID,
        visibleAlarmIDs: [UUID]
    ) -> Bool {
        cancelRequested && !visibleAlarmIDs.contains(alarmID)
    }
}


struct FlowerollAlarmMutationPresentation: Equatable {
    enum Kind: Equatable {
        case pending
        case ambiguous
        case definitelyNotStarted
    }

    let kind: Kind
    let title: String
    let detail: String

    static func resolve(
        pendingState: AlarmSettingsMutationIntentState?,
        lastResolution: AlarmSettingsMutationResolution?,
        localRequestInFlight: Bool = false
    ) -> Self? {
        if pendingState == .ambiguous {
            return Self(
                kind: .ambiguous,
                title: "修改结果暂时无法确认",
                detail: "系统状态暂时没有给出唯一结论。请刷新状态或稍后再确认；闹钟会保留在这里。"
            )
        }
        if pendingState == .pending || localRequestInFlight {
            return Self(
                kind: .pending,
                title: "正在确认修改结果",
                detail: "小卷正在核对系统中的实际状态，请不要重复操作。"
            )
        }
        if lastResolution == .definitelyNotStarted {
            return Self(
                kind: .definitelyNotStarted,
                title: "上次操作没有确认完成",
                detail: "闹钟仍保留，可以刷新状态后重试。"
            )
        }
        return nil
    }

    static func resolve(
        alarm: FlowerollAlarmRecord,
        localRequestInFlight: Bool = false
    ) -> Self? {
        resolve(
            pendingState: alarm.mutationStatus?.state,
            lastResolution: alarm.lastMutationOutcome?.resolution,
            localRequestInFlight: localRequestInFlight
        )
    }
}

struct FlowerollAlarmManagementView: View {
    @State private var model = AlarmManagementModel()

    var body: some View {
        List {
            Section {
                Text(FlowerollAlarmPresentationCopy.managementDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if model.isLoading && model.alarms.isEmpty {
                HStack { Spacer(); ProgressView("正在读取小卷闹钟…"); Spacer() }
            } else if model.alarms.isEmpty {
                ContentUnavailableView(
                    "没有小卷闹钟",
                    systemImage: "alarm",
                    description: Text(FlowerollAlarmPresentationCopy.emptyDescription)
                )
            } else {
                Section("小卷闹钟") {
                    ForEach(model.alarms) { alarm in
                        NavigationLink {
                            FlowerollAlarmDetailView(alarmID: alarm.id, model: model)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(alarm.title)
                                        .font(.body.weight(.semibold))
                                        .lineLimit(2)
                                    Spacer(minLength: 8)
                                    Text(FlowerollAlarmMutationPresentation.resolve(alarm: alarm)?.title ?? alarm.stateLabel)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(
                                            FlowerollAlarmMutationPresentation.resolve(alarm: alarm) == nil && alarm.state != .alerting
                                                ? Color.secondary
                                                : Color.orange
                                        )
                                }
                                HStack(spacing: 7) {
                                    Text(Self.scheduleText(alarm.schedule))
                                    Text("·")
                                    Text(Self.soundText(alarm.sound))
                                }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .accessibilityIdentifier("settings.alarm.row.\(alarm.id.uuidString)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if alarm.canDeleteFromManagement {
                                Button("删除", role: .destructive) {
                                    model.deleteFromManagement(alarm)
                                }
                                .accessibilityIdentifier("settings.alarm.delete.\(alarm.id.uuidString)")
                            }
                        }
                    }
                }
            }

            if let error = model.errorMessage {
                Section("状态") {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("小卷闹钟")
        .refreshable { model.refresh() }
        .task { model.refresh() }
    }

    static func scheduleText(_ schedule: AlarmDesiredSchedule) -> String {
        switch schedule.kind {
        case .fixed:
            return schedule.fireDate?.formatted(date: .abbreviated, time: .shortened) ?? "一次性闹钟"
        case .weekly:
            let days = (schedule.weekdays ?? []).map(weekdayText).joined(separator: "、")
            return String(format: "%02d:%02d · %@", schedule.hour ?? 0, schedule.minute ?? 0, days)
        }
    }

    static func weekdayText(_ day: AlarmWeekday) -> String {
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

    static func soundText(_ sound: AlarmSoundChoice) -> String {
        switch sound {
        case .defaultSound: return "系统默认声音"
        }
    }
}


private struct FlowerollAlarmDetailView: View {
    let alarmID: UUID
    let model: AlarmManagementModel

    @Environment(\.dismiss) private var dismiss
    @AppStorage("floweroll.developerMode") private var developerMode = false
    @State private var title: String
    @State private var scheduleKind: AlarmScheduleKind
    @State private var fixedDate: Date
    @State private var weeklyTime: Date
    @State private var weekdays: Set<AlarmWeekday>
    @State private var sound: AlarmSoundChoice
    @State private var showCancelConfirmation = false
    @State private var requestedMutation: AlarmSettingsMutationOperation?
    @State private var cancelAwaitingConfirmedRemoval = false

    init(alarmID: UUID, model: AlarmManagementModel) {
        self.alarmID = alarmID
        self.model = model
        let alarm = model.alarms.first(where: { $0.id == alarmID })
        let schedule = alarm?.schedule ?? .fixed(Date().addingTimeInterval(3600))
        _title = State(initialValue: alarm?.title ?? "小卷闹钟")
        _scheduleKind = State(initialValue: schedule.kind)
        _fixedDate = State(initialValue: schedule.fireDate ?? Date().addingTimeInterval(3600))
        let calendar = Calendar.current
        let time = calendar.date(
            bySettingHour: schedule.hour ?? calendar.component(.hour, from: Date()),
            minute: schedule.minute ?? calendar.component(.minute, from: Date()),
            second: 0,
            of: Date()
        ) ?? Date()
        _weeklyTime = State(initialValue: time)
        _weekdays = State(initialValue: Set(schedule.weekdays ?? [.monday, .tuesday, .wednesday, .thursday, .friday]))
        _sound = State(initialValue: alarm?.sound ?? .defaultSound)
    }

    private var alarm: FlowerollAlarmRecord? {
        model.alarms.first(where: { $0.id == alarmID })
    }

    private var mutationPresentation: FlowerollAlarmMutationPresentation? {
        guard let alarm else { return nil }
        return FlowerollAlarmMutationPresentation.resolve(
            alarm: alarm,
            localRequestInFlight: requestedMutation != nil && model.isLoading
        )
    }

    var body: some View {
        Form {
            if let alarm {
                Section("状态") {
                    LabeledContent(
                        "当前状态",
                        value: mutationPresentation?.title ?? alarm.stateLabel
                    )
                    if let mutationPresentation {
                        Label(
                            mutationPresentation.detail,
                            systemImage: mutationPresentation.kind == .pending
                                ? "arrow.trianglehead.2.clockwise.rotate.90"
                                : "exclamationmark.triangle"
                        )
                        .font(.footnote)
                        .foregroundStyle(mutationPresentation.kind == .pending ? Color.secondary : Color.orange)
                        .accessibilityIdentifier("settings.alarm.mutation-status")

                        if mutationPresentation.kind != .pending {
                            Button("刷新状态") { model.refresh() }
                                .disabled(model.isLoading)
                                .accessibilityIdentifier("settings.alarm.mutation-refresh")
                        }
                    }
                    if !alarm.nativePresent {
                        Label(FlowerollAlarmPresentationCopy.missingDescription, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings.alarm.missing-description")
                    }
                }

                if developerMode {
                    Section("开发者信息") {
                        LabeledContent("Alarm ID", value: alarm.id.uuidString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                if alarm.nativePresent {
                    Section("闹钟") {
                        TextField("标题", text: $title)
                            .textInputAutocapitalization(.never)
                        Picker("类型", selection: $scheduleKind) {
                            Text("一次").tag(AlarmScheduleKind.fixed)
                            Text("每周重复").tag(AlarmScheduleKind.weekly)
                        }
                        if scheduleKind == .fixed {
                            DatePicker("响铃时间", selection: $fixedDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        } else {
                            DatePicker("时间", selection: $weeklyTime, displayedComponents: [.hourAndMinute])
                            VStack(alignment: .leading, spacing: 10) {
                                Text("重复星期")
                                    .font(.subheadline.weight(.semibold))
                                ViewThatFits(in: .horizontal) {
                                    weekdayButtons(horizontal: true)
                                    weekdayButtons(horizontal: false)
                                }
                            }
                        }
                        Picker("声音", selection: $sound) {
                            ForEach(AlarmSoundChoice.allCases, id: \.self) { choice in
                                Text(FlowerollAlarmManagementView.soundText(choice)).tag(choice)
                            }
                        }
                    }

                    Section {
                        Button("保存修改") {
                            requestedMutation = .update
                            save(alarm)
                        }
                            .disabled(!canSave(alarm) || model.isLoading)
                            .accessibilityIdentifier("settings.alarm.save")

                        if alarm.canPause {
                            Button("暂停闹钟") {
                                requestedMutation = .pause
                                model.pause(alarm)
                            }
                                .disabled(model.isLoading)
                                .accessibilityIdentifier("settings.alarm.pause")
                        }
                        if alarm.canResume {
                            Button("恢复闹钟") {
                                requestedMutation = .resume
                                model.resume(alarm)
                            }
                                .disabled(model.isLoading)
                                .accessibilityIdentifier("settings.alarm.resume")
                        }
                        if alarm.canCancel {
                            Button("取消这个闹钟", role: .destructive) { showCancelConfirmation = true }
                                .disabled(model.isLoading)
                                .accessibilityIdentifier("settings.alarm.cancel")
                        }
                    }
                } else {
                    Section {
                        LabeledContent("原记录", value: alarm.title)
                        LabeledContent("原计划", value: FlowerollAlarmManagementView.scheduleText(alarm.schedule))
                        if alarm.canDeleteFromManagement {
                            Button("删除这条记录", role: .destructive) {
                                cancelAwaitingConfirmedRemoval = true
                                requestedMutation = .cancel
                                model.deleteFromManagement(alarm)
                            }
                            .disabled(model.isLoading)
                            .accessibilityIdentifier("settings.alarm.delete-missing")
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "闹钟已不存在",
                    systemImage: "alarm",
                    description: Text(FlowerollAlarmPresentationCopy.missingDescription)
                )
            }

            if let error = model.errorMessage {
                Section { Text(error).font(.footnote).foregroundStyle(.orange) }
            }
        }
        .navigationTitle("闹钟详情")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("取消这个小卷闹钟？", isPresented: $showCancelConfirmation, titleVisibility: .visible) {
            if let alarm {
                Button("取消闹钟", role: .destructive) {
                    cancelAwaitingConfirmedRemoval = true
                    requestedMutation = .cancel
                    model.cancel(alarm)
                }
            }
        }
        .onChange(of: model.isLoading) { wasLoading, isLoading in
            if wasLoading && !isLoading {
                requestedMutation = nil
            }
        }
        .onChange(of: model.alarms.map(\.id)) { _, alarmIDs in
            guard FlowerollAlarmCancelPresentationPolicy.shouldDismiss(
                cancelRequested: cancelAwaitingConfirmedRemoval,
                alarmID: alarmID,
                visibleAlarmIDs: alarmIDs
            ) else { return }
            cancelAwaitingConfirmedRemoval = false
            requestedMutation = nil
            dismiss()
        }
    }

    @ViewBuilder
    private func weekdayButtons(horizontal: Bool) -> some View {
        let content = ForEach(AlarmWeekday.allCases, id: \.self) { day in
            Button {
                if weekdays.contains(day) {
                    if weekdays.count > 1 { weekdays.remove(day) }
                } else {
                    weekdays.insert(day)
                }
            } label: {
                Text(shortWeekday(day))
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 30, minHeight: 30)
                    .foregroundStyle(weekdays.contains(day) ? Color.white : Color.primary)
                    .background(weekdays.contains(day) ? Color.accentColor : Color.secondary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(weekdays.contains(day) ? "已选择" : "未选择")
        }
        if horizontal { HStack(spacing: 7) { content } }
        else { LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) { content } }
    }

    private func canSave(_ alarm: FlowerollAlarmRecord) -> Bool {
        alarm.canEdit
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (scheduleKind != .weekly || !weekdays.isEmpty)
    }

    private func save(_ alarm: FlowerollAlarmRecord) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let schedule: AlarmDesiredSchedule
        switch scheduleKind {
        case .fixed:
            schedule = .fixed(fixedDate)
        case .weekly:
            let components = Calendar.current.dateComponents([.hour, .minute], from: weeklyTime)
            schedule = .weekly(hour: components.hour ?? 0, minute: components.minute ?? 0, weekdays: Array(weekdays))
        }
        model.update(alarm, title: cleanTitle, schedule: schedule, sound: sound)
    }

    private func shortWeekday(_ day: AlarmWeekday) -> String {
        switch day {
        case .monday: return "一"
        case .tuesday: return "二"
        case .wednesday: return "三"
        case .thursday: return "四"
        case .friday: return "五"
        case .saturday: return "六"
        case .sunday: return "日"
        }
    }
}
