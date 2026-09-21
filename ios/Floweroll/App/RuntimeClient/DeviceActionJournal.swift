import Foundation


enum DeviceActionJournalState: String, Codable, Sendable {
    case received
    case mayHaveStarted
    case completed
    case resultDelivered
}

struct DeviceActionJournalEntry: Codable, Equatable, Sendable {
    let attemptID: String
    let actionID: String
    let idempotencyKey: String
    let dispatchDigest: String
    var state: DeviceActionJournalState
    var success: Bool?
    var result: [String: JSONValue]?
    var error: String?
    var nativeCorrelationID: String?
    let createdAt: Date
    var updatedAt: Date
    var executionCount: Int? = nil
}

enum DeviceActionJournalDecision: Equatable, Sendable {
    case execute(DeviceActionJournalEntry)
    case reconcile(DeviceActionJournalEntry)
    case replayResult(DeviceActionJournalEntry)
}

enum DeviceActionJournalError: Error, Equatable {
    case dispatchIdentityConflict
    case unknownAttempt
    case invalidTransition
}

actor DeviceActionJournal {
    private struct Snapshot: Codable {
        var entries: [DeviceActionJournalEntry]
    }

    private let fileURL: URL
    private var entries: [String: DeviceActionJournalEntry]

    init(directoryURL: URL? = nil) throws {
        let directory = try directoryURL ?? Self.defaultDirectoryURL()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        self.fileURL = directory.appendingPathComponent("device-action-journal.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder.floweroll.decode(Snapshot.self, from: data)
            self.entries = Dictionary(
                uniqueKeysWithValues: snapshot.entries.map { ($0.attemptID, $0) }
            )
        } else {
            self.entries = [:]
        }
    }

    /// Admit an exact Host dispatch before native execution.
    ///
    /// `.execute` means no device-side evidence says the native effect started.
    /// The caller must immediately `markMayHaveStarted` before invoking EventKit,
    /// Reminders, or another side-effect API. `.reconcile` means a previous
    /// process may already have externalized the effect; never blindly re-run it.
    /// `.replayResult` means the result is already durable and can simply be
    /// re-posted to the Host.
    func prepare(_ dispatch: DeviceActionDispatch, now: Date = Date()) throws -> DeviceActionJournalDecision {
        if let existing = entries[dispatch.attemptID] {
            guard
                existing.actionID == dispatch.actionID,
                existing.idempotencyKey == dispatch.idempotencyKey,
                existing.dispatchDigest == dispatch.dispatchDigest
            else {
                throw DeviceActionJournalError.dispatchIdentityConflict
            }
            switch existing.state {
            case .received:
                return .execute(existing)
            case .mayHaveStarted:
                return .reconcile(existing)
            case .completed, .resultDelivered:
                return .replayResult(existing)
            }
        }

        let entry = DeviceActionJournalEntry(
            attemptID: dispatch.attemptID,
            actionID: dispatch.actionID,
            idempotencyKey: dispatch.idempotencyKey,
            dispatchDigest: dispatch.dispatchDigest,
            state: .received,
            success: nil,
            result: nil,
            error: nil,
            nativeCorrelationID: nil,
            createdAt: now,
            updatedAt: now
        )
        try commit(entry)
        return .execute(entry)
    }

    /// Must be persisted immediately before the native API call that can create
    /// a real side effect. A process death after this point requires read-back
    /// reconciliation instead of replaying the native call.
    /// Persist a definitive failure discovered before any side-effect API
    /// can run (for example missing permission or invalid native arguments).
    func recordPreflightFailure(
        attemptID: String,
        error: String,
        result: [String: JSONValue] = [:],
        now: Date = Date()
    ) throws -> DeviceActionJournalEntry {
        guard var entry = entries[attemptID] else {
            throw DeviceActionJournalError.unknownAttempt
        }
        guard entry.state == .received else {
            throw DeviceActionJournalError.invalidTransition
        }
        entry.state = .completed
        entry.success = false
        entry.result = result
        entry.error = error
        entry.updatedAt = now
        try commit(entry)
        return entry
    }

    func markMayHaveStarted(attemptID: String, now: Date = Date()) throws -> DeviceActionJournalEntry {
        guard var entry = entries[attemptID] else {
            throw DeviceActionJournalError.unknownAttempt
        }
        guard entry.state == .received else {
            throw DeviceActionJournalError.invalidTransition
        }
        entry.state = .mayHaveStarted
        entry.executionCount = (entry.executionCount ?? 0) + 1
        entry.updatedAt = now
        try commit(entry)
        return entry
    }

    func markDefinitelyNotStarted(
        attemptID: String,
        now: Date = Date()
    ) throws -> DeviceActionJournalEntry {
        guard var entry = entries[attemptID] else {
            throw DeviceActionJournalError.unknownAttempt
        }
        guard entry.state == .mayHaveStarted else {
            throw DeviceActionJournalError.invalidTransition
        }
        // Native read-back proved the side effect did not begin. Returning to
        // `received` permits one safe execution of the same Host Attempt.
        entry.state = .received
        entry.updatedAt = now
        try commit(entry)
        return entry
    }

    func recordResult(
        attemptID: String,
        success: Bool = true,
        result: [String: JSONValue],
        error: String? = nil,
        nativeCorrelationID: String? = nil,
        now: Date = Date()
    ) throws -> DeviceActionJournalEntry {
        guard var entry = entries[attemptID] else {
            throw DeviceActionJournalError.unknownAttempt
        }
        guard entry.state == .mayHaveStarted else {
            throw DeviceActionJournalError.invalidTransition
        }
        entry.state = .completed
        entry.success = success
        entry.result = result
        entry.error = error
        entry.nativeCorrelationID = nativeCorrelationID
        entry.updatedAt = now
        try commit(entry)
        return entry
    }

    /// Mark only after the Host acknowledges the exact Attempt result. If the
    /// network dies before this call, `.completed` survives and `prepare` will
    /// return `.replayResult` after app restart instead of re-executing.
    func markResultDelivered(attemptID: String, now: Date = Date()) throws -> DeviceActionJournalEntry {
        guard var entry = entries[attemptID] else {
            throw DeviceActionJournalError.unknownAttempt
        }
        guard entry.state == .completed || entry.state == .resultDelivered else {
            throw DeviceActionJournalError.invalidTransition
        }
        entry.state = .resultDelivered
        entry.updatedAt = now
        try commit(entry)
        return entry
    }

    func entry(attemptID: String) -> DeviceActionJournalEntry? {
        entries[attemptID]
    }

    func unresolved() -> [DeviceActionJournalEntry] {
        entries.values
            .filter { $0.state != .resultDelivered }
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.attemptID < $1.attemptID
                }
                return $0.createdAt < $1.createdAt
            }
    }

    private func commit(_ entry: DeviceActionJournalEntry) throws {
        var candidate = entries
        candidate[entry.attemptID] = entry
        let snapshot = Snapshot(entries: candidate.values.sorted { $0.attemptID < $1.attemptID })
        let data = try JSONEncoder.floweroll.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        entries = candidate
    }

    private static func defaultDirectoryURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("Floweroll", isDirectory: true)
            .appendingPathComponent("RuntimeClient", isDirectory: true)
    }
}
