import Foundation

// Mode presets are product policy. They never expand the user's selected sources.
enum ObservationSource: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case screen, ambientMicrophone, deviceAudio
    var id: String { rawValue }
    var title: String {
        switch self {
        case .screen: return "屏幕共享"
        case .ambientMicrophone: return "麦克风"
        case .deviceAudio: return "手机声音"
        }
    }
    var shortTitle: String {
        switch self {
        case .screen: return "屏幕"
        case .ambientMicrophone: return "周围"
        case .deviceAudio: return "手机声音"
        }
    }
    var systemImage: String {
        switch self {
        case .screen: return "rectangle.on.rectangle"
        case .ambientMicrophone: return "mic.fill"
        case .deviceAudio: return "speaker.wave.2.fill"
        }
    }
}

enum ObservationPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case meeting, screen, media, combined, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .meeting: return "会议"
        case .screen: return "屏幕"
        case .media: return "影音"
        case .combined: return "综合"
        case .custom: return "自定"
        }
    }
    var detail: String {
        switch self {
        case .meeting: return "记录会议、课堂或访谈，自动整理重点和纪要。"
        case .screen: return "理解浏览过的网页、文档和 App 内容。"
        case .media: return "一起理解视频、网课的画面与手机声音。"
        case .combined: return "一起记录现场讨论、手机画面和手机声音。"
        case .custom: return "只使用你这次选中的来源。"
        }
    }
    var sources: Set<ObservationSource> {
        switch self {
        case .meeting: return [.ambientMicrophone]
        case .screen: return [.screen]
        case .media: return [.screen, .deviceAudio]
        case .combined: return Set(ObservationSource.allCases)
        case .custom: return []
        }
    }
}

enum ObservationPhase: String, Codable, Sendable {
    case setup, authorizing, preparing, observing, pausing, paused, interrupted, stopping, stopUnconfirmed, finalizing, completed, failed
    var capturesMayBeRunning: Bool { [.preparing, .observing, .pausing, .stopping, .stopUnconfirmed].contains(self) }
    var title: String {
        switch self {
        case .setup: return "观察"
        case .authorizing: return "等待授权"
        case .preparing: return "正在准备"
        case .observing: return "正在观察"
        case .pausing: return "正在暂停"
        case .paused: return "已暂停"
        case .interrupted: return "观察已中断"
        case .stopping: return "正在停止"
        case .stopUnconfirmed: return "等待系统停止"
        case .finalizing: return "正在整理"
        case .completed: return "整理完成"
        case .failed: return "未能开始观察"
        }
    }
}

struct ObservationEvent: Codable, Identifiable, Equatable, Sendable {
    var id = UUID().uuidString
    let source: String
    let kind: String
    let capturedAt: String
    let offsetMS: Int
    let durationMS: Int
    let text: String
    var imageBase64: String? = nil
    enum CodingKeys: String, CodingKey {
        case id, source, kind, text
        case capturedAt = "captured_at", offsetMS = "offset_ms", durationMS = "duration_ms", imageBase64 = "image_base64"
    }
    var withoutImage: Self { var copy = self; copy.imageBase64 = nil; return copy }
}

enum ObservationTimelineFusion {
    static func presentationEvents(_ events: [ObservationEvent]) -> [ObservationEvent] {
        let transcripts = events.filter { $0.kind == "transcript" }
        var suppressed = Set<String>()
        for device in transcripts where device.source == ObservationSource.deviceAudio.rawValue {
            for ambient in transcripts where ambient.source == ObservationSource.ambientMicrophone.rawValue && !suppressed.contains(ambient.id) {
                if isAcousticEcho(ambient: ambient, device: device) { suppressed.insert(ambient.id) }
            }
        }
        return events.filter { !suppressed.contains($0.id) }
    }

    /// History must remain useful even when visual interpretation was throttled
    /// or unavailable. Keep every meaningful screen/transcript event and only
    /// remove acoustic echo/lifecycle bookkeeping from the user-facing timeline.
    static func historyEvents(_ events: [ObservationEvent]) -> [ObservationEvent] {
        presentationEvents(events)
            .filter { $0.kind == "transcript" || $0.kind == "screen" }
            .sorted {
                if $0.offsetMS == $1.offsetMS { return $0.id < $1.id }
                return $0.offsetMS < $1.offsetMS
            }
    }

    static func suppressedEchoCount(_ events: [ObservationEvent]) -> Int {
        events.count - presentationEvents(events).count
    }

    static func textsLikelyEcho(ambient: String, device: String) -> Bool {
        textSimilarity(ambient, device) >= 0.72
            || textContainmentSimilarity(ambient, device) >= 0.62
    }

