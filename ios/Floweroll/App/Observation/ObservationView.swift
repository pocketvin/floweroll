import SwiftUI

@MainActor
struct ObservationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.flowerollThemePalette) private var palette
    @Bindable var controller: ObservationController
    let endpoint: String
    @State private var question = ""
    @State private var showDelete = false
    @State private var showEvidence = false
    @FocusState private var questionFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if controller.hasSession { sessionPage } else { setupPage }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(controller.hasSession ? "" : "观察")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        if controller.hasSession { Label("回主页", systemImage: "house") }
                        else { Image(systemName: "xmark") }
                    }
                    .accessibilityIdentifier("observation.return-home")
                    .accessibilityHint("返回主页不会结束正在进行的观察")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if controller.hasSession {
                        Menu {
                            Button("查看原始记录", systemImage: "text.alignleft") { showEvidence = true }
                            ShareLink(item: controller.exportText) { Label("分享记录", systemImage: "square.and.arrow.up") }
                            if controller.record?.hasEnded == true || controller.phase == .failed {
                                Button("删除这段记录", systemImage: "trash", role: .destructive) { showDelete = true }
                            }
                        } label: { Image(systemName: "ellipsis") }
                    }
                }
            }
            .sheet(isPresented: $showEvidence) {
                NavigationStack {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(controller.events) { event in evidenceRow(event, showRawOCR: true) }
                        }
                        .padding(20)
                    }
                    .navigationTitle("原始记录")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showEvidence = false } } }
                }
            }
            .confirmationDialog("删除本机与后台保存的这段观察记录？", isPresented: $showDelete, titleVisibility: .visible) {
                Button("删除记录", role: .destructive) { Task { await controller.deleteCurrent() } }
            } message: {
                Text("已经分享到其他位置的副本不会被删除。")
            }
        }
    }

    private var setupPage: some View {
        ScrollView {
            VStack(spacing: 18) {
                FlowerollPresentationView(state: .idle, compact: true)
                    .frame(width: 126, height: 126).accessibilityHidden(true)
                    .padding(.top, 22)
                VStack(spacing: 7) {
                    Text("想让小卷陪你观察什么？").font(.title2.weight(.bold))
                    Text("选一个场景，记录和整理交给小卷。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(ObservationPreset.allCases) { preset in
                            Button { controller.selectedPreset = preset } label: {
                                Text(preset.title).font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 15).frame(height: 38)
                                    .foregroundStyle(controller.selectedPreset == preset ? palette.onStrongAccent : Color.primary)
                                    .background(controller.selectedPreset == preset ? palette.strongAccent : Color(uiColor: .secondarySystemBackground), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("observation.preset." + preset.rawValue)
                            .accessibilityAddTraits(controller.selectedPreset == preset ? .isSelected : [])
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("observation.preset-picker")
                VStack(alignment: .leading, spacing: 12) {
                    Text(controller.selectedPreset.detail).font(.subheadline).foregroundStyle(.secondary)
                    if controller.selectedPreset == .custom {
                        HStack(spacing: 8) {
                            ForEach(ObservationSource.allCases) { source in
                                let selected = controller.customSources.contains(source)
                                Button { controller.toggleCustomSource(source) } label: {
                                    Label(source.shortTitle, systemImage: source.systemImage)
                                        .font(.caption.weight(.semibold)).lineLimit(1)
                                        .frame(maxWidth: .infinity, minHeight: 38)
                                        .foregroundStyle(selected ? palette.strongAccent : Color.secondary)
                                        .background(selected ? palette.accent.opacity(0.15) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("observation.source." + source.rawValue)
                                .accessibilityAddTraits(selected ? .isSelected : [])
                            }
                        }
                    } else {
                        ViewThatFits(in: .horizontal) {
                            sourceHints
                            sourceHints.font(.caption2)
                        }
                    }
                    if controller.effectiveSources.contains(.deviceAudio), !controller.effectiveSources.contains(.screen) {
                        Text("仍需系统共享授权，小卷只处理声音，不保存画面。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if controller.effectiveSources.contains(.ambientMicrophone), !controller.effectiveSources.isDisjoint(with: [.screen, .deviceAudio]) {
                        Text("系统共享面板中也需要打开麦克风。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .accessibilityIdentifier("observation.source-hint")

                VStack(alignment: .leading, spacing: 8) {
                    Label("只在你开始后记录，随时可以暂停或结束。", systemImage: "hand.raised")
                    Text("转写文字和必要的关键画面会发送至你连接的花卷后台与 AI 服务，用于总结。不会保存完整录音或视频；通话、受保护内容可能无法采集。请先取得被记录者的同意。")
                }
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                if let message = controller.errorMessage {
                    Text(message).font(.callout).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            Button { controller.begin(endpoint: endpoint) } label: {
                Text("开始观察").font(.headline).frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent).tint(palette.strongAccent)
            .disabled(controller.effectiveSources.isEmpty)
            .accessibilityIdentifier("observation.start")
            .padding(.horizontal, 24).padding(.vertical, 14)
            .background(.regularMaterial)
        }
        .accessibilityIdentifier("observation.setup")
    }
    private var sourceHints: some View {
        HStack(spacing: 6) {
            Text("会用到").font(.caption2).foregroundStyle(.secondary)
            ForEach(ObservationSource.allCases.filter { controller.effectiveSources.contains($0) }) { source in
                Label(source.title, systemImage: source.systemImage)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .foregroundStyle(palette.strongAccent)
                    .background(palette.accent.opacity(0.1), in: Capsule())
            }
        }
    }

    private var sessionPage: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(controller.sessionTitle).font(.title2.weight(.bold))
                            .accessibilityIdentifier("observation.phase")
                        Text(controller.elapsedText)
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            .id(controller.clockRevision)
                    }
                    Spacer()
                    FlowerollPresentationView(state: controller.isCapturing ? .listening : .idle, compact: true)
                        .frame(width: 66, height: 66).accessibilityHidden(true)
                }
                Text(controller.statusMessage).font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("observation.status")
                if !controller.sourceIssues.isEmpty {
                    ForEach(ObservationSource.allCases.filter { controller.sourceIssues[$0] != nil }) { source in
                        Label(controller.sourceIssues[source] ?? "", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if controller.record?.hostView?.lastError != nil {
                    Button("重新整理") { Task { await controller.retryAnalysis() } }
                }
                if let final = controller.finalSummary {
                    summaryCard(final)
                } else {
                    if let latest = controller.record?.hostView?.notes.last {
                        summaryCard(latest)
                    }
                    let liveSources = controller.presentationInterimSources
                    if !liveSources.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("正在记录").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(liveSources) { source in
                                HStack(alignment: .top, spacing: 9) {
                                    sourceBadge(source)
                                    Text(controller.interim[source] ?? "")
                                        .font(.body).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16).background(palette.accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityIdentifier("observation.live-transcript")
                    }
                    let presentationEvents = controller.presentationEvents
                    let latestScreenID = presentationEvents.last(where: { $0.kind == "screen" })?.id
                    let recent = Array(presentationEvents.filter { event in
                        event.kind == "transcript"
                            || (event.kind == "screen" && (
                                controller.screenInsight(for: event.id) != nil
                                    || event.id == latestScreenID
                            ))
                    }.suffix(10))
                    if !recent.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("最近").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Spacer()
                                Button("全部记录") { showEvidence = true }.font(.caption)
                            }
                            ForEach(recent) { event in evidenceRow(event, compact: true) }
                        }
                        .padding(16).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    }
                }
                if let notes = controller.record?.hostView?.notes, notes.filter({ $0.kind == "checkpoint" }).count > 1 {
                    DisclosureGroup("之前的整理") {
                        ForEach(Array(notes.filter { $0.kind == "checkpoint" }.dropLast())) { note in summaryCard(note) }
                    }.font(.subheadline)
                }
                if let questions = controller.record?.hostView?.questions {
                    ForEach(questions) { item in
                        VStack(alignment: .leading, spacing: 9) {
                            Text(item.question).font(.subheadline.weight(.semibold))
                            if let result = item.result { Text(result.summary).textSelection(.enabled) }
                            else if item.status == "working" { ProgressView("正在查阅记录…").font(.caption) }
                            else { Text("这次回答未完成，可以稍后再问。").font(.caption).foregroundStyle(.secondary) }
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                    }
                }
                if ![.authorizing, .preparing, .failed, .stopping, .pausing].contains(controller.phase) {
                    HStack(alignment: .bottom) {
                        TextField("问问刚才的内容…", text: $question, axis: .vertical)
                            .lineLimit(1...4).focused($questionFocused)
                            .accessibilityIdentifier("observation.question")
                        Button {
                            let text = question
                            question = ""; questionFocused = false
                            Task { await controller.ask(text) }
                        } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .disabled(controller.isAsking || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("发送关于观察的问题")
                    }
                    .padding(14).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    if let error = controller.questionError { Text(error).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { controls }
        .accessibilityIdentifier("observation.active")
    }

    private var hasVisibleControls: Bool {
        if [.observing, .paused, .interrupted].contains(controller.phase) { return true }
        if ![.completed, .finalizing].contains(controller.phase) { return true }
        return controller.canSaveCurrentToTaskHistory
    }

    @ViewBuilder private var controls: some View {
        if hasVisibleControls {
            HStack(spacing: 12) {
            if [.observing, .paused, .interrupted].contains(controller.phase) {
                Button {
                    if controller.phase == .observing { Task { await controller.pause() } }
                    else { controller.resume() }
                } label: {
                    Label(controller.phase == .observing ? "暂停" : "继续",
                          systemImage: controller.phase == .observing ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.bordered).accessibilityIdentifier("observation.pause")
            }
            if ![.completed, .finalizing].contains(controller.phase) {
                Button(role: .destructive) { Task { await controller.end() } } label: {
                    Label(controller.phase == .failed ? "结束并保留记录" : (controller.phase == .stopUnconfirmed ? "再次确认停止" : "结束"), systemImage: "stop.fill")
                        .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.borderedProminent)
                .disabled([.stopping, .pausing].contains(controller.phase))
                .accessibilityIdentifier("observation.end")
            } else if controller.canSaveCurrentToTaskHistory {
                ShareLink(item: controller.exportText) { Label("分享纪要", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 42) }
                    .buttonStyle(.bordered)
                Button {
                    _ = controller.saveCurrentToTaskHistory()
                } label: {
                    Label("存入历史", systemImage: "tray.and.arrow.down.fill")
                        .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("保存到任务历史")
                .accessibilityIdentifier("observation.save-to-history")
            }
            }
            .tint(palette.strongAccent)
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(.regularMaterial)
        }
    }
    private func summaryCard(_ note: ObservationSummary) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(note.title).font(.headline)
            Text(note.summary).textSelection(.enabled)
            factSection("已讨论的决定", note.decisions)
            factSection("待办事项", note.todos)
            factSection("待确认", note.openQuestions)
            if !note.evidenceIDs.isEmpty {
                Button("核对原始记录") { showEvidence = true }.font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18).background(palette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityIdentifier(note.kind == "final" ? "observation.final-summary" : "observation.checkpoint")
    }
    @ViewBuilder private func factSection(_ title: String, _ facts: [ObservationFact]) -> some View {
        if !facts.isEmpty {
            Text(title).font(.subheadline.weight(.semibold)).padding(.top, 3)
            ForEach(facts, id: \.self) { fact in Text("· " + fact.text).font(.subheadline).textSelection(.enabled) }
        }
    }
    private func evidenceRow(_ event: ObservationEvent, compact: Bool = false, showRawOCR: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            let seconds = event.offsetMS / 1000
            HStack(spacing: 8) {
                if let source = ObservationSource(rawValue: event.source) {
                    sourceBadge(source, understood: source == .screen && controller.screenInsight(for: event.id) != nil)
                } else {
                    Label("系统", systemImage: "gearshape")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            if event.source == ObservationSource.screen.rawValue {
                if let insight = controller.screenInsight(for: event.id) {
                    Text(insight.summary).font(.subheadline.weight(.medium)).textSelection(.enabled)
                        .lineLimit(compact ? 6 : nil)
                    if !insight.keyItems.isEmpty {
                        Text(insight.keyItems.prefix(compact ? 3 : 8).joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(compact ? 3 : nil)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("画面已记录，正在理解。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if !event.text.isEmpty {
                            Text(event.text.replacingOccurrences(of: "\n", with: " · "))
                                .font(.caption).foregroundStyle(.tertiary)
                                .lineLimit(compact ? 2 : 4)
                        }
                    }
                }
                if showRawOCR, !event.text.isEmpty {
                    DisclosureGroup("OCR 原始文字") {
                        Text(event.text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .font(.caption)
                }
            } else {
                Text(event.text)
                    .font(.subheadline).textSelection(.enabled)
                    .lineLimit(compact ? 7 : nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceBadge(_ source: ObservationSource, understood: Bool = false) -> some View {
        Label(sourceDisplayTitle(source, understood: understood), systemImage: source.systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(source == .screen ? palette.strongAccent : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(source == .screen ? palette.accent.opacity(0.12) : Color.primary.opacity(0.055), in: Capsule())
    }

    private func sourceDisplayTitle(_ source: ObservationSource, understood: Bool) -> String {
        switch source {
        case .screen: return understood ? "屏幕画面 · 已理解" : "屏幕画面"
        case .ambientMicrophone: return "周围声音"
        case .deviceAudio: return "屏幕语音"
        }
    }
}

@MainActor
struct ObservationHistoryDetailView: View {
    @Environment(\.flowerollThemePalette) private var palette
    @Bindable var controller: ObservationController
    let recordID: String
    @State private var events: [ObservationEvent] = []
    @State private var loadMessage: String?

    private var record: ObservationSessionRecord? {
        if controller.record?.id == recordID { return controller.record }
        return controller.history.first { $0.id == recordID }
    }

    private var presentationEvents: [ObservationEvent] {
        ObservationTimelineFusion.historyEvents(events)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let record {
                    header(record)
                    if let final = record.hostView?.notes.last(where: { $0.kind == "final" }) {
                        summaryCard(final)
                    } else if let latest = record.hostView?.notes.last {
                        summaryCard(latest)
                    } else {
                        Label(record.phase == .finalizing ? "正在整理纪要" : "这次观察没有生成纪要", systemImage: "text.badge.clock")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("观察时间线").font(.headline)
                            if !presentationEvents.isEmpty {
                                Text("\(presentationEvents.count) 条")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        if presentationEvents.isEmpty {
                            Label("这段记录没有可展示的屏幕或语音时间线", systemImage: "clock.badge.questionmark")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(presentationEvents.enumerated()), id: \.element.id) { index, event in
                                historyEventRow(event, record: record, showsConnector: index < presentationEvents.count - 1)
                            }
                        }
                    }
                    .padding(16)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                    .accessibilityIdentifier("observation.history.timeline")
                } else {
                    ContentUnavailableView("找不到这段观察记录", systemImage: "eye.slash")
                }
                if let loadMessage {
                    Text(loadMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .navigationTitle(record?.hostView?.notes.last?.title ?? "观察记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let record {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: exportText(record)) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("分享观察记录")
                }
            }
        }
        .task(id: recordID) { loadEvents() }
        .accessibilityIdentifier("observation.history.detail")
    }

    private func header(_ record: ObservationSessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Label("观察记录", systemImage: "eye")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.strongAccent)
                Spacer()
                Text(dateText(record.configuration.createdAt))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(record.hostView?.notes.last?.title ?? record.configuration.preset.title + "观察")
                .font(.title2.bold())
            HStack(spacing: 7) {
                ForEach(record.configuration.sources, id: \.self) { source in
                    Label(sourceLabel(source), systemImage: source.systemImage)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                }
            }
            if record.capturedSeconds > 0 {
                Text("记录时长 " + durationText(record.capturedSeconds))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func summaryCard(_ note: ObservationSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(note.kind == "final" ? "最终纪要" : "阶段整理")
                .font(.caption.weight(.semibold)).foregroundStyle(palette.strongAccent)
            Text(note.summary).textSelection(.enabled)
            if !note.decisions.isEmpty { factSection("已讨论的决定", note.decisions) }
            if !note.todos.isEmpty { factSection("待办事项", note.todos) }
            if !note.openQuestions.isEmpty { factSection("待确认", note.openQuestions) }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder private func factSection(_ title: String, _ facts: [ObservationFact]) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).padding(.top, 2)
        ForEach(facts, id: \.self) { fact in Text("· " + fact.text).font(.subheadline).textSelection(.enabled) }
    }

    private func historyEventRow(
        _ event: ObservationEvent,
        record: ObservationSessionRecord,
        showsConnector: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 5) {
                Circle()
                    .fill(event.source == ObservationSource.screen.rawValue ? palette.strongAccent : Color.secondary)
                    .frame(width: 7, height: 7)
                    .padding(.top, 6)
                if showsConnector {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 9)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    if let source = ObservationSource(rawValue: event.source) {
                        Label(sourceLabel(source, understood: source == .screen && insight(for: event.id, record: record) != nil), systemImage: source.systemImage)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(source == .screen ? palette.strongAccent : Color.secondary)
                    }
                    Spacer()
                    let seconds = event.offsetMS / 1000
                    Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                if event.source == ObservationSource.screen.rawValue {
                    if let insight = insight(for: event.id, record: record) {
                        Text(insight.summary).font(.subheadline.weight(.medium)).textSelection(.enabled)
                        if !insight.keyItems.isEmpty {
                            Text(insight.keyItems.prefix(5).joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(event.text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else {
                        Text("画面已记录，但没有可展示的文字。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    Text(event.text).font(.subheadline).textSelection(.enabled)
                }
            }
            .padding(.bottom, showsConnector ? 7 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func insight(for eventID: String, record: ObservationSessionRecord) -> ObservationScreenInsight? {
        record.hostView?.screenInsights?.last { $0.eventID == eventID }
    }

    private func sourceLabel(_ source: ObservationSource, understood: Bool = false) -> String {
        switch source {
        case .screen: return understood ? "屏幕画面 · 已理解" : "屏幕画面"
        case .ambientMicrophone: return "周围声音"
        case .deviceAudio: return "屏幕语音"
        }
    }

    private func dateText(_ value: String) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) else { return value.prefix(16).replacingOccurrences(of: "T", with: " ") }
        if Calendar.current.isDateInToday(date) { return "今天 " + date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(date) { return "昨天 " + date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func exportText(_ record: ObservationSessionRecord) -> String {
        var parts = [record.hostView?.notes.last(where: { $0.kind == "final" })?.markdown ?? "# 观察记录"]
        parts.append("## 观察时间线")
        parts += presentationEvents.filter { $0.kind == "transcript" || $0.kind == "screen" }.map { event in
            let seconds = event.offsetMS / 1000
            let label = ObservationSource(rawValue: event.source).map { sourceLabel($0, understood: $0 == .screen && insight(for: event.id, record: record) != nil) } ?? "记录"
            let text = event.source == ObservationSource.screen.rawValue
                ? (insight(for: event.id, record: record)?.summary ?? "画面已记录")
                : event.text
            return String(format: "[%02d:%02d] ", seconds / 60, seconds % 60) + label + "\n" + text
        }
        return parts.joined(separator: "\n\n")
    }

    private func loadEvents() {
        do {
            let journal = try ObservationJournal()
            events = try journal.events(recordID)
            loadMessage = nil
        } catch {
            loadMessage = "原始时间线暂时无法读取，纪要仍可查看。"
        }
    }
}
