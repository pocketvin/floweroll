import SwiftUI

enum FlowerollStateAsset: String, CaseIterable, Identifiable {
    case idle, listening, thinking, working, waiting, done

    var id: Self { self }

    var assetName: String {
        switch self {
        case .idle: return "FlowerollStateIdle"
        case .listening: return "FlowerollStateListening"
        case .thinking: return "FlowerollStateThinking"
        case .working: return "FlowerollStateWorking"
        case .waiting: return "FlowerollStateWaiting"
        case .done: return "FlowerollStateDone"
        }
    }

    var title: String {
        switch self {
        case .idle: return "待机"
        case .listening: return "倾听"
        case .thinking: return "思考"
        case .working: return "工作"
        case .waiting: return "等你"
        case .done: return "完成"
        }
    }
}

enum FlowerollSceneAsset: String, CaseIterable, Identifiable {
    case rideHailing, foodDelivery, email, notes, calendar, search, map, files
    case checklist, phone, camera, translate, data, alarm

    var id: Self { self }

    var assetName: String {
        switch self {
        case .rideHailing: return "FlowerollSceneRideHailing"
        case .foodDelivery: return "FlowerollSceneFoodDelivery"
        case .email: return "FlowerollSceneEmail"
        case .notes: return "FlowerollSceneNotes"
        case .calendar: return "FlowerollSceneCalendar"
        case .search: return "FlowerollSceneSearch"
        case .map: return "FlowerollSceneMap"
        case .files: return "FlowerollSceneFiles"
        case .checklist: return "FlowerollSceneChecklist"
        case .phone: return "FlowerollScenePhone"
        case .camera: return "FlowerollSceneCamera"
        case .translate: return "FlowerollSceneTranslate"
        case .data: return "FlowerollSceneData"
        case .alarm: return "FlowerollSceneAlarm"
        }
    }

    var title: String {
        switch self {
        case .rideHailing: return "打车"
        case .foodDelivery: return "外卖"
        case .email: return "邮件"
        case .notes: return "笔记"
        case .calendar: return "日历"
        case .search: return "搜索"
        case .map: return "地图"
        case .files: return "文件"
        case .checklist: return "清单"
        case .phone: return "电话"
        case .camera: return "相机"
        case .translate: return "翻译"
        case .data: return "数据"
        case .alarm: return "提醒"
        }
    }
}

struct FlowerollStateAssetView: View {
    let state: FlowerollStateAsset

    var body: some View {
        Image(state.assetName)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .accessibilityHidden(true)
    }
}

struct FlowerollSceneAssetView: View {
    let scene: FlowerollSceneAsset

    var body: some View {
        Image(scene.assetName)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .accessibilityHidden(true)
    }
}

struct FlowerollAnimatedStateView: View {
    let state: FlowerollStateAsset
    var animated = true
    var compact = false

    @State private var epoch = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if animated && !reduceMotion {
                TimelineView(.animation) { context in
                    FlowerollCoreMotionFrame(
                        state: state,
                        time: max(0, context.date.timeIntervalSince(epoch)),
                        compact: compact
                    )
                }
            } else {
                FlowerollStateAssetView(state: state)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear { epoch = Date() }
        .onChange(of: state) { _, _ in epoch = Date() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("小卷，\(state.title)")
    }
}

private struct FlowerollCoreMotionFrame: View {
    let state: FlowerollStateAsset
    let time: TimeInterval
    let compact: Bool

    private struct Motion {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1
        var rotation: Double = 0
        var opacity: Double = 1
    }

    private var amplitude: CGFloat { compact ? 0.72 : 1.0 }

