import Foundation
import CryptoKit
import ImageIO
import CoreTransferable
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import PDFKit
import QuickLook



enum TaskFileExportOperationState: String, Codable, Sendable {
    case prepared = "PREPARED"
    case verified = "VERIFIED"
    case definitelyNotStarted = "DEFINITELY_NOT_STARTED"
    case mayHaveStarted = "MAY_HAVE_STARTED"
    case completedSystemExportTransaction = "COMPLETED_SYSTEM_EXPORT_TRANSACTION"
    case userCancelled = "USER_CANCELLED"
    case failedExplicit = "FAILED_EXPLICIT"
    case unknown = "UNKNOWN"

    var isTerminal: Bool {
        switch self {
        case .definitelyNotStarted, .completedSystemExportTransaction,
             .userCancelled, .failedExplicit, .unknown:
            return true
        case .prepared, .verified, .mayHaveStarted:
            return false
        }
    }
}


struct TaskFileExportOperationRecord: Codable, Sendable, Equatable, Identifiable {
    let exportOperationID: String
    let operationKind: String
    let taskID: String
    let sourceArtifactID: String
    let sourceSHA256: String
    let sourceSizeBytes: Int
    let sourceMediaType: String
    let displayFilename: String
    var state: TaskFileExportOperationState
    let preparedAt: Date
    var mayHaveStartedAt: Date?
    var terminalAt: Date?
    var destinationFilename: String?
    var errorCode: String?

    var id: String { exportOperationID }
}


actor TaskFileExportOperationStore {
    static let shared: TaskFileExportOperationStore? = try? TaskFileExportOperationStore()

    private let fileURL: URL
    private var records: [String: TaskFileExportOperationRecord]

    init(directoryURL: URL? = nil, recoveryDate: Date = Date()) throws {
        let directory: URL
        if let directoryURL {
            directory = directoryURL
        } else {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            directory = base
                .appendingPathComponent("Floweroll", isDirectory: true)
                .appendingPathComponent("NativeArtifactOperations", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("files-export-v1.json")

        var loaded: [TaskFileExportOperationRecord] = []
        if let data = try? Data(contentsOf: fileURL), !data.isEmpty {
            loaded = try JSONDecoder().decode([TaskFileExportOperationRecord].self, from: data)
        }
        var changed = false
        for index in loaded.indices where loaded[index].state == .mayHaveStarted {
            loaded[index].state = .unknown
            loaded[index].terminalAt = recoveryDate
            loaded[index].errorCode = "callback_missing_after_relaunch"
            changed = true
        }
        records = Dictionary(uniqueKeysWithValues: loaded.map { ($0.exportOperationID, $0) })
        if changed {
            try Self.persist(Array(records.values), to: fileURL)
        }
    }

    func prepare(
        taskID: String,
        file: TaskMaterialFile,
        at date: Date = Date()
    ) throws -> TaskFileExportOperationRecord {
        try TaskMaterialExportIntegrity.validateMetadata(file)
        let operationID = UUID().uuidString
        let record = TaskFileExportOperationRecord(
            exportOperationID: operationID,
            operationKind: "files_export",
            taskID: taskID,
            sourceArtifactID: file.id,
            sourceSHA256: file.sha256.lowercased(),
            sourceSizeBytes: file.sizeBytes,
            sourceMediaType: file.mediaType,
            displayFilename: TaskFileExportFormat.sanitizedDisplayFilename(file.name, mediaType: file.mediaType),
            state: .prepared,
            preparedAt: date,
            mayHaveStartedAt: nil,
            terminalAt: nil,
            destinationFilename: nil,
            errorCode: nil
        )
        records[operationID] = record
        try persist()
        return record
    }

    @discardableResult
    func markVerified(_ operationID: String, at date: Date = Date()) throws -> TaskFileExportOperationRecord {
        try transition(operationID, to: .verified, at: date)
    }

    @discardableResult
    func markMayHaveStarted(_ operationID: String, at date: Date = Date()) throws -> TaskFileExportOperationRecord {
        try transition(operationID, to: .mayHaveStarted, at: date)
    }

    @discardableResult
    func complete(
        _ operationID: String,
        destinationFilename: String?,
        at date: Date = Date()
    ) throws -> TaskFileExportOperationRecord {
        try transition(
            operationID,
            to: .completedSystemExportTransaction,
            at: date,
            destinationFilename: destinationFilename.map(Self.safeDestinationFilename)
        )
    }

    @discardableResult
    func cancel(_ operationID: String, at date: Date = Date()) throws -> TaskFileExportOperationRecord {
        try transition(operationID, to: .userCancelled, at: date)
    }

    @discardableResult
    func failExplicit(
        _ operationID: String,
        errorCode: String,
        at date: Date = Date()
    ) throws -> TaskFileExportOperationRecord {
        try transition(operationID, to: .failedExplicit, at: date, errorCode: errorCode)
    }

    @discardableResult
    func markDefinitelyNotStarted(
        _ operationID: String,
        errorCode: String,
        at date: Date = Date()
    ) throws -> TaskFileExportOperationRecord {
        try transition(operationID, to: .definitelyNotStarted, at: date, errorCode: errorCode)
    }

    func record(_ operationID: String) -> TaskFileExportOperationRecord? {
        records[operationID]
    }

    func latestUnknown(taskID: String) -> TaskFileExportOperationRecord? {
        records.values
            .filter { $0.taskID == taskID && $0.state == .unknown }
            .max { $0.preparedAt < $1.preparedAt }
    }

    func latestRecord(taskID: String) -> TaskFileExportOperationRecord? {
        records.values
            .filter { $0.taskID == taskID }
            .max { $0.preparedAt < $1.preparedAt }
    }

    private func transition(
        _ operationID: String,
        to next: TaskFileExportOperationState,
        at date: Date,
        destinationFilename: String? = nil,
        errorCode: String? = nil
    ) throws -> TaskFileExportOperationRecord {
        guard var record = records[operationID], Self.canTransition(from: record.state, to: next) else {
            throw TaskFileExportError.invalidOperationState
        }
        record.state = next
        if next == .mayHaveStarted { record.mayHaveStartedAt = date }
        if next.isTerminal { record.terminalAt = date }
        if let destinationFilename { record.destinationFilename = destinationFilename }
        if let errorCode { record.errorCode = errorCode }
        records[operationID] = record
        try persist()
        return record
    }

    private static func canTransition(
        from current: TaskFileExportOperationState,
        to next: TaskFileExportOperationState
    ) -> Bool {
        switch (current, next) {
        case (.prepared, .verified),
             (.prepared, .definitelyNotStarted),
             (.verified, .mayHaveStarted),
             (.verified, .definitelyNotStarted),
             (.mayHaveStarted, .completedSystemExportTransaction),
             (.mayHaveStarted, .userCancelled),
             (.mayHaveStarted, .failedExplicit),
             (.mayHaveStarted, .unknown):
            return true
        default:
            return false
        }
    }

    private func persist() throws {
        try Self.persist(Array(records.values), to: fileURL)
    }

    private static func persist(_ records: [TaskFileExportOperationRecord], to url: URL) throws {
        let ordered = records.sorted { $0.preparedAt < $1.preparedAt }
        let data = try JSONEncoder().encode(ordered)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func safeDestinationFilename(_ raw: String) -> String {
        let clean = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.prefix(240))
    }
}
