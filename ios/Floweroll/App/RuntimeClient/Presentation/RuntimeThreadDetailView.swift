import AppIntents
import Observation
import SwiftUI



struct RuntimeThreadDetailView: View {
    let threadID: String
    let initialTaskID: String?
    let store: RuntimeTaskStore
    let onBringToHome: () -> Void

    @Environment(\.flowerollThemePalette) private var themePalette
    @Environment(\.dismiss) private var dismiss
    @State private var model = RuntimeThreadDetailModel()
    @State private var continuationText = ""
    @State private var continuationEventID = UUID().uuidString
    @State private var activeInAppEventID: String?
    @State private var inAppExecutionError: String?

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            if !model.tasks.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        threadHeader

                        if model.nextCursor != nil || model.isLoadingMore {
                            HStack {
                                Spacer()
                                Button {
                                    Task { @MainActor in
                                        await model.loadMore(threadID: threadID, store: store)
                                    }
                                } label: {
                                    if model.isLoadingMore {
                                        ProgressView(RuntimeThreadRestorationPresentation.olderPageLoadingMessage)
                                    } else {
                                        Label(RuntimeThreadRestorationPresentation.olderPageLabel, systemImage: "arrow.up.circle")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(model.isLoadingMore)
                                Spacer()
                            }
                        }

                        ForEach(Array(model.tasks.enumerated()), id: \.element.taskID) { index, task in
                            RuntimeThreadEpisodeDetailView(
                                task: task,
                                store: store,
                                isFirstEpisode: index == 0,
                                updateMode: RuntimeTaskDetailUpdatePolicy.mode(
                                    task: task, liveTaskID: model.activeTask?.taskID
                                ),
                                onStateChange: {
                                    Task { @MainActor in
                                        await model.load(threadID: threadID, store: store)
                                    }
                                }
                            )
                        }

                        if showsContinuationComposer {
                            continuationComposer
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 36)
                }
                .refreshable {
                    await model.load(threadID: threadID, store: store)
                }
            } else if RuntimeThreadRestorationPresentation.showsBlockingFirstPageLoading(
                taskCount: model.tasks.count,
                isLoading: model.isLoading
            ) {
                ProgressView(RuntimeThreadRestorationPresentation.firstPageLoadingMessage)
            } else {
                RuntimeEmptyState(
                    title: "暂时无法读取任务历史",
                    message: model.lastError ?? "后台没有返回这条任务工作流。",
                    symbol: "clock.arrow.circlepath"
                )
                .padding(.horizontal, 18)
            }
        }
        .accessibilityIdentifier("task.detail")
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.tasks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("调到前台") {
                        markLatestTerminalReviewed()
                        store.activateHomeThread(
                            threadID: threadID,
                            preferredTaskID: model.activeTask?.taskID ?? initialTaskID
                        )
                        onBringToHome()
                        dismiss()
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let error = inAppExecutionError ?? model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 8)
            }
        }
        .task(id: threadID) {
            await model.load(threadID: threadID, store: store)
            markLatestTerminalReviewed()
        }
        .onChange(of: model.latestTask?.taskID) { _, _ in
            markLatestTerminalReviewed()
        }
        .onReceive(NotificationCenter.default.publisher(for: TaskScopedInAppIntentEvents.notification)) { notification in
            handleInAppEvent(notification)
        }
    }

    private func markLatestTerminalReviewed() {
        guard let latest = model.latestTask,
              latest.presentationTruth.isTerminal
        else { return }
        store.terminalReviewState.markReviewed(taskIDs: [latest.taskID])
    }

    private var threadHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(threadStatusColor)
                        .frame(width: 7, height: 7)
                    Text(threadStatusLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(threadStatusColor)
                    if model.tasks.count > 1 {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text("\(model.tasks.count) 轮")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Text(model.latestTask?.title ?? "任务")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .tracking(-0.4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
            FlowerollAnimatedStateView(
                state: threadMascotState,
                animated: !threadIsTerminal
            )
                .frame(width: 72, height: 72)
                .id(threadMascotState)
        }
        .padding(17)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
    }

    @ViewBuilder
    private var continuationComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.activeTask == nil ? "继续这件事" : "补充或修改当前任务")
                .font(.headline)

            HStack(alignment: .bottom, spacing: 9) {
                TextField(
                    model.activeTask == nil
                        ? "继续补充要求，会接在同一条历史下面…"
                        : "补充或修改当前要求…",
                    text: $continuationText,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)

                if let active = model.activeTask {
                    Button(intent: TaskScopedHouIntent.userTurn(
                        taskID: active.taskID,
                        eventID: continuationEventID,
                        text: continuationText.trimmingCharacters(in: .whitespacesAndNewlines)
                    )) {
                        continuationActionLabel
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        beginInAppContinuation()
                    })
                    .disabled(continuationDisabled)
                } else if let latest = model.latestTask {
                    Button(intent: ThreadFollowUpHouIntent(
                        parentTaskID: latest.taskID,
                        text: continuationText.trimmingCharacters(in: .whitespacesAndNewlines),
                        submissionID: continuationEventID
                    )) {
                        continuationActionLabel
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        beginInAppContinuation()
                    })
                    .disabled(continuationDisabled)
                }
            }

            Text(
                model.activeTask == nil
                    ? "上一轮已经结束时，会新建一个执行 episode，但仍属于这条任务历史。"
                    : "当前轮仍在执行时，补充会作为 UserTurn 进入同一个 Task。"
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var showsContinuationComposer: Bool {
        guard let active = model.activeTask else { return true }
        let cached = store.cachedTaskView(taskID: active.taskID)
        return RuntimeTaskComposerPolicy.showsGenericComposer(
            isTerminal: false,
            hasPendingInteraction: active.needsUser || cached?.typedPendingInteraction != nil
        )
    }

    private var continuationActionLabel: some View {
        Group {
            if activeInAppEventID == continuationEventID {
                ProgressView()
                    .frame(width: 30, height: 30)
            } else {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
        }
    }

    private var continuationDisabled: Bool {
        continuationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.isSending
            || activeInAppEventID != nil
    }

    private func beginInAppContinuation() {
        guard !continuationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              activeInAppEventID == nil
        else { return }
        let eventID = continuationEventID
        activeInAppEventID = eventID
        inAppExecutionError = nil
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard activeInAppEventID == eventID else { return }
            activeInAppEventID = nil
            inAppExecutionError = "后台提交暂未确认，可再次提交；同一事件不会重复执行。"
        }
    }

    private func handleInAppEvent(_ notification: Notification) {
        guard let info = notification.userInfo,
              info[TaskScopedInAppIntentEvents.eventIDKey] as? String == continuationEventID,
              let kind = info[TaskScopedInAppIntentEvents.kindKey] as? String
        else { return }

        activeInAppEventID = nil
        switch kind {
        case "accepted":
            inAppExecutionError = nil
            continuationText = ""
            continuationEventID = UUID().uuidString
            Task { @MainActor in
                await model.load(threadID: threadID, store: store)
                markLatestTerminalReviewed()
            }
        case "failed":
            inAppExecutionError = info[TaskScopedInAppIntentEvents.messageKey] as? String
                ?? "这次操作暂时没有进入后台执行。"
        default:
            break
        }
    }

    private var threadIsTerminal: Bool {
        model.latestTask?.presentationTruth.isTerminal ?? true
    }

    private var threadMascotState: FlowerollStateAsset {
        guard let latest = model.latestTask else { return .idle }
        switch latest.presentationTruth.state {
        case .completed, .failed, .cancelled: return .done
        case .waiting, .paused, .needsUser: return .waiting
        case .active: return .working
        }
    }

    private var threadStatusLabel: String {
        guard let latest = model.latestTask else { return "历史" }
        return latest.presentationTruth.statusLabel
    }

    private var threadStatusColor: Color {
        guard let latest = model.latestTask else { return .secondary }
        switch latest.presentationTruth.state {
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .needsUser, .paused: return .orange
        case .active, .waiting: return themePalette.accent
        }
    }
}