    var body: some View {
        ZStack {
            switch state {
            case .idle:
                layer("FlowerollMotionIdleMain", motion: idleMain, anchor: mainAnchor)

            case .listening:
                layer("FlowerollMotionListeningMain", motion: listeningMain, anchor: mainAnchor)
                layer("FlowerollMotionListeningSignal", motion: listeningSignal, anchor: UnitPoint(x: 0.110, y: 0.351))

            case .thinking:
                layer("FlowerollMotionThinkingMain", motion: thinkingMain, anchor: mainAnchor)
                layer("FlowerollMotionThinkingQuestion", motion: thinkingQuestion, anchor: UnitPoint(x: 0.790, y: 0.219))
                layer("FlowerollMotionThinkingTailAccent", motion: thinkingTailAccent, anchor: UnitPoint(x: 0.948, y: 0.442))

            case .working:
                layer("FlowerollMotionWorkingMain", motion: workingMain, anchor: mainAnchor)
                layer("FlowerollMotionWorkingAccent", motion: workingAccent, anchor: UnitPoint(x: 0.936, y: 0.389))

            case .waiting:
                layer("FlowerollMotionWaitingMain", motion: waitingMain, anchor: mainAnchor)
                layer("FlowerollMotionWaitingBubble", motion: waitingBubble, anchor: UnitPoint(x: 0.178, y: 0.292))

            case .done:
                layer("FlowerollMotionDoneMain", motion: doneMain, anchor: mainAnchor)
                layer("FlowerollMotionDoneSparklesLeft", motion: doneSparklesLeft, anchor: UnitPoint(x: 0.115, y: 0.353))
                layer("FlowerollMotionDoneSparklesRight", motion: doneSparklesRight, anchor: UnitPoint(x: 0.843, y: 0.334))
            }
        }
    }

    private var mainAnchor: UnitPoint {
        switch state {
        case .idle: return UnitPoint(x: 0.537, y: 0.801)
        case .listening: return UnitPoint(x: 0.528, y: 0.792)
        case .thinking: return UnitPoint(x: 0.509, y: 0.886)
        case .working: return UnitPoint(x: 0.524, y: 0.779)
        case .waiting: return UnitPoint(x: 0.557, y: 0.796)
        case .done: return UnitPoint(x: 0.533, y: 0.812)
        }
    }

    private func wave(period: Double, phase: Double = 0) -> CGFloat {
        CGFloat(sin((time / period) * .pi * 2 + phase))
    }

    private func pulse(period: Double, phase: Double = 0) -> CGFloat {
        (wave(period: period, phase: phase) + 1) * 0.5
    }

    private func oneShot(duration: Double) -> CGFloat {
        guard time < duration else { return 0 }
        return CGFloat(sin(.pi * max(0, min(1, time / duration))))
    }

    private func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.70158
        let c3 = c1 + 1
        let t = x - 1
        return 1 + c3 * t * t * t + c1 * t * t
    }

    private var idleMain: Motion {
        let breath = wave(period: 4.8)
        return Motion(
            y: breath * 0.75 * amplitude,
            scaleX: 1 - breath * 0.0015 * amplitude,
            scaleY: 1 + breath * 0.0055 * amplitude,
            rotation: Double(wave(period: 6.6)) * 0.16 * Double(amplitude)
        )
    }

    private var listeningMain: Motion {
        let nod = oneShot(duration: 0.46)
        let breath = wave(period: 4.2)
        return Motion(
            y: (-1.1 * nod + breath * 0.25) * amplitude,
            scaleX: 1 - breath * 0.0008 * amplitude,
            scaleY: 1 + breath * 0.0025 * amplitude,
            rotation: Double(-0.65 * nod * amplitude + wave(period: 4.0) * 0.08 * amplitude)
        )
    }

    private var listeningSignal: Motion {
        let p = pulse(period: 0.95)
        return Motion(
            x: -0.6 * (1 - p) * amplitude,
            scaleX: 0.96 + p * 0.045 * amplitude,
            scaleY: 0.96 + p * 0.045 * amplitude,
            opacity: 0.52 + Double(p) * 0.48
        )
    }

    private var thinkingMain: Motion {
        let slow = wave(period: 4.6)
        return Motion(
            y: slow * 0.45 * amplitude,
            scaleY: 1 + slow * 0.0025 * amplitude,
            rotation: Double(slow) * 0.22 * Double(amplitude)
        )
    }

    private var thinkingQuestion: Motion {
        let p = wave(period: 2.2)
        return Motion(
            y: p * 2.0 * amplitude,
            scaleX: 1 + p * 0.025 * amplitude,
            scaleY: 1 + p * 0.025 * amplitude,
            rotation: Double(p) * 0.9 * Double(amplitude),
            opacity: 0.82 + Double(pulse(period: 2.2)) * 0.18
        )
    }

