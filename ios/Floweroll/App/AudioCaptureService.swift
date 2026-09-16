@preconcurrency import AVFAudio
import Foundation
import Speech


struct SpeechTranscriptionUpdate: Sendable, Equatable {
    let finalized: String
    let volatile: String

    var combined: String {
        finalized + volatile
    }
}

private struct UncheckedPCMBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

private final class ConverterInputBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ inputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if supplied {
            inputStatus.pointee = .noDataNow
            return nil
        }
        supplied = true
        inputStatus.pointee = .haveData
        return buffer
    }
}

/// AVAudioEngine invokes taps on a Core Audio realtime queue. This bridge has no
/// actor isolation: it copies the short-lived tap buffer immediately, then moves
/// conversion + SpeechAnalyzer input delivery onto a dedicated serial queue.
private final class SpeechAnalyzerAudioBridge: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let analyzerFormat: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let queue = DispatchQueue(label: "com.maxenceyu.floweroll.speech-input", qos: .userInitiated)

    init?(
        inputFormat: AVAudioFormat,
        analyzerFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
            return nil
        }
        self.converter = converter
        self.analyzerFormat = analyzerFormat
        self.continuation = continuation
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let copied = Self.copy(buffer) else { return }
        let packet = UncheckedPCMBuffer(buffer: copied)
        queue.async { [weak self] in
            self?.convertAndYield(packet.buffer)
        }
    }

    func finish() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                self?.flushConverter()
                self?.continuation.finish()
                continuation.resume()
            }
        }
    }

    private func convertAndYield(_ input: AVAudioPCMBuffer) {
        let ratio = analyzerFormat.sampleRate / input.format.sampleRate
        let estimated = max(1, Int(ceil(Double(input.frameLength) * ratio)) + 32)
        guard let output = AVAudioPCMBuffer(
            pcmFormat: analyzerFormat,
            frameCapacity: AVAudioFrameCount(estimated)
        ) else { return }

        let inputBox = ConverterInputBox(buffer: input)
        var nsError: NSError?
        let status = converter.convert(to: output, error: &nsError) { _, inputStatus in
            inputBox.next(inputStatus)
        }

        guard nsError == nil else { return }
        switch status {
        case .haveData, .inputRanDry:
            if output.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: output))
            }
        case .endOfStream, .error:
            break
        @unknown default:
            break
        }
    }

    private func flushConverter() {
        while true {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: analyzerFormat,
                frameCapacity: 1024
            ) else { return }
            var nsError: NSError?
            let status = converter.convert(to: output, error: &nsError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if nsError != nil { return }
            if output.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: output))
            }
            if status == .endOfStream || status == .error || output.frameLength == 0 {
                return
            }
        }
    }

    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }
        copy.frameLength = source.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            var destinationBuffer = destinationBuffers[index]
            let byteCount = min(Int(sourceBuffer.mDataByteSize), Int(destinationBuffer.mDataByteSize))
            guard byteCount > 0,
                  let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffer.mData else { continue }
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffer.mDataByteSize = UInt32(byteCount)
            destinationBuffers[index] = destinationBuffer
        }
        return copy
    }
}

private func makeMicrophoneTapBlock(
    bridge: SpeechAnalyzerAudioBridge
) -> AVAudioNodeTapBlock {
    { buffer, _ in
        bridge.consume(buffer)
    }
}

enum FlowerollPrototypeError: LocalizedError {
    case microphonePermissionRequired
    case observationMicrophoneBusy
    case audioInputUnavailable
    case speechTranscriberUnavailable
    case speechLocaleUnsupported
    case speechModelUnavailable
    case speechAudioConversionUnavailable

    var errorDescription: String? {
        switch self {
        case .observationMicrophoneBusy:
            return "请先结束当前语音输入，再开始观察。"
        case .microphonePermissionRequired:
            return "请先在花卷 App 内授予麦克风权限。"
        case .audioInputUnavailable:
            return "当前没有可用的麦克风输入。"
        case .speechTranscriberUnavailable:
            return "这台设备当前无法使用本机语音转写。"
        case .speechLocaleUnsupported:
            return "当前设备的本机语音模型暂不支持中文转写。"
        case .speechModelUnavailable:
            return "中文语音模型暂时无法准备，请联网后再试一次。"
        case .speechAudioConversionUnavailable:
            return "当前麦克风格式无法交给语音识别器。"
        }
    }
}

@MainActor
final class AudioCaptureService {
    static let shared = AudioCaptureService()

    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var preservesObservationPlayback = false
    private var observationSpeechLeased = false
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var analyzerFormat: AVAudioFormat?
    private var analyzerInputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var audioBridge: SpeechAnalyzerAudioBridge?
    private var resultTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Error>?
    private var speechSessionID: UUID?
    private var finalizedTranscript = ""
    private var volatileTranscript = ""
    private var transcriptionHandler: ((SpeechTranscriptionUpdate) -> Void)?

    private init() {}

    var isRecording: Bool {
        engine.isRunning
    }

    func acquireObservationSpeechLease() async throws {
        guard !isRecording else { throw FlowerollPrototypeError.observationMicrophoneBusy }
        observationSpeechLeased = true
        let pending = preparationTask
        pending?.cancel()
        _ = try? await pending?.value
        preparationTask = nil
        let oldAnalyzer = analyzer
        let oldResults = resultTask
        analyzerInputContinuation?.finish()
        analyzer = nil; transcriber = nil; analyzerFormat = nil
        analyzerInputContinuation = nil; resultTask = nil; speechSessionID = nil
        finalizedTranscript = ""; volatileTranscript = ""; transcriptionHandler = nil
        await oldAnalyzer?.cancelAndFinishNow()
        oldResults?.cancel()
    }
    func releaseObservationSpeechLease() { observationSpeechLeased = false }

