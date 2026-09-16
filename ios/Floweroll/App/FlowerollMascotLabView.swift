import SwiftUI

struct FlowerollMascotLabView: View {
    @Environment(\.flowerollThemePalette) private var themePalette
    @State private var selectedState: FlowerollStateAsset = .idle
    @State private var animated = true
    @State private var replayToken = 0

    private let stateColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    private let sceneColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 11) {
                    FlowerollAnimatedStateView(state: selectedState, animated: animated)
                        .id("\(selectedState.rawValue)-\(replayToken)-\(animated)")
                        .frame(width: 150, height: 150)
                        .contentTransition(.opacity)

                    Text(selectedState.title)
                        .font(.title3.bold())
                    Text(description(for: selectedState))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))

                HStack(spacing: 10) {
                    Toggle("播放动效", isOn: $animated)
                    Spacer()
                    Button("重播") {
                        replayToken += 1
                    }
                    .buttonStyle(.bordered)
                    .disabled(!animated)
                }
                .padding(.horizontal, 2)

                VStack(alignment: .leading, spacing: 10) {
                    Text("正式状态")
                        .font(.headline)
                    LazyVGrid(columns: stateColumns, spacing: 10) {
                        ForEach(FlowerollStateAsset.allCases) { state in
                            Button {
                                withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                                    selectedState = state
                                    replayToken += 1
                                }
                            } label: {
                                VStack(spacing: 5) {
                                    FlowerollStateAssetView(state: state)
                                        .frame(width: 70, height: 70)
                                    Text(state.title)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.primary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    selectedState == state
                                        ? themePalette.accent.opacity(0.11)
                                        : Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                                )
                                .overlay {
                                    if selectedState == state {
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .stroke(themePalette.accent.opacity(0.38), lineWidth: 1)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("场景资产")
                        .font(.headline)
                    Text("这些图只用于匹配的 Artifact / Result / Handoff，不会塞进普通 Timeline。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: sceneColumns, spacing: 10) {
                        ForEach(FlowerollSceneAsset.allCases) { scene in
                            VStack(spacing: 5) {
                                FlowerollSceneAssetView(scene: scene)
                                    .frame(width: 70, height: 70)
                                Text(scene.title)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.primary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                            )
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("当前视觉基线", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                    Text("当前产品资产已经固定为 1 个 App Icon、6 个状态 Pose 和 14 个场景图。所有状态/场景图都是透明背景；App Icon 保留粉白渐变。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("旧 552×381 Rig 只保留为微动技术参考，不再定义小卷的外形。下一阶段的 blink、尾巴、呼吸和短逐帧都必须从上面的正式 Pose 出发。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("小卷 IP")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func description(for state: FlowerollStateAsset) -> String {
        switch state {
        case .idle: return "安静待命。只在空状态等少数低信息密度位置出现。"
        case .listening: return "正在听你说话。首页录音时短暂出现，停止后立即退场。"
        case .thinking: return "刚进入规划或还没有形成执行 Timeline 时使用。"
        case .working: return "任务已经进入执行阶段。主要用于 Task Detail 页头。"
        case .waiting: return "等待你补充、确认或等待外部结果；视觉上不催促。"
        case .done: return "完成后的短反应；常规完成不会让角色持续占屏。"
        }
    }
}
