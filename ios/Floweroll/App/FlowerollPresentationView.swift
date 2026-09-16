import SwiftUI

/// The Home mascot is itself the interaction target. Keep standard Button
/// semantics while making the label visually invariant under `isPressed`.
struct FlowerollMascotButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// 小卷的统一展示入口。待机和聆听使用已确认的 sprite 与独立眼睛；
/// 其他状态沿用状态资源。渲染方式不是类型身份，调用方不依赖具体动画库。
@MainActor
struct FlowerollPresentationView: View {
    let state: FlowerollStateAsset
    var animated = true
    var compact = false
    var pokeRevision = 0
    var gazeX: Double = 0
    var gazeY: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pokeOffsetY: CGFloat = 0
    @State private var pokeSquint: CGFloat = 1
    @State private var pokeTask: Task<Void, Never>?

    private var usesSprite: Bool {
        state == .idle || state == .listening
    }

    var body: some View {
        Group {
            if usesSprite {
                FlowerollHomeSpriteSurface(
                    state: state,
                    animated: animated && !reduceMotion,
                    gazeX: gazeX,
                    gazeY: gazeY,
                    pokeSquint: pokeSquint
                )
                .offset(y: pokeOffsetY)
            } else {
                FlowerollAnimatedStateView(
                    state: state,
                    animated: animated,
                    compact: compact
                )
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("小卷，\(state.title)")
        .onChange(of: pokeRevision) { _, _ in
            guard state == .idle, animated, !reduceMotion else { return }
            runPoke()
        }
        .onChange(of: state) { _, newState in
            guard newState != .idle else { return }
            pokeTask?.cancel()
            pokeTask = nil
            pokeOffsetY = 0
            pokeSquint = 1
        }
        .onDisappear {
            pokeTask?.cancel()
            pokeTask = nil
        }
    }

    private func runPoke() {
        pokeTask?.cancel()
        pokeTask = Task { @MainActor in
            withAnimation(.easeOut(duration: 0.07)) {
                pokeOffsetY = -4
                pokeSquint = 0.34
            }
            try? await Task.sleep(nanoseconds: 75_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.09)) {
                pokeOffsetY = 1.5
                pokeSquint = 1
            }
            try? await Task.sleep(nanoseconds: 95_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.10)) {
                pokeOffsetY = 0
            }
        }
    }
}

private struct FlowerollHomeSpriteSurface: View {
    let state: FlowerollStateAsset
    let animated: Bool
    let gazeX: Double
    let gazeY: Double
    let pokeSquint: CGFloat

    private static let sourceSize: CGFloat = 1254
    private static let bodyFrame = "FlowerollHomeSpriteBody00"
    private static let bobPeriod: TimeInterval = 3.0
    private static let bobAmplitudePixels: CGFloat = 10

    private static let leftEyeCenter = CGPoint(x: 420, y: 661)
    private static let rightEyeCenter = CGPoint(x: 689, y: 660)
    private static let eyeCropSize = CGSize(width: 120, height: 150)

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                frame(at: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            frame(at: 0)
        }
    }

    @ViewBuilder
    private func frame(at time: TimeInterval) -> some View {
        let autoBlink = animated ? blinkScale(at: time) : 1
        let resolvedBlink = min(autoBlink, pokeSquint)
        let signalOpacity = state == .listening && animated
            ? 0.62 + 0.38 * ((sin(time * 5.1) + 1) * 0.5)
            : (state == .listening ? 0.82 : 0)
        let bobProgress = animated
            ? (1 - cos((time.truncatingRemainder(dividingBy: Self.bobPeriod) / Self.bobPeriod) * 2 * .pi)) * 0.5
            : 0

        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let xOrigin = (proxy.size.width - side) / 2
            let yOrigin = (proxy.size.height - side) / 2
            let bobOffset = -CGFloat(bobProgress) * Self.bobAmplitudePixels / Self.sourceSize * side
            let resolvedGazeX = state == .listening ? 0 : max(-1, min(1, gazeX))
            let resolvedGazeY = state == .listening ? 0 : max(-1, min(1, gazeY))
            let gazeOffsetX = CGFloat(resolvedGazeX)
                * CGFloat(HomeIdleGazePolicy.horizontalSourcePixelAmplitude)
                / Self.sourceSize * side
            let gazeOffsetY = CGFloat(resolvedGazeY)
                * CGFloat(HomeIdleGazePolicy.verticalSourcePixelAmplitude)
                / Self.sourceSize * side
            let eyeWidth = Self.eyeCropSize.width / Self.sourceSize * side
            let eyeHeight = Self.eyeCropSize.height / Self.sourceSize * side

            // Body, eyes and listening signal still share the accepted bob.
            // Finger gaze moves both eyes by one shared bounded vector; the
            // vertical range is deliberately less than half the horizontal range.
            ZStack {
                Image(Self.bodyFrame)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: side, height: side)
                    .position(
                        x: xOrigin + side / 2,
                        y: yOrigin + side / 2
                    )

                eye(
                    name: "FlowerollHomeSpriteEyeLeft",
                    center: Self.leftEyeCenter,
                    gazeOffsetX: gazeOffsetX,
                    gazeOffsetY: gazeOffsetY,
                    blinkScale: resolvedBlink,
                    eyeWidth: eyeWidth,
                    eyeHeight: eyeHeight,
                    side: side,
                    xOrigin: xOrigin,
                    yOrigin: yOrigin
                )

                eye(
                    name: "FlowerollHomeSpriteEyeRight",
                    center: Self.rightEyeCenter,
                    gazeOffsetX: gazeOffsetX,
                    gazeOffsetY: gazeOffsetY,
                    blinkScale: resolvedBlink,
                    eyeWidth: eyeWidth,
                    eyeHeight: eyeHeight,
                    side: side,
                    xOrigin: xOrigin,
                    yOrigin: yOrigin
                )

                if state == .listening {
                    Image("FlowerollMotionListeningSignal")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: side, height: side)
                        .position(
                            x: xOrigin + side / 2,
                            y: yOrigin + side / 2
                        )
                        .opacity(signalOpacity)
                }
            }
            .offset(y: bobOffset)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func eye(
        name: String,
        center: CGPoint,
        gazeOffsetX: CGFloat,
        gazeOffsetY: CGFloat,
        blinkScale: CGFloat,
        eyeWidth: CGFloat,
        eyeHeight: CGFloat,
        side: CGFloat,
        xOrigin: CGFloat,
        yOrigin: CGFloat
    ) -> some View {
        Image(name)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: eyeWidth, height: eyeHeight)
            .scaleEffect(x: 1, y: blinkScale, anchor: .center)
            .position(
                x: xOrigin + center.x / Self.sourceSize * side + gazeOffsetX,
                y: yOrigin + center.y / Self.sourceSize * side + gazeOffsetY
            )
    }

    private func blinkScale(at time: TimeInterval) -> CGFloat {
        let period = 4.6
        let blinkDuration = 0.18
        let local = time.truncatingRemainder(dividingBy: period)
        let start = period - blinkDuration
        guard local >= start else { return 1 }

        let progress = (local - start) / blinkDuration
        let closeAmount: Double
        if progress < 0.45 {
            closeAmount = progress / 0.45
        } else {
            closeAmount = max(0, (1 - progress) / 0.55)
        }
        return max(0.12, 1 - CGFloat(closeAmount) * 0.88)
    }
}
