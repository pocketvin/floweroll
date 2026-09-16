import AVFAudio
import AVFoundation
import ContactsUI
import SwiftUI
import UserNotifications


private struct FlowerollTaskEmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 9) {
            FlowerollAnimatedStateView(state: .idle)
                .frame(width: 76, height: 76)
                .padding(.bottom, 2)

            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 18)
    }
}

struct MinimalRuntimeTaskCard: View {
    let task: HostTaskIndexItem
    let episodeCount: Int
    var showsPendingReviewBadge = false
    var showsTimestamp = false

    @Environment(\.flowerollThemePalette) private var themePalette

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.09))
                    .frame(width: 36, height: 36)
                Image(systemName: statusSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(statusLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(statusColor)
                    if episodeCount > 1 {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text("\(episodeCount) 轮")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let latest = task.latestTimeline?.title, !latest.isEmpty {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(latest)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if showsTimestamp, let timestamp = taskTimestamp {
                    Text(timestamp)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(15)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.55)
        }
        .overlay(alignment: .topTrailing) {
            if showsPendingReviewBadge {
                Circle()
                    .fill(themePalette.accent.opacity(0.58))
                    .frame(width: 7, height: 7)
                    .overlay {
                        Circle()
                            .stroke(themePalette.strongAccent.opacity(0.16), lineWidth: 0.5)
                    }
                    .padding(.top, 10)
                    .padding(.trailing, 10)
                    .accessibilityLabel("待看")
                    .accessibilityIdentifier("tasks.history.pending-review.\(task.taskID)")
            }
        }
    }

    private var taskTimestamp: String? {
        guard let date = RuntimeTaskStore.hostDate(task.createdAt) else { return nil }
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "今天 \(time)" }
        if calendar.isDateInYesterday(date) { return "昨天 \(time)" }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private var presentationTruth: RuntimeTaskPresentationTruth {
        task.presentationTruth
    }

    private var statusLabel: String {
        presentationTruth.statusLabel
    }

    private var statusColor: Color {
        switch presentationTruth.state {
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .needsUser, .paused: return .orange
        case .active, .waiting: return themePalette.accent
        }
    }

    private var statusSymbol: String {
        switch presentationTruth.state {
        case .completed: return "checkmark"
        case .failed: return "exclamationmark"
        case .cancelled: return "xmark"
        case .waiting: return "clock"
        case .paused: return "pause.circle"
        case .needsUser: return "person.fill.questionmark"
        case .active: return "circle.dotted"
        }
    }
}


struct ObservationTaskHistoryCard: View {
    let record: ObservationSessionRecord
    @Environment(\.flowerollThemePalette) private var themePalette

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(themePalette.accent.opacity(0.10))
                    .frame(width: 36, height: 36)
                Image(systemName: "eye")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(themePalette.strongAccent)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(statusLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(statusColor)
                    Text("·").foregroundStyle(.tertiary)
                    Text(sourceSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(timestamp)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(15)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.55)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("观察记录，" + title + "，" + statusLabel)
    }

    private var title: String {
        record.hostView?.notes.last(where: { $0.kind == "final" })?.title
            ?? record.hostView?.notes.last?.title
            ?? record.configuration.preset.title + "观察"
    }

    private var statusLabel: String {
        if hasFullyCoveredSummary { return "整理完成" }
        if record.phase == .finalizing || record.hostView?.status == "finalizing" { return "正在整理" }
        if record.hostView?.status == "analysis_failed" { return "整理未完成" }
        return "观察记录"
    }

    private var statusColor: Color {
        if hasFullyCoveredSummary { return .green }
        if record.hostView?.status == "analysis_failed" { return .orange }
        if record.phase == .finalizing || record.hostView?.status == "finalizing" { return themePalette.accent }
        return .green
    }

    private var hasFullyCoveredSummary: Bool {
        guard record.hasEnded,
              let hostView = record.hostView,
              !hostView.notes.isEmpty else { return false }
        return hostView.summaryThroughSeq >= hostView.eventCount
    }

    private var sourceSummary: String {
        record.configuration.sources.map { source in
            switch source {
            case .screen: return "屏幕画面"
            case .ambientMicrophone: return "周围声音"
            case .deviceAudio: return "屏幕语音"
            }
        }.joined(separator: " · ")
    }

    private var timestamp: String {
        guard let date = RuntimeTaskStore.hostDate(record.configuration.createdAt) else {
            return record.configuration.createdAt.prefix(16).replacingOccurrences(of: "T", with: " ")
        }
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "今天 " + time }
        if Calendar.current.isDateInYesterday(date) { return "昨天 " + time }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}


private struct TaskListRowChrome: ViewModifier {
    let verticalInset: CGFloat

    func body(content: Content) -> some View {
        content
            .listRowInsets(
                EdgeInsets(
                    top: verticalInset,
                    leading: 18,
                    bottom: verticalInset,
                    trailing: 18
                )
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

extension View {
    func taskListRowChrome(verticalInset: CGFloat = 7) -> some View {
        modifier(TaskListRowChrome(verticalInset: verticalInset))
    }
}