    private var thinkingTailAccent: Motion {
        let p = pulse(period: 2.6, phase: 0.7)
        return Motion(
            scaleX: 0.98 + p * 0.025,
            scaleY: 0.98 + p * 0.025,
            opacity: 0.55 + Double(p) * 0.45
        )
    }

    private var workingMain: Motion {
        let breath = wave(period: 2.8)
        let settle = oneShot(duration: 0.42)
        return Motion(
            y: (0.32 * breath + 0.55 * settle) * amplitude,
            scaleX: 1 - breath * 0.0005 * amplitude,
            scaleY: 1 + breath * 0.0018 * amplitude,
            rotation: Double(wave(period: 5.2)) * 0.05 * Double(amplitude)
        )
    }

    private var workingAccent: Motion {
        let p = pulse(period: 1.55)
        return Motion(
            scaleX: 0.98 + p * 0.025,
            scaleY: 0.98 + p * 0.025,
            opacity: 0.42 + Double(p) * 0.58
        )
    }

    private var waitingMain: Motion {
        let breath = wave(period: 5.4)
        return Motion(
            y: breath * 0.55 * amplitude,
            scaleX: 1 - breath * 0.0008 * amplitude,
            scaleY: 1 + breath * 0.0032 * amplitude,
            rotation: Double(wave(period: 7.0)) * 0.08 * Double(amplitude)
        )
    }

    private var waitingBubble: Motion {
        let p = wave(period: 2.8)
        return Motion(
            y: p * 1.8 * amplitude,
            scaleX: 1 + p * 0.018 * amplitude,
            scaleY: 1 + p * 0.018 * amplitude,
            opacity: 0.82 + Double(pulse(period: 2.8)) * 0.18
        )
    }

    private var doneMain: Motion {
        let jump = oneShot(duration: 0.65)
        let settledBreath: CGFloat = time > 0.85 ? wave(period: 4.8) : 0
        return Motion(
            y: (-4.2 * jump + settledBreath * 0.28) * amplitude,
            scaleX: 1 + jump * 0.028 * amplitude - settledBreath * 0.0008,
            scaleY: 1 + jump * 0.042 * amplitude + settledBreath * 0.002,
            rotation: Double(jump) * -0.75 * Double(amplitude)
        )
    }

    private var doneSparklePop: CGFloat {
        if time < 0.65 {
            let p = max(0, min(1, time / 0.65))
            return CGFloat(0.72 + 0.28 * easeOutBack(p))
        }
        return 1 + wave(period: 3.8) * 0.015
    }

    private var doneSparkleOpacity: Double {
        if time < 0.18 { return max(0, min(1, time / 0.18)) }
        return 0.92 + Double(pulse(period: 3.8)) * 0.08
    }

    private var doneSparklesLeft: Motion {
        Motion(
            y: -oneShot(duration: 0.65) * 1.8 * amplitude,
            scaleX: doneSparklePop,
            scaleY: doneSparklePop,
            rotation: -Double(oneShot(duration: 0.65)) * 3.0,
            opacity: doneSparkleOpacity
        )
    }

    private var doneSparklesRight: Motion {
        Motion(
            y: -oneShot(duration: 0.65) * 1.4 * amplitude,
            scaleX: doneSparklePop,
            scaleY: doneSparklePop,
            rotation: Double(oneShot(duration: 0.65)) * 3.0,
            opacity: doneSparkleOpacity
        )
    }

    private func layer(_ name: String, motion: Motion, anchor: UnitPoint) -> some View {
        Image(name)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .scaleEffect(x: motion.scaleX, y: motion.scaleY, anchor: anchor)
            .rotationEffect(.degrees(motion.rotation), anchor: anchor)
            .offset(x: motion.x, y: motion.y)
            .opacity(motion.opacity)
    }
}

enum FlowerollMascotState: String, CaseIterable, Identifiable {
    case idle
    case listening
    case thinking
    case working
    case waiting
    case done
    case tailBattle

    var id: Self { self }

    var title: String {
        switch self {
        case .idle: return "待机"
        case .listening: return "倾听"
        case .thinking: return "思考"
        case .working: return "工作"
        case .waiting: return "等你"
        case .done: return "完成"
        case .tailBattle: return "和尾巴较劲"
        }
    }
}

