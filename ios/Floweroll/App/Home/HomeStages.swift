import AVFAudio
import AVFoundation
import ContactsUI
import SwiftUI
import UserNotifications



enum HomeEmptyStagePresentationPolicy {
    static func showsIdleMascot(
        composerFocused: Bool,
        hasTextDraft: Bool,
        attachmentCount: Int,
        attachmentLoading: Bool
    ) -> Bool {
        _ = composerFocused
        _ = hasTextDraft
        _ = attachmentCount
        _ = attachmentLoading
        return true
    }
}

struct HomeReturnToLatestButton: View {
    let action: () -> Void

    @Environment(\.flowerollThemePalette) private var themePalette

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(themePalette.accent)
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle().stroke(Color.primary.opacity(0.09), lineWidth: 0.6)
                }
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .accessibilityIdentifier("home.return-to-latest")
        .accessibilityLabel("回到最新")
        .accessibilityHint("滚动到当前任务的最新进度，并恢复自动跟随")
    }
}

struct LiveSpeechTranscriptView: View {
    let base: String
    let finalized: String
    let volatile: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if visibleText.isEmpty {
                Text("正在听…")
                    .foregroundStyle(.secondary)
            } else {
                Text(styledText)
                    .contentTransition(reduceMotion ? .opacity : .interpolate)
            }
        }
        .font(.body)
        .lineLimit(1...6)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: volatile)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: finalized)
        .accessibilityLabel(visibleText.isEmpty ? "正在听" : visibleText)
    }

    private var styledText: AttributedString {
        var stable = AttributedString(stableText)
        stable.foregroundColor = .primary
        var volatilePart = AttributedString(volatileSuffix)
        volatilePart.foregroundColor = .secondary
        stable.append(volatilePart)
        return stable
    }

    private var stableText: String {
        Self.merge(base: base, transcript: finalized)
    }

    private var volatileSuffix: String {
        guard !volatile.isEmpty else { return "" }
        let stable = stableText
        guard !stable.isEmpty else { return volatile }
        let needsSpace = stable.last?.isASCII == true && volatile.first?.isASCII == true
        return (needsSpace ? " " : "") + volatile
    }

    private var visibleText: String {
        stableText + volatileSuffix
    }

    private static func merge(base: String, transcript: String) -> String {
        guard !base.isEmpty else { return transcript }
        guard !transcript.isEmpty else { return base }
        let needsSpace = base.last?.isASCII == true && transcript.first?.isASCII == true
        return base + (needsSpace ? " " : "") + transcript
    }
}

struct HomeThreadRecoveryStage: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("正在恢复当前任务…")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
            Text("正在同步当前任务的最新进度。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在恢复当前任务")
    }
}


struct RootTabAwareFlowerollPresentationView: View {
    let state: FlowerollStateAsset
    var compact = false
    var pokeRevision = 0
    var gazeX: Double = 0
    var gazeY: Double = 0

    @Environment(\.rootTabSurfaceActive) private var surfaceIsActive

    var body: some View {
        FlowerollPresentationView(
            state: state,
            animated: surfaceIsActive,
            compact: compact,
            pokeRevision: pokeRevision,
            gazeX: gazeX,
            gazeY: gazeY
        )
    }
}

struct HomeIdleStage: View {
    let state: FlowerollStateAsset
    let gaze: HomeIdleGazeVector
    let onMascotFrameChange: (CGRect) -> Void

    @State private var pokeRevision = 0

    private let mascotSize: CGFloat = 232

    var body: some View {
        VStack(spacing: 10) {
            Button {
                guard state == .idle else { return }
                // The visible reaction is authored in FlowerollStateMachine.poke.
                // Keep SwiftUI out of the character motion so the Rive proof is honest.
                pokeRevision &+= 1
            } label: {
                RootTabAwareFlowerollPresentationView(
                    state: state,
                    pokeRevision: pokeRevision,
                    gazeX: gaze.x,
                    gazeY: gaze.y
                )
                .frame(width: mascotSize, height: mascotSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(FlowerollMascotButtonStyle())
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named("home-idle-canvas"))
            } action: { frame in
                onMascotFrameChange(frame)
            }
            .accessibilityLabel(state == .idle ? "小卷，待机。轻点会回应" : "小卷，正在听")

            Text(state == .listening ? "我在听" : "想让小卷帮你做什么？")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .tracking(-0.15)
                .foregroundStyle(.primary)
                .contentTransition(.opacity)
        }
        .animation(.easeInOut(duration: 0.2), value: state)
    }
}

struct HomeThreadStage: View {
    let tasks: [HostTaskIndexItem]
    let store: RuntimeTaskStore
    let onSeenThread: () -> Void
    let onTimelineChange: () -> Void

    @Environment(\.flowerollThemePalette) private var themePalette

    private var latestTask: HostTaskIndexItem? { tasks.last }
    private var liveTaskID: String? {
        tasks.last(where: { !$0.presentationTruth.isTerminal })?.taskID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(tasks.enumerated()), id: \.element.taskID) { index, task in
                HomeThreadEpisodeView(
                    task: task,
                    store: store,
                    isFirstEpisode: index == 0,
                    updateMode: RuntimeTaskDetailUpdatePolicy.mode(
                        task: task, liveTaskID: liveTaskID
                    ),
                    onTimelineChange: onTimelineChange
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: terminalViewingKey) {
            guard terminalViewingKey != nil else { return }
            onSeenThread()
        }
    }

    private var terminalViewingKey: String? {
        guard let latestTask, latestTask.presentationTruth.isTerminal else { return nil }
        return latestTask.taskID + ":" + latestTask.updatedAt
    }
}
