@preconcurrency import AVFoundation
#if canImport(ScreenCaptureKit)
@preconcurrency import ScreenCaptureKit
#endif
@preconcurrency import Speech
@preconcurrency import Vision
import CoreImage
import ImageIO
import UIKit

struct ObservationInputPulse: Sendable, Equatable {
    let uptime: Double
    let rmsDB: Double
}

struct ObservationCaptureCallbacks: Sendable {
    let evidence: @MainActor @Sendable (ObservationEvent) -> Void
    let interim: @MainActor @Sendable (ObservationSource, String) -> Void
    let input: @MainActor @Sendable (ObservationSource, ObservationInputPulse) -> Void
    let issue: @MainActor @Sendable (ObservationSource?, String) -> Void
}

@MainActor
protocol ObservationCaptureDriver: AnyObject {
    func start() async throws
    func stop() async throws
    func setAppForeground(_ foreground: Bool)
}

enum ObservationCaptureError: LocalizedError {
    case unavailable, cancelled, microphoneDenied, microphoneOffInPicker, emptySources, stopUnconfirmed
    var errorDescription: String? {
        switch self {
        case .unavailable: return "当前设备无法启动屏幕共享。请确认使用 iOS 27，且没有其他屏幕共享占用。"
        case .cancelled: return "已取消系统共享，没有开始观察。"
        case .microphoneDenied: return "麦克风权限未允许，请到设置开启后再开始。"
        case .microphoneOffInPicker: return "系统共享中没有打开麦克风。这次没有开始，请重新开始并开启系统面板中的麦克风。"
        case .emptySources: return "请至少选择一个观察来源。"
        case .stopUnconfirmed: return "系统尚未确认停止共享，请在系统屏幕共享面板点击停止。小卷已停止处理新内容。"
        }
    }
}

private struct ObservationPCM: @unchecked Sendable { let value: AVAudioPCMBuffer; let start: CMTime }
private final class ObservationConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var used = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard !used else { status.pointee = .noDataNow; return nil }
        used = true; status.pointee = .haveData; return buffer
    }
}

/// Bounded real-time bridge. No file I/O, network, Vision or model work on taps.
final class ObservationAudioFeeder: @unchecked Sendable {
    private let format: AVAudioFormat
    private let epochUptime: Double
    private var nextTime = CMTime.zero
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let queue = DispatchQueue(label: "floweroll.observation.audio", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 12)
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var ended = false
    private var lastInput = 0.0
    private var reportedGap = false
    let pulse: @Sendable (ObservationInputPulse) -> Void
    let gap: @Sendable (String) -> Void

