import Foundation
import CryptoKit
import ImageIO
import CoreTransferable
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import PDFKit
import QuickLook



struct TaskMaterialFile: Codable, Sendable, Identifiable {
    struct Progress: Codable, Sendable {
        let phase: String
        let status: String
        let detail: [String: JSONValue]
        let updatedAt: String

        enum CodingKeys: String, CodingKey {
            case phase, status, detail
            case updatedAt = "updated_at"
        }
    }

    let id: String
    let name: String
    let mediaType: String
    let sizeBytes: Int
    let sha256: String
    let category: String
    let metadata: [String: JSONValue]
    let progress: Progress?

    init(
        id: String,
        name: String,
        mediaType: String,
        sizeBytes: Int,
        sha256: String,
        category: String,
        metadata: [String: JSONValue],
        progress: Progress? = nil
    ) {
        self.id = id
        self.name = name
        self.mediaType = mediaType
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.category = category
        self.metadata = metadata
        self.progress = progress
    }

    enum CodingKeys: String, CodingKey {
        case id, name, sha256, category, metadata, progress
        case mediaType = "media_type", sizeBytes = "size_bytes"
    }
}

extension TaskMaterialFile {
    var localInputURL: URL? {
        guard category == "input",
              let directory = try? PendingAttachment.directory()
        else { return nil }
        let name = id + "." + TaskAttachmentFormat.storedExtension(for: mediaType)
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var verifiedLocalInputURL: URL? {
        guard category == "input" else { return nil }
        let storedName = id + "." + TaskAttachmentFormat.storedExtension(for: mediaType)
        let attachment = PendingAttachment(
            id: id,
            name: name,
            mediaType: mediaType,
            sizeBytes: sizeBytes,
            sha256: sha256,
            storedName: storedName
        )
        return try? attachment.verifiedFileURL()
    }
}


extension TaskMaterialFile {
    var userFacingDeliveryStatus: String {
        let progressPDF = progress?.detail["pdf_status"]?.stringValue?.lowercased()
        let progressOCR = progress?.detail["ocr_status"]?.stringValue?.lowercased()
        let reviewRecommended = progress?.detail["review_recommended"]?.boolValue == true
        if progressPDF == "ready" {
            switch progressOCR {
            case "processing":
                return "PDF 已生成 · 正在识别文字"
            case "failed":
                return "PDF 已生成 · 文字识别未完成，建议核对"
            case "partial":
                return "PDF 已生成 · 文字识别不完整，建议核对"
            case "complete":
                return reviewRecommended || progress?.status == "needs_review"
                    ? "PDF 已生成 · 文字识别完成，建议核对"
                    : "PDF 和文字识别已完成"
            default:
                return "PDF 已生成 · 文件已经可用"
            }
        }

        let ocrStatus = metadata["ocr_status"]?.stringValue?.lowercased()
        let materialStatus = metadata["status"]?.stringValue?.lowercased()
        let qualityStatus = metadata["quality_status"]?.stringValue?.lowercased()
        if mediaType == "application/pdf" {
            if ocrStatus == "failed" {
                return "PDF 已生成 · 文字识别未完成，建议核对"
            }
            if materialStatus == "needs_review" || qualityStatus?.contains("review") == true {
                return "PDF 已生成 · 文字识别结果建议核对"
            }
            if ocrStatus == "complete" {
                return "PDF 和文字识别已完成"
            }
        }
        if let label = metadata["label"]?.stringValue, !label.isEmpty { return label }
        return category == "input" ? "原件保留" : "文件已生成"
    }
}
