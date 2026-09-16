import Observation
import SwiftUI


// MARK: - Developer observability

private enum DeveloperObservabilityPresentation {
    static func statusLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "active", "executing": return "进行中"
        case "completed", "succeeded", "success", "committed": return "已完成"
        case "waiting": return "等待中"
        case "blocked": return "已暂停"
        case "cancelled": return "已取消"
        case "failed", "error": return "失败"
        case "in_flight": return "处理中"
        default: return raw
        }
    }

    static func color(_ raw: String) -> Color {
        switch raw.lowercased() {
        case "completed", "succeeded", "success", "committed": return .green
        case "blocked", "waiting": return .orange
        case "failed", "error": return .red
        case "cancelled": return .secondary
        default: return .accentColor
        }
    }

    static func milliseconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value < 1_000 { return "\(Int(value.rounded())) ms" }
        if value < 60_000 { return String(format: "%.1f 秒", value / 1_000) }
        return "\(Int(value / 60_000)) 分 \(Int(value.truncatingRemainder(dividingBy: 60_000) / 1_000)) 秒"
    }

    static func bytes(_ value: Int?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    static func timestamp(_ raw: String?) -> String {
        guard let raw, let date = RuntimeTaskStore.hostDate(raw) else { return raw ?? "—" }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
    }

    static func json(_ value: JSONValue?) -> String {
        guard let value else { return "没有记录到该内容。" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }

    static func json(_ value: [String: JSONValue]) -> String {
        json(.object(value))
    }

    static func evidenceSummary(_ item: HostDeveloperTaskOverview.Evidence) -> String {
        guard let object = item.data.objectValue else { return json(item.data) }
        for key in ["error", "error_type", "reason", "wait_reason"] {
            if let value = object[key]?.stringValue, !value.isEmpty { return value }
        }
        return json(item.data)
    }
}

struct DeveloperObservabilityTaskListView: View {
    let store: RuntimeTaskStore

    @AppStorage("floweroll.developerMode") private var developerMode = false
    @State private var tasks: [HostDeveloperTaskSummary] = []
    @State private var status: HostDeveloperObservabilityStatus?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if !developerMode {
                ContentUnavailableView(
                    "开发者模式已关闭",
                    systemImage: "ladybug",
                    description: Text("回到设置打开开发者模式后再查看 Agent 调试信息。")
                )
            } else {
                List {
                    Section {
                        Label("只读观察，不会重新执行模型或 Tool，也不会修改 Task 状态。", systemImage: "eye")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let status {
                            LabeledContent("采集模式", value: status.captureMode == "local_full" ? "本机完整采集" : status.captureMode)
                            LabeledContent("完整请求", value: status.fullCaptureAvailable ? "可查看" : "未启用")
                        }
                    }

                    if isLoading && tasks.isEmpty {
                        HStack { Spacer(); ProgressView("正在读取 Agent Trace…"); Spacer() }
                    } else if tasks.isEmpty {
                        ContentUnavailableView(
                            "暂时没有可查看任务",
                            systemImage: "waveform.path.ecg",
                            description: Text(errorMessage ?? "Host 没有返回开发者观测任务。")
                        )
                    } else {
                        Section("最近任务 · \(tasks.count)") {
                            ForEach(tasks) { task in
                                NavigationLink {
                                    DeveloperTaskObservabilityView(taskID: task.taskID, store: store)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(task.goal)
                                            .font(.body.weight(.medium))
                                            .lineLimit(3)
                                        HStack(spacing: 7) {
                                            Circle()
                                                .fill(DeveloperObservabilityPresentation.color(task.status))
                                                .frame(width: 6, height: 6)
                                            Text(DeveloperObservabilityPresentation.statusLabel(task.status))
                                            if let calls = task.plannerCalls {
                                                Text("· Planner \(calls)")
                                            }
                                            Text("· Tool \(task.actionCount)")
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        Text(DeveloperObservabilityPresentation.timestamp(task.updatedAt))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 3)
                                }
                                .accessibilityIdentifier("developer.observability.task.\(task.taskID)")
                            }
                        }
                    }

                    if let errorMessage, !tasks.isEmpty {
                        Section("状态") {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .refreshable { await refresh() }
            }
        }
        .navigationTitle("Agent 调试")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: developerMode) {
            guard developerMode else { return }
            await refresh()
        }
    }

    @MainActor
    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await store.makeClient().fetchDeveloperTaskIndex(limit: 40)
            tasks = result.tasks
            status = result.status
            errorMessage = nil
        } catch {
            errorMessage = RuntimeTaskStore.userMessage(for: error)
        }
    }
}

