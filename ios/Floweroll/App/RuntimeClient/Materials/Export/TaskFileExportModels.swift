import Foundation
import CryptoKit
import ImageIO
import CoreTransferable
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import PDFKit
import QuickLook



enum TaskFileExportError: Error, LocalizedError, Sendable, Equatable {
    case missingVerifiedSource
    case unsupportedMediaType
    case invalidSourceMetadata
    case sourceMissing
    case sourceSizeMismatch
    case sourceHashMismatch
    case operationStoreUnavailable
    case invalidOperationState

    var errorDescription: String? {
        switch self {
        case .missingVerifiedSource:
            return "这个文件还没有成为已验证的任务成果，暂时不能保存到文件。"
        case .unsupportedMediaType:
            return "这个文件格式暂时不能保存到“文件”。"
        case .invalidSourceMetadata, .sourceMissing, .sourceSizeMismatch, .sourceHashMismatch:
            return "文件校验失败，没有开始保存。请重新取回文件后再试。"
        case .operationStoreUnavailable:
            return "暂时无法安全记录这次保存操作，没有开始保存。"
        case .invalidOperationState:
            return "这次保存操作的状态已经变化，请重新点击“保存到文件”。"
        }
    }

    var code: String {
        switch self {
        case .missingVerifiedSource: return "missing_verified_source"
        case .unsupportedMediaType: return "unsupported_media_type"
        case .invalidSourceMetadata: return "invalid_source_metadata"
        case .sourceMissing: return "source_missing"
        case .sourceSizeMismatch: return "source_size_mismatch"
        case .sourceHashMismatch: return "source_sha256_mismatch"
        case .operationStoreUnavailable: return "operation_store_unavailable"
        case .invalidOperationState: return "invalid_operation_state"
        }
    }
}


enum TaskFileExportFormat {
    static let markdownType = UTType(filenameExtension: "md")
        ?? UTType(importedAs: "net.daringfireball.markdown")

    static func contentType(for mediaType: String) -> UTType? {
        switch mediaType.lowercased() {
        case "application/pdf": return .pdf
        case "image/jpeg", "image/jpg": return .jpeg
        case "image/png": return .png
        case "text/plain": return .plainText
        case "text/html": return .html
        case "text/markdown": return markdownType
        case TaskAttachmentFormat.docxMIME: return TaskAttachmentFormat.docxType
        default: return nil
        }
    }

    static func defaultExtension(for mediaType: String) -> String {
        switch mediaType.lowercased() {
        case "application/pdf": return "pdf"
        case "image/png": return "png"
        case "text/plain": return "txt"
        case "text/html": return "html"
        case "text/markdown": return "md"
        case TaskAttachmentFormat.docxMIME: return "docx"
        default: return "jpg"
        }
    }

    static func sanitizedDisplayFilename(_ raw: String, mediaType: String) -> String {
        var clean = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty || clean == "." || clean == ".." {
            clean = "结果.\(defaultExtension(for: mediaType))"
        }
        return String(clean.prefix(240))
    }
}


enum TaskFileExportPolicy {
    static func verifiedOutput(
        sourceArtifactID: String,
        manifest: TaskMaterialManifest
    ) -> TaskMaterialFile? {
        guard let file = manifest.outputs.first(where: { $0.id == sourceArtifactID }),
              TaskFileExportFormat.contentType(for: file.mediaType) != nil
        else { return nil }
        return file
    }
}


struct TaskMaterialExportSource: Sendable, Equatable {
    let taskID: String
    let sourceArtifactID: String
    let sourceSHA256: String
    let sourceSizeBytes: Int
    let sourceMediaType: String
    let displayFilename: String
    let localURL: URL
}


enum TaskMaterialExportIntegrity {
    static func validateMetadata(_ file: TaskMaterialFile) throws {
        guard file.sizeBytes > 0,
              file.sizeBytes <= 64 * 1024 * 1024,
              file.sha256.count == 64,
              file.sha256.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 65...70, 97...102: return true
                  default: return false
                  }
              }),
              TaskFileExportFormat.contentType(for: file.mediaType) != nil
        else {
            if TaskFileExportFormat.contentType(for: file.mediaType) == nil {
                throw TaskFileExportError.unsupportedMediaType
            }
            throw TaskFileExportError.invalidSourceMetadata
        }
    }

    static func verifiedSource(
        taskID: String,
        file: TaskMaterialFile,
        localURL: URL
    ) throws -> TaskMaterialExportSource {
        try validateMetadata(file)
        guard localURL.isFileURL else { throw TaskFileExportError.sourceMissing }
        let values = try localURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw TaskFileExportError.sourceMissing }
        guard values.fileSize == file.sizeBytes else { throw TaskFileExportError.sourceSizeMismatch }

        let digest = try sha256(localURL)
        guard digest == file.sha256.lowercased() else { throw TaskFileExportError.sourceHashMismatch }
        return TaskMaterialExportSource(
            taskID: taskID,
            sourceArtifactID: file.id,
            sourceSHA256: file.sha256.lowercased(),
            sourceSizeBytes: file.sizeBytes,
            sourceMediaType: file.mediaType,
            displayFilename: TaskFileExportFormat.sanitizedDisplayFilename(file.name, mediaType: file.mediaType),
            localURL: localURL
        )
    }

    @discardableResult
    static func reverify(_ source: TaskMaterialExportSource) throws -> URL {
        let values = try source.localURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw TaskFileExportError.sourceMissing }
        guard values.fileSize == source.sourceSizeBytes else { throw TaskFileExportError.sourceSizeMismatch }
        guard try sha256(source.localURL) == source.sourceSHA256.lowercased() else {
            throw TaskFileExportError.sourceHashMismatch
        }
        return source.localURL
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}


