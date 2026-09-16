import Observation
import SwiftUI



enum RuntimeTimelinePresentationPolicy {
    private static let genericTitles: Set<String> = ["处理方式已找到", "已找到处理方式"]

    static func visibleItems(
        _ items: [HostTimelineItem],
        taskStatus: String,
        hideCompletedToolRowsWhenWorkSummaryExists: Bool = false,
        structuredResult: JSONValue? = nil
    ) -> [HostTimelineItem] {
        let terminal = RuntimeTaskStore.isTerminalStatus(taskStatus)
        var output: [HostTimelineItem] = []
        for item in items where item.isUserVisible {
            let kind = item.kind.uppercased()
            let state = item.presentationState.uppercased()
            if kind == "PUBLIC_WORKLOG", item.title == "任务已交给小卷" { continue }
            if terminal, state == "ACTIVE" { continue }
            if taskStatus.lowercased() == "completed",
               kind == "RESULT",
               state == "COMPLETE",
               let structuredResult,
               terminalResultMatchesStructuredResult(item, result: structuredResult) {
                continue
            }
            if kind == "TOOL_ACTIVITY", state == "COMPLETE", genericTitles.contains(item.title) { continue }
            if hideCompletedToolRowsWhenWorkSummaryExists, kind == "TOOL_ACTIVITY", state == "COMPLETE" { continue }
            if let last = output.last,
               genericStrategy(last), genericStrategy(item),
               last.presentationState == item.presentationState { continue }
            output.append(item)
        }
        return output
    }

    private static func terminalResultMatchesStructuredResult(
        _ item: HostTimelineItem,
        result: JSONValue
    ) -> Bool {
        let resultTexts = structuredResultTexts(result)
        guard !resultTexts.isEmpty else { return false }
        let timelineTexts = [item.title, item.summary]
            .compactMap { $0 }
            .map(normalizedComparableText)
            .filter { !$0.isEmpty }
        return timelineTexts.contains(where: resultTexts.contains)
    }

    private static func structuredResultTexts(_ result: JSONValue) -> Set<String> {
        var values: [String] = []
        if case let .string(text) = result {
            values.append(text)
        }
        if let object = result.objectValue,
           let summary = object["summary"]?.stringValue {
            values.append(summary)
        }
        let presentation = RuntimeStructuredResultPresentation.make(from: result)
        if let lead = presentation.lead { values.append(lead) }
        values.append(contentsOf: presentation.sections.map(\.body))
        values.append(contentsOf: presentation.checklist.map(\.text))
        values.append(contentsOf: presentation.facts.map(\.value))
        return Set(values.map(normalizedComparableText).filter { !$0.isEmpty })
    }

    private static func normalizedComparableText(_ raw: String) -> String {
        RuntimeHumanText.normalize(raw)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func title(for item: HostTimelineItem) -> String {
        switch item.title {
        case "正在选择合适的处理方式": return "正在确定下一步"
        case "处理方式已找到", "已找到处理方式": return "已确定下一步"
        case "小卷正在思考下一步": return "正在根据最新结果安排下一步"
        default: return RuntimeHumanText.normalize(item.title)
        }
    }

    static func summary(for item: HostTimelineItem) -> String? {
        guard let raw = item.summary else { return nil }
        let text = RuntimeHumanText.normalize(raw)
        return text.isEmpty ? nil : text
    }

    private static func genericStrategy(_ item: HostTimelineItem) -> Bool {
        ["正在选择合适的处理方式", "处理方式已找到", "已找到处理方式"].contains(item.title)
    }
}

struct RuntimeTimelineRow: View {
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
                    Spacer(minLength: 38)
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
                        Text(Self.shortTime(item.updatedAt))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .padding(.trailing, 5)
                    }
                }
                .padding(.vertical, 5)
            } else if isActive {
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(themePalette.accent.opacity(0.11))
                        ProgressView()
                            .controlSize(.mini)
                            .tint(themePalette.accent)
                    }
                    .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(RuntimeTimelinePresentationPolicy.title(for: item))
                                .font(.body.weight(.semibold))
                            Spacer(minLength: 8)
                            Text(Self.shortTime(item.updatedAt))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        if let summary = RuntimeTimelinePresentationPolicy.summary(for: item) {
                            Text(summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(13)
                .background(
                    themePalette.accent.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(themePalette.accent.opacity(0.14), lineWidth: 0.7)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .topLeading)))
            } else {
                HStack(alignment: .top, spacing: 13) {
                    VStack(spacing: 0) {
                        ZStack {
                            Circle()
                                .fill(markerColor.opacity(0.12))
                            Image(systemName: markerSymbol)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(markerColor)
                        }
                        .frame(width: 28, height: 28)

                        if !isLast {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.18))
                                .frame(width: 1.3)
                                .frame(minHeight: 52)
                                .padding(.vertical, 3)
                        }
                    }
                    .frame(width: 28)

                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(RuntimeTimelinePresentationPolicy.title(for: item))
                                .font(.body.weight(.semibold))
                                .foregroundStyle(isCompletedPresentation ? Color.secondary : Color.primary)
                            Spacer(minLength: 8)
                            Text(Self.shortTime(item.updatedAt))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        if let summary = RuntimeTimelinePresentationPolicy.summary(for: item) {
                            Text(summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.bottom, isLast ? 0 : 22)
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

    private static func shortTime(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return "" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}
