import Foundation
import CryptoKit
import ImageIO
import CoreTransferable
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import PDFKit
import QuickLook



enum TaskAttachmentFormat {
    static let docxMIME = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    static let docxType = UTType(filenameExtension: "docx")
        ?? UTType(importedAs: "org.openxmlformats.wordprocessingml.document")
    static let allowedFileImportTypes: [UTType] = [.image, .pdf, .plainText, docxType]

    static func storedExtension(for mediaType: String) -> String {
        switch mediaType {
        case "application/pdf": return "pdf"
        case "image/png": return "png"
        case "text/plain": return "txt"
        case docxMIME: return "docx"
        default: return "jpg"
        }
    }

    static func iconName(for mediaType: String) -> String {
        switch mediaType {
        case "application/pdf", docxMIME: return "doc.richtext"
        case let value where value.hasPrefix("image/"): return "photo"
        default: return "doc.text"
        }
    }
}

struct PendingAttachment: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let mediaType: String
    let sizeBytes: Int
    let sha256: String
    let storedName: String

    static func directory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let result = base.appendingPathComponent("Floweroll/TaskAttachments", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    func fileURL() throws -> URL {
        guard !storedName.contains("/"), !storedName.contains("..") else { throw URLError(.badURL) }
        return try Self.directory().appendingPathComponent(storedName)
    }

    func verifiedFileURL() throws -> URL {
        let url = try fileURL()
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.fileSize == sizeBytes else {
            throw MaterialsError.message("附件已损坏或丢失，请重新选择。")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else {
            throw MaterialsError.message("附件已损坏或丢失，请重新选择。")
        }
        return url
    }

    func verifiedData() throws -> Data {
        let url = try verifiedFileURL()
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
}

enum MaterialsError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}