    init(format: AVAudioFormat, epochUptime: Double, continuation: AsyncStream<AnalyzerInput>.Continuation,
         pulse: @escaping @Sendable (ObservationInputPulse) -> Void, gap: @escaping @Sendable (String) -> Void) {
        self.format = format; self.epochUptime = epochUptime; self.continuation = continuation; self.pulse = pulse; self.gap = gap
    }
    func consume(_ sample: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sample), let desc = CMSampleBufferGetFormatDescription(sample),
              let sourceFormat = AVAudioFormat(cmAudioFormatDescription: desc) as AVAudioFormat?,
              sourceFormat.channelCount > 0 else { return }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, frames <= 65536,
              let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let age = hostTime - pts
        let sampleStart = pts.isFinite && age.isFinite && abs(age) < 10
            ? now - age : now - Double(frames) / sourceFormat.sampleRate
        enqueue(buffer, at: sampleStart)
    }
    func consume(_ original: AVAudioPCMBuffer, captureUptime: Double? = nil) {
        guard let copied = AVAudioPCMBuffer(pcmFormat: original.format, frameCapacity: original.frameLength) else { return }
        copied.frameLength = original.frameLength
        let src = UnsafeMutableAudioBufferListPointer(original.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(copied.mutableAudioBufferList)
        guard src.count == dst.count else { return }
        for i in src.indices {
            guard let from = src[i].mData, let to = dst[i].mData else { continue }
            memcpy(to, from, min(Int(src[i].mDataByteSize), Int(dst[i].mDataByteSize)))
        }
        enqueue(copied, at: captureUptime ?? (ProcessInfo.processInfo.systemUptime - Double(original.frameLength) / original.format.sampleRate))
    }
    private func enqueue(_ buffer: AVAudioPCMBuffer, at captureUptime: Double) {
        guard slots.wait(timeout: .now()) == .success else {
            // Report loss rather than pretending a complete recording exists.
            gap("音频处理短暂拥堵，可能漏掉一小段内容。")
            return
        }
        let packet = ObservationPCM(value: buffer, start: CMTime(seconds: max(0, captureUptime - epochUptime), preferredTimescale: 48000))
        queue.async { [self] in
            defer { slots.signal() }
            guard !ended else { return }
            convert(packet.value, start: packet.start)
        }
    }
    private func convert(_ buffer: AVAudioPCMBuffer, start: CMTime) {
        if inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { reportGap("当前音频格式无法转写。"); return }
        let capacity = AVAudioFrameCount(max(1, ceil(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate)) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        let box = ObservationConverterInput(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in box.next(state) }
        guard error == nil, status != .error else { reportGap("音频转换失败，部分内容未转写。"); return }
        if output.frameLength > 0 {
            // Preserve the real capture timeline independently for both tracks;
            // dropped/silent buffers must not shift later speech into the past.
            // Resampling/host-time rounding can overlap by a fraction of a
            // sample. SpeechAnalyzer rejects even this overlap. Clamp only
            // backwards jitter; a genuine capture gap still advances the clock.
            let resolvedStart = CMTimeCompare(start, nextTime) >= 0 ? start : nextTime
            nextTime = resolvedStart + CMTime(value: Int64(output.frameLength), timescale: Int32(format.sampleRate))
            switch continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: resolvedStart)) {
            case .dropped: reportGap("转写未能跟上输入，部分内容未处理。")
            default: break
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastInput >= 1 {
            lastInput = now
            pulse(.init(uptime: now, rmsDB: Self.rmsDB(output)))
        }
    }
    private static func rmsDB(_ buffer: AVAudioPCMBuffer) -> Double {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return -160 }
        var sum = 0.0
        var count = 0
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return -160 }
            for channel in 0..<channels {
                for frame in 0..<frames { let value = Double(data[channel][frame]); sum += value * value; count += 1 }
            }
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return -160 }
            for channel in 0..<channels {
                for frame in 0..<frames { let value = Double(data[channel][frame]) / 32768.0; sum += value * value; count += 1 }
            }
        case .pcmFormatInt32:
            guard let data = buffer.int32ChannelData else { return -160 }
            for channel in 0..<channels {
                for frame in 0..<frames { let value = Double(data[channel][frame]) / 2147483648.0; sum += value * value; count += 1 }
            }
        default:
            return -160
        }
        guard count > 0 else { return -160 }
        let rms = sqrt(sum / Double(count))
        return 20 * log10(max(rms, 0.00000001))
    }
    private func reportGap(_ message: String) {
        guard !reportedGap else { return }
        reportedGap = true; gap(message)
    }
    func finish() async {
        await withCheckedContinuation { done in
            queue.async { [self] in
                ended = true
                if let converter {
                    for _ in 0..<8 {
                        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048) else { break }
                        var error: NSError?
                        let status = converter.convert(to: output, error: &error) { _, state in state.pointee = .endOfStream; return nil }
                        if output.frameLength > 0 {
                            continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: nextTime))
                            nextTime = nextTime + CMTime(value: Int64(output.frameLength), timescale: Int32(format.sampleRate))
                        }
                        if status == .endOfStream || status == .error || error != nil || output.frameLength == 0 { break }
                    }
                }
                continuation.finish(); done.resume()
            }
        }
    }
}