struct TaskMaterialLocalFileResolver: Sendable {
    let download: @Sendable (String, TaskMaterialFile) async throws -> URL

    func resolve(
        taskID: String,
        sourceArtifactID: String,
        manifest: TaskMaterialManifest
    ) async throws -> TaskMaterialExportSource {
        guard !taskID.isEmpty,
              let file = TaskFileExportPolicy.verifiedOutput(
                sourceArtifactID: sourceArtifactID,
                manifest: manifest
              )
        else { throw TaskFileExportError.missingVerifiedSource }
        try TaskMaterialExportIntegrity.validateMetadata(file)
        let url = try await download(taskID, file)
        return try TaskMaterialExportIntegrity.verifiedSource(taskID: taskID, file: file, localURL: url)
    }
}


struct ExportableTaskFile: Transferable, Sendable, Equatable, Identifiable {
    static let shouldAllowToOpenInPlace = false
    static let allowAccessingOriginalFile = false

    let operationID: String
    let source: TaskMaterialExportSource

    var id: String { operationID }
    var contentType: UTType? { TaskFileExportFormat.contentType(for: source.sourceMediaType) }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf, shouldAllowToOpenInPlace: false) { item in
            try sentFile(item, mediaType: "application/pdf")
        }
        .exportingCondition { $0.source.sourceMediaType.lowercased() == "application/pdf" }
        .suggestedFileName { $0.source.displayFilename }

        FileRepresentation(exportedContentType: .jpeg, shouldAllowToOpenInPlace: false) { item in
            try sentFile(item, mediaType: "image/jpeg")
        }
        .exportingCondition {
            ["image/jpeg", "image/jpg"].contains($0.source.sourceMediaType.lowercased())
        }
        .suggestedFileName { $0.source.displayFilename }

        FileRepresentation(exportedContentType: .png, shouldAllowToOpenInPlace: false) { item in
            try sentFile(item, mediaType: "image/png")
        }
        .exportingCondition { $0.source.sourceMediaType.lowercased() == "image/png" }
        .suggestedFileName { $0.source.displayFilename }

        FileRepresentation(exportedContentType: .plainText, shouldAllowToOpenInPlace: false) { item in
            try sentFile(item, mediaType: "text/plain")
        }
        .exportingCondition { $0.source.sourceMediaType.lowercased() == "text/plain" }
        .suggestedFileName { $0.source.displayFilename }

        FileRepresentation(exportedContentType: .html, shouldAllowToOpenInPlace: false) { item in
            try sentFile(item, mediaType: "text/html")
        }
        .exportingCondition { $0.source.sourceMediaType.lowercased() == "text/html" }
        .suggestedFileName { $0.source.displayFilename }

        FileRepresentation(exportedContentType: TaskFileExportFormat.markdownType, shouldAllowToOpenInPlace: false) { item in
            try sentFile(item, mediaType: "text/markdown")
        }
        .exportingCondition { $0.source.sourceMediaType.lowercased() == "text/markdown" }
        .suggestedFileName { $0.source.displayFilename }

        FileRepresentation(exportedContentType: TaskAttachmentFormat.docxType, shouldAllowToOpenInPlace: false) { item in
            try sentFile(item, mediaType: TaskAttachmentFormat.docxMIME)
        }
        .exportingCondition { $0.source.sourceMediaType.lowercased() == TaskAttachmentFormat.docxMIME }
        .suggestedFileName { $0.source.displayFilename }
    }

    private static func sentFile(
        _ item: ExportableTaskFile,
        mediaType: String
    ) throws -> SentTransferredFile {
        let actual = item.source.sourceMediaType.lowercased()
        let expected = mediaType.lowercased()
        if expected == "image/jpeg" {
            guard actual == "image/jpeg" || actual == "image/jpg" else {
                throw TaskFileExportError.unsupportedMediaType
            }
        } else {
            guard actual == expected else { throw TaskFileExportError.unsupportedMediaType }
        }
        let url = try TaskMaterialExportIntegrity.reverify(item.source)
        return SentTransferredFile(url, allowAccessingOriginalFile: false)
    }
}


struct TaskFileExportFeedback: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case success
        case cancelled
        case failure
        case unknown
    }

    let kind: Kind
    let message: String

    var systemImage: String {
        switch kind {
        case .success: return "checkmark.circle"
        case .cancelled: return "xmark.circle"
        case .failure: return "exclamationmark.triangle"
        case .unknown: return "questionmark.circle"
        }
    }
}
