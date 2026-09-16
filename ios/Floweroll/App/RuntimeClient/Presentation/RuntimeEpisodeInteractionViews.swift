import AppIntents
import Observation
import SwiftUI


struct RuntimeEpisodeInteractionCard: View {
    let taskID: String
    let interaction: HostPendingInteraction
    let store: RuntimeTaskStore
    let model: RuntimeTaskDetailModel
    @Binding var text: String

    @State private var interactionEventID = UUID().uuidString
    @State private var activeInAppEventID: String?
    @State private var inAppExecutionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("需要你", systemImage: "person.fill.questionmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)

            switch interaction {
            case let .clarification(id, question, options, acceptsText, _):
                Text(question).font(.headline)
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
                        beginInAppEvent()
                    })
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isSending || activeInAppEventID != nil)
                }
                if acceptsText {
                    input(intent: TaskScopedHouIntent.clarificationText(
                        taskID: taskID,
                        eventID: interactionEventID,
                        clarificationID: id,
                        text: text.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }

            case let .actionInput(id, attemptID, prompt, options, acceptsText, _, bindingDigest):
                Text(prompt).font(.headline)
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
                            beginInAppEvent()
                        })
                        .buttonStyle(.borderedProminent)

                        Button("取消") {
                            Task { _ = await model.respondToActionInput(
                                taskID: taskID, inputRequestID: id, bindingDigest: bindingDigest,
                                response: ["approved": .bool(false)], store: store
                            ) }
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
                            beginInAppEvent()
                        })
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isSending || activeInAppEventID != nil)
                    }
                    if acceptsText {
                        input(intent: TaskScopedHouIntent.actionInput(
                            taskID: taskID,
                            eventID: interactionEventID,
                            inputRequestID: id,
                            bindingDigest: bindingDigest,
                            response: ["text": .string(text.trimmingCharacters(in: .whitespacesAndNewlines))]
                        ))
                    }
                }
            }

            Divider()
            Button("取消整个任务", role: .destructive) {
                Task {
                    _ = await model.cancelUsingStore(
                        taskID: taskID,
                        store: store,
                        reason: "用户从待处理卡片取消整个任务"
                    )
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.isSending || activeInAppEventID != nil)
            .accessibilityIdentifier("task.pending.cancel")

            if let message = inAppExecutionError ?? model.cancellationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("task.pending.cancel-status")
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(Color.orange.opacity(0.2), lineWidth: 0.8) }
        .onReceive(NotificationCenter.default.publisher(for: TaskScopedInAppIntentEvents.notification)) { notification in
            handleInAppEvent(notification)
        }
    }

    private func input(intent: TaskScopedHouIntent) -> some View {
        HStack(spacing: 8) {
            TextField("补充信息", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            Button(intent: intent) {
                if activeInAppEventID == interactionEventID {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
            }
            .simultaneousGesture(TapGesture().onEnded {
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                beginInAppEvent()
            })
            .disabled(
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || model.isSending
                    || activeInAppEventID != nil
            )
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
              info[TaskScopedInAppIntentEvents.sourceTaskIDKey] as? String == taskID,
              info[TaskScopedInAppIntentEvents.eventIDKey] as? String == interactionEventID,
              let kind = info[TaskScopedInAppIntentEvents.kindKey] as? String
        else { return }

        activeInAppEventID = nil
        if kind == "accepted" {
            inAppExecutionError = nil
            text = ""
            interactionEventID = UUID().uuidString
            Task { @MainActor in
                await model.refresh(taskID: taskID, store: store)
            }
        } else if kind == "failed" {
            inAppExecutionError = info[TaskScopedInAppIntentEvents.messageKey] as? String
                ?? "这次操作暂时没有进入后台执行。"
        }
    }
}

struct RuntimeEpisodeArtifactLinks: View {
    let taskID: String
    let artifacts: [ArtifactSummary]
    let store: RuntimeTaskStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("这一轮的产物").font(.subheadline.weight(.semibold))
            ForEach(artifacts, id: \.artifactID) { artifact in
                NavigationLink {
                    RuntimeArtifactDetailView(taskID: taskID, summary: artifact, store: store)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "doc.text")
                        Text(artifact.title).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline)
                    .padding(11)
                    .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