@MainActor
final class ObservationSpeechPipe {
    private(set) var preparationStage = "locale"
    private var analyzer: SpeechAnalyzer?
    private var resultTask: Task<Void, Never>?
    private var lastInterimText = ""
    private var lastInterimStart: TimeInterval = 0
    private var lastInterimDuration: TimeInterval = 0
    private(set) var feeder: ObservationAudioFeeder?
    let source: ObservationSource
    let epoch: Date
    let epochUptime: Double
    let offsetMS: Int
    let callbacks: ObservationCaptureCallbacks
    init(source: ObservationSource, epoch: Date, epochUptime: Double, offsetMS: Int, callbacks: ObservationCaptureCallbacks) {
        self.source = source; self.epoch = epoch; self.epochUptime = epochUptime; self.offsetMS = offsetMS; self.callbacks = callbacks
    }
    func prepare() async throws {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else {
            throw FlowerollPrototypeError.speechTranscriberUnavailable
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        preparationStage = "assets"
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        preparationStage = "audio-format"
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw FlowerollPrototypeError.speechAudioConversionUnavailable
        }
        let pair = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingNewest(128))
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let source = source, callbacks = callbacks
        feeder = ObservationAudioFeeder(format: format, epochUptime: epochUptime, continuation: pair.continuation, pulse: { value in
            Task { @MainActor in callbacks.input(source, value) }
        }, gap: { message in
            Task { @MainActor in callbacks.issue(source, message) }
        })
        preparationStage = "prepare-analyzer"
        try await analyzer.prepareToAnalyze(in: format)
        resultTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let start = max(0, result.range.start.seconds.isFinite ? result.range.start.seconds : 0)
                    let duration = max(0, result.range.duration.seconds.isFinite ? result.range.duration.seconds : 0)
                    if result.isFinal {
                        self.lastInterimText = ""
                        let event = ObservationEvent(source: source.rawValue, kind: "transcript",
                            capturedAt: observationTimestamp(self.epoch.addingTimeInterval(start)),
                            offsetMS: self.offsetMS + Int(start * 1000), durationMS: Int(duration * 1000), text: text)
                        callbacks.evidence(event)
                        callbacks.interim(source, "")
                    } else {
                        self.lastInterimText = text
                        self.lastInterimStart = start
                        self.lastInterimDuration = duration
                        callbacks.interim(source, text)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                callbacks.issue(source, "本机语音转写已中断，未识别的内容不会被补写。")
            }
        }
        preparationStage = "start-analyzer"
        try await analyzer.start(inputSequence: pair.stream)
        preparationStage = "ready"
    }
    func finish() async {
        await feeder?.finish()
        guard let analyzer else { return }
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            await analyzer.cancelAndFinishNow()
        }
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
        catch { await analyzer.cancelAndFinishNow() }
        _ = await resultTask?.result
        timeout.cancel()
        if !lastInterimText.isEmpty {
            callbacks.evidence(ObservationEvent(
                source: source.rawValue,
                kind: "transcript",
                capturedAt: observationTimestamp(epoch.addingTimeInterval(lastInterimStart)),
                offsetMS: offsetMS + Int(lastInterimStart * 1000),
                durationMS: Int(lastInterimDuration * 1000),
                text: lastInterimText
            ))
            callbacks.interim(source, "")
            lastInterimText = ""
        }
        self.analyzer = nil; resultTask = nil; feeder = nil
    }
}