/// 小卷的正式视觉入口。
///
/// 角色轮廓不再由 SwiftUI Canvas 重画。Rig v2 的 Body / Tail / Face layers
/// 全部来自用户确认过的唯一母版，neutral composition 与母版逐像素一致。
/// 动画只允许作用于批准过的图层 transform 或独立 accessory。
struct FlowerollMascotView: View {
    let state: FlowerollMascotState
    var animated = true
    var compact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if animated && !reduceMotion {
                TimelineView(.animation(minimumInterval: compact ? 1.0 / 20.0 : 1.0 / 30.0)) { context in
                    FlowerollApprovedRig(
                        state: state,
                        time: context.date.timeIntervalSinceReferenceDate,
                        compact: compact
                    )
                }
            } else {
                FlowerollApprovedRig(state: state, time: 0, compact: compact)
            }
        }
        .aspectRatio(552.0 / 381.0, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("小卷，\(state.title)")
    }
}

private struct FlowerollApprovedRig: View {
    let state: FlowerollMascotState
    let time: TimeInterval
    let compact: Bool

    private var bodyBob: CGFloat {
        switch state {
        case .done: return CGFloat(sin(time * 4.6)) * 1.8
        case .listening: return CGFloat(sin(time * 2.8)) * 0.8
        case .working: return CGFloat(sin(time * 2.2)) * 0.55
        default: return CGFloat(sin(time * 1.55)) * 0.35
        }
    }

    private var bodyScaleY: CGFloat {
        let amplitude: Double = compact ? 0.002 : 0.006
        // time == 0 must be the exact neutral master. This also means
        // Reduce Motion / static previews never retain a hidden half-breath.
        return 1.0 + CGFloat(sin(time * 1.7) * amplitude)
    }

    private var wholeRotation: Angle {
        switch state {
        case .listening:
            return .degrees(sin(time * 2.2) * 0.65)
        case .thinking:
            return .degrees(-1.2 + sin(time * 1.0) * 0.35)
        case .tailBattle:
            return .degrees(sin(time * 5.1) * 1.15)
        default:
            return .zero
        }
    }

    private var tailRotation: Angle {
        let degrees: Double
        switch state {
        case .idle: degrees = sin(time * 1.35) * 1.7
        case .listening: degrees = sin(time * 1.8) * 0.7
        case .thinking: degrees = sin(time * 0.9) * 1.0 - 1.0
        case .working: degrees = sin(time * 1.7) * 1.2
        case .waiting: degrees = sin(time * 0.75) * 2.2
        case .done: degrees = sin(time * 4.2) * 4.4
        case .tailBattle: degrees = sin(time * 5.4) * 10.0 - 4.0
        }
        return .degrees(degrees)
    }

    private var eyeLeftScaleY: CGFloat {
        guard time != 0 else { return 1 }
        let period: Double = switch state {
        case .working: 5.3
        case .thinking: 4.9
        case .waiting: 5.8
        case .done: 3.6
        default: 4.6
        }
        let local = time.truncatingRemainder(dividingBy: period)
        let blinkStart = period - 0.18
        guard local >= blinkStart else {
            switch state {
            case .working: return 0.94
            case .thinking: return 0.97
            default: return 1
            }
        }
        let x = (local - blinkStart) / 0.18
        let close = x < 0.45 ? x / 0.45 : (1 - x) / 0.55
        return max(0.12, 1 - CGFloat(max(0, close)) * 0.88)
    }

    private var eyeLeftOffset: CGSize {
        guard time != 0 else { return .zero }
        switch state {
        case .thinking:
            return CGSize(width: 1.4, height: -1.0)
        case .working:
            return CGSize(width: 0.4, height: 1.2)
        case .tailBattle:
            return CGSize(width: 2.4, height: 0.2)
        default:
            return .zero
        }
    }

    private var mouthScale: CGSize {
        guard time != 0 else { return CGSize(width: 1, height: 1) }
        switch state {
        case .done:
            let p = CGFloat((sin(time * 4.0) + 1) * 0.5)
            return CGSize(width: 1 + p * 0.035, height: 1 + p * 0.08)
        case .listening:
            return CGSize(width: 1, height: 0.98 + CGFloat(sin(time * 2.1)) * 0.015)
        case .tailBattle:
            return CGSize(width: 0.98, height: 0.96)
        default:
            return CGSize(width: 1, height: 1)
        }
    }

