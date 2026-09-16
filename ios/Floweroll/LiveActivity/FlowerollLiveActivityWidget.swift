import ActivityKit
import SwiftUI
import WidgetKit

struct FlowerollLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlowerollActivityAttributes.self) { context in
            HStack(spacing: 12) {
                currentAppIcon(size: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.state.taskTitle ?? "小卷")
                        .font(.headline)
                        .lineLimit(1)
                    Text(context.state.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    progressRow(context.state)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .activityBackgroundTint(.clear)
            .activitySystemActionForegroundColor(.primary)
            .widgetURL(context.state.homeURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    dynamicIslandBrandMark(width: 40, height: 28)
                        .accessibilityLabel("小卷")
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.state.taskTitle ?? "小卷")
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.state.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    phaseIndicator(context.state)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    progressRow(context.state)
                        .padding(.top, 2)
                }
            } compactLeading: {
                dynamicIslandBrandMark(width: 25, height: 18)
                    .accessibilityLabel("小卷")
            } compactTrailing: {
                compactProgress(context.state)
            } minimal: {
                dynamicIslandBrandMark(width: 22, height: 16)
                    .accessibilityLabel(accessibilityLabel(context.state.phase))
            }
            .widgetURL(context.state.homeURL)
        }
    }

    @ViewBuilder
    private func currentAppIcon(size: CGFloat) -> some View {
        Image("FlowerollLiveActivityAppIcon")
            .renderingMode(.original)
            .resizable()
            .widgetAccentedRenderingMode(.fullColor)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
    }

    /// The square App Icon is intentionally not used in the Dynamic Island: its
    /// near-white artboard becomes a white tile at 20–25 pt. This asset is a
    /// small transparent crop of the same Floweroll character artwork, so the
    /// island keeps the product identity without introducing a grey/white plate.
    @ViewBuilder
    private func dynamicIslandBrandMark(width: CGFloat, height: CGFloat) -> some View {
        Image("FlowerollDynamicIslandMark")
            .renderingMode(.original)
            .resizable()
            .widgetAccentedRenderingMode(.fullColor)
            .scaledToFit()
            .frame(width: width, height: height)
    }

    @ViewBuilder
    private func phaseIndicator(_ state: FlowerollActivityAttributes.ContentState) -> some View {
        if state.phase == .processing {
            jumpingEllipsis(state)
                .frame(minWidth: 18, alignment: .trailing)
                .accessibilityLabel(accessibilityLabel(state.phase))
        } else {
            Text(shortLabel(state.phase))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .frame(minWidth: 18, alignment: .trailing)
                .accessibilityLabel(accessibilityLabel(state.phase))
        }
    }

    private func jumpingEllipsis(_ state: FlowerollActivityAttributes.ContentState) -> some View {
        let frame = state.effectivePresentationPulse % 6
        let offsets: [[CGFloat]] = [
            [-2.8, -0.2, 0.2],
            [-1.4, -1.4, 0.1],
            [-0.2, -2.8, -0.2],
            [0.1, -1.4, -1.4],
            [0.2, -0.2, -2.8],
            [-1.4, 0.1, -1.4]
        ]

        return HStack(spacing: 2.15) {
            ForEach(0..<3, id: \.self) { index in
                let y = offsets[frame][index]
                let isPeak = y <= -2.4
                let isMoving = y <= -1.0
                Circle()
                    .fill(.primary)
                    .frame(width: 3.05, height: 3.05)
                    .scaleEffect(isPeak ? 1.08 : (isMoving ? 1.0 : 0.92))
                    .opacity(isPeak ? 1.0 : (isMoving ? 0.78 : 0.52))
                    .offset(y: y)
                    .animation(.easeInOut(duration: 0.20), value: frame)
                    .frame(width: 4, height: 10, alignment: .bottom)
            }
        }
        .frame(width: 20, height: 12)
    }

    @ViewBuilder
    private func compactProgress(_ state: FlowerollActivityAttributes.ContentState) -> some View {
        if state.phase == .processing,
           let completed = state.completedCount,
           let total = state.totalCount,
           state.fraction != nil {
            Text("\(completed)/\(total)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(minWidth: 24)
            .accessibilityLabel(state.progressLabel ?? "正在处理")
        } else if state.phase == .processing {
            jumpingEllipsis(state)
                .frame(minWidth: 18)
                .accessibilityLabel("小卷正在处理")
        } else {
            Text(shortLabel(state.phase))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .frame(minWidth: 18)
                .accessibilityLabel(accessibilityLabel(state.phase))
        }
    }

    @ViewBuilder
    private func progressRow(_ state: FlowerollActivityAttributes.ContentState) -> some View {
        if state.phase == .processing, let fraction = state.fraction {
            HStack(spacing: 8) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.secondary.opacity(0.22))
                        Capsule()
                            .fill(.primary.opacity(0.82))
                            .frame(width: max(6, proxy.size.width * fraction))
                    }
                }
                .frame(height: 5)

                Text(progressText(state))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func progressText(_ state: FlowerollActivityAttributes.ContentState) -> String {
        guard let completed = state.completedCount,
              let total = state.totalCount,
              total > 0,
              completed >= 0,
              completed <= total
        else { return "" }
        return "\(completed)/\(total)"
    }

    private func shortLabel(_ phase: FlowerollActivityPhase) -> String {
        switch phase {
        case .listening: return "听"
        case .processing: return "···"
        case .needsUser: return "?"
        case .completed: return "✓"
        case .failed: return "!"
        case .cancelled: return "−"
        }
    }

    private func accessibilityLabel(_ phase: FlowerollActivityPhase) -> String {
        switch phase {
        case .listening: return "小卷正在听"
        case .processing: return "小卷正在处理"
        case .needsUser: return "小卷需要确认"
        case .completed: return "小卷已完成"
        case .failed: return "任务暂时无法继续"
        case .cancelled: return "任务已停止"
        }
    }
}