    func prepare(forVoiceCommand: Bool = false) async throws {
        if observationSpeechLeased && !forVoiceCommand { return }
        if isSpeechPrepared { return }
        if let preparationTask {
            try await preparationTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await self.buildPreparedSpeechSession()
        }
        preparationTask = task
        do {
            try await task.value
            preparationTask = nil
        } catch {
            preparationTask = nil
            throw error
        }
    }

    func start(preservePlayback: Bool = false, onTranscription: ((SpeechTranscriptionUpdate) -> Void)? = nil) async throws {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw FlowerollPrototypeError.microphonePermissionRequired
        }

        if engine.isRunning { return }

        // Preparing the language model/analyzer is intentionally separate from
        // microphone activation. Hold-to-talk starts this work on touch-down, so
        // by the time the hold threshold is crossed, the realtime path is warm.
        try await prepare(forVoiceCommand: true)
        try Task.checkCancellation()

        guard let analyzerFormat, let analyzerInputContinuation else {
            throw FlowerollPrototypeError.speechModelUnavailable
        }

        let session = AVAudioSession.sharedInstance()
        preservesObservationPlayback = preservePlayback
        if preservePlayback {
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
        } else {
            try session.setCategory(.record, mode: .measurement, options: [])
        }
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
        try Task.checkCancellation()

        let input = engine.inputNode
        let naturalFormat = input.outputFormat(forBus: 0)
        guard naturalFormat.channelCount > 0 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw FlowerollPrototypeError.audioInputUnavailable
        }

        guard let bridge = SpeechAnalyzerAudioBridge(
            inputFormat: naturalFormat,
            analyzerFormat: analyzerFormat,
            continuation: analyzerInputContinuation
        ) else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw FlowerollPrototypeError.speechAudioConversionUnavailable
        }

        audioBridge = bridge
        transcriptionHandler = onTranscription

        if tapInstalled {
            input.removeTap(onBus: 0)
        }
        input.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: naturalFormat,
            block: makeMicrophoneTapBlock(bridge: bridge)
        )
        tapInstalled = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            audioBridge = nil
            transcriptionHandler = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    func stop(onFinalized: ((String) -> Void)? = nil) {
        preparationTask?.cancel()
        preparationTask = nil

        if engine.isRunning {
            engine.stop()
        }

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        let currentBridge = audioBridge
        let currentAnalyzer = analyzer
        let currentResultTask = resultTask
        let currentSessionID = speechSessionID
        let currentInputContinuation = analyzerInputContinuation
        audioBridge = nil
        analyzer = nil
        transcriber = nil
        analyzerFormat = nil
        analyzerInputContinuation = nil
        resultTask = nil

        Task { @MainActor [weak self] in
            if let currentBridge {
                await currentBridge.finish()
            } else {
                currentInputContinuation?.finish()
            }
            do {
                try await currentAnalyzer?.finalizeAndFinishThroughEndOfInput()
            } catch {
                await currentAnalyzer?.cancelAndFinishNow()
            }
            _ = await currentResultTask?.result
            guard let self, self.speechSessionID == currentSessionID else { return }
            let finalTranscript = (self.finalizedTranscript + self.volatileTranscript)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.speechSessionID = nil
            self.transcriptionHandler = nil
            self.finalizedTranscript = ""
            self.volatileTranscript = ""
            onFinalized?(finalTranscript)
        }

        if !preservesObservationPlayback || !ObservationController.shared.isCapturing {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        preservesObservationPlayback = false
    }

    private var isSpeechPrepared: Bool {
        analyzer != nil
            && transcriber != nil
            && analyzerFormat != nil
            && analyzerInputContinuation != nil
            && resultTask != nil
            && speechSessionID != nil
    }

    private func buildPreparedSpeechSession() async throws {
        if isSpeechPrepared { return }
        guard SpeechTranscriber.isAvailable else {
            throw FlowerollPrototypeError.speechTranscriberUnavailable
        }

        let requestedLocale = Locale(identifier: "zh-CN")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw FlowerollPrototypeError.speechLocaleUnsupported
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .progressiveTranscription
        )

        if let installationRequest = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await installationRequest.downloadAndInstall()
        }
        try Task.checkCancellation()

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw FlowerollPrototypeError.speechModelUnavailable
        }

        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        try Task.checkCancellation()
        try await analyzer.start(inputSequence: inputSequence)
        try Task.checkCancellation()

        let sessionID = UUID()
        self.speechSessionID = sessionID
        self.finalizedTranscript = ""
        self.volatileTranscript = ""
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.analyzerFormat = analyzerFormat
        self.analyzerInputContinuation = inputBuilder

        resultTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, self.speechSessionID == sessionID else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.finalizedTranscript += text
                        self.volatileTranscript = ""
                    } else {
                        self.volatileTranscript = text
                    }
                    self.transcriptionHandler?(
                        SpeechTranscriptionUpdate(
                            finalized: self.finalizedTranscript,
                            volatile: self.volatileTranscript
                        )
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                // A prepared analyzer can be discarded and rebuilt on the next
                // speech interaction if its result stream fails unexpectedly.
            }
        }
    }

    private func tearDownSpeechImmediately() async {
        preparationTask?.cancel()
        preparationTask = nil
        resultTask?.cancel()
        resultTask = nil
        analyzerInputContinuation?.finish()
        analyzerInputContinuation = nil
        analyzerFormat = nil
        audioBridge = nil
        transcriber = nil
        speechSessionID = nil
        transcriptionHandler = nil
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        self.analyzer = nil
    }
}
