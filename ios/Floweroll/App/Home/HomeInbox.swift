import AVFAudio
import AVFoundation
import ContactsUI
import SwiftUI
import UserNotifications


struct HomeResultInboxControl: View {
    let count: Int
    @Binding var isCollapsed: Bool
    let onOpen: () -> Void

    @Environment(\.flowerollThemePalette) private var themePalette

    var body: some View {
        Button {
            let opening = isCollapsed
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                isCollapsed.toggle()
            }
            if opening { onOpen() }
        } label: {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle()
                        .fill(.regularMaterial)
                    Circle()
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.6)
                    Image(systemName: count > 0 ? "tray.full.fill" : "tray")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(count > 0 ? Color.primary : Color.secondary)
                }
                .frame(width: 38, height: 38)
                .shadow(color: .black.opacity(0.035), radius: 8, y: 3)

                if count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            HomeInboxBadgePolicy.usesDarkForeground(accentRGB: themePalette.accentRGB)
                                ? Color.black
                                : Color.white
                        )
                        .padding(.horizontal, count > 9 ? 5 : 4)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(themePalette.accent, in: Capsule())
                        .offset(x: 5, y: -5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(count > 0 ? 1 : 0.72)
        .accessibilityIdentifier("home.inbox")
        .accessibilityLabel(
            isCollapsed ? "展开待确认收件箱" : "收起待确认收件箱"
        )
        .accessibilityValue(count == 0 ? "所有任务都已确认" : "\(count) 条待确认")
        .accessibilityHint(count == 0 ? "打开后会显示所有任务都已确认" : "只改变首页展示，不会确认任务")
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: count)
    }
}


struct HomeResultInboxView: View {
    let needsUserTasks: [HostTaskIndexItem]
    let runningTasks: [HostTaskIndexItem]
    let resultTasks: [HostTaskIndexItem]
    let store: RuntimeTaskStore
    @Binding var isExpanded: Bool
    @Binding var isCollapsed: Bool
    let ageLabel: (HostTaskIndexItem) -> String
    let onBringToHome: (HostTaskIndexItem) -> Void
    let onAcknowledgeAll: () -> Void

    private var primaryResults: [HostTaskIndexItem] { Array(resultTasks.prefix(2)) }
    private var backlogResults: [HostTaskIndexItem] { Array(resultTasks.dropFirst(primaryResults.count)) }
    private var totalCount: Int { needsUserTasks.count + runningTasks.count + resultTasks.count }

    var body: some View {
        Group {
            if isCollapsed { EmptyView() }
            else if totalCount == 0 {
                Label("现在没有其他任务", systemImage: "checkmark.circle")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(13).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 17))
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 7) {
                        Image("FlowerollDynamicIslandMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 15)
                            .accessibilityHidden(true)
                        Text("任务收件箱")
                            .font(.headline)
                        Text("\(totalCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !resultTasks.isEmpty {
                            Button("全部看过", action: onAcknowledgeAll)
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !needsUserTasks.isEmpty { sectionTitle("需要我处理", "person.crop.circle.badge.exclamationmark", .orange, needsUserTasks.count); rows(needsUserTasks) }
                    if !runningTasks.isEmpty { sectionTitle("正在进行", "arrow.trianglehead.2.clockwise.rotate.90", .accentColor, runningTasks.count); rows(runningTasks) }
                    if !primaryResults.isEmpty { sectionTitle("已完成待看", "checkmark.circle", .green, resultTasks.count); rows(primaryResults) }
                    if !backlogResults.isEmpty {
                        Button(isExpanded ? "收起其他结果" : "还有 \(backlogResults.count) 条已完成结果") { withAnimation { isExpanded.toggle() } }.font(.subheadline.weight(.medium)).buttonStyle(.plain).foregroundStyle(.secondary)
                        if isExpanded { rows(backlogResults) }
                    }
                }
                .padding(12)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 21))
                .overlay { RoundedRectangle(cornerRadius: 21).stroke(Color.primary.opacity(0.06), lineWidth: 0.6) }
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.9), value: (needsUserTasks + runningTasks + resultTasks).map(\.taskID))
        .accessibilityIdentifier("home.task-inbox")
    }

    @ViewBuilder private func rows(_ tasks: [HostTaskIndexItem]) -> some View {
        ForEach(tasks, id: \.taskID) { task in
            HomeInboxTaskRow(
                task: task,
                store: store,
                ageLabel: ageLabel(task),
                onBringToHome: { onBringToHome(task) }
            )
        }
    }
    private func sectionTitle(_ title: String, _ symbol: String, _ color: Color, _ count: Int) -> some View {
        HStack(spacing: 6) { Image(systemName: symbol).foregroundStyle(color); Text(title); Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary); Spacer() }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

enum HomeComposerExecutionStopPolicy {
    static func shouldOfferStop(for state: RuntimeTaskPresentationState?) -> Bool {
        state == .active
    }
}

enum HomeInboxTaskSection: Equatable {
    case needsUser
    case running
    case terminal
}

enum HomeInboxTaskPresentationPolicy {
    static func truth(for task: HostTaskIndexItem) -> RuntimeTaskPresentationTruth {
        task.presentationTruth
    }

    static func section(for task: HostTaskIndexItem) -> HomeInboxTaskSection {
        switch truth(for: task).state {
        case .needsUser:
            return .needsUser
        case .active, .waiting, .paused:
            return .running
        case .completed, .failed, .cancelled:
            return .terminal
        }
    }

    static func label(for task: HostTaskIndexItem) -> String {
        truth(for: task).statusLabel
    }
}

private struct HomeInboxTaskRow: View {
    let task: HostTaskIndexItem
    let store: RuntimeTaskStore
    let ageLabel: String
    let onBringToHome: () -> Void

    @Environment(\.flowerollThemePalette) private var themePalette

    private var presentationTruth: RuntimeTaskPresentationTruth {
        HomeInboxTaskPresentationPolicy.truth(for: task)
    }

    private var accentColor: Color {
        switch presentationTruth.state {
        case .failed: return .red
        case .cancelled: return .secondary
        case .completed: return .green
        case .needsUser, .paused: return .orange
        case .active, .waiting: return themePalette.accent
        }
    }

    private var symbol: String {
        switch presentationTruth.state {
        case .failed: return "exclamationmark"
        case .cancelled: return "xmark"
        case .completed: return "checkmark"
        case .needsUser: return "person.fill.questionmark"
        case .waiting: return "clock"
        case .paused: return "pause.circle.fill"
        case .active: return "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }

    private var label: String {
        HomeInboxTaskPresentationPolicy.label(for: task)
    }

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(accentColor.opacity(0.1))
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(accentColor)
            }
            .frame(width: 30, height: 30)

            NavigationLink {
                RuntimeCanonicalTaskDetailView(
                    taskID: task.taskID,
                    knownThreadID: task.threadID,
                    store: store,
                    onBringToHome: onBringToHome
                )
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        Text(label).foregroundStyle(accentColor)
                        Text("·").foregroundStyle(.tertiary)
                        Text(ageLabel).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(minHeight: 68)
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .accessibilityIdentifier("home.inbox.row.\(task.taskID)")
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(accentColor.opacity(0.1), lineWidth: 0.55)
        }
    }
}
