import XCTest
import AVFoundation
import Speech
@testable import Floweroll

/// Test-only driver: exercises controller state/ACK/fencing without requesting
/// microphone or screen consent. Physical framework proof is a separate test.
@MainActor
private final class ObservationTestDriver: ObservationCaptureDriver {
    var starts = 0
    var stops = 0
    var stopFails = false
    var callbacks: ObservationCaptureCallbacks?
    var lastOnStop = false
    func start() async throws { starts += 1 }
    func stop() async throws {
        stops += 1
        if stopFails { throw ObservationCaptureError.stopUnconfirmed }
        if lastOnStop {
            callbacks?.evidence(.init(source: "ambientMicrophone", kind: "transcript", capturedAt: observationTimestamp(), offsetMS: 100, durationMS: 100, text: "停止前的最后一句。"))
            lastOnStop = false
        }
    }
    func setAppForeground(_ foreground: Bool) {}
}

@MainActor
final class ObservationTests: XCTestCase {
    private var root: URL!
    private var journal: ObservationJournal!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ObservationTests-" + UUID().uuidString)
        journal = try ObservationJournal(root: root)
    }
    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        journal = nil; root = nil
    }
    private func configuration(_ sources: [ObservationSource] = [.ambientMicrophone]) -> ObservationConfiguration {
        .init(id: UUID().uuidString, preset: .custom, sources: sources, createdAt: observationTimestamp(), consentVersion: 1)
    }
    private func event(text: String = "演示完成之后再确认上线时间。") -> ObservationEvent {
        .init(source: "ambientMicrophone", kind: "transcript", capturedAt: observationTimestamp(), offsetMS: 100, durationMS: 500, text: text)
    }
    private func controller(driver: ObservationTestDriver) -> ObservationController {
        ObservationController(journal: journal, observeSystem: false, captureFactory: { _, _, callbacks in
            driver.callbacks = callbacks
            return driver
        })
    }
    private func awaitPhase(_ phase: ObservationPhase, _ controller: ObservationController) async {
        for _ in 0..<200 {
            if controller.phase == phase { return }
            await Task.yield()
        }
        XCTAssertEqual(controller.phase, phase)
    }
    func testAllSevenSourceCombinationsAreExplicit() {
        let controller = ObservationController(journal: journal, observeSystem: false)
        controller.selectedPreset = .custom
        for mask in 1...7 {
            let selected = Set(ObservationSource.allCases.enumerated().compactMap { (mask & (1 << $0.offset)) != 0 ? $0.element : nil })
            controller.customSources = selected
            XCTAssertEqual(controller.effectiveSources, selected)
        }
        XCTAssertEqual(ObservationPreset.meeting.sources, [.ambientMicrophone])
        XCTAssertEqual(ObservationPreset.media.sources, [.screen, .deviceAudio])
        XCTAssertEqual(ObservationPreset.combined.sources, Set(ObservationSource.allCases))
    }
    func testEmptySourcesDoNotStartNativeOrCreateRecord() {
        let driver = ObservationTestDriver(); let controller = controller(driver: driver)
        controller.selectedPreset = .custom; controller.customSources = []
        controller.begin(endpoint: "http://127.0.0.1:9")
        XCTAssertFalse(controller.hasSession); XCTAssertEqual(driver.starts, 0)
    }
    func testRemoteUnpairedEndpointDoesNotStartNative() {
        let driver = ObservationTestDriver(); let controller = controller(driver: driver)
        controller.begin(endpoint: "http://remote.invalid")
        XCTAssertFalse(controller.hasSession); XCTAssertEqual(driver.starts, 0)
        XCTAssertNotNil(controller.errorMessage)
    }
    func testJournalAckRemovesOnlyImagesAndRetainsIdentity() throws {
        let record = ObservationSessionRecord(configuration: configuration([.screen]), endpoint: "https://paired.example", phase: .observing)
        try journal.save(record)
        let frame = ObservationEvent(source: "screen", kind: "screen", capturedAt: observationTimestamp(), offsetMS: 300, durationMS: 0, text: "标题文字", imageBase64: "test-frame")
        try journal.append(frame, to: record)
        try journal.append(frame, to: record)
        XCTAssertEqual(try journal.events(record.id).count, 1)
        XCTAssertNotNil(try journal.events(record.id)[0].imageBase64)
        try journal.removeAcknowledgedImages([frame.id], sessionID: record.id)
        let reread = try journal.events(record.id)[0]
        XCTAssertEqual(reread.id, frame.id); XCTAssertEqual(reread.text, frame.text)
        XCTAssertNil(reread.imageBase64)
    }
    func testDeleteClearsCurrentPointerWithoutBreakingOtherRecords() throws {
        let one = ObservationSessionRecord(configuration: configuration(), endpoint: "http://127.0.0.1", phase: .completed)
        let two = ObservationSessionRecord(configuration: configuration(), endpoint: "http://127.0.0.1", phase: .completed)
        try journal.save(one); try journal.save(two)
        try journal.delete(two.id)
        XCTAssertNil(try journal.current())
        XCTAssertEqual(journal.records().map(\.id), [one.id])
    }
    func testRelaunchActiveCaptureNeverAutoResumes() throws {
        for phase in [ObservationPhase.authorizing, .preparing, .observing, .pausing, .stopping, .stopUnconfirmed] {
            let record = ObservationSessionRecord(configuration: configuration(), endpoint: "http://127.0.0.1", phase: phase)
            try journal.save(record); try journal.append(event(), to: record)
            let driver = ObservationTestDriver(); let controller = controller(driver: driver)
            XCTAssertEqual(controller.phase, .interrupted)
            XCTAssertEqual(driver.starts, 0)
            XCTAssertEqual(controller.events.count, 1)
            XCTAssertFalse(controller.isCapturing)
        }
    }
    func testNewSessionClearsPointerButKeepsHistory() throws {
        var record = ObservationSessionRecord(configuration: configuration(), endpoint: "http://127.0.0.1", phase: .completed)
        record.hasEnded = true; try journal.save(record)
        let controller = ObservationController(journal: journal, observeSystem: false)
        controller.newSession()
        XCTAssertNil(try journal.current()); XCTAssertFalse(controller.hasSession)
        XCTAssertEqual(journal.records().count, 1)
    }
    func testPauseKeepsFinalTranscriptionAndExplicitResume() async {
        let driver = ObservationTestDriver(); let controller = controller(driver: driver)
        controller.begin(endpoint: "http://127.0.0.1:9")
        await awaitPhase(.observing, controller)
        driver.lastOnStop = true
        await controller.pause()
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertTrue(controller.events.contains { $0.text == "停止前的最后一句。" })
        XCTAssertFalse(controller.record?.hasEnded ?? true)
        controller.resume(); await awaitPhase(.observing, controller)
        XCTAssertEqual(driver.starts, 2)
        await controller.end()
        XCTAssertEqual(controller.phase, .finalizing)
        XCTAssertTrue(controller.record?.hasEnded ?? false)
    }
    func testUnconfirmedNativeStopCannotBecomeFinalizingOrResume() async {
        let driver = ObservationTestDriver(); let controller = controller(driver: driver)
        controller.begin(endpoint: "http://127.0.0.1:9"); await awaitPhase(.observing, controller)
        driver.stopFails = true
        await controller.end()
        XCTAssertEqual(controller.phase, .stopUnconfirmed)
        XCTAssertFalse(controller.record?.hasEnded ?? true)
        controller.resume(); XCTAssertEqual(driver.starts, 1)
        driver.stopFails = false
        await controller.end()
        XCTAssertEqual(controller.phase, .finalizing)
        XCTAssertTrue(controller.record?.hasEnded ?? false)
        XCTAssertEqual(driver.stops, 2)
    }
    func testVoiceCommandSharesCaptureWithoutStoppingObservation() async throws {
        let driver = ObservationTestDriver(); let controller = controller(driver: driver)
        controller.begin(endpoint: "http://127.0.0.1:9"); await awaitPhase(.observing, controller)
        driver.callbacks?.interim(.ambientMicrophone, "之前讨论。")
        var updates: [SpeechTranscriptionUpdate] = []
        let lease = try XCTUnwrap(controller.beginSharedVoiceInput { updates.append($0) })
        driver.callbacks?.interim(.ambientMicrophone, "之前讨论。帮我查天气。")
        XCTAssertEqual(updates.last?.combined, "帮我查天气。")
        XCTAssertEqual(controller.endSharedVoiceInput(lease), "帮我查天气。")
        XCTAssertEqual(driver.stops, 0); XCTAssertTrue(controller.isCapturing)
        await controller.end()
    }
    func testLateCallbacksFromEndedCaptureCannotMutateSession() async {
        let driver = ObservationTestDriver(); let controller = controller(driver: driver)
        controller.begin(endpoint: "http://127.0.0.1:9"); await awaitPhase(.observing, controller)
        let old = driver.callbacks
        await controller.end()
        let count = controller.events.count
        old?.evidence(event(text: "不应回流的旧采集"))
        XCTAssertEqual(controller.events.count, count)
    }
    func testConvertedAudioTimelineDoesNotOverlapUnderTimestampJitter() async throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1))
        let outputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false))
        let pair = AsyncStream.makeStream(of: AnalyzerInput.self)
        let feeder = ObservationAudioFeeder(format: outputFormat, epochUptime: 0, continuation: pair.continuation, pulse: { _ in }, gap: { _ in })
        for index in 0..<4 {
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 1024))
            pcm.frameLength = 1024
            pcm.floatChannelData![0].initialize(repeating: 0, count: 1024)
            feeder.consume(pcm, captureUptime: Double(index) * 0.046)
        }
        await feeder.finish()
        var end = CMTime.zero
        var count = 0
        for await input in pair.stream {
            let start = try XCTUnwrap(input.bufferStartTime)
            XCTAssertGreaterThanOrEqual(CMTimeCompare(start, end), 0)
            end = start + CMTime(value: Int64(input.buffer.frameLength), timescale: Int32(input.buffer.format.sampleRate))
            count += 1
        }
        XCTAssertGreaterThan(count, 1)
    }

    func testFinishedObservationPublishesToTaskHistoryOnlyAfterExplicitSave() async {
        let driver = ObservationTestDriver(); let controller = controller(driver: driver)
        controller.begin(endpoint: "http://127.0.0.1:9")
        await awaitPhase(.observing, controller)
        driver.callbacks?.evidence(event(text: "这是一段需要保存的观察。"))
        await controller.end()
        XCTAssertTrue(controller.record?.hasEnded ?? false)
        let currentID = controller.record?.id
        XCTAssertFalse(controller.history.contains { $0.id == currentID })

        // This unit uses no Host, so synthesize the same terminal state a
        // completed final summary would produce before exercising the archive
        // commit itself.
        var finished = try! XCTUnwrap(controller.record)
        finished.phase = .completed
        try! journal.save(finished)
        let reloaded = ObservationController(journal: journal, observeSystem: false)
        XCTAssertEqual(reloaded.phase, .completed)
        XCTAssertEqual(reloaded.homeTitle, "整理完成")
        XCTAssertTrue(reloaded.saveCurrentToTaskHistory())
        XCTAssertFalse(reloaded.hasSession)
        XCTAssertNil(try! journal.current())
        XCTAssertTrue(reloaded.history.contains { $0.id == currentID })
    }

    func testFullyCoveredCheckpointCanBeSavedWhenFinalMergeIsRateLimited() throws {
        let config = configuration([.screen, .deviceAudio])
        let note = ObservationSummary(
            id: UUID().uuidString,
            kind: "checkpoint",
            createdAt: observationTimestamp(),
            title: "果茶含糖量实测讨论",
            summary: "最新阶段整理已经覆盖全部记录。",
            evidenceIDs: [],
            decisions: [],
            todos: [],
            openQuestions: []
        )
        let hostView = ObservationHostView(
            id: config.id,
            status: "analysis_failed",
            eventCount: 42,
            lastSeq: 42,
            summaryThroughSeq: 42,
            analysisRunning: false,
            modelReady: true,
            lastError: "MODEL_HTTP_429",
            notes: [note],
            questions: [],
            screenInsights: [],
            visionRunning: false
        )
        var record = ObservationSessionRecord(
            configuration: config,
            endpoint: "http://127.0.0.1",
            phase: .finalizing
        )
        record.hasEnded = true
        record.eventCount = 42
        record.hostView = hostView
        try journal.save(record)

        let controller = ObservationController(journal: journal, observeSystem: false)
        XCTAssertEqual(controller.phase, .finalizing)
        XCTAssertTrue(controller.canSaveCurrentToTaskHistory)
        XCTAssertEqual(controller.homeTitle, "整理完成")
        XCTAssertEqual(controller.sessionTitle, "果茶含糖量实测讨论")
        XCTAssertTrue(controller.statusMessage.contains("覆盖全部记录"))
        XCTAssertTrue(controller.saveCurrentToTaskHistory())
        XCTAssertFalse(controller.hasSession)
        XCTAssertTrue(controller.history.contains { $0.id == config.id })
    }

    func testPresentationTimelineSuppressesSpeakerEchoButKeepsRealAmbientSpeech() {
        let device = ObservationEvent(source: ObservationSource.deviceAudio.rawValue, kind: "transcript", capturedAt: observationTimestamp(),
                                      offsetMS: 35_073, durationMS: 14_760, text: "这个抖音啊，如果它开了声音的话还是感觉麦克风比较大。")
        let echo = ObservationEvent(source: ObservationSource.ambientMicrophone.rawValue, kind: "transcript", capturedAt: observationTimestamp(),
                                    offsetMS: 35_156, durationMS: 9_840, text: "这个抖音啊如果他开了声音的话还是感觉麦克风比较大")
        let user = ObservationEvent(source: ObservationSource.ambientMicrophone.rawValue, kind: "transcript", capturedAt: observationTimestamp(),
                                    offsetMS: 47_500, durationMS: 1_600, text: "小卷帮我把这一点记下来")
        let fused = ObservationTimelineFusion.presentationEvents([echo, device, user])
        XCTAssertEqual(fused.map(\.id), [device.id, user.id])
        XCTAssertEqual(ObservationTimelineFusion.suppressedEchoCount([echo, device, user]), 1)
    }

    func testLongScreenSpeechKeepsDeviceAudioAndSuppressesShortMicrophoneEchoes() {
        let userIntro = ObservationEvent(
            source: ObservationSource.ambientMicrophone.rawValue, kind: "transcript", capturedAt: observationTimestamp(),
            offsetMS: 12_999, durationMS: 5_520, text: "我们继续看视频吧，然后刚好是我们"
        )
        let device = ObservationEvent(
            source: ObservationSource.deviceAudio.rawValue, kind: "transcript", capturedAt: observationTimestamp(),
            offsetMS: 13_851, durationMS: 33_480,
            text: "好，然后刚好是我们。怎么把2026年9月这个周末两个看似矛盾的重磅信号同时在全球金融市场引爆。后面不是普通增资，而是一次关乎无数普通投资者系统性资产负债表的重构。今天我们不带任何情绪，只用客观数据，把藏在汇率与注资背后的宏观大账彻底算清楚。"
        )
        let shortEcho = ObservationEvent(
            source: ObservationSource.ambientMicrophone.rawValue, kind: "transcript", capturedAt: observationTimestamp(),
            offsetMS: 18_519, durationMS: 9_240,
            text: "2026年9月这个周末两个看似矛盾的重磅信号在全球金融市场引爆"
        )
        let tailEcho = ObservationEvent(
            source: ObservationSource.ambientMicrophone.rawValue, kind: "transcript", capturedAt: observationTimestamp(),
            offsetMS: 38_319, durationMS: 13_200,
            text: "不是普通增资而是一次关乎无数普通投资者系统性资产负债表的重构今天我们不带任何情绪只用客观数据把藏在汇率与注资背后的宏观大账彻底算清楚"
        )

        let fused = ObservationTimelineFusion.presentationEvents([userIntro, device, shortEcho, tailEcho])
        XCTAssertEqual(fused.map(\.id), [userIntro.id, device.id])
        XCTAssertEqual(ObservationTimelineFusion.suppressedEchoCount([userIntro, device, shortEcho, tailEcho]), 2)
    }

    func testHistoryTimelineKeepsScreenOCRWithoutVisionInsight() {
        let lifecycle = ObservationEvent(
            source: "system", kind: "lifecycle", capturedAt: observationTimestamp(),
            offsetMS: 0, durationMS: 0, text: "开始"
        )
        let screen = ObservationEvent(
            source: ObservationSource.screen.rawValue, kind: "screen", capturedAt: observationTimestamp(),
            offsetMS: 26_232, durationMS: 0, text: "某品牌百香果茶 不另加糖 总糖 4.28g/100mL"
        )
        let speech = ObservationEvent(
            source: ObservationSource.ambientMicrophone.rawValue, kind: "transcript", capturedAt: observationTimestamp(),
            offsetMS: 20_407, durationMS: 1_000, text: "不加糖的果茶仍然测出了糖"
        )
        let timeline = ObservationTimelineFusion.historyEvents([screen, lifecycle, speech])
        XCTAssertEqual(timeline.map(\.id), [speech.id, screen.id])
        XCTAssertEqual(timeline.last?.text, screen.text)
    }

    func testTransientAudioSessionInterruptionRequiresActualMicrophoneInputStall() {
        XCTAssertTrue(ObservationController.microphoneInputAdvanced(since: 100.0, latest: 100.25))
        XCTAssertFalse(ObservationController.microphoneInputAdvanced(since: 100.0, latest: 100.0))
        XCTAssertTrue(ObservationController.microphoneInputAdvanced(since: nil, latest: 100.0))
        XCTAssertFalse(ObservationController.microphoneInputAdvanced(since: nil, latest: nil))
    }

    func testUploadBatchUsesEncodedBytesNotCharacterCount() throws {
        let frame = ObservationEvent(source: "screen", kind: "screen", capturedAt: observationTimestamp(), offsetMS: 0, durationMS: 0,
                                     text: String(repeating: "会议", count: 7500), imageBase64: String(repeating: "/", count: 466000))
        var frames: [ObservationEvent] = []
        for _ in 0..<4 { var copy = frame; copy.id = UUID().uuidString; frames.append(copy) }
        let batch = ObservationController.uploadBatch(frames, acknowledgedIDs: [])
        XCTAssertFalse(batch.isEmpty)
        struct Body: Encodable { let events: [ObservationEvent] }
        XCTAssertLessThan(try JSONEncoder().encode(Body(events: batch)).count, 2 * 1024 * 1024)
        let remaining = ObservationController.uploadBatch(frames, acknowledgedIDs: Set(batch.map(\.id)))
        XCTAssertTrue(Set(batch.map(\.id)).isDisjoint(with: remaining.map(\.id)))
    }
}

