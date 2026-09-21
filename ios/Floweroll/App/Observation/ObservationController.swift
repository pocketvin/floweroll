import Foundation
import Observation
import UIKit
import AVFAudio

@MainActor
@Observable
final class ObservationController {
    static let shared = ObservationController()
    var selectedPreset: ObservationPreset = .meeting
    var customSources: Set<ObservationSource> = [.screen, .ambientMicrophone]
    private(set) var record: ObservationSessionRecord?
    private(set) var events: [ObservationEvent] = []
    private(set) var history: [ObservationSessionRecord] = []
    private(set) var interim: [ObservationSource: String] = [:]
    private(set) var sourceIssues: [ObservationSource: String] = [:]
    private(set) var inputHeartbeats: [ObservationSource: Double] = [:]
    private(set) var inputLevelsDB: [ObservationSource: Double] = [:]
    private(set) var audibleHeartbeats: [ObservationSource: Double] = [:]
    private(set) var transcriptHeartbeats: [ObservationSource: Double] = [:]
    private(set) var connectionMessage: String?
    private(set) var errorMessage: String?
    private(set) var questionError: String?
    private(set) var isAsking = false
    private(set) var clockRevision = 0
    typealias CaptureFactory = @MainActor (Set<ObservationSource>, Int, ObservationCaptureCallbacks) -> any ObservationCaptureDriver
    @ObservationIgnored private let captureFactory: CaptureFactory?
    @ObservationIgnored private let observesSystem: Bool
    @ObservationIgnored private var journal: ObservationJournal?
    @ObservationIgnored private var capture: (any ObservationCaptureDriver)?
    @ObservationIgnored private var runStartUptime: Double?
    @ObservationIgnored private var captureGeneration = UUID()
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var audioSessionNotificationTokens: [NotificationCenter.ObservationToken] = []
    @ObservationIgnored private var syncBusy = false
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var lastIssueAt: [String: Double] = [:]
    @ObservationIgnored private var audioInterruptionGraceTask: Task<Void, Never>?
    @ObservationIgnored private var voiceConsumers: [UUID: VoiceConsumer] = [:]
    private struct VoiceConsumer {
        let startOffsetMS: Int
        var prefix: String
        var finalized = ""
        var volatile = ""
        let handler: (SpeechTranscriptionUpdate) -> Void
    }