/// A lock protects only the tiny input gate. Vision and image encoding run on a
/// dedicated serial callback queue; frames older than the current window drop.
private final class ObservationVideoSink: @unchecked Sendable {
    private let lock = NSLock()
    private var foreground = true
    private var stopped = false
    private var lastFrame = 0.0
    private var lastVisionFrame = -Double.infinity
    private var lastHash: [UInt8]?
    private var lastIssue = 0.0
    private let context = CIContext(options: [.cacheIntermediates: false])
    let epoch: Date
    let baseUptime: Double
    let offsetMS: Int
    let callbacks: ObservationCaptureCallbacks
    init(epoch: Date, epochUptime: Double, offsetMS: Int, callbacks: ObservationCaptureCallbacks) {
        self.epoch = epoch; self.offsetMS = offsetMS; self.callbacks = callbacks
        baseUptime = epochUptime
    }
    func setForeground(_ value: Bool) { lock.lock(); foreground = value; lock.unlock() }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    func consume(_ buffer: CMSampleBuffer, orientation: UInt32) {
        lock.lock(); let allowed = !foreground && !stopped; lock.unlock()
        let now = ProcessInfo.processInfo.systemUptime
        guard allowed, now - lastFrame >= ObservationLimits.screenInterval,
              let pixel = CMSampleBufferGetImageBuffer(buffer) else { return }
        lastFrame = now
        autoreleasepool {
            let original = CIImage(cvPixelBuffer: pixel).oriented(forExifOrientation: Int32(orientation))
            let rect = original.extent
            guard rect.width > 0, rect.height > 0 else { return }
            let thumb = original.transformed(by: CGAffineTransform(scaleX: 16 / rect.width, y: 16 / rect.height))
            var hash = [UInt8](repeating: 0, count: 256)
            hash.withUnsafeMutableBytes { ptr in
                context.render(thumb, toBitmap: ptr.baseAddress!, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 16, height: 16), format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
            }
            if let previous = lastHash {
                let diff = zip(previous, hash).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
                if diff < 256 * 3 { return }
            }
            lastHash = hash
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.008
            let handler = VNImageRequestHandler(ciImage: original)
            var text = ""
            do {
                try handler.perform([request])
                text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            } catch {
                if now - lastIssue > 60 {
                    lastIssue = now
                    Task { @MainActor in callbacks.issue(.screen, "这张画面的文字未能识别，将交给画面理解核对。") }
                }
            }
            var jpeg: String? = nil
            if now - lastVisionFrame >= ObservationLimits.screenVisionInterval {
                let scale = min(1, 1600 / max(rect.width, rect.height))
                let image = original.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                var data = context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.76])
                if let encoded = data, encoded.count > 700000 {
                    data = context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.56])
                }
                jpeg = data.flatMap { $0.count <= 700000 ? $0.base64EncodedString() : nil }
                if jpeg != nil { lastVisionFrame = now }
            }
            guard !text.isEmpty || jpeg != nil else { return }
            lock.lock(); let stillAllowed = !stopped && !foreground; lock.unlock()
            guard stillAllowed else { return }
            let elapsed = max(0, now - baseUptime)
            let event = ObservationEvent(source: "screen", kind: "screen", capturedAt: observationTimestamp(epoch.addingTimeInterval(elapsed)),
                                         offsetMS: offsetMS + Int(elapsed * 1000), durationMS: 0, text: String(text.prefix(15000)), imageBase64: jpeg)
            Task { @MainActor in callbacks.evidence(event); callbacks.input(.screen, .init(uptime: now, rmsDB: 0)) }
        }
    }
}

#if canImport(ScreenCaptureKit)
@available(iOS 27.0, *)
private final class ObservationStreamSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let video: ObservationVideoSink?
    let microphone: ObservationAudioFeeder?
    let audio: ObservationAudioFeeder?
    init(video: ObservationVideoSink?, microphone: ObservationAudioFeeder?, audio: ObservationAudioFeeder?) {
        self.video = video; self.microphone = microphone; self.audio = audio
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard let video else { return }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
            if let status = attachments?.first?[.status] as? Int, status != SCFrameStatus.complete.rawValue { return }
            let orientation = (attachments?.first?[.videoOrientation] as? NSNumber)?.uint32Value ?? 1
            video.consume(sampleBuffer, orientation: orientation)
        case .audio: audio?.consume(sampleBuffer)
        case .microphone: microphone?.consume(sampleBuffer)
        @unknown default: break
        }
    }
}

