import AVFAudio
import AVFoundation
import ContactsUI
import SwiftUI
import UserNotifications


private struct HomeFocusedTaskStage: View {
    let task: HostTaskIndexItem
    let store: RuntimeTaskStore

    @State private var model = RuntimeTaskDetailModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.flowerollThemePalette) private var themePalette

    private var timeline: [HostTimelineItem] {
        model.view?.timeline ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            NavigationLink {
                RuntimeCanonicalTaskDetailView(
                    taskID: task.taskID,
                    knownThreadID: task.threadID,
                    store: store,
                    onBringToHome: {}
                )
            } label: {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 7, height: 7)
                            Text(statusLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(statusColor)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }

                        Text(task.title)
                            .font(.system(size: 23, weight: .semibold, design: .rounded))
                            .tracking(-0.35)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let mascotState {
                        FlowerollAnimatedStateView(state: mascotState)
                            .id(mascotState)
                            .frame(width: 76, height: 76)
                            .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    }
                }
            }
            .buttonStyle(.plain)

            if let view = model.view {
                VStack(alignment: .leading, spacing: 0) {
                    let visibleTimeline = RuntimeTimelinePresentationPolicy.visibleItems(
                        view.timeline,
                        taskStatus: view.task.status,
                        structuredResult: RuntimeTaskStore.isTerminalStatus(view.task.status) ? view.result : nil
                    )
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
                    reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.48, dampingFraction: 0.88),
                    value: RuntimeTimelinePresentationPolicy.visibleItems(
                        view.timeline,
                        taskStatus: view.task.status,
                        structuredResult: RuntimeTaskStore.isTerminalStatus(view.task.status) ? view.result : nil
                    ).map { "\($0.timelineItemID):\($0.revision)" }
                )

                if let interaction = view.typedPendingInteraction {
                    NavigationLink {
                        RuntimeCanonicalTaskDetailView(
                    taskID: task.taskID,
                    knownThreadID: task.threadID,
                    store: store,
                    onBringToHome: {}
                )
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.fill.questionmark")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("需要你")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(interactionSummary(interaction))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(13)
                        .background(Color.orange.opacity(0.075), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                if !view.artifacts.isEmpty {
                    NavigationLink {
                        RuntimeCanonicalTaskDetailView(
                    taskID: task.taskID,
                    knownThreadID: task.threadID,
                    store: store,
                    onBringToHome: {}
                )
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                            Text("已生成 \(view.artifacts.count) 个产物")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else if model.isLoading {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    Text(task.latestTimeline?.title ?? "正在恢复任务…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            } else if let lastError = model.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let latest = task.latestTimeline {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(latest.title ?? "正在处理")
                            .font(.subheadline.weight(.semibold))
                        if let summary = latest.summary, !summary.isEmpty {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task(id: task.taskID) {
            model.start(taskID: task.taskID, store: store)
        }
        .onDisappear {
            model.stop()
        }
    }

    private var mascotState: FlowerollStateAsset? {
        if task.needsUser { return .waiting }
        if let view = model.view {
            if view.typedPendingInteraction != nil { return .waiting }
            switch view.task.status.lowercased() {
            case "completed": return .done
            case "failed", "cancelled": return nil
            case "waiting", "blocked": return .waiting
            default:
                if let active = view.timeline.last(where: {
                    $0.isUserVisible && $0.presentationState.uppercased() == "ACTIVE"
                }) {
                    return active.kind.uppercased() == "AGENT_ACTIVITY" ? .thinking : .working
                }
                return view.timeline.isEmpty ? .thinking : .working
            }
        }
        switch task.status.lowercased() {
        case "failed", "cancelled": return nil
        case "completed": return .done
        case "waiting", "blocked": return .waiting
        default:
            return task.latestTimeline == nil ? .thinking : .working
        }
    }

    private var statusLabel: String {
        if task.needsUser { return "需要你" }
        switch task.status.lowercased() {
        case "completed": return "已完成"
        case "failed": return "失败"
        case "cancelled": return "已取消"
        case "waiting": return "等待中"
        case "blocked": return "已暂停"
        default: return "正在处理"
        }
    }

    private var statusColor: Color {
        if task.needsUser { return .orange }
        switch task.status.lowercased() {
        case "completed": return .green
        case "failed": return .red
        case "cancelled": return .secondary
        case "waiting", "blocked": return .orange
        default: return themePalette.accent
        }
    }

    private func interactionSummary(_ interaction: HostPendingInteraction) -> String {
        switch interaction {
        case let .clarification(_, question, _, _, _):
            return question
        case let .actionInput(_, _, prompt, _, _, _, _):
            return prompt
        }
    }
}