    init(journal: ObservationJournal? = nil, observeSystem: Bool = true, captureFactory: CaptureFactory? = nil) {
        self.captureFactory = captureFactory
        self.observesSystem = observeSystem
        do {
            self.journal = try journal ?? ObservationJournal()
            record = try self.journal?.current()
            if var stored = record {
                events = try self.journal?.events(stored.id) ?? []
                stored.eventCount = events.count
                // No capture ever resumes automatically after process death.
                if stored.phase.capturesMayBeRunning || stored.phase == .authorizing {
                    stored.phase = .interrupted
                    stored.interruption = "应用重启后，上一段观察已停止。可以继续，或结束并整理已记录的内容。"
                } else if stored.hasEnded,
                          stored.hostView?.status == "completed" || stored.hostView?.notes.contains(where: { $0.kind == "final" }) == true {
                    // Repair an older/stale local phase from the durable Host
                    // result so a finished record never reopens as "正在整理".
                    stored.phase = .completed
                }
                record = stored
                try self.journal?.save(stored)
            }
            refreshHistory()
        } catch {
            errorMessage = "观察记录暂时无法读取。为避免丢失内容，暂不能开始新的观察。"
        }
        guard observeSystem else { return }
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setForeground(false) }
        })
        notificationTokens.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setForeground(true) }
        })
        let audioSession = AVAudioSession.sharedInstance()
        audioSessionNotificationTokens.append(
            center.addObserver(of: audioSession, for: .didBecomeInactive) { [weak self] message in
                guard let self,
                      Self.audioDeactivationIsSystemInterruption(message.deactivationResult)
                else { return }
                self.handleAudioInterruptionBegan()
            }
        )
        audioSessionNotificationTokens.append(
            center.addObserver(of: audioSession, for: .resumptionRecommendation) { [weak self] message in
                guard let self,
                      Self.audioResumptionShouldResume(message.recommendation)
                else { return }
                self.handleAudioInterruptionEnded()
            }
        )
        notificationTokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue || reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue {
                Task { @MainActor in
                    guard self?.record?.configuration.sources.contains(.ambientMicrophone) == true else { return }
                    if self?.activeSources == [.ambientMicrophone] {
                        self?.interrupt("麦克风设备发生变化，已暂停以避免漏记。点击继续重新连接。")
                    } else {
                        self?.sourceIssue(.ambientMicrophone, "麦克风设备发生变化；屏幕与手机声音继续观察。")
                    }
                }
            }
        })
        notificationTokens.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                if ProcessInfo.processInfo.thermalState == .critical { self?.interrupt("设备温度过高，已暂停观察。") }
            }
        })
        statusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                if self.record?.phase == .observing {
                    self.clockRevision &+= 1
                    let now = ProcessInfo.processInfo.systemUptime
                    for source in self.activeSources where source != .screen {
                        let lastInput = self.inputHeartbeats[source] ?? self.runStartUptime ?? 0
                        if now - lastInput > 20, self.sourceIssues[source] == nil {
                            self.sourceIssue(source, "暂时没有收到" + source.title + "输入；静音、通话或受保护内容可能无法采集。")
                            continue
                        }
                        let audible = self.audibleHeartbeats[source] ?? 0
                        let transcript = self.transcriptHeartbeats[source] ?? self.runStartUptime ?? 0
                        if audible > 0, now - audible < 5, now - transcript > 15,
                           self.sourceIssues[source] == nil {
                            self.sourceIssue(source, "已经收到" + source.title + "声音，但本机语音识别暂时没有产出文字。")
                        }
                    }
                    if self.elapsedSeconds >= ObservationLimits.maximumDuration {
                        self.errorMessage = "已达到单次四小时上限，正在停止并整理记录。"
                        await self.end()
                    }
                }
            }
        }
        if record != nil { startSyncLoop() }
    }

    isolated deinit {
        statusTask?.cancel()
        syncTask?.cancel()
        let center = NotificationCenter.default
        for token in notificationTokens {
            center.removeObserver(token)
        }
        for token in audioSessionNotificationTokens {
            center.removeObserver(token)
        }
    }

    var phase: ObservationPhase { record?.phase ?? .setup }
    var hasSession: Bool { record != nil }
    var activeSources: Set<ObservationSource> { Set(record?.configuration.sources ?? []) }
    var effectiveSources: Set<ObservationSource> { selectedPreset == .custom ? customSources : selectedPreset.sources }
    var isCapturing: Bool { phase == .observing && capture != nil }
    var homeTitle: String {
        if canSaveCurrentToTaskHistory { return "整理完成" }
        switch phase {
        case .observing: return "观察中"
        case .paused, .interrupted: return "观察已暂停"
        case .finalizing: return "正在整理"
        case .completed: return "整理完成"
        case .stopUnconfirmed: return "观察待停止"
        default: return "观察"
        }
    }
    var sessionTitle: String {
        if canSaveCurrentToTaskHistory { return latestSummary?.title ?? "整理完成" }
        return phase.title
    }
    var latestSummary: ObservationSummary? { record?.hostView?.notes.last }
    private var hasFullyCoveredFallbackSummary: Bool {
        guard record?.hasEnded == true,
              let view = record?.hostView,
              view.status == "analysis_failed",
              view.analysisRunning == false,
              !view.notes.isEmpty else { return false }
        return view.summaryThroughSeq >= view.eventCount
    }
    var canSaveCurrentToTaskHistory: Bool {
        record?.hasEnded == true && (
            phase == .completed
                || record?.hostView?.status == "completed"
                || finalSummary != nil
                || hasFullyCoveredFallbackSummary
        )
    }
    var canStartNew: Bool { record == nil || phase == .completed || (phase == .failed && events.isEmpty) }
    var elapsedSeconds: TimeInterval {
        (record?.capturedSeconds ?? 0) + (runStartUptime.map { max(0, ProcessInfo.processInfo.systemUptime - $0) } ?? 0)
    }
    var elapsedText: String {
        let value = Int(elapsedSeconds)
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%02d:%02d", value / 60, value % 60)
    }
    var finalSummary: ObservationSummary? { record?.hostView?.notes.last { $0.kind == "final" } }
    var presentationEvents: [ObservationEvent] { ObservationTimelineFusion.presentationEvents(events) }
    var suppressedEchoCount: Int { ObservationTimelineFusion.suppressedEchoCount(events) }
    var screenInsights: [ObservationScreenInsight] { record?.hostView?.screenInsights ?? [] }
    var presentationInterimSources: [ObservationSource] {
        var sources = ObservationSource.allCases.filter { !(interim[$0] ?? "").isEmpty }
        if let ambient = interim[.ambientMicrophone], let device = interim[.deviceAudio],
           !ambient.isEmpty, !device.isEmpty,
           ObservationTimelineFusion.textsLikelyEcho(ambient: ambient, device: device) {
            sources.removeAll { $0 == .ambientMicrophone }
        }
        return sources
    }
    func screenInsight(for eventID: String) -> ObservationScreenInsight? {
        screenInsights.last { $0.eventID == eventID }
    }
    var pendingCount: Int { events.filter { !(record?.acknowledgedIDs.contains($0.id) ?? false) }.count }
    var statusMessage: String {
        if let errorMessage { return errorMessage }
        if hasFullyCoveredFallbackSummary {
            return "最新整理已经覆盖全部记录，可以直接存入历史。最终总合并暂时未完成，但不会影响已整理内容。"
        }
        if let connectionMessage { return connectionMessage }
        if let error = record?.hostView?.lastError { return Self.analysisError(error) }
        if let interruption = record?.interruption, phase == .interrupted { return interruption }
        switch phase {
        case .authorizing, .preparing: return "请在系统面板确认共享；语言模型首次准备可能需要一点时间。"
        case .observing:
            return events.contains { $0.kind == "transcript" || $0.kind == "screen" }
                ? "正在记录。你可以回主页继续交给小卷其他任务。"
                : (activeSources == [.screen] ? "切换到其他 App 后会开始理解画面，小卷不会分析自己的页面。" : "已经开始，等待可识别的内容。")
        case .pausing, .stopping: return "正在关闭采集并保存最后一段内容。"
        case .stopUnconfirmed: return "系统尚未确认停止共享。请在系统面板停止，或再次点击结束；小卷不再处理新内容。"
        case .paused: return "没有采集新内容。继续后会接着记录。"
        case .interrupted: return "观察已中断，需要你点击继续。"
        case .finalizing: return pendingCount > 0 ? "采集已停止，正在同步最后的记录。" : "采集已停止，正在根据实际记录整理纪要。"
        case .completed: return "纪要由实际记录自动整理，重要信息请核对原文。"
        case .failed: return "没有继续采集。请检查权限或连接后重试。"
        case .setup: return ""
        }
    }
    var exportText: String {
        var parts = [finalSummary?.markdown ?? "# 观察记录"]
        if finalSummary == nil {
            parts += (record?.hostView?.notes ?? []).map(\.markdown)
        }
        parts.append("## 观察时间线")
        if suppressedEchoCount > 0 { parts.append("已自动合并 \(suppressedEchoCount) 条来自扬声器串入麦克风的重复转写。") }
        parts += presentationEvents.filter { $0.kind != "lifecycle" }.map {
            let source = ObservationSource(rawValue: $0.source)?.title ?? "记录说明"
            let seconds = $0.offsetMS / 1000
            return String(format: "[%02d:%02d] ", seconds / 60, seconds % 60) + source + "\n" + ($0.text.isEmpty ? "画面已采集；此处没有可转写文字。" : $0.text)
        }
        return parts.joined(separator: "\n\n")
    }

    func toggleCustomSource(_ source: ObservationSource) {
        if customSources.contains(source) { customSources.remove(source) } else { customSources.insert(source) }
    }
    func newSession() {
        guard canStartNew else { return }
        do { try journal?.clearCurrent() }
        catch { errorMessage = "暂时无法新建观察，请稍后重试。"; return }
        syncTask?.cancel(); syncTask = nil
        record = nil; events = []; interim = [:]; sourceIssues = [:]; inputHeartbeats = [:]; inputLevelsDB = [:]; audibleHeartbeats = [:]; transcriptHeartbeats = [:]
        errorMessage = nil; connectionMessage = nil; questionError = nil
        refreshHistory()
    }
    /// Move the finished observation out of the working surface and expose it
    /// in the unified Tasks > History list. The session/evidence files are
    /// already durable; clearing only the current pointer is the archive commit.
    @discardableResult
    func saveCurrentToTaskHistory() -> Bool {
        guard let snapshot = record, canSaveCurrentToTaskHistory else { return false }
        do { try journal?.clearCurrent() }
        catch {
            errorMessage = "暂时无法保存到任务历史，请稍后重试。"
            return false
        }
        syncTask?.cancel(); syncTask = nil
        record = nil; events = []; interim = [:]; sourceIssues = [:]
        inputHeartbeats = [:]; inputLevelsDB = [:]; audibleHeartbeats = [:]; transcriptHeartbeats = [:]
        errorMessage = nil; connectionMessage = nil; questionError = nil
        refreshHistory()
        return history.contains { $0.id == snapshot.id }
    }
    func begin(endpoint: String) {
        guard record == nil, !effectiveSources.isEmpty, journal != nil else { return }
        guard let url = URL(string: endpoint), !endpoint.isEmpty else { errorMessage = "请先在设置中连接花卷的后台。"; return }
        do { try FlowerollHostClient.paired(baseURL: url).validateEndpointSecurity() }
        catch { errorMessage = "后台连接或配对凭据不完整，请先检查设置。"; return }
        guard #available(iOS 27.0, *) else { errorMessage = "观察模式需要 iOS 27 或更高版本。"; return }
        let configuration = ObservationConfiguration(id: UUID().uuidString, preset: selectedPreset,
            sources: effectiveSources.sorted { $0.rawValue < $1.rawValue }, createdAt: observationTimestamp(), consentVersion: 1)
        record = ObservationSessionRecord(configuration: configuration, endpoint: endpoint, phase: .authorizing)
        events = []; interim = [:]; sourceIssues = [:]; inputHeartbeats = [:]; inputLevelsDB = [:]; audibleHeartbeats = [:]; transcriptHeartbeats = [:]; errorMessage = nil
        guard persist() else { record = nil; return }
        startSyncLoop()
        startNative()
    }
    func resume() {
        guard [.paused, .interrupted].contains(phase), record?.hasEnded == false else { return }
        errorMessage = nil; record?.interruption = nil; sourceIssues = [:]
        startNative()
    }
    private func startNative() {
        guard #available(iOS 27.0, *), let record else { return }
        let generation = UUID(); captureGeneration = generation
        self.record?.phase = .preparing; persist()
        let callbacks = ObservationCaptureCallbacks(evidence: { [weak self] event in
            guard let self, self.captureGeneration == generation else { return }
            self.receive(event)
        }, interim: { [weak self] source, text in
            guard let self, self.captureGeneration == generation else { return }
            self.interim[source] = text
            if !text.isEmpty {
                self.transcriptHeartbeats[source] = ProcessInfo.processInfo.systemUptime
                if self.sourceIssues[source]?.hasPrefix("已经收到") == true { self.sourceIssues[source] = nil }
            }
            if source == .ambientMicrophone { self.voiceInterim(text) }
        }, input: { [weak self] source, pulse in
            guard let self, self.captureGeneration == generation else { return }
            self.inputHeartbeats[source] = pulse.uptime
            self.inputLevelsDB[source] = pulse.rmsDB
            if pulse.rmsDB > -48 { self.audibleHeartbeats[source] = pulse.uptime }
            if self.sourceIssues[source]?.hasPrefix("暂时没有收到") == true
                || self.sourceIssues[source]?.hasPrefix("麦克风输入暂时中断") == true
                || self.sourceIssues[source]?.hasPrefix("麦克风被系统音频暂时占用") == true {
                self.sourceIssues[source] = nil
            }
        }, issue: { [weak self] source, message in
            guard let self, self.captureGeneration == generation else { return }
            if let source { self.sourceIssue(source, message) } else { self.interrupt(message) }
        })
        let engine: any ObservationCaptureDriver
        if let captureFactory {
            engine = captureFactory(Set(record.configuration.sources), currentOffsetMS, callbacks)
        } else {
            engine = ObservationCaptureEngine(sources: Set(record.configuration.sources), offsetMS: currentOffsetMS, callbacks: callbacks)
        }
        engine.setAppForeground(foreground)
        capture = engine
        startTask = Task { @MainActor [weak self] in
            do {
                try await engine.start()
                try Task.checkCancellation()
                guard let self, self.captureGeneration == generation else { try? await engine.stop(); return }
                self.record?.phase = .observing
                self.runStartUptime = ProcessInfo.processInfo.systemUptime
                self.receiveLifecycle("已开始实际采集。")
                self.persist()
            } catch {
                try? await engine.stop()
                guard let self, self.captureGeneration == generation,
                      self.phase != .stopping, self.phase != .pausing, self.phase != .stopUnconfirmed else { return }
                self.capture = nil; self.runStartUptime = nil
                self.record?.phase = self.events.contains { $0.kind != "lifecycle" } ? .interrupted : .failed
                self.errorMessage = error.localizedDescription
                self.record?.interruption = self.errorMessage
                self.persist()
            }
        }
    }
    private var currentOffsetMS: Int {
        guard let stamp = record?.configuration.createdAt else { return 0 }
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = format.date(from: stamp) else { return 0 }
        return max(0, min(86_400_000, Int(Date().timeIntervalSince(date) * 1000)))
    }
    func pause() async {
        guard phase == .observing else { return }
        await stopNative(ending: false, interruption: nil)
    }
    func end() async {
        guard record != nil, ![.stopping, .pausing, .completed].contains(phase) else { return }
        if record?.hasEnded == true { await retryAnalysis(); return }
        await stopNative(ending: true, interruption: nil)
    }
    private func handleAudioInterruptionBegan() {
        guard phase == .observing, activeSources.contains(.ambientMicrophone) else { return }
        let baselineInput = inputHeartbeats[.ambientMicrophone]
        // Full-display ScreenCaptureKit can transiently reconfigure the shared
        // AVAudioSession as another app starts playback. Treat the system
        // notification only as a candidate interruption: raw microphone input
        // heartbeat is the actual source of truth.
        audioInterruptionGraceTask?.cancel()
        audioInterruptionGraceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, self.phase == .observing,
                  self.activeSources.contains(.ambientMicrophone) else { return }
            let latestInput = self.inputHeartbeats[.ambientMicrophone]
            guard !Self.microphoneInputAdvanced(since: baselineInput, latest: latestInput) else { return }
            if self.activeSources == [.ambientMicrophone] {
                await self.stopNative(ending: false, interruption: "麦克风输入持续中断，观察已暂停。")
            } else {
                self.sourceIssue(.ambientMicrophone, "麦克风输入暂时中断；其他观察来源继续。")
            }
        }
    }
    private func handleAudioInterruptionEnded() {
        audioInterruptionGraceTask?.cancel(); audioInterruptionGraceTask = nil
        if sourceIssues[.ambientMicrophone]?.hasPrefix("麦克风输入暂时中断") == true
            || sourceIssues[.ambientMicrophone]?.hasPrefix("麦克风被系统音频暂时占用") == true {
            sourceIssues[.ambientMicrophone] = nil
        }
        if phase == .observing, activeSources.contains(.ambientMicrophone) {
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }
    nonisolated static func audioDeactivationIsSystemInterruption(
        _ result: AVAudioSession.DeactivationResult
    ) -> Bool {
        switch result {
        case .systemInterruption:
            return true
        case .appDeactivated:
            return false
        @unknown default:
            return false
        }
    }
    nonisolated static func audioResumptionShouldResume(
        _ recommendation: AVAudioSession.ResumptionRecommendation
    ) -> Bool {
        recommendation == .shouldResume
    }
    nonisolated static func microphoneInputAdvanced(since baseline: Double?, latest: Double?) -> Bool {
        guard let latest else { return false }
        guard let baseline else { return true }
        return latest > baseline + 0.001
    }
    private func interrupt(_ message: String) {
        guard phase == .observing else { return }
        Task { @MainActor in await stopNative(ending: false, interruption: message) }
    }
    private func stopNative(ending: Bool, interruption: String?) async {
        guard record != nil, ![.stopping, .pausing].contains(phase) else { return }
        let captured = elapsedSeconds
        record?.capturedSeconds = captured; runStartUptime = nil
        record?.phase = ending ? .stopping : .pausing
        startTask?.cancel(); startTask = nil
        persist()
        do { try await capture?.stop() }
        catch {
            // Do not let a network/finalization state claim that native capture
            // stopped before the system confirmed it. Keep the driver for retry.
            captureGeneration = UUID()
            voiceConsumers.removeAll(); interim = [:]
            record?.phase = .stopUnconfirmed
            errorMessage = error.localizedDescription
            persist()
            return
        }
        errorMessage = nil
        capture = nil; captureGeneration = UUID()
        voiceConsumers.removeAll(); interim = [:]
        record?.hasEnded = ending
        record?.interruption = interruption
        record?.phase = ending ? .finalizing : (interruption == nil ? .paused : .interrupted)
        receiveLifecycle(ending ? "实际采集已停止，准备整理。" : (interruption ?? "已暂停采集。"))
        persist()
        if ending { refreshHistory() }
        startSyncLoop()
    }
    private func sourceIssue(_ source: ObservationSource, _ message: String) {
        let key = source.rawValue + message
        let now = ProcessInfo.processInfo.systemUptime
        guard now - (lastIssueAt[key] ?? -100) > 30 else { return }
        lastIssueAt[key] = now
        sourceIssues[source] = message
        receive(ObservationEvent(source: source.rawValue, kind: "gap", capturedAt: observationTimestamp(), offsetMS: currentOffsetMS, durationMS: 0, text: message))
    }
    private func receiveLifecycle(_ text: String) {
        receive(ObservationEvent(source: "system", kind: "lifecycle", capturedAt: observationTimestamp(), offsetMS: currentOffsetMS, durationMS: 0, text: text))
    }
    private func receive(_ event: ObservationEvent) {
        guard var record, !record.hasEnded || event.kind == "lifecycle" else { return }
        guard !events.contains(where: { $0.id == event.id }) else { return }
        if event.kind != "lifecycle", events.count >= ObservationLimits.eventCount - 4 {
            interrupt("这段观察已经达到记录上限，请结束整理后开始新的一段。")
            return
        }
        let pendingBytes = events.filter { !record.acknowledgedIDs.contains($0.id) }.reduce(0) { $0 + $1.text.utf8.count + ($1.imageBase64?.utf8.count ?? 0) }
        if event.kind != "lifecycle", pendingBytes > ObservationLimits.offlineBytes {
            interrupt("离线待同步内容过多，已暂停以保护记录。恢复连接后可以继续。")
            return
        }
        do {
            try journal?.append(event, to: record)
            events.append(event)
            record.eventCount = events.count
            self.record = record
            persist()
            if event.kind == "transcript", let source = ObservationSource(rawValue: event.source) {
                transcriptHeartbeats[source] = ProcessInfo.processInfo.systemUptime
                if sourceIssues[source]?.hasPrefix("已经收到") == true { sourceIssues[source] = nil }
                if source == .ambientMicrophone { voiceFinal(event) }
            }
        } catch {
            errorMessage = "记录保存失败，正在停止采集，避免丢失更多内容。"
            interrupt(errorMessage!)
        }
    }
    @discardableResult private func persist() -> Bool {
        guard var snapshot = record, let journal else { return false }
        snapshot.capturedSeconds = elapsedSeconds
        do { try journal.save(snapshot); return true }
        catch { errorMessage = "观察记录保存失败，请检查设备可用空间。"; return false }
    }
    private func setForeground(_ value: Bool) {
        foreground = value; capture?.setAppForeground(value)
        if value { clockRevision &+= 1; startSyncLoop() }
    }
    private func pairedClient(for record: ObservationSessionRecord) throws -> FlowerollHostClient {
        guard let url = URL(string: record.endpoint) else { throw HostClientSecurityError.invalidEndpoint }
        let configuration = URLSessionConfiguration.ephemeral
        // Observation keyframes can be a few hundred KB over a mobile tunnel.
        // Keep this independent from the normal Task client so a slow image ACK
        // cannot make ordinary task reads feel disconnected.
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 2
        return try FlowerollHostClient.paired(baseURL: url, session: URLSession(configuration: configuration))
    }
    private func startSyncLoop() {
        guard observesSystem, syncTask == nil, record != nil else { return }
        syncTask = Task { @MainActor [weak self] in
            var delay = 1.0
            while !Task.isCancelled {
                guard let self, self.record != nil else { return }
                let success = await self.syncOnce()
                delay = success ? (self.pendingCount > 0 ? 1 : 8) : min(30, max(4, delay * 2))
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }
    @discardableResult
    func syncOnce() async -> Bool {
        guard !syncBusy, let snapshot = record else { return false }
        syncBusy = true; defer { syncBusy = false }
        let sid = snapshot.id
        do {
            let client = try pairedClient(for: snapshot)
            if !snapshot.hostCreated {
                let data = try await client.observationRequest(method: "POST", suffix: ["sessions"], body: JSONEncoder().encode(snapshot.configuration))
                let view = try JSONDecoder().decode(ObservationHostView.self, from: data)
                guard record?.id == sid else { return false }
                record?.hostCreated = true; adopt(view); persist()
            }
            guard record?.id == sid else { return false }
            // One small batch per iteration keeps ordinary Task network work responsive.
            var pending = Self.uploadBatch(events, acknowledgedIDs: record?.acknowledgedIDs ?? [])
            if !pending.isEmpty {
                // Large keyframes can reach the Host even when the tunnel drops
                // the response. Reconcile exact IDs before replaying expensive
                // images (and always while finalizing) so recovery is cheap.
                if snapshot.hasEnded || pending.contains(where: { $0.imageBase64 != nil }) {
                    struct EventStatusBody: Encodable { let ids: [String] }
                    struct EventStatus: Decodable {
                        let acknowledgedIDs: [String]
                        enum CodingKeys: String, CodingKey { case acknowledgedIDs = "acknowledged_ids" }
                    }
                    let statusData = try await client.observationRequest(
                        method: "POST",
                        suffix: ["sessions", sid, "event-status"],
                        body: JSONEncoder().encode(EventStatusBody(ids: pending.map(\.id)))
                    )
                    let status = try JSONDecoder().decode(EventStatus.self, from: statusData)
                    guard record?.id == sid else { return false }
                    let candidates = Set(pending.map(\.id))
                    let reconciled = Set(status.acknowledgedIDs)
                    guard reconciled.isSubset(of: candidates) else { throw URLError(.badServerResponse) }
                    if !reconciled.isEmpty {
                        record?.acknowledgedIDs.formUnion(reconciled)
                        guard persist() else { return false }
                        try journal?.removeAcknowledgedImages(reconciled, sessionID: sid)
                        events = events.map { reconciled.contains($0.id) ? $0.withoutImage : $0 }
                        pending = Self.uploadBatch(events, acknowledgedIDs: record?.acknowledgedIDs ?? [])
                    }
                }
            }
            if !pending.isEmpty {
                struct Batch: Encodable { let events: [ObservationEvent] }
                let data = try await client.observationRequest(method: "POST", suffix: ["sessions", sid, "events"], body: JSONEncoder().encode(Batch(events: pending)))
                let receipt = try JSONDecoder().decode(ObservationUploadReceipt.self, from: data)
                guard record?.id == sid else { return false }
                let sent = Set(pending.map(\.id))
                guard Set(receipt.acknowledgedIDs) == sent else { throw URLError(.badServerResponse) }
                record?.acknowledgedIDs.formUnion(sent)
                // Persist ACK first; stripping images must never change an unacknowledged replay.
                guard persist() else { return false }
                try journal?.removeAcknowledgedImages(sent, sessionID: sid)
                events = events.map { sent.contains($0.id) ? $0.withoutImage : $0 }
                adopt(receipt.session)
            }
            guard record?.id == sid else { return false }
            if record?.hasEnded == true, pendingCount == 0, record?.hostView?.status == "recording" {
                let body = try JSONSerialization.data(withJSONObject: ["event_count": events.count])
                let data = try await client.observationRequest(method: "POST", suffix: ["sessions", sid, "finish"], body: body)
                adopt(try JSONDecoder().decode(ObservationHostView.self, from: data))
            } else {
                let data = try await client.observationRequest(method: "GET", suffix: ["sessions", sid])
                guard record?.id == sid else { return false }
                adopt(try JSONDecoder().decode(ObservationHostView.self, from: data))
            }
            connectionMessage = nil
            if record?.hostView?.modelReady == false { connectionMessage = "后台的 AI 尚未配置，原始记录已保存，但暂时无法生成总结。" }
            persist()
            return true
        } catch {
            guard record?.id == sid else { return false }
            connectionMessage = record?.hasEnded == true
                ? "采集已停止，后台暂时不可达。记录保存在本机，连接恢复后继续整理。"
                : "后台暂时不可达，正在保存在本机，连接恢复后同步。"
            persist()
            return false
        }
    }
    static func uploadBatch(_ events: [ObservationEvent], acknowledgedIDs: Set<String>) -> [ObservationEvent] {
        var batch: [ObservationEvent] = []
        var bytes = 32
        for event in events where !acknowledgedIDs.contains(event.id) {
            guard batch.count < 4 else { break }
            guard let data = try? JSONEncoder().encode(event) else { break }
            let nextBytes = bytes + data.count + 1
            if nextBytes > ObservationLimits.uploadBatchBytes {
                // Never deadlock on one legitimate high-quality keyframe. Send
                // it alone with the longer Observation timeout; following
                // events wait for its exact ACK.
                if batch.isEmpty, data.count < ObservationLimits.uploadSingleEventFallbackBytes {
                    batch.append(event)
                }
                break
            }
            batch.append(event); bytes = nextBytes
        }
        return batch
    }
    private func adopt(_ view: ObservationHostView) {
        guard view.id == record?.id else { return }
        record?.hostView = view
        if record?.hasEnded == true, view.status == "completed" {
            record?.phase = .completed
            persist()
            refreshHistory()
        }
    }

    private func refreshHistory() {
        let currentID = record?.id
        history = (journal?.records() ?? []).filter { $0.id != currentID }
    }
    func retryAnalysis() async {
        guard let record else { return }
        do {
            let client = try pairedClient(for: record)
            let data = try await client.observationRequest(method: "POST", suffix: ["sessions", record.id, "retry"], body: Data("{}".utf8))
            adopt(try JSONDecoder().decode(ObservationHostView.self, from: data))
            connectionMessage = nil
        } catch { connectionMessage = "暂时无法连接后台，请稍后重试。" }
    }
    func ask(_ question: String) async {
        guard let snapshot = record, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isAsking else { return }
        isAsking = true; questionError = nil; defer { isAsking = false }
        _ = await syncOnce()
        do {
            let client = try pairedClient(for: snapshot)
            let body = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "question": question])
            let data = try await client.observationRequest(method: "POST", suffix: ["sessions", snapshot.id, "questions"], body: body)
            adopt(try JSONDecoder().decode(ObservationHostView.self, from: data)); persist()
        } catch { questionError = "暂时无法提交问题。原始记录仍保留，可稍后再问。" }
    }
    func loadHistory(_ item: ObservationSessionRecord) {
        guard canStartNew || record?.id == item.id else { return }
        guard item.hasEnded || item.phase == .failed else { return }
        syncTask?.cancel(); syncTask = nil
        do { events = try journal?.events(item.id) ?? []; record = item; persist(); errorMessage = nil; startSyncLoop() }
        catch { errorMessage = "这段观察记录无法读取。" }
    }
    func deleteCurrent() async {
        guard let item = record, item.hasEnded || phase == .failed else { return }
        _ = await deleteHistory(item)
    }
    @discardableResult
    func deleteHistory(_ item: ObservationSessionRecord) async -> Bool {
        guard item.hasEnded || item.phase == .failed || item.phase == .completed else { return false }
        do {
            if item.hostCreated {
                let client = try pairedClient(for: item)
                _ = try await client.observationRequest(method: "POST", suffix: ["sessions", item.id, "delete"], body: Data("{}".utf8))
            }
            if record?.id == item.id {
                syncTask?.cancel(); syncTask = nil
            }
            try journal?.delete(item.id)
            if record?.id == item.id {
                record = nil; events = []; interim = [:]; sourceIssues = [:]
                inputHeartbeats = [:]; inputLevelsDB = [:]; audibleHeartbeats = [:]; transcriptHeartbeats = [:]
                errorMessage = nil; connectionMessage = nil
            }
            refreshHistory()
            return true
        } catch {
            errorMessage = "删除尚未完成，请连接后台后重试，避免只删掉一端的记录。"
            return false
        }
    }
    static func analysisError(_ code: String) -> String {
        if code == "MODEL_NOT_CONFIGURED" { return "后台 AI 未配置，原始记录已经保留。" }
        if code.hasPrefix("MODEL_HTTP_429") { return "AI 服务暂时限流，记录已保留，可稍后重新整理。" }
        if code == "SUMMARY_CONTEXT_LIMIT" { return "记录较长，自动整理超过单次处理上限。原始记录已保留，可以分段查看。" }
        return "AI 整理未成功，原始记录已保留，可点击重新整理。"
    }

    // Composer and observation share the selected live microphone transcript.
    // Starting/stopping a normal voice command must not start/stop native capture.
    var canShareVoiceInput: Bool { isCapturing && activeSources.contains(.ambientMicrophone) }
    func beginSharedVoiceInput(handler: @escaping (SpeechTranscriptionUpdate) -> Void) -> UUID? {
        guard canShareVoiceInput else { return nil }
        let id = UUID()
        voiceConsumers[id] = VoiceConsumer(startOffsetMS: currentOffsetMS, prefix: interim[.ambientMicrophone] ?? "", handler: handler)
        return id
    }
    func endSharedVoiceInput(_ id: UUID) -> String {
        guard let consumer = voiceConsumers.removeValue(forKey: id) else { return "" }
        return consumer.finalized + consumer.volatile
    }
    private func voiceInterim(_ text: String) {
        for id in Array(voiceConsumers.keys) {
            guard var consumer = voiceConsumers[id] else { continue }
            consumer.volatile = trimmedVoice(text, prefix: consumer.prefix)
            consumer.handler(.init(finalized: consumer.finalized, volatile: consumer.volatile))
            voiceConsumers[id] = consumer
        }
    }
    private func voiceFinal(_ event: ObservationEvent) {
        for id in Array(voiceConsumers.keys) {
            guard var consumer = voiceConsumers[id] else { continue }
            guard event.offsetMS + event.durationMS >= consumer.startOffsetMS else { continue }
            consumer.finalized += trimmedVoice(event.text, prefix: consumer.prefix)
            consumer.prefix = ""; consumer.volatile = ""
            consumer.handler(.init(finalized: consumer.finalized, volatile: ""))
            voiceConsumers[id] = consumer
        }
    }
    private func trimmedVoice(_ text: String, prefix: String) -> String {
        guard !prefix.isEmpty else { return text }
        return text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : String(text.dropFirst(min(prefix.count, text.count)))
    }
}
