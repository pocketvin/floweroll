import Foundation


enum PendingSubmissionStoreError: Error, Equatable {
    case emptyText
    case duplicateSubmissionID
    case duplicateUserTurnID
}

struct PendingUserTurn: Codable, Equatable, Sendable, Identifiable {
    let eventID: String
    let taskID: String
    let text: String
    let createdAt: Date
    var attachments: [PendingAttachment]? = nil
    var attemptCount: Int = 0
    var lastAttemptAt: Date? = nil
    var lastErrorMessage: String? = nil

    var id: String { eventID }
}

actor PendingSubmissionStore {
    /// One process-wide owner for the persist-first send journal.
    ///
    /// It owns both new/follow-up Task submissions and task-scoped user turns.
    /// Network/background execution may disappear at any point after this file is
    /// written; replay reuses the same submission_id/event_id and is idempotent.
    static let shared: PendingSubmissionStore? = try? PendingSubmissionStore()

    private struct Snapshot: Codable {
        static let currentSchema = 3
        var schema: Int
        var submissions: [PendingSubmission]
        var userTurns: [PendingUserTurn]

        init(
            schema: Int = currentSchema,
            submissions: [PendingSubmission],
            userTurns: [PendingUserTurn] = []
        ) {
            self.schema = schema
            self.submissions = submissions
            self.userTurns = userTurns
        }

        enum CodingKeys: String, CodingKey {
            case schema, submissions
            case userTurns = "user_turns"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? 1
            submissions = try container.decode([PendingSubmission].self, forKey: .submissions)
            userTurns = try container.decodeIfPresent([PendingUserTurn].self, forKey: .userTurns) ?? []
        }
    }

    private let fileURL: URL
    private var submissions: [String: PendingSubmission]
    private var userTurns: [String: PendingUserTurn]
    // These bounded, process-local identities only distinguish an ACK consumed
    // by a sibling sender from an explicit discard. Host remains the authority:
    // a sibling still reconciles/replays the exact submission_id/event_id.
    // No response cache or second Task state is persisted here.
    private var acknowledgedSubmissionIDs: [String] = []
    private var acknowledgedUserTurnIDs: [String] = []

    init(directoryURL: URL? = nil) throws {
        let directory = try directoryURL ?? Self.defaultDirectoryURL()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        self.fileURL = directory.appendingPathComponent("pending-submissions.json")

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder.floweroll.decode(Snapshot.self, from: data)
            if snapshot.schema < 2 {
                // Build 1 left visually-abandoned failures in the active queue.
                // Replaying them after upgrade could create surprise Tasks.
                // Preserve the exact old bytes for audit/manual recovery, but
                // start the current active outbox empty.
                let quarantine = directory.appendingPathComponent(
                    "pending-submissions-build1-quarantine.json"
                )
                if !FileManager.default.fileExists(atPath: quarantine.path) {
                    try data.write(to: quarantine, options: .atomic)
                }
                self.submissions = [:]
                self.userTurns = [:]
                let clean = Snapshot(submissions: [], userTurns: [])
                let cleanData = try JSONEncoder.floweroll.encode(clean)
                try cleanData.write(to: fileURL, options: .atomic)
            } else {
                self.submissions = Dictionary(
                    uniqueKeysWithValues: snapshot.submissions.map { ($0.submissionID, $0) }
                )
                self.userTurns = Dictionary(
                    uniqueKeysWithValues: snapshot.userTurns.map { ($0.eventID, $0) }
                )
                if snapshot.schema < Snapshot.currentSchema {
                    let migrated = Snapshot(
                        submissions: Self.sortedSubmissions(self.submissions.values),
                        userTurns: Self.sortedUserTurns(self.userTurns.values)
                    )
                    let migratedData = try JSONEncoder.floweroll.encode(migrated)
                    try migratedData.write(to: fileURL, options: .atomic)
                }
            }
        } else {
            self.submissions = [:]
            self.userTurns = [:]
        }
    }

    @discardableResult
    func create(
        text: String,
        invocationSource: String,
        parentTaskID: String? = nil,
        attachments: [PendingAttachment] = [],
        submissionID: String = UUID().uuidString,
        createdAt: Date = Date()
    ) throws -> PendingSubmission {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw PendingSubmissionStoreError.emptyText
        }
        if let existing = submissions[submissionID] {
            guard existing.text == normalized,
                  existing.invocationSource == invocationSource,
                  existing.parentTaskID == parentTaskID,
                  (existing.attachments ?? []) == attachments
            else { throw PendingSubmissionStoreError.duplicateSubmissionID }
            return existing
        }
        // submission_id is the sole idempotency identity. A fresh user send
        // must never be captured by an older failed entry just because the
        // text and attachments happen to match.
        let submission = PendingSubmission(
            submissionID: submissionID,
            text: normalized,
            invocationSource: invocationSource,
            parentTaskID: parentTaskID,
            createdAt: createdAt,
            attachments: attachments.isEmpty ? nil : attachments
        )
        var nextSubmissions = submissions
        nextSubmissions[submissionID] = submission
        try persist(submissions: nextSubmissions, userTurns: userTurns)
        submissions = nextSubmissions
        return submission
    }

    func pending() -> [PendingSubmission] {
        Self.sortedSubmissions(submissions.values)
    }

    func attachmentIDsInUse() -> Set<String> {
        var ids = Set(submissions.values.flatMap { ($0.attachments ?? []).map(\.id) })
        ids.formUnion(
            userTurns.values.flatMap { ($0.attachments ?? []).map(\.id) }
        )
        return ids
    }

    func submission(id: String) -> PendingSubmission? {
        submissions[id]
    }

    func markAttempting(submissionID: String, at: Date = Date()) throws {
        guard var submission = submissions[submissionID] else { return }
        submission.attemptCount += 1
        submission.lastAttemptAt = at
        submission.lastErrorMessage = nil
        var nextSubmissions = submissions
        nextSubmissions[submissionID] = submission
        try persist(submissions: nextSubmissions, userTurns: userTurns)
        submissions = nextSubmissions
    }

    func markFailed(submissionID: String, message: String, at: Date = Date()) throws {
        guard var submission = submissions[submissionID] else { return }
        submission.lastAttemptAt = at
        submission.lastErrorMessage = message
        var nextSubmissions = submissions
        nextSubmissions[submissionID] = submission
        try persist(submissions: nextSubmissions, userTurns: userTurns)
        submissions = nextSubmissions
    }

    func markAccepted(submissionID: String) throws {
        guard submissions[submissionID] != nil else { return }
        var nextSubmissions = submissions
        nextSubmissions.removeValue(forKey: submissionID)
        try persist(submissions: nextSubmissions, userTurns: userTurns)
        submissions = nextSubmissions
        acknowledgedSubmissionIDs.append(submissionID)
        if acknowledgedSubmissionIDs.count > 256 { acknowledgedSubmissionIDs.removeFirst() }
    }

    func canReplaySubmission(submissionID: String) -> Bool {
        submissions[submissionID] != nil || acknowledgedSubmissionIDs.contains(submissionID)
    }

    @discardableResult
    func discard(submissionID: String) throws -> PendingSubmission? {
        guard let removed = submissions[submissionID] else {
            acknowledgedSubmissionIDs.removeAll { $0 == submissionID }
            return nil
        }
        var nextSubmissions = submissions
        nextSubmissions.removeValue(forKey: submissionID)
        try persist(submissions: nextSubmissions, userTurns: userTurns)
        submissions = nextSubmissions
        acknowledgedSubmissionIDs.removeAll { $0 == submissionID }
        return removed
    }

    @discardableResult
    func createUserTurn(
        taskID: String,
        text: String,
        attachments: [PendingAttachment] = [],
        eventID: String = UUID().uuidString,
        createdAt: Date = Date()
    ) throws -> PendingUserTurn {
        let normalizedTaskID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTaskID.isEmpty, !normalized.isEmpty else {
            throw PendingSubmissionStoreError.emptyText
        }
        if let existing = userTurns[eventID] {
            guard existing.taskID == normalizedTaskID,
                  existing.text == normalized,
                  (existing.attachments ?? []) == attachments
            else { throw PendingSubmissionStoreError.duplicateUserTurnID }
            return existing
        }
        let turn = PendingUserTurn(
            eventID: eventID,
            taskID: normalizedTaskID,
            text: normalized,
            createdAt: createdAt,
            attachments: attachments.isEmpty ? nil : attachments
        )
        var nextUserTurns = userTurns
        nextUserTurns[eventID] = turn
        try persist(submissions: submissions, userTurns: nextUserTurns)
        userTurns = nextUserTurns
        return turn
    }

    func pendingUserTurns() -> [PendingUserTurn] {
        Self.sortedUserTurns(userTurns.values)
    }

    func userTurn(eventID: String) -> PendingUserTurn? {
        userTurns[eventID]
    }

    func markUserTurnAttempting(eventID: String, at: Date = Date()) throws {
        guard var turn = userTurns[eventID] else { return }
        turn.attemptCount += 1
        turn.lastAttemptAt = at
        turn.lastErrorMessage = nil
        var nextUserTurns = userTurns
        nextUserTurns[eventID] = turn
        try persist(submissions: submissions, userTurns: nextUserTurns)
        userTurns = nextUserTurns
    }

    func markUserTurnFailed(eventID: String, message: String, at: Date = Date()) throws {
        guard var turn = userTurns[eventID] else { return }
        turn.lastAttemptAt = at
        turn.lastErrorMessage = message
        var nextUserTurns = userTurns
        nextUserTurns[eventID] = turn
        try persist(submissions: submissions, userTurns: nextUserTurns)
        userTurns = nextUserTurns
    }

    func markUserTurnAccepted(eventID: String) throws {
        guard userTurns[eventID] != nil else { return }
        var nextUserTurns = userTurns
        nextUserTurns.removeValue(forKey: eventID)
        try persist(submissions: submissions, userTurns: nextUserTurns)
        userTurns = nextUserTurns
        acknowledgedUserTurnIDs.append(eventID)
        if acknowledgedUserTurnIDs.count > 256 { acknowledgedUserTurnIDs.removeFirst() }
    }

    func canReplayUserTurn(eventID: String) -> Bool {
        userTurns[eventID] != nil || acknowledgedUserTurnIDs.contains(eventID)
    }

    @discardableResult
    func discardUserTurn(eventID: String) throws -> PendingUserTurn? {
        guard let removed = userTurns[eventID] else {
            acknowledgedUserTurnIDs.removeAll { $0 == eventID }
            return nil
        }
        var nextUserTurns = userTurns
        nextUserTurns.removeValue(forKey: eventID)
        try persist(submissions: submissions, userTurns: nextUserTurns)
        userTurns = nextUserTurns
        acknowledgedUserTurnIDs.removeAll { $0 == eventID }
        return removed
    }

    private func persist(
        submissions: [String: PendingSubmission],
        userTurns: [String: PendingUserTurn]
    ) throws {
        let snapshot = Snapshot(
            submissions: Self.sortedSubmissions(submissions.values),
            userTurns: Self.sortedUserTurns(userTurns.values)
        )
        let data = try JSONEncoder.floweroll.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func sortedSubmissions<S: Sequence>(_ values: S) -> [PendingSubmission]
    where S.Element == PendingSubmission {
        values.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.submissionID < $1.submissionID
            }
            return $0.createdAt < $1.createdAt
        }
    }

    private static func sortedUserTurns<S: Sequence>(_ values: S) -> [PendingUserTurn]
    where S.Element == PendingUserTurn {
        values.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.eventID < $1.eventID
            }
            return $0.createdAt < $1.createdAt
        }
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

extension JSONEncoder {
    static var floweroll: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var floweroll: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
