import Observation
import SwiftUI



struct RuntimeStructuredResultPresentation {
    struct TimeBlock: Equatable { let title: String; let detail: String }
    struct Section: Equatable { let title: String; let body: String }
    struct ChecklistItem: Equatable { let text: String; let completed: Bool? }
    struct Fact: Equatable { let label: String; let value: String }

    let lead: String?
    let timeBlocks: [TimeBlock]
    let sections: [Section]
    let checklist: [ChecklistItem]
    let facts: [Fact]
    let technicalFacts: [Fact]

    private static let internalKeys: Set<String> = [
        "action_id", "attempt_id", "artifact_id", "file_id", "sha256", "revision",
        "revision_id", "decision_id", "submission_id", "task_id", "thread_id", "trace_id",
        "idempotency_key", "correlation_id"
    ]
    private static let timeKeys: Set<String> = ["events", "schedule", "time_blocks", "agenda", "itinerary", "calendar", "timeline"]
    private static let checklistKeys: Set<String> = ["checklist", "steps", "tasks", "items", "todo", "todos"]
    private static let sectionKeys: Set<String> = ["sections", "chapters", "groups"]

    static func make(from result: JSONValue) -> Self {
        guard case let .object(object) = result else {
            return .init(lead: displayText(result).map(RuntimeHumanText.normalize), timeBlocks: [], sections: [], checklist: [], facts: [], technicalFacts: [])
        }
        var parsed = parseSummary(object["summary"]?.stringValue)
        var facts: [Fact] = []
        var technical: [Fact] = []
        for key in object.keys.sorted() where key != "summary" {
            guard let value = object[key] else { continue }
            if internalKeys.contains(key) {
                if let text = displayText(value), !text.isEmpty { technical.append(.init(label: label(for: key), value: RuntimeHumanText.normalize(text))) }
                continue
            }
            if let values = value.arrayValue {
                if timeKeys.contains(key) {
                    parsed.timeBlocks.append(contentsOf: values.compactMap(timeBlock))
                    continue
                }
                if checklistKeys.contains(key) {
                    parsed.checklist.append(contentsOf: values.compactMap(checklistItem))
                    continue
                }
                if sectionKeys.contains(key) {
                    parsed.sections.append(contentsOf: values.compactMap(section))
                    continue
                }
            }
            if let text = displayText(value), !text.isEmpty { facts.append(.init(label: label(for: key), value: RuntimeHumanText.normalize(text))) }
        }
        return .init(lead: parsed.lead, timeBlocks: dedupe(parsed.timeBlocks), sections: parsed.sections, checklist: parsed.checklist, facts: Array(facts.prefix(10)), technicalFacts: technical)
    }

    private struct Parsed { var lead: String?; var timeBlocks: [TimeBlock]; var sections: [Section]; var checklist: [ChecklistItem] }

