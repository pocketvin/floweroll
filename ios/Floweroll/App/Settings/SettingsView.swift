import AVFAudio
import AVFoundation
import ContactsUI
import SwiftUI
import UserNotifications



struct SettingsView: View {
    let runtimeStore: RuntimeTaskStore
    @Environment(FlowerollThemeStore.self) private var theme
    @AppStorage("floweroll.developerMode") private var developerMode = false

    private var buildIdentity: String {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "—"
        return "\(version)（\(build)）"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image("FlowerollCurrentAppIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                Text("设置")
                    .font(.system(size: 34, weight: .bold, design: .default))
                    .tracking(-0.7)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Form {
            Section("后台") {
                NavigationLink {
                    RuntimeConnectionSettingsView(store: runtimeStore)
                } label: {
                    HStack {
                        Text("后台连接")
                        Spacer()
                        RuntimeConnectionBadge(state: runtimeStore.connectionState)
                    }
                }
            }

            Section("系统能力") {
                NavigationLink {
                    ScheduleHubView()
                } label: {
                    Label(ScheduleHubPresentation.settingsEntryTitle, systemImage: "calendar.badge.clock")
                }
                .accessibilityIdentifier("settings.schedule-hub")

                NavigationLink {
                    FlowerollAlarmManagementView()
                } label: {
                    Label("小卷闹钟", systemImage: "alarm")
                }
                Text(FlowerollAlarmPresentationCopy.settingsDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("主题色") {
                ForEach(FlowerollAccentChoice.allCases) { choice in
                    Button {
                        theme.select(choice)
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(choice.palette.accent)
                                .frame(width: 24, height: 24)
                                .overlay {
                                    Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.6)
                                }
                            Text(choice.displayName)
                                .foregroundStyle(.primary)
                            Spacer()
                            if theme.choice == choice {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(theme.palette.strongAccent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("主题色 \(choice.displayName)")
                    .accessibilityValue(theme.choice == choice ? "已选择" : "未选择")
                }

                Text("选择后会立即应用到小卷的导航、操作按钮和进行中状态；完成、错误和警告颜色保持原来的语义。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            SettingsPermissionSection()

            Section("Tools") {
                NavigationLink {
                    SettingsToolsView(runtimeStore: runtimeStore)
                } label: {
                    Label("已接入 Tools", systemImage: "wrench.and.screwdriver")
                }
                Text("读取当前 Host 的真实 capability 状态，只展示已经 ready 的能力。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("显示") {
                Toggle(isOn: $developerMode) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("开发者模式")
                        Text("在任务 Timeline 中显示 Capability、Attempt、延迟与 Verification 等技术信息。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if developerMode {
                    NavigationLink {
                        DeveloperObservabilityTaskListView(store: runtimeStore)
                    } label: {
                        Label("Agent 调试", systemImage: "ladybug")
                    }
                    .accessibilityIdentifier("settings.developer-observability")

                    Text("只读查看真实 Planner Prompt、Context、Tools、耗时与失败恢复证据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                NavigationLink("小卷 IP 动效实验室") {
                    FlowerollMascotLabView()
                }
            }

            Section("版本") {
                LabeledContent("当前版本", value: buildIdentity)
            }

            Section {
                Text("任务状态与历史现在由后台 Runtime 提供；SwiftUI 前台可以随时销毁并从 Task Index / View + SSE 重建。静态交互样例只保留给开发者模式做视觉实验。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            }
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemBackground))
        }
        .background(Color(uiColor: .systemBackground))
        .toolbar(.hidden, for: .navigationBar)
    }
}
