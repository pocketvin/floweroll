import AppIntents
import Observation
import SwiftUI


struct RuntimeTaskDetailView: View {
    let taskID: String
    let store: RuntimeTaskStore

    @Environment(\.flowerollThemePalette) private var themePalette
    @State private var model = RuntimeTaskDetailModel()
    @State private var steeringText = ""
    @State private var interactionText = ""
    @State private var showCancelConfirmation = false
    @State private var steeringEventID = UUID().uuidString
    @State private var interactionEventID = UUID().uuidString
    @State private var activeInAppEventID: String?
    @State private var inAppExecutionError: String?

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            if let view = model.view {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        header(view)

                        let visibleTimeline = RuntimeTimelinePresentationPolicy.visibleItems(
                            view.timeline,
                            taskStatus: view.task.status,
                            structuredResult: presentationTruth(view).isTerminal ? view.result : nil
                        )
                        ForEach(Array(visibleTimeline.enumerated()), id: \.element.timelineItemID) { index, item in
                            RuntimeTimelineRow(
                                item: item,
                                isLast: index == visibleTimeline.count - 1,
                                taskID: taskID,
                                store: store,
                                materials: model.materials
                            )
                        }

                        if let result = view.result, presentationTruth(view).isTerminal {
                            RuntimeTaskResultCard(result: result)
                        }

                        if !presentationTruth(view).isTerminal,
                           let interaction = view.typedPendingInteraction {
                            interactionCard(interaction)
                        }

                        if !view.artifacts.isEmpty {
                            artifactSection(view.artifacts)
                        }

                        if presentationTruth(view).state == .paused {
                            RuntimePausedTaskCard(
                                view: view,
                                isRetrying: model.isSending,
                                onRetry: {
                                    Task {
                                        _ = await model.retryPausedTask(taskID: taskID, store: store)
                                    }
                                }
                            )
                        }

                        if RuntimeTaskComposerPolicy.showsGenericComposer(
                            isTerminal: presentationTruth(view).isTerminal,
                            hasPendingInteraction: view.typedPendingInteraction != nil
                        ) {
                            steeringComposer
                        }

                        // Deliverables are the final product of the steps above.
                        TaskMaterialsPanel(taskID: taskID, store: store,
                            revision: "\(view.presentationCursor):\(view.workSummary?.revision ?? "")")
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 40)
                }
                .refreshable {
                    await model.refresh(taskID: taskID, store: store)
                }
            } else if model.isLoading {
                ProgressView("正在恢复任务…")
            } else {
                RuntimeEmptyState(
                    title: "暂时无法读取任务",
                    message: model.lastError ?? "后台没有返回任务详情。",
                    symbol: "exclamationmark.triangle"
                )
            }
        }
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let view = model.view, !presentationTruth(view).isTerminal {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消", role: .destructive) {
                        showCancelConfirmation = true
                    }
                    .disabled(model.isSending)
                }
            }
        }
        .confirmationDialog(
            "取消这个任务？",
            isPresented: $showCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button("取消任务", role: .destructive) {
                Task {
                    _ = await model.cancelUsingStore(
                        taskID: taskID,
                        store: store,
                        reason: "用户从任务详情取消整个任务"
                    )
                }
            }
        } message: {
            Text("如果外部操作已经开始，小卷会先确认真实状态，再安全停止后续步骤。")
        }
        .overlay(alignment: .bottom) {
            if let message = inAppExecutionError ?? model.lastError ?? model.cancellationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 10)
                    .accessibilityIdentifier(
                        inAppExecutionError == nil && model.lastError == nil
                            ? "task.cancel-status"
                            : "task.error-status"
                    )
            }
        }
        .task(id: taskID) {
            model.start(taskID: taskID, store: store)
        }
        .onReceive(NotificationCenter.default.publisher(for: TaskScopedInAppIntentEvents.notification)) { notification in
            handleInAppEvent(notification)
        }
        .onDisappear {
            model.stop()
        }
    }

    private func header(_ view: HostTaskView) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                Text(statusLabel(view))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor(view))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(statusColor(view).opacity(0.1), in: Capsule())

                if let materials = model.materials {
                    TaskMessageAttachmentStrip(
                        files: materials.initialMessageFiles(submissionID: view.task.submissionID)
                    )
                }

                Text(view.task.goal)
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .tracking(-0.5)
                    .fixedSize(horizontal: false, vertical: true)

                Text("历史来自后台 Runtime；关闭花卷后再回来也会重新恢复。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let mascotState = headerMascotState(view) {
                FlowerollAnimatedStateView(state: mascotState)
                    .frame(width: 72, height: 72)
                    .id(mascotState)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
    }

    private func interactionCard(_ interaction: HostPendingInteraction) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("需要你", systemImage: "person.fill.questionmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)

            switch interaction {
            case let .clarification(id, question, options, acceptsText, _):
                Text(question)
                    .font(.headline)
                ForEach(options) { option in
                    Button(intent: TaskScopedHouIntent.clarificationOption(
                        taskID: taskID,
                        eventID: interactionEventID,
                        clarificationID: id,
                        optionID: option.id
                    )) {
                        Text(option.label)
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        beginInAppEvent(interactionEventID)
                    })
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isSending || activeInAppEventID != nil)
                }
                if acceptsText {
                    interactionTextField(intent: TaskScopedHouIntent.clarificationText(
                        taskID: taskID,
                        eventID: interactionEventID,
                        clarificationID: id,
                        text: interactionText.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }

            case let .actionInput(id, attemptID, prompt, options, acceptsText, _, bindingDigest):
                Text(prompt)
                    .font(.headline)
                if attemptID == nil {
                    HStack(spacing: 10) {
                        Button(intent: TaskScopedHouIntent.actionInput(
                            taskID: taskID,
                            eventID: interactionEventID,
                            inputRequestID: id,
                            bindingDigest: bindingDigest,
                            response: ["approved": .bool(true)]
                        )) {
                            Text("确认")
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            beginInAppEvent(interactionEventID)
                        })
                        .buttonStyle(.borderedProminent)

                        // Explicit rejection does not resume work, so it does
                        // not create a fresh LongRunning execution session.
                        Button("取消") {
                            Task {
                                _ = await model.respondToActionInput(
                                    taskID: taskID,
                                    inputRequestID: id,
                                    bindingDigest: bindingDigest,
                                    response: ["approved": .bool(false)],
                                    store: store
                                )
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .disabled(model.isSending || activeInAppEventID != nil)
                } else {
                    ForEach(options) { option in
                        Button(intent: TaskScopedHouIntent.actionInput(
                            taskID: taskID,
                            eventID: interactionEventID,
                            inputRequestID: id,
                            bindingDigest: bindingDigest,
                            response: ["option_id": .string(option.id)]
                        )) {
                            Text(option.label)
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            beginInAppEvent(interactionEventID)
                        })
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isSending || activeInAppEventID != nil)
                    }
                    if acceptsText {
                        interactionTextField(intent: TaskScopedHouIntent.actionInput(
                            taskID: taskID,
                            eventID: interactionEventID,
                            inputRequestID: id,
                            bindingDigest: bindingDigest,
                            response: ["text": .string(
                                interactionText.trimmingCharacters(in: .whitespacesAndNewlines)
                            )]
                        ))
                    }
                }
            }
        }
        .padding(16)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.orange.opacity(0.22), lineWidth: 0.8)
        }
    }

    private func interactionTextField(intent: TaskScopedHouIntent) -> some View {
        HStack(spacing: 9) {
            TextField("补充信息", text: $interactionText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            Button(intent: intent) {
                if activeInAppEventID == interactionEventID {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
            }
            .simultaneousGesture(TapGesture().onEnded {
                guard !interactionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                beginInAppEvent(interactionEventID)
            })
            .disabled(
                interactionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || model.isSending
                    || activeInAppEventID != nil
            )
        }
    }

    private var steeringComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("补充或修改任务")
                .font(.headline)
            HStack(alignment: .bottom, spacing: 10) {
                TextField("例如：改成十点；先不要发送…", text: $steeringText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button(intent: TaskScopedHouIntent.userTurn(
                    taskID: taskID,
                    eventID: steeringEventID,
                    text: steeringText.trimmingCharacters(in: .whitespacesAndNewlines)
                )) {
                    if activeInAppEventID == steeringEventID {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                }
                .simultaneousGesture(TapGesture().onEnded {
                    guard !steeringText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    beginInAppEvent(steeringEventID)
                })
                .disabled(
                    steeringText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isSending
                        || activeInAppEventID != nil
                )
            }
            Text("如果真实副作用已经开始，新要求会先进入 Runtime 安全边界，不会直接覆盖已发生的操作。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func beginInAppEvent(_ eventID: String) {
        guard activeInAppEventID == nil else { return }
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
              info[TaskScopedInAppIntentEvents.sourceTaskIDKey] as? String == taskID,
              let eventID = info[TaskScopedInAppIntentEvents.eventIDKey] as? String,
              let kind = info[TaskScopedInAppIntentEvents.kindKey] as? String
        else { return }

        if activeInAppEventID == eventID {
            activeInAppEventID = nil
        }
        switch kind {
        case "accepted":
            inAppExecutionError = nil
            if eventID == steeringEventID {
                steeringText = ""
                steeringEventID = UUID().uuidString
            }
            if eventID == interactionEventID {
                interactionText = ""
                interactionEventID = UUID().uuidString
            }
            Task { @MainActor in
                await model.refresh(taskID: taskID, store: store)
            }
        case "failed":
            inAppExecutionError = info[TaskScopedInAppIntentEvents.messageKey] as? String
                ?? "这次操作暂时没有进入后台执行。"
        default:
            break
        }
    }

    private func artifactSection(_ artifacts: [ArtifactSummary]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("产物")
                .font(.title3.bold())
            ForEach(artifacts, id: \.artifactID) { artifact in
                NavigationLink {
                    RuntimeArtifactDetailView(
                        taskID: taskID,
                        summary: artifact,
                        store: store
                    )
                } label: {
                    HStack(spacing: 10) {
                        if let scene = sceneAsset(for: artifact.kind) {
                            FlowerollSceneAssetView(scene: scene)
                                .frame(width: 34, height: 34)
                        } else {
                            Image(systemName: RuntimeArtifactPresentation.symbol(for: artifact.kind))
                                .foregroundStyle(.tint)
                                .frame(width: 34, height: 34)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(artifact.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(RuntimeArtifactPresentation.subtitle(for: artifact))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(13)
                    .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func headerMascotState(_ view: HostTaskView) -> FlowerollStateAsset? {
        switch presentationTruth(view).state {
        case .completed: return .done
        case .failed, .cancelled: return nil
        case .waiting, .paused, .needsUser: return .waiting
        case .active:
            if let active = view.timeline.last(where: {
                $0.isUserVisible && $0.presentationState.uppercased() == "ACTIVE"
            }) {
                return active.kind.uppercased() == "AGENT_ACTIVITY" ? .thinking : .working
            }
            return view.timeline.isEmpty ? .thinking : .working
        }
    }

    private func sceneAsset(for artifactKind: String) -> FlowerollSceneAsset? {
        // Keep production mapping conservative: only map Host artifact kinds that
        // are actually defined today. Future result/handoff semantics can enable
        // the remaining canonical scene assets without changing their artwork.
        switch artifactKind.lowercased() {
        case "email_draft": return .email
        default: return nil
        }
    }

    private func presentationTruth(_ view: HostTaskView) -> RuntimeTaskPresentationTruth {
        store.presentationTruth(taskID: taskID, view: view) ?? view.presentationTruth
    }

    private func statusLabel(_ view: HostTaskView) -> String {
        presentationTruth(view).statusLabel
    }

    private func statusColor(_ view: HostTaskView) -> Color {
        switch presentationTruth(view).state {
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .needsUser, .paused: return .orange
        case .active, .waiting: return themePalette.accent
        }
    }
}