/// Real-framework physical proof with an explicit, synthetic audio fixture.
/// This does not request permission or sample the owner's microphone. It proves
/// iPhone SpeechAnalyzer + both source-tagged audio pipelines, not system capture.
@MainActor
final class ObservationPhysicalSpeechTests: XCTestCase {
    func testTwoRealSpeechPipelinesOnPhysicalIPhone() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Physical SpeechAnalyzer proof requires the paired iPhone.")
#else
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ObservationAcceptance", isDirectory: true)
        let fixture = folder.appendingPathComponent("voice-fixture.aiff")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("No explicitly staged synthetic voice fixture.")
        }
        let file = try AVAudioFile(forReading: fixture)
        let epoch = Date(); let uptime = ProcessInfo.processInfo.systemUptime
        var evidence: [ObservationEvent] = []
        var issues: [String] = []
        let callbacks = ObservationCaptureCallbacks(evidence: { evidence.append($0) }, interim: { _, _ in },
                                                   input: { _, _ in }, issue: { _, text in issues.append(text) })
        let mic = ObservationSpeechPipe(source: .ambientMicrophone, epoch: epoch, epochUptime: uptime, offsetMS: 0, callbacks: callbacks)
        let audio = ObservationSpeechPipe(source: .deviceAudio, epoch: epoch, epochUptime: uptime, offsetMS: 0, callbacks: callbacks)
        try await AudioCaptureService.shared.acquireObservationSpeechLease()
        defer { AudioCaptureService.shared.releaseObservationSpeechLease() }
        do {
            try await mic.prepare()
            try await audio.prepare()
        } catch {
            print("Observation native preparation: mic=" + mic.preparationStage + ", audio=" + audio.preparationStage + ", taskCancelled=" + String(Task.isCancelled))
            await mic.finish(); await audio.finish()
            throw error
        }
        var frame: AVAudioFramePosition = 0
        let frameCount: AVAudioFrameCount = 4096
        while frame < file.length {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount))
            try file.read(into: buffer, frameCount: frameCount)
            if buffer.frameLength == 0 { break }
            let position = uptime + Double(frame) / file.processingFormat.sampleRate
            mic.feeder?.consume(buffer, captureUptime: position)
            audio.feeder?.consume(buffer, captureUptime: position)
            frame += AVAudioFramePosition(buffer.frameLength)
            try await Task.sleep(for: .milliseconds(70))
        }
        await mic.finish(); await audio.finish()
        struct Proof: Encodable {
            let physicalDevice: String
            let operatingSystem: String
            let fixtureFrames: Int64
            let events: [ObservationEvent]
            let issues: [String]
            let actualCaptureExercised: Bool
        }
        let proof = Proof(physicalDevice: "paired iPhone", operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                          fixtureFrames: file.length, events: evidence, issues: issues, actualCaptureExercised: false)
        try JSONEncoder().encode(proof).write(to: folder.appendingPathComponent("speech-proof.json"), options: .atomic)
        for source in [ObservationSource.ambientMicrophone, .deviceAudio] {
            let text = evidence.filter { $0.source == source.rawValue }.map(\.text).joined()
            XCTAssertFalse(text.isEmpty, "Real transcriber returned no text for " + source.rawValue)
            XCTAssertTrue(text.contains("演示"), "Missing synthetic speech canary: " + text)
        }
        XCTAssertTrue(issues.isEmpty, "Native pipeline reported loss: " + issues.joined(separator: "; "))

        // Exercise the exact iPhone transport/codec/ACK/final-state path, not a
        // desktop HTTP imitation. This journal contains only the explicit test
        // fixture and never replaces the owner's current observation pointer.
        let endpoint = RuntimeTaskStore().configuredEndpoint
        guard !endpoint.isEmpty else { throw XCTSkip("No paired Host endpoint on test iPhone.") }
        let testRoot = folder.appendingPathComponent("isolated-native-chain-" + UUID().uuidString)
        let journal = try ObservationJournal(root: testRoot)
        let config = ObservationConfiguration(id: UUID().uuidString, preset: .custom,
            sources: [.ambientMicrophone, .deviceAudio], createdAt: observationTimestamp(epoch), consentVersion: 1)
        var record = ObservationSessionRecord(configuration: config, endpoint: endpoint, phase: .finalizing)
        record.hasEnded = true; record.eventCount = evidence.count
        try journal.save(record)
        for event in evidence { try journal.append(event, to: record) }
        let controller = ObservationController(journal: journal, observeSystem: false)
        do {
            let deadline = Date().addingTimeInterval(150)
            while Date() < deadline, controller.phase != .completed {
                let synced = await controller.syncOnce()
                XCTAssertTrue(synced, "Native paired request failed: " + (controller.connectionMessage ?? "unknown"))
                if controller.record?.hostView?.lastError != nil { break }
                if controller.phase != .completed { try await Task.sleep(for: .seconds(1)) }
            }
            XCTAssertEqual(controller.phase, .completed)
            XCTAssertEqual(controller.pendingCount, 0)
            XCTAssertTrue(controller.record?.hostView?.notes.contains { $0.kind == "final" } ?? false)
            await controller.ask("这段记录中需要检查哪些事情？")
            let answerDeadline = Date().addingTimeInterval(90)
            while Date() < answerDeadline, controller.record?.hostView?.questions.last?.status == "working" {
                try await Task.sleep(for: .seconds(1))
                _ = await controller.syncOnce()
            }
            XCTAssertEqual(controller.record?.hostView?.questions.last?.status, "completed")
            let view = try XCTUnwrap(controller.record?.hostView)
            try JSONEncoder().encode(view).write(to: folder.appendingPathComponent("native-chain-proof.json"), options: .atomic)
            await controller.deleteCurrent()
            XCTAssertFalse(controller.hasSession, "Synthetic native session should be removed from both stores.")
            try? FileManager.default.removeItem(at: testRoot)
        } catch {
            await controller.deleteCurrent()
            try? FileManager.default.removeItem(at: testRoot)
            throw error
        }
#endif
    }
}