    private static func parseSummary(_ raw: String?) -> Parsed {
        guard let raw else { return .init(lead: nil, timeBlocks: [], sections: [], checklist: []) }
        let text = RuntimeHumanText.normalize(raw)
        var lead: [String] = [], times: [TimeBlock] = [], sections: [Section] = [], checks: [ChecklistItem] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            var wasBullet = false
            for prefix in ["- ", "• ", "· ", "* ", "✓ ", "✅ ", "☐ ", "□ "] where line.hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                wasBullet = true
                break
            }
            if !wasBullet, let range = line.range(of: #"^\d+[\.、\)]\s*"#, options: .regularExpression) {
                line = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                wasBullet = true
            }
            if let clock = splitLeadingClock(line) {
                times.append(.init(title: clock.title, detail: clock.body.isEmpty ? "待安排" : clock.body))
                continue
            }
            if let embedded = splitEmbeddedDateTime(line) {
                times.append(.init(title: embedded.title, detail: embedded.body.isEmpty ? "待安排" : embedded.body))
                continue
            }
            if let pair = splitHeading(line) {
                if looksLikeTime(pair.title) { times.append(.init(title: pair.title, detail: pair.body.isEmpty ? "待安排" : pair.body)) }
                else if wasBullet { checks.append(.init(text: line, completed: nil)) }
                else if pair.body.isEmpty { sections.append(.init(title: pair.title, body: "")) }
                else { sections.append(.init(title: pair.title, body: pair.body)) }
            } else if wasBullet {
                checks.append(.init(text: line, completed: nil))
            } else {
                lead.append(line)
            }
        }
        // Empty heading-only sections are visual headings, not useful cards.
        sections.removeAll { $0.body.isEmpty }
        let leadText = lead.joined(separator: "\n")
        return .init(lead: leadText.isEmpty ? nil : leadText, timeBlocks: times, sections: sections, checklist: checks)
    }

    private static func splitLeadingClock(_ line: String) -> (title: String, body: String)? {
        guard let range = line.range(
            of: #"^(?:[01]?\d|2[0-3]):[0-5]\d(?:\s+|$)"#,
            options: .regularExpression
        ) else { return nil }
        let token = String(line[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        let body = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (token, body)
    }

    private static func splitEmbeddedDateTime(_ line: String) -> (title: String, body: String)? {
        guard let range = line.range(
            of: #"\d{4}年\d{1,2}月\d{1,2}日\s+(?:[01]?\d|2[0-3]):[0-5]\d"#,
            options: .regularExpression
        ) else { return nil }

        let title = String(line[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        let punctuation = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,；;"))
        let before = String(line[..<range.lowerBound]).trimmingCharacters(in: punctuation)
        let after = String(line[range.upperBound...]).trimmingCharacters(in: punctuation)
        let body: String
        switch (before.isEmpty, after.isEmpty) {
        case (false, false): body = before + "，" + after
        case (false, true): body = before
        case (true, false): body = after
        case (true, true): body = ""
        }
        return (title, body)
    }

    private static func splitHeading(_ line: String) -> (title: String, body: String)? {
        // Prefer the full-width Chinese colon. For ASCII colons, explicitly skip
        // valid HH:mm clock separators even when the clock appears mid-sentence.
        if let r = line.range(of: "：") {
            let title = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let body = String(line[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, title.count <= 40 { return (title, body) }
        }

        var searchStart = line.startIndex
        while searchStart < line.endIndex,
              let r = line.range(of: ":", range: searchStart..<line.endIndex) {
            if !isClockColon(line, colon: r) {
                let title = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let body = String(line[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty, title.count <= 40 { return (title, body) }
            }
            searchStart = r.upperBound
        }
        return nil
    }

    private static func isClockColon(_ line: String, colon: Range<String.Index>) -> Bool {
        let left = line[..<colon.lowerBound]
        let right = line[colon.upperBound...]
        let hourDigits = String(left.reversed().prefix(while: { $0.isNumber }).reversed())
        let minuteDigits = String(right.prefix(2))
        guard (1...2).contains(hourDigits.count), minuteDigits.count == 2,
              hourDigits.allSatisfy({ $0.isNumber }), minuteDigits.allSatisfy({ $0.isNumber }),
              let hour = Int(hourDigits), let minute = Int(minuteDigits),
              (0...23).contains(hour), (0...59).contains(minute)
        else { return false }
        let afterMinute = right.dropFirst(2).first
        return afterMinute.map { !$0.isNumber } ?? true
    }

    private static func looksLikeTime(_ text: String) -> Bool {
        text.range(of: #"\d{1,2}[月/]\d{1,2}"#, options: .regularExpression) != nil
            || text.range(of: #"\b\d{1,2}:\d{2}\b"#, options: .regularExpression) != nil
            || ["周一","周二","周三","周四","周五","周六","周日"].contains { text.contains($0) }
    }

    private static func timeBlock(_ value: JSONValue) -> TimeBlock? {
        if case let .string(text) = value {
            let normalized = RuntimeHumanText.normalize(text)
            if let clock = splitLeadingClock(normalized) {
                return .init(title: clock.title, detail: clock.body.isEmpty ? "待安排" : clock.body)
            }
            if let embedded = splitEmbeddedDateTime(normalized) {
                return .init(title: embedded.title, detail: embedded.body.isEmpty ? "待安排" : embedded.body)
            }
            if let pair = splitHeading(normalized) {
                return .init(title: pair.title, detail: pair.body)
            }
            return nil
        }
        guard let object = value.objectValue else { return nil }
        let title = firstText(object, ["time","date","start_at","start","when","title"]) ?? "安排"
        let detail = firstText(object, ["summary","detail","name","event","activity","end_at","end"]) ?? ""
        return title.isEmpty && detail.isEmpty ? nil : .init(title: RuntimeHumanText.normalize(title), detail: RuntimeHumanText.normalize(detail))
    }

    private static func checklistItem(_ value: JSONValue) -> ChecklistItem? {
        if case let .string(text) = value { let t = RuntimeHumanText.normalize(text); return t.isEmpty ? nil : .init(text: t, completed: nil) }
        guard let object = value.objectValue, let text = firstText(object, ["title","text","name","task","item","summary"]) else { return nil }
        let completed = object["completed"]?.boolValue ?? object["done"]?.boolValue
        return .init(text: RuntimeHumanText.normalize(text), completed: completed)
    }

    private static func section(_ value: JSONValue) -> Section? {
        guard let object = value.objectValue,
              let title = firstText(object, ["heading","title","name"]),
              let body = firstText(object, ["body","text","summary","content"]) else { return nil }
        return .init(title: RuntimeHumanText.normalize(title), body: RuntimeHumanText.normalize(body))
    }

    private static func firstText(_ object: [String: JSONValue], _ keys: [String]) -> String? {
        for key in keys { if let value = displayText(object[key]), !value.isEmpty { return value } }
        return nil
    }

    static func displayText(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case let .string(text): return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let .number(number): return number.rounded() == number ? String(Int(number)) : String(format: "%.3f", number).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        case let .bool(flag): return flag ? "是" : "否"
        case let .array(values): let p = values.compactMap { displayText($0) }; return p.isEmpty ? nil : p.prefix(8).map { "• " + $0 }.joined(separator: "\n")
        case let .object(object): return firstText(object, ["summary","title","name","text","value","body"])
        case .null: return nil
        }
    }

    static func label(for key: String) -> String {
        let map = ["status":"状态","count":"数量","total":"总计","value":"结果","date":"日期","time":"时间","start":"开始","end":"结束","start_at":"开始","end_at":"结束","title":"标题","name":"名称","text":"内容","query":"查询","page_count":"页数","ocr_text":"识别文字","result":"结果","location":"地点","duration":"时长"]
        return map[key] ?? key.replacingOccurrences(of: "_", with: " ")
    }

    private static func dedupe(_ values: [TimeBlock]) -> [TimeBlock] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.title + "\u{0}" + $0.detail).inserted }
    }
}


struct RuntimeTaskResultCard: View {
    let result: JSONValue
    @AppStorage("floweroll.developerMode") private var developerMode = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var presentation: RuntimeStructuredResultPresentation { .make(from: result) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("结果", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.green)
            if let lead = presentation.lead { Text(lead).font(.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            if !presentation.timeBlocks.isEmpty {
                subheading("时间安排", "calendar")
                VStack(spacing: 8) { ForEach(Array(presentation.timeBlocks.enumerated()), id: \.offset) { _, block in timeBlockRow(block).padding(10).background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12)) } }
            }
            ForEach(Array(presentation.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 6) { Text(section.title).font(.subheadline.weight(.semibold)); Text(section.body).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled) }
                    .padding(11).frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
            }
            if !presentation.checklist.isEmpty {
                subheading("清单", "checklist")
                VStack(alignment: .leading, spacing: 9) { ForEach(Array(presentation.checklist.enumerated()), id: \.offset) { _, item in HStack(alignment: .top, spacing: 9) { Image(systemName: item.completed == true ? "checkmark.circle.fill" : "circle").foregroundStyle(item.completed == true ? Color.green : Color.secondary); Text(item.text).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) } } }
            }
            if !presentation.facts.isEmpty {
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 9) { ForEach(Array(presentation.facts.enumerated()), id: \.offset) { _, row in HStack(alignment: .top, spacing: 10) { Text(row.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 78, alignment: .leading); Text(row.value).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) } } }
            }
            if developerMode, !presentation.technicalFacts.isEmpty {
                DisclosureGroup("技术字段") { ForEach(Array(presentation.technicalFacts.enumerated()), id: \.offset) { _, row in LabeledContent(row.label, value: row.value).font(.caption.monospaced()) } }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.055), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.green.opacity(0.13), lineWidth: 0.7) }
        .accessibilityIdentifier("task.structured-result")
    }

    @ViewBuilder private func timeBlockRow(_ block: RuntimeStructuredResultPresentation.TimeBlock) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 5) { Text(block.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary); Text(block.detail).font(.subheadline).textSelection(.enabled) }
        } else {
            HStack(alignment: .top, spacing: 11) { Text(block.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 92, alignment: .leading); Text(block.detail).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
        }
    }
    private func subheading(_ title: String, _ symbol: String) -> some View { Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
}
