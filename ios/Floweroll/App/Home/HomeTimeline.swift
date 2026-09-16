import AVFAudio
import AVFoundation
import ContactsUI
import SwiftUI
import UserNotifications


struct HomeTimelineRow: View {
    let item: HostTimelineItem
    let isLast: Bool
    let taskID: String
    let store: RuntimeTaskStore
    let materials: TaskMaterialManifest?

    @Environment(\.flowerollThemePalette) private var themePalette

    var body: some View {
        Group {
            if isUserInput {
                HStack(alignment: .top) {
                    Spacer(minLength: 44)
                    VStack(alignment: .trailing, spacing: 6) {
                        if !messageAttachmentFiles.isEmpty {
                            TaskMessageAttachmentStrip(files: messageAttachmentFiles)
                        }
                        Text(userInputText)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .background(
                                themePalette.accent.opacity(0.09),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                        if localDeliveryState == "sending" {
                            Text("发送中…")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.trailing, 5)
                        }
                    }
                }
                .padding(.vertical, 5)
            } else if isActive {
                HStack(alignment: .top, spacing: 9) {
                    ZStack {
                        Circle()
                            .fill(themePalette.accent.opacity(0.10))
                        ProgressView()
                            .controlSize(.mini)
                            .tint(themePalette.accent)
                    }
                    .frame(width: 26, height: 26)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(RuntimeTimelinePresentationPolicy.title(for: item))
                            .font(.subheadline.weight(.semibold))
                        if let summary = RuntimeTimelinePresentationPolicy.summary(for: item) {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 11)
                .background(
                    themePalette.accent.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(themePalette.accent.opacity(0.14), lineWidth: 0.6)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .leading)))
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        ZStack {
                            Circle()
                                .fill(markerColor.opacity(0.1))
                                .frame(width: 22, height: 22)
                            Image(systemName: markerSymbol)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(markerColor)
                        }

                        if !isLast {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.13))
                                .frame(width: 1)
                                .frame(minHeight: 44)
                                .padding(.vertical, 3)
                        }
                    }
                    .frame(width: 22)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(RuntimeTimelinePresentationPolicy.title(for: item))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isCompletedPresentation ? Color.secondary : Color.primary)
                        if let summary = RuntimeTimelinePresentationPolicy.summary(for: item) {
                            Text(summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.bottom, isLast ? 0 : 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var isUserInput: Bool {
        item.kind.uppercased() == "USER_INPUT"
    }

    private var userInputText: String {
        let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return summary.isEmpty ? item.title : summary
    }

    private var attachmentIDs: [String] {
        guard case .array(let values) = item.payload["attachment_ids"] else { return [] }
        return values.compactMap(\.stringValue)
    }

    private var eventID: String? {
        item.payload["event_id"]?.stringValue
    }

    private var messageAttachmentFiles: [TaskMaterialFile] {
        materials?.userTurnMessageFiles(attachmentIDs: attachmentIDs, eventID: eventID) ?? []
    }

    private var localDeliveryState: String? {
        item.payload["local_delivery_state"]?.stringValue
    }

    private var isActive: Bool {
        item.presentationState.uppercased() == "ACTIVE"
    }

    private var isCompletedPresentation: Bool {
        item.presentationState.uppercased() == "COMPLETE"
    }

    private var markerColor: Color {
        switch item.presentationState.uppercased() {
        case "COMPLETE": return .green
        case "FAILED": return .red
        case "NEEDS_USER": return .orange
        case "INFO": return .secondary
        default: return themePalette.accent
        }
    }

    private var markerSymbol: String {
        switch item.presentationState.uppercased() {
        case "COMPLETE": return "checkmark"
        case "FAILED": return "xmark"
        case "NEEDS_USER": return "person.fill"
        case "INFO": return "info"
        default: return "circle.fill"
        }
    }
}

enum StatusTone {
    case neutral
    case success
    case warning
}

struct StatusNote: View {
    let text: String
    let icon: String
    let tone: StatusTone

    private var color: Color {
        switch tone {
        case .neutral: return .secondary
        case .success: return .green
        case .warning: return .orange
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