struct DeveloperTaskObservabilityView: View {
    let taskID: String
    let store: RuntimeTaskStore

    @AppStorage("floweroll.developerMode") private var developerMode = false
    @State private var overview: HostDeveloperTaskOverview?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if !developerMode {
                ContentUnavailableView(
                    "开发者模式已关闭",
                    systemImage: "ladybug",
                    description: Text("这页只在开发者模式中提供。")
                )
            } else if let overview {
                List {
                    Section("任务") {
                        Text(overview.task.goal)
                            .font(.body.weight(.medium))
                            .textSelection(.enabled)
                        LabeledContent("状态", value: DeveloperObservabilityPresentation.statusLabel(overview.task.status))
                        if let phase = overview.task.phase { LabeledContent("Runtime Phase", value: phase) }
                        LabeledContent("Task ID", value: String(overview.task.taskID.prefix(8)))
                            .font(.caption.monospaced())
                        if let reason = overview.task.blockReason {
                            LabeledContent("暂停原因", value: reason)
                                .foregroundStyle(.orange)
                        }
                    }

                    Section("概览") {
                        LabeledContent("Planner", value: "\(overview.summary.plannerCalls) 次")
                        LabeledContent("Tool Action", value: "\(overview.summary.actions) 次")
                        LabeledContent("已报告 Token", value: overview.summary.reportedTokensOnly.formatted())
                        LabeledContent("模型耗时累计", value: DeveloperObservabilityPresentation.milliseconds(overview.summary.modelMSSum))
                        LabeledContent("完整请求", value: "\(overview.summary.fullCapturedCalls) / \(overview.summary.plannerCalls)")
                        Text(overview.summary.costNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("Planner") {
                        if overview.plannerCalls.isEmpty {
                            Text("这条任务没有 Planner 调用记录。")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(overview.plannerCalls) { call in
                            NavigationLink {
                                DeveloperPlannerCallView(
                                    taskID: taskID,
                                    call: call,
                                    store: store
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("Planner #\(call.callNumber)")
                                            .font(.body.weight(.semibold))
                                        Spacer()
                                        Text(DeveloperObservabilityPresentation.milliseconds(call.durationMS))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    HStack(spacing: 7) {
                                        Text(DeveloperObservabilityPresentation.statusLabel(call.outcome))
                                            .foregroundStyle(DeveloperObservabilityPresentation.color(call.outcome))
                                        if let model = call.providerModel { Text("· \(model)") }
                                        if let tokens = call.totalTokens { Text("· \(tokens.formatted()) tokens") }
                                    }
                                    .font(.caption)
                                    Text(call.captureAvailable ? "实际请求可查看" : "完整请求未采集")
                                        .font(.caption2)
                                        .foregroundStyle(call.captureAvailable ? Color.secondary : Color.orange)
                                }
                                .padding(.vertical, 3)
                            }
                            .accessibilityIdentifier("developer.observability.planner.\(call.callNumber)")
                        }
                    }

                    if !overview.actions.isEmpty {
                        Section("Tools / Actions") {
                            ForEach(overview.actions) { action in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(action.actionType)
                                            .font(.subheadline.monospaced())
                                        Spacer()
                                        Text(DeveloperObservabilityPresentation.statusLabel(action.status))
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(DeveloperObservabilityPresentation.color(action.status))
                                    }
                                    Text("Step \(action.stepIndex) · Attempt \(action.attemptCount)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    if let error = action.errorText, !error.isEmpty {
                                        Text(error)
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                            .textSelection(.enabled)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    Section("异常与恢复证据") {
                        if overview.evidence.isEmpty {
                            Text("没有记录到当前覆盖类型的失败 / 恢复事件。这不代表全链路已经验收。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(overview.evidence) { item in
                                NavigationLink {
                                    DeveloperObservabilityTextView(
                                        title: item.eventType,
                                        text: DeveloperObservabilityPresentation.json(item.data)
                                    )
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.eventType)
                                            .font(.subheadline.monospaced())
                                        Text(DeveloperObservabilityPresentation.evidenceSummary(item))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(3)
                                        Text(DeveloperObservabilityPresentation.timestamp(item.createdAt))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }

                    Section("边界") {
                        ForEach(overview.observability.limitations, id: \.self) { limitation in
                            Label(limitation, systemImage: "info.circle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .refreshable { await refresh() }
            } else if isLoading {
                ProgressView("正在读取开发者信息…")
            } else {
                ContentUnavailableView(
                    "暂时无法读取开发者信息",
                    systemImage: "ladybug",
                    description: Text(errorMessage ?? "Host 没有返回这条任务的观测数据。")
                )
            }
        }
        .navigationTitle("开发者信息")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: taskID + ":" + String(developerMode)) {
            guard developerMode else { return }
            await refresh()
        }
    }

    @MainActor
    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            overview = try await store.makeClient().fetchDeveloperTaskOverview(taskID: taskID)
            errorMessage = nil
        } catch {
            errorMessage = RuntimeTaskStore.userMessage(for: error)
        }
    }
}

private struct DeveloperPlannerCallView: View {
    let taskID: String
    let call: HostDeveloperTaskOverview.PlannerCall
    let store: RuntimeTaskStore

    @AppStorage("floweroll.developerMode") private var developerMode = false
    @State private var detail: HostDeveloperPlannerCallDetail?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Planner #\(call.callNumber)") {
                LabeledContent("状态", value: DeveloperObservabilityPresentation.statusLabel(call.outcome))
                LabeledContent("总耗时", value: DeveloperObservabilityPresentation.milliseconds(call.durationMS))
                LabeledContent("模型耗时", value: DeveloperObservabilityPresentation.milliseconds(call.modelMS))
                if let model = call.providerModel { LabeledContent("模型", value: model) }
                if let tokens = call.totalTokens { LabeledContent("Token", value: tokens.formatted()) }
                if let detail {
                    LabeledContent("请求大小", value: DeveloperObservabilityPresentation.bytes(detail.metadata.requestBytes))
                }
            }

            if let detail {
                Section {
                    Text(detail.note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if detail.available {
                    Section("实际输入") {
                        if let prompt = detail.systemPrompt {
                            NavigationLink("System Prompt") {
                                DeveloperObservabilityTextView(title: "System Prompt", text: prompt)
                            }
                        }
                        if let context = detail.decisionContext {
                            NavigationLink("Context") {
                                DeveloperObservabilityTextView(
                                    title: "Context",
                                    text: DeveloperObservabilityPresentation.json(context)
                                )
                            }
                        }
                        if let tools = detail.tools {
                            NavigationLink("Tools · \(tools.visible.count)") {
                                DeveloperObservabilityTextView(
                                    title: "Tools",
                                    text: DeveloperObservabilityPresentation.json(.object([
                                        "visible": .array(tools.visible.map(JSONValue.string)),
                                        "definitions": .array(tools.definitions),
                                        "note": .string(tools.note),
                                    ]))
                                )
                            }
                        }
                        if let wire = detail.wireRequest {
                            NavigationLink("Raw Request") {
                                DeveloperObservabilityTextView(
                                    title: "Raw Request",
                                    text: DeveloperObservabilityPresentation.json(wire)
                                )
                            }
                        }
                    }

                    Section("实际输出") {
                        if let output = detail.modelResponse {
                            NavigationLink("模型结构化结果") {
                                DeveloperObservabilityTextView(
                                    title: "模型结果",
                                    text: DeveloperObservabilityPresentation.json(output)
                                )
                            }
                        } else {
                            Text("没有记录到模型公开响应。")
                                .foregroundStyle(.secondary)
                        }
                        if let matches = detail.promptMatchesCurrentSource {
                            LabeledContent("与当前 Prompt 源码", value: matches ? "一致" : "不同")
                                .foregroundStyle(matches ? Color.primary : Color.orange)
                        }
                        if let sha = detail.metadata.promptSHA256 {
                            LabeledContent("Prompt SHA", value: String(sha.prefix(16)))
                                .font(.caption.monospaced())
                        }
                    }
                } else {
                    Section("完整请求") {
                        Label("未采集。不会使用当前 Prompt 模板伪造这次历史调用。", systemImage: "clock.arrow.circlepath")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !detail.metrics.isEmpty {
                    Section("Metrics") {
                        NavigationLink("查看原始 Metrics") {
                            DeveloperObservabilityTextView(
                                title: "Metrics",
                                text: detail.metrics.map(DeveloperObservabilityPresentation.json).joined(separator: "\n\n")
                            )
                        }
                    }
                }
            } else if isLoading {
                HStack { Spacer(); ProgressView("正在读取 Planner 请求…"); Spacer() }
            } else if let errorMessage {
                Section("状态") {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Planner #\(call.callNumber)")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(taskID):\(call.callNumber):\(developerMode)") {
            guard developerMode else { return }
            await refresh()
        }
    }

    @MainActor
    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            detail = try await store.makeClient().fetchDeveloperPlannerCall(
                taskID: taskID,
                callNumber: call.callNumber
            )
            errorMessage = nil
        } catch {
            errorMessage = RuntimeTaskStore.userMessage(for: error)
        }
    }
}

private struct DeveloperObservabilityTextView: View {
    let title: String
    let text: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(16)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
