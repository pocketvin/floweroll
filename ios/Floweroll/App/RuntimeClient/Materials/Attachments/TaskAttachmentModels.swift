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

    static func acceptedCacheDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let result = base.appendingPathComponent("Floweroll/TaskAttachments", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    func fileURL() throws -> URL {
        guard !storedName.contains("/"), !storedName.contains("..") else { throw URLError(.badURL) }
        return try Self.directory().appendingPathComponent(storedName)
    }

    func acceptedCacheURL() throws -> URL {
        guard !storedName.contains("/"), !storedName.contains("..") else { throw URLError(.badURL) }
        return try Self.acceptedCacheDirectory().appendingPathComponent(storedName)
    }

    func verifiedFileURL() throws -> URL {
        let url = try fileURL()
        try verify(url)
        return url
    }

    /// Presentation may use either the durable pre-admission copy or the
    /// recreatable post-admission cache. Upload/recovery intentionally keeps
    /// using verifiedFileURL(), so Caches can never become outbox truth.
    func verifiedPresentationFileURL() throws -> URL {
        let candidates = [try fileURL(), try acceptedCacheURL()]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            do {
                try verify(url)
                return url
            } catch {
                continue
            }
        }
        throw MaterialsError.message("附件已损坏或丢失，请重新打开任务获取。")
    }

    private func verify(_ url: URL) throws {
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
    }

    static func moveAcceptedBytesToCache(
        _ ids: Set<String>,
        sourceDirectory: URL? = nil,
        cacheDirectory: URL? = nil
    ) {
        guard !ids.isEmpty else { return }
        guard let sourceDirectory = sourceDirectory ?? (try? directory()),
              let cacheDirectory = cacheDirectory ?? (try? acceptedCacheDirectory()),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: sourceDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              )
        else { return }

        for source in urls {
            let name = source.lastPathComponent
            guard isAttachmentStoredName(name) else { continue }
            let id = source.deletingPathExtension().lastPathComponent
            guard ids.contains(id) else { continue }
            moveToAcceptedCache(source, cacheDirectory: cacheDirectory)
        }
    }

    /// Upgrade/repair path for attachments accepted by older builds. Active
    /// composer/outbox identities are supplied by the caller and remain in
    /// Application Support; everything else is a recreatable presentation copy.
    static func moveUnreferencedDurableBytesToCache(
        protectedIDs: Set<String>,
        sourceDirectory: URL? = nil,
        cacheDirectory: URL? = nil
    ) {
        guard let sourceDirectory = sourceDirectory ?? (try? directory()),
              let cacheDirectory = cacheDirectory ?? (try? acceptedCacheDirectory()),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: sourceDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              )
        else { return }

        for source in urls {
            let name = source.lastPathComponent
            guard isAttachmentStoredName(name) else { continue }
            let id = source.deletingPathExtension().lastPathComponent
            guard !protectedIDs.contains(id) else { continue }
            moveToAcceptedCache(source, cacheDirectory: cacheDirectory)
        }
    }

    private static func isAttachmentStoredName(_ name: String) -> Bool {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        return ["jpg", "png", "pdf", "txt", "docx"].contains(ext)
    }

    private static func moveToAcceptedCache(_ source: URL, cacheDirectory: URL) {
        let destination = cacheDirectory.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            if FileManager.default.contentsEqual(
                atPath: source.path,
                andPath: destination.path
            ) {
                try? FileManager.default.removeItem(at: source)
            }
            return
        }
        try? FileManager.default.moveItem(at: source, to: destination)
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
