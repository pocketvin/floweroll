import CryptoKit
import Foundation
import Observation
import SwiftUI



struct RuntimeConnectionSettingsView: View {
    let store: RuntimeTaskStore

    @State private var endpoint = ""
    @State private var token = ""
    @State private var statusMessage: String?
    @State private var isSaving = false

    var body: some View {
        Form {
            Section {
                TextField("https://…", text: $endpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                SecureField("配对凭据（留空则保留已有凭据）", text: $token)
                    .textContentType(.password)

                connectionStatus
            } header: {
                Text("后台 Host")
            } footer: {
                Text("真实 iPhone 不会直接连 Mac 的明文 LAN HTTP。V1 使用 HTTPS Tunnel / 反向代理到 Mac loopback Host；配对凭据只保存在本机 Keychain。")
            }

            Section {
                Button {
                    saveAndTest()
                } label: {
                    HStack {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isSaving ? "正在验证…" : "保存并连接")
                    }
                }
                .disabled(endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)

                Button("删除当前地址的配对凭据") {
                    do {
                        try store.removeCredentialForConfiguredEndpoint()
                        statusMessage = "已删除 Keychain 凭据。"
                        token = ""
                    } catch {
                        statusMessage = RuntimeTaskStore.userMessage(for: error)
                    }
                }
                .disabled(store.configuredEndpoint.isEmpty || isSaving)

                Button("清除 Host 配置", role: .destructive) {
                    store.clearConfiguration()
                    endpoint = ""
                    token = ""
                    statusMessage = "Host 配置已清除。"
                }
                .disabled(store.configuredEndpoint.isEmpty || isSaving)
            }

        }
        .navigationTitle("后台连接")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            endpoint = store.configuredEndpoint
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch store.connectionState {
        case .notConfigured:
            Label("尚未配置", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .connecting:
            Label("正在连接", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .connected:
            Label("已连接后台 Runtime", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }

        if let statusMessage {
            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func saveAndTest() {
        guard !isSaving else { return }
        isSaving = true
        statusMessage = nil

        Task { @MainActor in
            defer { isSaving = false }
            do {
                try store.configure(
                    endpoint: endpoint,
                    bearerToken: token.isEmpty ? nil : token
                )
                token = ""
                await store.bootstrap()
                switch store.connectionState {
                case .connected:
                    statusMessage = "连接成功，已从后台恢复任务列表。"
                case let .failed(message):
                    statusMessage = message
                default:
                    statusMessage = nil
                }
            } catch {
                statusMessage = RuntimeTaskStore.userMessage(for: error)
            }
        }
    }
}