@available(iOS 27.0, *)
private struct ObservationFilter: @unchecked Sendable { let value: SCContentFilter }

@available(iOS 27.0, *)
@MainActor
final class ObservationCaptureEngine: NSObject, ObservationCaptureDriver, SCContentSharingPickerObserver, SCStreamDelegate {
    private let sources: Set<ObservationSource>
    private let callbacks: ObservationCaptureCallbacks
    private let offsetMS: Int
    private let epoch = Date()
    private let epochUptime = ProcessInfo.processInfo.systemUptime
    private var stopTask: Task<Void, Error>?
    private var screen: SCStream?
    private var sink: ObservationStreamSink?
    private var microphone: AVAudioEngine?
    private var micPipe: ObservationSpeechPipe?
    private var audioPipe: ObservationSpeechPipe?
    private var video: ObservationVideoSink?
    private var selection: CheckedContinuation<ObservationFilter, Error>?
    private var expectingStop = false
    private var ownsSpeechLease = false
    private var appForeground = true
    private let videoQueue = DispatchQueue(label: "floweroll.observation.screen", qos: .utility)
    private let audioQueue = DispatchQueue(label: "floweroll.observation.samples", qos: .userInitiated)

    init(sources: Set<ObservationSource>, offsetMS: Int, callbacks: ObservationCaptureCallbacks) {
        self.sources = sources; self.offsetMS = offsetMS; self.callbacks = callbacks
    }
    func start() async throws {
        guard !sources.isEmpty else { throw ObservationCaptureError.emptySources }
        expectingStop = false
        if !sources.isDisjoint(with: [.ambientMicrophone, .deviceAudio]) {
            try await AudioCaptureService.shared.acquireObservationSpeechLease()
            ownsSpeechLease = true
        }
        if sources.contains(.ambientMicrophone) {
            if AVAudioApplication.shared.recordPermission == .undetermined {
                guard await AVAudioApplication.requestRecordPermission() else { throw ObservationCaptureError.microphoneDenied }
            }
            guard AVAudioApplication.shared.recordPermission == .granted else { throw ObservationCaptureError.microphoneDenied }
        }
        let usesSharing = sources.contains(.screen) || sources.contains(.deviceAudio)
        let filter: SCContentFilter?
        if usesSharing {
            guard SCContentSharingPicker.shared.isAvailable else { throw ObservationCaptureError.unavailable }
            let box = try await withCheckedThrowingContinuation { continuation in
                selection = continuation
                let picker = SCContentSharingPicker.shared
                var configuration = SCContentSharingPickerConfiguration()
                configuration.showsMicrophoneControl = sources.contains(.ambientMicrophone)
                configuration.showsCameraControl = false
                picker.defaultConfiguration = configuration
                picker.add(self)
                picker.isActive = true
                picker.present()
            }
            filter = box.value
            if sources.contains(.ambientMicrophone), !box.value.isMicrophoneEnabled {
                throw ObservationCaptureError.microphoneOffInPicker
            }
        } else { filter = nil }
        try Task.checkCancellation()
        if sources.contains(.ambientMicrophone) {
            micPipe = ObservationSpeechPipe(source: .ambientMicrophone, epoch: epoch, epochUptime: epochUptime, offsetMS: offsetMS, callbacks: callbacks)
            try await micPipe?.prepare()
        }
        if sources.contains(.deviceAudio) {
            audioPipe = ObservationSpeechPipe(source: .deviceAudio, epoch: epoch, epochUptime: epochUptime, offsetMS: offsetMS, callbacks: callbacks)
            try await audioPipe?.prepare()
        }
        try Task.checkCancellation()
        if sources.contains(.ambientMicrophone) {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
        }
        if let filter {
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = sources.contains(.deviceAudio)
            configuration.sampleRate = 48000
            configuration.channelCount = 1
            configuration.excludesCurrentProcessAudio = true
            // These properties, unlike minimumFrameInterval/pixelFormat, exist on iOS.
            configuration.width = sources.contains(.screen) ? 864 : 320
            configuration.height = sources.contains(.screen) ? 1872 : 640
            if sources.contains(.screen) {
                video = ObservationVideoSink(epoch: epoch, epochUptime: epochUptime, offsetMS: offsetMS, callbacks: callbacks)
                video?.setForeground(appForeground)
            }
            let sink = ObservationStreamSink(video: video, microphone: micPipe?.feeder, audio: audioPipe?.feeder)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            self.sink = sink; self.screen = stream
            // iOS expects a screen sink even for an audio-only stream. The sink
            // discards every frame immediately when screen wasn't selected.
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: videoQueue)
            if sources.contains(.deviceAudio) { try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: audioQueue) }
            if sources.contains(.ambientMicrophone) { try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: audioQueue) }
            try await stream.startCapture()
            guard stream.isCapturing else { throw ObservationCaptureError.unavailable }
        } else if let feeder = micPipe?.feeder {
            let engine = AVAudioEngine()
            microphone = engine
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else { throw FlowerollPrototypeError.audioInputUnavailable }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in feeder.consume(buffer) }
            engine.prepare(); try engine.start()
        }
    }
    func stop() async throws {
        if let stopTask { return try await stopTask.value }
        let task = Task { @MainActor in try await self.stopResources() }
        stopTask = task
        do { try await task.value }
        catch { stopTask = nil; throw error }
    }
    private func stopResources() async throws {
        expectingStop = true
        if let selection { self.selection = nil; selection.resume(throwing: ObservationCaptureError.cancelled) }
        video?.stop()
        if let microphone {
            microphone.stop(); microphone.inputNode.removeTap(onBus: 0); self.microphone = nil
        }
        var stopFailed = false
        if let screen {
            do { try await screen.stopCapture() } catch { }
            stopFailed = screen.isCapturing
            if !stopFailed { self.screen = nil }
        }
        let picker = SCContentSharingPicker.shared
        if !stopFailed { picker.remove(self); picker.isActive = false }
        await micPipe?.finish(); await audioPipe?.finish()
        micPipe = nil; audioPipe = nil; video = nil
        if !stopFailed { sink = nil }
        if !stopFailed, !AudioCaptureService.shared.isRecording {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        if stopFailed { throw ObservationCaptureError.stopUnconfirmed }
        if ownsSpeechLease {
            AudioCaptureService.shared.releaseObservationSpeechLease()
            ownsSpeechLease = false
        }
    }
    func setAppForeground(_ foreground: Bool) { appForeground = foreground; video?.setForeground(foreground) }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            guard let selection = self.selection else { return }
            self.selection = nil; selection.resume(throwing: ObservationCaptureError.cancelled)
        }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        let box = ObservationFilter(value: filter)
        Task { @MainActor in
            guard let selection = self.selection else { return }
            self.selection = nil; selection.resume(returning: box)
        }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in
            guard let selection = self.selection else { return }
            self.selection = nil; selection.resume(throwing: ObservationCaptureError.unavailable)
        }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            guard !self.expectingStop else { return }
            self.callbacks.issue(nil, "系统屏幕共享已停止或被其他应用中断，观察已暂停。")
        }
    }
}
#else
/// Simulator SDK doesn't ship ScreenCaptureKit. Never fake its output or claim
/// a capture succeeded; state-machine unit tests inject a test-only driver.
@MainActor
final class ObservationCaptureEngine: ObservationCaptureDriver {
    init(sources: Set<ObservationSource>, offsetMS: Int, callbacks: ObservationCaptureCallbacks) {}
    func start() async throws { throw ObservationCaptureError.unavailable }
    func stop() async throws {}
    func setAppForeground(_ foreground: Bool) {}
}
#endif
