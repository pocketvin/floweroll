import AVFAudio
import AVFoundation
import ContactsUI
import SwiftUI
import UserNotifications


struct SettingsToolsView: View {
    let runtimeStore: RuntimeTaskStore
    @State private var capabilities: [HostCapabilityStatus] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var readyCapabilities: [HostCapabilityStatus] {
        capabilities.filter(\.ready).sorted { $0.capabilityID < $1.capabilityID }
    }

    private var nativeTools: [HostCapabilityStatus] {
        readyCapabilities.filter { $0.source.kind == "ios" }
    }

    private var mcpTools: [HostCapabilityStatus] {
        readyCapabilities.filter { $0.source.kind == "mcp" }
    }

    private var hostTools: [HostCapabilityStatus] {
        readyCapabilities.filter { $0.source.kind != "ios" && $0.source.kind != "mcp" }
    }

    var body: some View {
        List {
            if isLoading && capabilities.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("正在读取当前 Tools…")
                    Spacer()
                }
            } else if let errorMessage, capabilities.isEmpty {
                ContentUnavailableView(
                    "暂时无法读取 Tools",
                    systemImage: "wrench.and.screwdriver",
                    description: Text(errorMessage)
                )
            } else {
                toolSection("iPhone 原生", tools: nativeTools)
                toolSection("MCP", tools: mcpTools)
                toolSection("Host / 本机", tools: hostTools)
            }
        }
        .navigationTitle("已接入 Tools")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task { await refresh() }
    }

    @ViewBuilder
    private func toolSection(_ title: String, tools: [HostCapabilityStatus]) -> some View {
        if !tools.isEmpty {
            Section("\(title) · \(tools.count)") {
                ForEach(tools) { tool in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(tool.capabilityID)
                            .font(.body.monospaced())
                        Text(tool.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                        Text(sourceLabel(tool))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func sourceLabel(_ tool: HostCapabilityStatus) -> String {
        if tool.source.kind == "ios" { return "iPhone 原生" }
        if tool.source.kind == "mcp" {
            return tool.source.serverID.map { "MCP · \($0)" } ?? "MCP"
        }
        return "Host · \(tool.source.kind)"
    }

    @MainActor
    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try runtimeStore.makeClient()
            let result = try await client.fetchCapabilityStatus()
            capabilities = result.capabilities
            errorMessage = nil
        } catch {
            errorMessage = RuntimeTaskStore.userMessage(for: error)
        }
    }
}
