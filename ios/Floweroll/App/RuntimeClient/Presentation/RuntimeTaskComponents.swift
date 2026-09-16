import Observation
import SwiftUI


struct RuntimeTaskCard: View {
    let task: HostTaskIndexItem

    @Environment(\.flowerollThemePalette) private var themePalette

    var body: some View {
        HStack(spacing: 13) {
            FlowerollMascotView(state: mascotState, animated: !isTerminal, compact: true)
                .frame(width: 52, height: 46)
                .padding(.horizontal, 2)

            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(statusColor)
                    if let latest = task.latestTimeline?.title, !latest.isEmpty {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(latest)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(15)
        .background(.background, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.6)
        }
    }

    private var presentationTruth: RuntimeTaskPresentationTruth {
        task.presentationTruth
    }

    private var isTerminal: Bool {
        presentationTruth.isTerminal
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

    private var mascotState: FlowerollMascotState {
        switch presentationTruth.state {
        case .completed, .failed, .cancelled: return .done
        case .waiting, .paused, .needsUser: return .waiting
        case .active: return .working
        }
    }
}

struct RuntimePausedTaskCard: View {
    let view: HostTaskView
    let isRetrying: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("任务已暂停", systemImage: "pause.circle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            if RuntimeTaskRetryPolicy.canRetry(view) {
                Text("后台规划暂时中断，现有进度已经保留。重新尝试会从当前任务继续，不会把它当成一条新的输入。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button(action: onRetry) {
                    if isRetrying {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在重新尝试…")
                        }
                    } else {
                        Label("重新尝试", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRetrying)
                .accessibilityIdentifier("task.retry-paused")
            } else {
                Text("当前暂停不是临时规划故障。你可以补充或修改要求；小卷不会强行重试受限制的操作。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.orange.opacity(0.2), lineWidth: 0.8)
        }
    }
}


enum RuntimeHumanText {
    static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("\\n") {
            text = text.replacingOccurrences(of: "\\r\\n", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
        }
        return text
    }
}

struct RuntimeEmptyState: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
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
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct RuntimeConnectionBadge: View {
    let state: RuntimeConnectionState

    @Environment(\.flowerollThemePalette) private var themePalette

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var label: String {
        switch state {
        case .notConfigured: return "未连接"
        case .connecting: return "连接中"
        case .connected: return "后台在线"
        case .failed: return "后台异常"
        }
    }

    private var color: Color {
        switch state {
        case .connected: return .green
        case .connecting: return themePalette.accent
        case .failed: return .orange
        case .notConfigured: return .secondary
        }
    }
}