private struct RuntimeThreadEpisodeDetailView: View {
    let task: HostTaskIndexItem
    let store: RuntimeTaskStore
    let isFirstEpisode: Bool
    let updateMode: RuntimeTaskDetailUpdateMode
    let onStateChange: () -> Void

    @Environment(\.flowerollThemePalette) private var themePalette
    @AppStorage("floweroll.developerMode") private var developerMode = false
    @State private var model = RuntimeTaskDetailModel()
    @State private var interactionText = ""

    private var visibleTimeline: [HostTimelineItem] {
        guard let view = model.view else { return [] }
        return RuntimeTimelinePresentationPolicy.visibleItems(
            view.timeline,
            taskStatus: view.task.status,
            structuredResult: RuntimeTaskStore.isTerminalStatus(view.task.status) ? view.result : nil
        )
    }

    private var presentationState: RuntimeTaskPresentationState {
        (store.presentationTruth(taskID: task.taskID, view: model.view) ?? task.presentationTruth).state
    }

    private var fallbackTerminalReviewEligible: Bool {
        model.view != nil
            && presentationState.isTerminal
            && model.view?.result == nil
    }

    private var taskTimestamp: String? {
        guard let date = RuntimeTaskStore.hostDate(task.createdAt) else { return nil }
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "今天 \(time)" }
        if calendar.isDateInYesterday(date) { return "昨天 \(time)" }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !isFirstEpisode {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.14))
                        .frame(height: 1)
                    Text("继续")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.14))
                        .frame(height: 1)
                }
                .padding(.vertical, 2)
            }

            HStack(alignment: .top) {
                Spacer(minLength: 38)
                VStack(alignment: .trailing, spacing: 4) {
                    if let materials = model.materials {
                        TaskMessageAttachmentStrip(
                            files: materials.initialMessageFiles(submissionID: task.submissionID)
                        )
                    }
                    Text(task.goal)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .background(themePalette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 17, style: .continuous))

                    if task.presentationTruth.isTerminal, let timestamp = taskTimestamp {
                        Text(timestamp)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .padding(.trailing, 7)
                    }
                }
            }

            if model.isLoading && model.view == nil {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(task.latestTimeline?.title ?? "正在恢复这一轮…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(Array(visibleTimeline.enumerated()), id: \.element.timelineItemID) { index, item in
                    RuntimeTimelineRow(
                        item: item,
                        isLast: index == visibleTimeline.count - 1,
                        taskID: task.taskID,
                        store: store,
                        materials: model.materials
                    )
                }
            }

            if let view = model.view, presentationState == .paused {
                RuntimePausedTaskCard(
                    view: view,
                    isRetrying: model.isSending,
                    onRetry: {
                        Task {
                            let resumed = await model.retryPausedTask(taskID: task.taskID, store: store)
                            if resumed { onStateChange() }
                        }
                    }
                )
            }

            if let interaction = model.view?.typedPendingInteraction {
                RuntimeEpisodeInteractionCard(
                    taskID: task.taskID,
                    interaction: interaction,
                    store: store,
                    model: model,
                    text: $interactionText
                )
            }

            if let result = model.view?.result,
               RuntimeTaskStore.isTerminalStatus(model.view?.task.status ?? task.status) {
                RuntimeTaskResultCard(result: result)
                    .runtimeTerminalReviewVisibility(
                        taskID: task.taskID,
                        state: presentationState,
                        surface: .taskDetail,
                        store: store,
                        enabled: presentationState.isTerminal,
                        threshold: 0.45
                    )
            }

            if let artifacts = model.view?.artifacts, !artifacts.isEmpty {
                RuntimeEpisodeArtifactLinks(taskID: task.taskID, artifacts: artifacts, store: store)
            }

            TaskMaterialsPanel(taskID: task.taskID, store: store,
                revision: "\(model.view?.presentationCursor ?? 0):\(model.view?.workSummary?.revision ?? "")")

            if developerMode {
                NavigationLink {
                    DeveloperTaskObservabilityView(taskID: task.taskID, store: store)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "ladybug")
                            .foregroundStyle(themePalette.strongAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("开发者信息")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("查看这轮真实 Planner、Tools、耗时与异常证据")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("task.developer-observability.\(task.taskID)")
            }
        }
        .runtimeTerminalReviewVisibility(
            taskID: task.taskID,
            state: presentationState,
            surface: .taskDetail,
            store: store,
            enabled: fallbackTerminalReviewEligible,
            threshold: 0.2
        )
        .task(id: task.taskID + ":" + (updateMode == .live ? "live" : "snapshot")) {
            model.start(taskID: task.taskID, store: store, updateMode: updateMode)
        }
        .onDisappear {
            model.stop()
        }
        .onChange(of: model.view?.task.status ?? task.status) { oldValue, newValue in
            if oldValue != newValue {
                onStateChange()
            }
        }
    }
}