    private var cheekScale: CGFloat {
        guard time != 0, state == .done else { return 1 }
        return 1 + CGFloat((sin(time * 3.7) + 1) * 0.5) * 0.045
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Image("FlowerollTailBase")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .rotationEffect(
                        tailRotation,
                        anchor: UnitPoint(x: 0.721014, y: 0.766404)
                    )

                Image("FlowerollTailAccent")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .rotationEffect(
                        tailRotation,
                        anchor: UnitPoint(x: 0.721014, y: 0.766404)
                    )

                Image("FlowerollBodyBase")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()

                Image("FlowerollCheekLeft")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .scaleEffect(cheekScale, anchor: UnitPoint(x: 0.25, y: 0.515))

                Image("FlowerollCheekRight")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .scaleEffect(cheekScale, anchor: UnitPoint(x: 0.605, y: 0.445))

                Image("FlowerollEyeLeft")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .scaleEffect(
                        x: 1,
                        y: eyeLeftScaleY,
                        anchor: UnitPoint(x: 0.335, y: 0.43)
                    )
                    .offset(eyeLeftOffset)

                Image("FlowerollEyeRightWink")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .rotationEffect(
                        state == .tailBattle && time != 0 ? .degrees(-2.2) : .zero,
                        anchor: UnitPoint(x: 0.515, y: 0.378)
                    )

                Image("FlowerollMouth")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .scaleEffect(
                        x: mouthScale.width,
                        y: mouthScale.height,
                        anchor: UnitPoint(x: 0.435, y: 0.50)
                    )

                if !compact {
                    stateAccessory(in: size)
                }
            }
            .scaleEffect(x: 1, y: bodyScaleY, anchor: .bottom)
            .offset(y: bodyBob)
            .rotationEffect(wholeRotation, anchor: .bottom)
        }
    }

    @ViewBuilder
    private func stateAccessory(in size: CGSize) -> some View {
        switch state {
        case .idle:
            EmptyView()

        case .listening:
            HStack(spacing: max(3, size.width * 0.012)) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(Color.accentColor.opacity(0.36 + Double(index) * 0.12))
                        .frame(
                            width: max(2, size.width * 0.008),
                            height: size.height * CGFloat(0.08 + 0.035 * sin(time * 4.0 + Double(index)))
                        )
                }
            }
            .position(x: size.width * 0.055, y: size.height * 0.50)

        case .thinking:
            Text("…")
                .font(.system(size: max(14, size.width * 0.075), weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .position(x: size.width * 0.84, y: size.height * 0.12)
                .offset(y: CGFloat(sin(time * 1.6)) * 1.5)

        case .working:
            RoundedRectangle(cornerRadius: max(5, size.width * 0.018), style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    Image(systemName: "ellipsis")
                        .font(.system(size: max(9, size.width * 0.035), weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: size.width * 0.18, height: size.height * 0.105)
                .position(x: size.width * 0.82, y: size.height * 0.15)

        case .waiting:
            Image(systemName: "ellipsis.message.fill")
                .font(.system(size: max(14, size.width * 0.075), weight: .medium))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeating.speed(0.45))
                .position(x: size.width * 0.83, y: size.height * 0.14)

        case .done:
            ZStack {
                Image(systemName: "sparkle")
                    .font(.system(size: max(12, size.width * 0.06), weight: .medium))
                    .foregroundStyle(Color(red: 0.96, green: 0.55, blue: 0.62))
                    .position(x: size.width * 0.82, y: size.height * 0.13)
                Image(systemName: "sparkle")
                    .font(.system(size: max(8, size.width * 0.035), weight: .medium))
                    .foregroundStyle(Color(red: 0.96, green: 0.65, blue: 0.48))
                    .position(x: size.width * 0.15, y: size.height * 0.23)
            }
            .scaleEffect(1.0 + CGFloat((sin(time * 4.0) + 1.0) * 0.04))

        case .tailBattle:
            Image(systemName: "exclamationmark.3")
                .font(.system(size: max(11, size.width * 0.055), weight: .black))
                .foregroundStyle(.red.opacity(0.72))
                .rotationEffect(.degrees(-8))
                .position(x: size.width * 0.73, y: size.height * 0.12)
        }
    }
}