    static func isAcousticEcho(ambient: ObservationEvent, device: ObservationEvent) -> Bool {
        guard ambient.kind == "transcript", device.kind == "transcript",
              ambient.source == ObservationSource.ambientMicrophone.rawValue,
              device.source == ObservationSource.deviceAudio.rawValue else { return false }
        let aDuration = max(1_000, ambient.durationMS)
        let dDuration = max(1_000, device.durationMS)
        let aEnd = ambient.offsetMS + aDuration
        let dEnd = device.offsetMS + dDuration
        let overlap = max(0, min(aEnd, dEnd) - max(ambient.offsetMS, device.offsetMS))
        let closeStart = abs(ambient.offsetMS - device.offsetMS) <= 2_500
        // System audio often arrives as one long transcript while the same
        // loudspeaker playback leaks into the microphone as shorter ASR chunks.
        // Compare coverage of the ambient chunk rather than penalizing the
        // very different segment lengths.
        let ambientCoverage = Double(overlap) / Double(aDuration)
        guard closeStart || ambientCoverage >= 0.50 else { return false }
        return textSimilarity(ambient.text, device.text) >= 0.72
            || textContainmentSimilarity(ambient.text, device.text) >= 0.62
    }

    private static func textSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let a = normalizedCharacters(lhs), b = normalizedCharacters(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        if min(a.count, b.count) < 5 {
            let common = Set(a).intersection(Set(b)).count
            return Double(common * 2) / Double(a.count + b.count)
        }
        let aa = bigrams(a), bb = bigrams(b)
        guard !aa.isEmpty, !bb.isEmpty else { return 0 }
        return Double(2 * aa.intersection(bb).count) / Double(aa.count + bb.count)
    }

    private static func textContainmentSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let a = normalizedCharacters(lhs), b = normalizedCharacters(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let aa = bigrams(a), bb = bigrams(b)
        guard !aa.isEmpty, !bb.isEmpty else {
            let common = Set(a).intersection(Set(b)).count
            return Double(common) / Double(max(1, min(a.count, b.count)))
        }
        return Double(aa.intersection(bb).count) / Double(min(aa.count, bb.count))
    }

