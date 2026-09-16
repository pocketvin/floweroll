import Observation
import SwiftUI



@MainActor
@Observable
private final class RuntimeArtifactDetailModel {
    private(set) var artifact: HostArtifact?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var lastError: String?

    func load(taskID: String, artifactID: String, store: RuntimeTaskStore) async {
        isLoading = artifact == nil
        defer { isLoading = false }
        do {
            let client = try store.makeClient()
            artifact = try await client.fetchArtifact(taskID: taskID, artifactID: artifactID)
            lastError = nil
        } catch {
            lastError = RuntimeTaskStore.userMessage(for: error)
        }
    }

    func save(
        taskID: String,
        artifactID: String,
        expectedRevisionID: String,
        content: [String: JSONValue],
        store: RuntimeTaskStore
    ) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let client = try store.makeClient()
            artifact = try await client.editArtifact(
                taskID: taskID,
                artifactID: artifactID,
                expectedRevisionID: expectedRevisionID,
                content: content
            )
            lastError = nil
            await store.refresh()
            return true
        } catch {
            lastError = RuntimeTaskStore.userMessage(for: error)
            return false
        }
    }
}

struct RuntimeArtifactDetailView: View {
    let taskID: String
    let summary: ArtifactSummary
    let store: RuntimeTaskStore

