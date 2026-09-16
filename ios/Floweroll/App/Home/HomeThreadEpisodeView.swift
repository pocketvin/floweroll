import AppIntents
import AVFAudio
import AVFoundation
import ContactsUI
import SwiftUI
import UserNotifications


struct HomeThreadEpisodeView: View {
    let task: HostTaskIndexItem
    let store: RuntimeTaskStore
    let isFirstEpisode: Bool
    let updateMode: RuntimeTaskDetailUpdateMode
    let onTimelineChange: () -> Void

    @State private var model = RuntimeTaskDetailModel()
    @State private var interactionText = ""
    @State private var interactionEventID = UUID().uuidString
    @State private var activeInAppEventID: String?
    @State private var inAppExecutionError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.flowerollThemePalette) private var themePalette

    private var visibleTimeline: [HostTimelineItem] {
        let preferredView: HostTaskView?
        if let modelView = model.view, let cached = store.cachedTaskView(taskID: task.taskID) {
            preferredView = RuntimeTaskPresentationReducer.preferred(
                existing: modelView,
                incoming: cached
            )
        } else {
            preferredView = model.view ?? store.cachedTaskView(taskID: task.taskID)
        }
        let authoritative = preferredView?.timeline ?? []
        let merged = store.localUserTurnTimelineItems(
            taskID: task.taskID,
            authoritativeTimeline: authoritative
        )
        let status = preferredView?.task.status ?? task.status
        return RuntimeTimelinePresentationPolicy.visibleItems(
            merged,
            taskStatus: status,
            hideCompletedToolRowsWhenWorkSummaryExists: (preferredView?.workSummary?.total ?? 0) > 0,
            structuredResult: RuntimeTaskStore.isTerminalStatus(status) ? preferredView?.result : nil
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !isFirstEpisode {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.12))
                        .frame(height: 1)
                    Text("继续这件事")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.12))
                        .frame(height: 1)
                }
                .padding(.vertical, 2)
            }

            HStack(alignment: .top) {
                Spacer(minLength: 44)
                VStack(alignment: .trailing, spacing: 6) {
                    if let materials = model.materials {
                        TaskMessageAttachmentStrip(
                            files: materials.initialMessageFiles(submissionID: task.submissionID)
                        )
                    }
                    Text(task.goal)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .background(themePalette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .stroke(themePalette.accent.opacity(0.12), lineWidth: 0.55)
                        }
                }
            }

            if model.isLoading && model.view == nil {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    Text(task.latestTimeline?.title ?? "正在恢复任务…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleTimeline.enumerated()), id: \.element.timelineItemID) { index, item in
                        HomeTimelineRow(
                            item: item,
                            isLast: index == visibleTimeline.count - 1,
                            taskID: task.taskID,
                            store: store,
                            materials: model.materials
                        )
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .opacity
                                    .combined(with: .move(edge: .bottom))
                                    .combined(with: .scale(scale: 0.985, anchor: .top))
                        )
                    }
                }
                .animation(
                    reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.46, dampingFraction: 0.9),
                    value: visibleTimeline.map { "\($0.timelineItemID):\($0.revision)" }
                )
            }

            if let result = model.view?.result,
               RuntimeTaskStore.isTerminalStatus(model.view?.task.status ?? task.status) {
                RuntimeTaskResultCard(result: result)
                    .runtimeTerminalReviewVisibility(
                        taskID: task.taskID,
                        state: presentationState,
                        surface: .homeResult,
                        store: store,
                        enabled: presentationState.isTerminal,
                        threshold: 0.45
                    )
            }

            if !(store.presentationTruth(taskID: task.taskID, view: model.view) ?? task.presentationTruth).isTerminal,
               let interaction = model.view?.typedPendingInteraction {
                pendingInteractionControls(interaction)
            }

            // Files and reports are outcomes of the work above. Keeping them
            // last prevents a newly published HTML report from jumping above
            // the conversation/progress that produced it.
            TaskMaterialsPanel(taskID: task.taskID, store: store,
                revision: "\(model.view?.presentationCursor ?? 0):\(model.view?.workSummary?.revision ?? "")")

            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .runtimeTerminalReviewVisibility(
            taskID: task.taskID,
            state: presentationState,
            surface: .homeResult,
            store: store,
            enabled: fallbackTerminalReviewEligible,
            threshold: 0.2
        )
        .task(id: task.taskID + ":" + (updateMode == .live ? "live" : "snapshot")) {
            model.start(taskID: task.taskID, store: store, updateMode: updateMode)
        }
        .onReceive(NotificationCenter.default.publisher(for: TaskScopedInAppIntentEvents.notification)) { notification in
            handleInAppEvent(notification)
        }
        .onDisappear {
            model.stop()
        }
        .onChange(of: visibleTimeline.map { "\($0.timelineItemID):\($0.revision)" }) { _, _ in
            onTimelineChange()
        }
        .onChange(of: (store.presentationTruth(taskID: task.taskID, view: model.view) ?? task.presentationTruth).state) { oldState, newState in
            onTimelineChange()
            if !oldState.isTerminal, newState.isTerminal {
                Task { @MainActor in
                    await store.refresh()
                }
            }
        }
    }

    @ViewBuilder
    private func pendingInteractionControls(_ interaction: HostPendingInteraction) -> some View {
        switch interaction {
        case let .clarification(id, _, options, acceptsText, _):
            VStack(alignment: .leading, spacing: 9) {
                if !options.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(options) { option in
                                Button(intent: TaskScopedHouIntent.clarificationOption(
                                    taskID: task.taskID,
                                    eventID: interactionEventID,
                                    clarificationID: id,
                                    optionID: option.id
                                )) {
                                    Text(option.label)
                                }
                                .simultaneousGesture(TapGesture().onEnded {
                                    beginInAppEvent()
                                })
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(model.isSending || activeInAppEventID != nil)
                            }
                        }
                    }
                }
                if acceptsText {
                    Label("也可以直接在下方输入框回复", systemImage: "arrow.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 30)

        case let .actionInput(id, attemptID, _, options, acceptsText, _, bindingDigest):
            VStack(alignment: .leading, spacing: 9) {
                if attemptID == nil {
                    HStack(spacing: 9) {
                        Button(intent: TaskScopedHouIntent.actionInput(
                            taskID: task.taskID,
                            eventID: interactionEventID,
                            inputRequestID: id,
                            bindingDigest: bindingDigest,
                            response: ["approved": .bool(true)]
                        )) {
                            Text("确认")
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            beginInAppEvent()
                        })
                        .buttonStyle(.borderedProminent)

                        Button("取消") {
                            Task { @MainActor in
                                if await model.respondToActionInput(
                                    taskID: task.taskID,
                                    inputRequestID: id,
                                    bindingDigest: bindingDigest,
                                    response: ["approved": .bool(false)],
                                    store: store
                                ) { onTimelineChange() }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .disabled(model.isSending || activeInAppEventID != nil)
                } else {
                    if !options.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(options) { option in
                                    Button(intent: TaskScopedHouIntent.actionInput(
                                        taskID: task.taskID,
                                        eventID: interactionEventID,
                                        inputRequestID: id,
                                        bindingDigest: bindingDigest,
                                        response: ["option_id": .string(option.id)]
                                    )) {
                                        Text(option.label)
                                    }
                                    .simultaneousGesture(TapGesture().onEnded {
                                        beginInAppEvent()
                                    })
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(model.isSending || activeInAppEventID != nil)
                                }
                            }
                        }
                    }
                    if acceptsText {
                        HStack(spacing: 8) {
                            TextField("直接补充", text: $interactionText, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(1...3)
                            Button(intent: TaskScopedHouIntent.actionInput(
                                taskID: task.taskID,
                                eventID: interactionEventID,
                                inputRequestID: id,
                                bindingDigest: bindingDigest,
                                response: ["text": .string(
                                    interactionText.trimmingCharacters(in: .whitespacesAndNewlines)
                                )]
                            )) {
                                if activeInAppEventID == interactionEventID {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("发送")
                                }
                            }
                            .simultaneousGesture(TapGesture().onEnded {
                                guard !interactionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                                beginInAppEvent()
                            })
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                interactionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || model.isSending
                                    || activeInAppEventID != nil
                            )
                        }
                    }
                }
            }
            .padding(.leading, 30)
        }

        Button("取消整个任务", role: .destructive) {
            Task { @MainActor in
                if await model.cancelUsingStore(
                    taskID: task.taskID,
                    store: store,
                    reason: "用户从首页待处理卡片取消整个任务"
                ) != nil {
                    onTimelineChange()
                }
            }
        }
        .buttonStyle(.bordered)
        .disabled(model.isSending || activeInAppEventID != nil)
        .padding(.leading, 30)
        .accessibilityIdentifier("home.pending.cancel-task")

        if let message = inAppExecutionError ?? model.cancellationMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 30)
                .accessibilityIdentifier("home.pending.cancel-status")
        }
    }

    private func beginInAppEvent() {
        guard activeInAppEventID == nil else { return }
        let eventID = interactionEventID
        activeInAppEventID = eventID
        inAppExecutionError = nil
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard activeInAppEventID == eventID else { return }
            activeInAppEventID = nil
            inAppExecutionError = "后台提交暂未确认，可再次提交。"
        }
    }

    private func handleInAppEvent(_ notification: Notification) {
        guard let info = notification.userInfo,
              info[TaskScopedInAppIntentEvents.sourceTaskIDKey] as? String == task.taskID,
              info[TaskScopedInAppIntentEvents.eventIDKey] as? String == interactionEventID,
              let kind = info[TaskScopedInAppIntentEvents.kindKey] as? String
        else { return }

        activeInAppEventID = nil
        if kind == "accepted" {
            inAppExecutionError = nil
            interactionText = ""
            interactionEventID = UUID().uuidString
            onTimelineChange()
            Task { @MainActor in
                await model.refresh(taskID: task.taskID, store: store)
            }
        } else if kind == "failed" {
            inAppExecutionError = info[TaskScopedInAppIntentEvents.messageKey] as? String
                ?? "这次操作暂时没有进入后台执行。"
        }
    }

}