    private static func normalizedCharacters(_ text: String) -> [Character] {
        Array(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
    private static func bigrams(_ chars: [Character]) -> Set<String> {
        guard chars.count >= 2 else { return [] }
        var result = Set<String>()
        for index in 0..<(chars.count - 1) { result.insert(String([chars[index], chars[index + 1]])) }
        return result
    }
}

struct ObservationScreenInsight: Codable, Identifiable, Sendable {
    var id: String { eventID }
    let eventID: String
    let pageType: String
    let summary: String
    let keyItems: [String]
    let visibleActions: [String]
    let uncertainties: [String]
    enum CodingKeys: String, CodingKey {
        case summary, uncertainties
        case eventID = "event_id", pageType = "page_type", keyItems = "key_items", visibleActions = "visible_actions"
    }
}

struct ObservationFact: Codable, Hashable, Sendable {
    let text: String
    let evidenceIDs: [String]
    enum CodingKeys: String, CodingKey { case text; case evidenceIDs = "evidence_ids" }
}

struct ObservationSummary: Codable, Identifiable, Sendable {
    var id: String? = nil
    var kind: String? = nil
    var createdAt: String? = nil
    let title: String
    let summary: String
    let evidenceIDs: [String]
    let decisions: [ObservationFact]
    let todos: [ObservationFact]
    let openQuestions: [ObservationFact]
    enum CodingKeys: String, CodingKey {
        case id, kind, title, summary, decisions, todos
        case createdAt = "created_at", evidenceIDs = "evidence_ids", openQuestions = "open_questions"
    }
    var markdown: String {
        var pieces = ["# " + title, summary]
        for (heading, facts) in [("已讨论的决定", decisions), ("待办事项", todos), ("待确认", openQuestions)] where !facts.isEmpty {
            pieces.append("## " + heading + "\n" + facts.map { "- " + $0.text }.joined(separator: "\n"))
        }
        return pieces.joined(separator: "\n\n")
    }
}

struct ObservationQuestion: Codable, Identifiable, Sendable {
    let id: String
    let question: String
    let status: String
    let error: String?
    let result: ObservationSummary?
}

struct ObservationHostView: Codable, Sendable {
    let id: String
    let status: String
    let eventCount: Int
    let lastSeq: Int
    let summaryThroughSeq: Int
    let analysisRunning: Bool
    let modelReady: Bool
    let lastError: String?
    let notes: [ObservationSummary]
    let questions: [ObservationQuestion]
    let screenInsights: [ObservationScreenInsight]?
    let visionRunning: Bool?
    enum CodingKeys: String, CodingKey {
        case id, status, notes, questions
        case screenInsights = "screen_insights", visionRunning = "vision_running"
        case eventCount = "event_count", lastSeq = "last_seq", summaryThroughSeq = "summary_through_seq"
        case analysisRunning = "analysis_running", modelReady = "model_ready", lastError = "last_error"
    }
}

struct ObservationUploadReceipt: Decodable, Sendable {
    let acknowledgedIDs: [String]
    let session: ObservationHostView
    enum CodingKeys: String, CodingKey { case session; case acknowledgedIDs = "acknowledged_ids" }
}

struct ObservationConfiguration: Codable, Sendable {
    let id: String
    let preset: ObservationPreset
    let sources: [ObservationSource]
    let createdAt: String
    let consentVersion: Int
    enum CodingKeys: String, CodingKey {
        case id, preset, sources
        case createdAt = "created_at", consentVersion = "consent_version"
    }
}

struct ObservationSessionRecord: Codable, Identifiable, Sendable {
    var id: String { configuration.id }
    let configuration: ObservationConfiguration
    /// Pin the paired destination: observations cannot silently follow a changed Host.
    let endpoint: String
    var phase: ObservationPhase
    var capturedSeconds: Double = 0
    var eventCount = 0
    var acknowledgedIDs: Set<String> = []
    var hostCreated = false
    var hasEnded = false
    var interruption: String? = nil
    var hostView: ObservationHostView? = nil
}

enum ObservationLimits {
    static let eventCount = 12_000
    static let offlineBytes = 48 * 1024 * 1024
    static let screenInterval: TimeInterval = 2
    static let screenVisionInterval: TimeInterval = 5
    static let summaryInterval: TimeInterval = 120
    static let maximumDuration: TimeInterval = 4 * 60 * 60
    static let uploadBatchBytes = 320_000 // Keep normal screenshot uploads comfortably below mobile tunnel timeouts.
    static let uploadSingleEventFallbackBytes = 1_800_000 // Still below the Host 2 MiB body guard.
}

func observationTimestamp(_ date: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

/// One durable journal for session state and exact-ID evidence. No raw audio or
/// full video is stored. Images are removed locally after the paired Host ACK.
/// Only application-owned observation paths are writable.
@MainActor
final class ObservationJournal {
    let root: URL
    init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Observation", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var location = self.root; try location.setResourceValues(values)
    }
    private func directory(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        return root.appendingPathComponent(id, isDirectory: true)
    }
    private func write<T: Encodable>(_ value: T, to path: URL) throws {
        try JSONEncoder().encode(value).write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func save(_ record: ObservationSessionRecord) throws {
        let dir = try directory(record.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write(record, to: dir.appendingPathComponent("session.json"))
        try write(record.id, to: root.appendingPathComponent("current.json"))
    }
    func append(_ event: ObservationEvent, to record: ObservationSessionRecord) throws {
        guard UUID(uuidString: event.id) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        let dir = try directory(record.id).appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(event.id + ".json")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        try write(event, to: file)
    }
    func events(_ id: String) throws -> [ObservationEvent] {
        let dir = try directory(id).appendingPathComponent("events", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(ObservationEvent.self, from: Data(contentsOf: $0)) }
            .sorted { $0.offsetMS == $1.offsetMS ? $0.id < $1.id : $0.offsetMS < $1.offsetMS }
    }
    func removeAcknowledgedImages(_ ids: Set<String>, sessionID: String) throws {
        let dir = try directory(sessionID).appendingPathComponent("events", isDirectory: true)
        for id in ids {
            guard UUID(uuidString: id) != nil else { continue }
            let path = dir.appendingPathComponent(id + ".json")
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            let event = try JSONDecoder().decode(ObservationEvent.self, from: Data(contentsOf: path))
            if event.imageBase64 != nil { try write(event.withoutImage, to: path) }
        }
    }
    func current() throws -> ObservationSessionRecord? {
        let path = root.appendingPathComponent("current.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let id = try JSONDecoder().decode(String.self, from: Data(contentsOf: path))
        let file = try directory(id).appendingPathComponent("session.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(ObservationSessionRecord.self, from: Data(contentsOf: file))
    }
    func records() -> [ObservationSessionRecord] {
        let directories = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return directories.compactMap { dir in
            guard UUID(uuidString: dir.lastPathComponent) != nil,
                  let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")) else { return nil }
            return try? JSONDecoder().decode(ObservationSessionRecord.self, from: data)
        }.sorted { $0.configuration.createdAt > $1.configuration.createdAt }
    }
    func clearCurrent() throws {
        let path = root.appendingPathComponent("current.json")
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    func delete(_ id: String) throws {
        let isCurrent = try current()?.id == id
        try FileManager.default.removeItem(at: directory(id))
        if isCurrent { try clearCurrent() }
    }
}