    @Environment(\.flowerollThemePalette) private var themePalette
    @State private var model = RuntimeArtifactDetailModel()
    @State private var showingEditor = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            if let artifact = model.artifact,
               let revision = artifact.currentRevision {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        artifactHeader(artifact, revision: revision)

                        if artifact.kind.lowercased() == "email_draft" {
                            RuntimeEmailArtifactCard(content: revision.content ?? [:])
                        } else {
                            RuntimeGenericArtifactCard(
                                kind: artifact.kind,
                                content: revision.content ?? [:]
                            )
                        }

                        if artifact.revisions.count > 1 {
                            revisionHistory(artifact)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 36)
                }
                .refreshable {
                    await model.load(
                        taskID: taskID,
                        artifactID: summary.artifactID,
                        store: store
                    )
                }
            } else if model.isLoading {
                ProgressView("正在读取产物…")
            } else {
                RuntimeEmptyState(
                    title: "暂时无法读取产物",
                    message: model.lastError ?? "后台没有返回可显示的产物内容。",
                    symbol: "doc.text.magnifyingglass"
                )
                .padding(.horizontal, 18)
            }
        }
        .navigationTitle(summary.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let shareText = artifactShareText {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: shareText, subject: Text(summary.title)) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("artifact-share")
                }
            }
            if model.artifact?.kind.lowercased() == "email_draft",
               model.artifact?.currentRevision != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("编辑") {
                        showingEditor = true
                    }
                    .disabled(model.isSaving)
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            if let artifact = model.artifact,
               let revision = artifact.currentRevision {
                RuntimeEmailArtifactEditorView(
                    taskID: taskID,
                    artifact: artifact,
                    revision: revision,
                    store: store,
                    model: model
                )
            }
        }
        .overlay(alignment: .bottom) {
            if let error = model.lastError, model.artifact != nil {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 10)
            }
        }
        .task(id: summary.artifactID) {
            await model.load(
                taskID: taskID,
                artifactID: summary.artifactID,
                store: store
            )
        }
    }

    private var artifactShareText: String? {
        guard let artifact = model.artifact,
              let revision = artifact.currentRevision else { return nil }
        let content = revision.content ?? [:]
        let body = RuntimeArtifactPresentation.firstText(
            in: content,
            keys: ["body", "text", "content", "markdown", "summary", "description"]
        )
        let recipient = RuntimeArtifactPresentation.recipient(in: content)
        let subject = RuntimeArtifactPresentation.text(content["subject"])
        let parts = [
            artifact.title,
            recipient.map { "收件人：" + $0 },
            subject.map { "主题：" + $0 },
            body.map(RuntimeHumanText.normalize),
        ].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private func artifactHeader(
        _ artifact: HostArtifact,
        revision: HostArtifactRevision
    ) -> some View {
        HStack(alignment: .center, spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(themePalette.accent.opacity(0.09))
                Image(systemName: RuntimeArtifactPresentation.symbol(for: artifact.kind))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(RuntimeArtifactPresentation.label(for: artifact.kind))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(artifact.title)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
            Text("第 \(revision.revisionNumber) 版")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.08), in: Capsule())
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func revisionHistory(_ artifact: HostArtifact) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("版本")
                .font(.headline)

            ForEach(artifact.revisions.sorted { $0.revisionNumber > $1.revisionNumber }) { revision in
                HStack(spacing: 9) {
                    Image(systemName: revision.revisionID == artifact.currentRevisionID ? "checkmark.circle.fill" : "clock.arrow.circlepath")
                        .foregroundStyle(revision.revisionID == artifact.currentRevisionID ? Color.green : Color.secondary)
                    Text("第 \(revision.revisionNumber) 版")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(Self.shortDate(revision.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(15)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private static func shortDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return "" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct RuntimeEmailArtifactCard: View {
    let content: [String: JSONValue]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("邮件草稿", systemImage: "envelope.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 14)

            if let recipient = RuntimeArtifactPresentation.recipient(in: content), !recipient.isEmpty {
                RuntimeArtifactMetadataRow(label: "收件人", value: recipient)
                Divider().padding(.vertical, 10)
            }

            if let subject = RuntimeArtifactPresentation.text(content["subject"]), !subject.isEmpty {
                RuntimeArtifactMetadataRow(label: "主题", value: subject)
                Divider().padding(.vertical, 14)
            }

            let bodyText = RuntimeArtifactPresentation.firstText(
                in: content,
                keys: ["body", "text", "content", "markdown"]
            ) ?? ""
            Text(bodyText.isEmpty ? "正文为空" : bodyText)
                .font(.body)
                .foregroundStyle(bodyText.isEmpty ? .secondary : .primary)
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.6)
        }
    }
}

private struct RuntimeGenericArtifactCard: View {
    let kind: String
    let content: [String: JSONValue]

    var body: some View {
        let preview = RuntimeArtifactPresentation.firstText(
            in: content,
            keys: ["body", "text", "content", "markdown", "summary", "description"]
        )

        VStack(alignment: .leading, spacing: 12) {
            Label(
                RuntimeArtifactPresentation.label(for: kind),
                systemImage: RuntimeArtifactPresentation.symbol(for: kind)
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            Text(preview?.isEmpty == false ? preview! : "这个产物暂时没有可直接预览的正文。")
                .font(.body)
                .foregroundStyle(preview?.isEmpty == false ? .primary : .secondary)
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.6)
        }
    }
}

private struct RuntimeArtifactMetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RuntimeEmailArtifactEditorView: View {
    let taskID: String
    let artifact: HostArtifact
    let revision: HostArtifactRevision
    let store: RuntimeTaskStore
    let model: RuntimeArtifactDetailModel

    @Environment(\.dismiss) private var dismiss
    @State private var subject: String
    @State private var bodyText: String
    @State private var recipientText: String
    @State private var isSaving = false

    private let originalContent: [String: JSONValue]
    private let recipientKey: String?

    init(
        taskID: String,
        artifact: HostArtifact,
        revision: HostArtifactRevision,
        store: RuntimeTaskStore,
        model: RuntimeArtifactDetailModel
    ) {
        self.taskID = taskID
        self.artifact = artifact
        self.revision = revision
        self.store = store
        self.model = model

        let content = revision.content ?? [:]
        originalContent = content
        let detectedRecipientKey = RuntimeArtifactPresentation.recipientKeys.first { content[$0] != nil }
        recipientKey = detectedRecipientKey
        _subject = State(initialValue: RuntimeArtifactPresentation.text(content["subject"]) ?? "")
        _bodyText = State(
            initialValue: RuntimeArtifactPresentation.firstText(
                in: content,
                keys: ["body", "text", "content", "markdown"]
            ) ?? ""
        )
        _recipientText = State(initialValue: RuntimeArtifactPresentation.recipient(in: content) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("邮件") {
                    if recipientKey != nil {
                        TextField("收件人", text: $recipientText, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    TextField("主题", text: $subject, axis: .vertical)
                }

                Section("正文") {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 220)
                }

                if let error = model.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("编辑邮件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中…" : "保存") {
                        save()
                    }
                    .disabled(isSaving || model.isSaving || !hasChanges)
                }
            }
            .interactiveDismissDisabled(isSaving || model.isSaving)
        }
    }

    private var hasChanges: Bool {
        editedContent != originalContent
    }

    private var editedContent: [String: JSONValue] {
        var content = originalContent
        content["subject"] = .string(subject.trimmingCharacters(in: .whitespacesAndNewlines))

        if content["body"] != nil || (content["text"] == nil && content["content"] == nil && content["markdown"] == nil) {
            content["body"] = .string(bodyText)
        } else if content["text"] != nil {
            content["text"] = .string(bodyText)
        } else if content["content"] != nil {
            content["content"] = .string(bodyText)
        } else if content["markdown"] != nil {
            content["markdown"] = .string(bodyText)
        }

        if let recipientKey {
            content[recipientKey] = RuntimeArtifactPresentation.editedRecipientValue(
                recipientText,
                preservingShapeOf: originalContent[recipientKey]
            )
        }
        return content
    }

    private func save() {
        guard !isSaving, !model.isSaving, hasChanges else { return }
        isSaving = true
        let content = editedContent
        Task { @MainActor in
            let saved = await model.save(
                taskID: taskID,
                artifactID: artifact.artifactID,
                expectedRevisionID: revision.revisionID,
                content: content,
                store: store
            )
            isSaving = false
            if saved {
                dismiss()
            }
        }
    }
}

enum RuntimeArtifactPresentation {
    static let recipientKeys = ["to", "recipient", "recipients"]

    static func label(for kind: String) -> String {
        switch kind.lowercased() {
        case "email_draft": return "邮件草稿"
        case "email": return "邮件"
        case "report": return "报告"
        case "itinerary": return "行程"
        case "table": return "表格"
        case "file": return "文件"
        case "code": return "代码"
        case "image": return "图片"
        default: return "产物"
        }
    }

    static func symbol(for kind: String) -> String {
        switch kind.lowercased() {
        case "email_draft", "email": return "envelope"
        case "report": return "doc.richtext"
        case "itinerary": return "map"
        case "table": return "tablecells"
        case "code": return "chevron.left.forwardslash.chevron.right"
        case "image": return "photo"
        default: return "doc.text"
        }
    }

    static func subtitle(for artifact: ArtifactSummary) -> String {
        if let revision = artifact.currentRevisionNumber, revision > 0 {
            return "\(label(for: artifact.kind)) · 第 \(revision) 版"
        }
        return label(for: artifact.kind)
    }

    static func text(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case let .string(text):
            return text
        case let .number(number):
            return number.formatted()
        case let .bool(flag):
            return flag ? "是" : "否"
        case let .array(values):
            let parts = values.compactMap { text($0) }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        case .object, .null:
            return nil
        }
    }

    static func firstText(in content: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = text(content[key]), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func recipient(in content: [String: JSONValue]) -> String? {
        firstText(in: content, keys: recipientKeys)
    }

    static func editedRecipientValue(
        _ text: String,
        preservingShapeOf original: JSONValue?
    ) -> JSONValue {
        switch original {
        case .array:
            let recipients = text
                .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "，" || $0 == "；" || $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map(JSONValue.string)
            return .array(recipients)
        default:
            return .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

extension HostArtifact {
    var currentRevision: HostArtifactRevision? {
        if let currentRevisionID,
           let exact = revisions.first(where: { $0.revisionID == currentRevisionID }) {
            return exact
        }
        return revisions.max { $0.revisionNumber < $1.revisionNumber }
    }
}
