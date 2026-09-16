import AVFAudio
import AVFoundation
import ContactsUI
import SwiftUI
import UserNotifications


struct AppShellCompletionAttentionCard: View {
    let presentation: RuntimeCompletionAttentionPresentation
    let owner: RuntimeCompletionAttentionOwner
    let appIsActive: Bool
    let onViewTask: (String) -> Void

    @Environment(\.flowerollThemePalette) private var themePalette

    private var status: String { presentation.status.lowercased() }
    private var symbol: String {
        switch status {
        case "completed": return "checkmark"
        case "failed": return "exclamationmark"
        case "cancelled": return "xmark"
        default: return "checkmark"
        }
    }
    private var label: String {
        switch status {
        case "completed": return "后台任务已完成"
        case "failed": return "后台任务需要查看"
        case "cancelled": return "后台任务已取消"
        default: return "任务有新结果"
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(themePalette.accent.opacity(0.13))
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(themePalette.accent)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(presentation.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("查看") {
                switch owner.viewCurrent() {
                case .openTask(let taskID): onViewTask(taskID)
                case .none, .preserveExplicitTask: break
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .accessibilityIdentifier("app.completion-attention.view")

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                    _ = owner.dismissCurrent()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("暂时收起")
            .accessibilityIdentifier("app.completion-attention.dismiss")
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(themePalette.accent.opacity(0.16), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.08), radius: 14, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app.completion-attention")
        .accessibilityLabel("\(label)，\(presentation.title)")
        .task(id: "seen:\(presentation.taskID):\(appIsActive)") {
            guard appIsActive else { return }
            do {
                try await Task.sleep(for: .milliseconds(AppShellCompletionAttentionPolicy.meaningfulVisibleDelayMilliseconds))
            } catch { return }
            guard appIsActive, owner.currentTaskID == presentation.taskID else { return }
            owner.markPresented(taskID: presentation.taskID)
        }
        .task(id: "timeout:\(presentation.taskID):\(appIsActive)") {
            guard appIsActive else { return }
            do {
                try await Task.sleep(for: .seconds(AppShellCompletionAttentionPolicy.timeoutSeconds))
            } catch { return }
            guard appIsActive, owner.currentTaskID == presentation.taskID else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                _ = owner.timeoutCurrent()
            }
        }
    }
}
