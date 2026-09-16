import Foundation
import CryptoKit
import ImageIO
import CoreTransferable
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import PDFKit
import QuickLook



enum TaskImageAttachmentProcessor {
    nonisolated static let maximumStoredBytes = 12 * 1024 * 1024
    nonisolated static let targetStoredBytes = 10 * 1024 * 1024
    nonisolated static let maximumSourceImageBytes = 80 * 1024 * 1024
    nonisolated static let maximumPixelDimension = 4_096

    nonisolated static func compressedJPEG(
        from data: Data,
        maxBytes: Int = targetStoredBytes,
        maxPixelDimension: Int = maximumPixelDimension
    ) throws -> Data {
        guard !data.isEmpty else { throw MaterialsError.message("这张照片是空的，请重新拍摄。") }
        guard data.count <= maximumSourceImageBytes else {
            throw MaterialsError.message("这张照片异常大，暂时无法安全处理，请重新拍摄。")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw MaterialsError.message("无法读取这张图片，请重新选择。")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelDimension),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MaterialsError.message("无法读取这张图片，请重新选择。")
        }
        return try compressedJPEG(
            from: UIImage(cgImage: cgImage),
            maxBytes: maxBytes,
            maxPixelDimension: maxPixelDimension
        )
    }

    nonisolated static func compressedJPEG(
        from image: UIImage,
        maxBytes: Int = targetStoredBytes,
        maxPixelDimension: Int = maximumPixelDimension
    ) throws -> Data {
        guard maxBytes > 0, maxPixelDimension > 0 else {
            throw MaterialsError.message("照片压缩参数无效。")
        }

        var working = normalizedAndResized(image, maximumDimension: CGFloat(maxPixelDimension))
        let qualities: [CGFloat] = [0.90, 0.82, 0.74, 0.66, 0.58, 0.50, 0.42, 0.34, 0.26]
        for _ in 0..<9 {
            for quality in qualities {
                guard let bytes = working.jpegData(compressionQuality: quality) else { continue }
                if bytes.count <= maxBytes { return bytes }
            }
            let longest = max(working.size.width, working.size.height)
            guard longest > 480 else { break }
            working = normalizedAndResized(working, maximumDimension: max(480, longest * 0.80))
        }

        throw MaterialsError.message("照片自动压缩失败，请重新拍摄。")
    }

    nonisolated private static func normalizedAndResized(
        _ image: UIImage,
        maximumDimension: CGFloat
    ) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        let scale = longest > 0 ? min(1, maximumDimension / longest) : 1
        let target = CGSize(
            width: max(1, image.size.width * scale),
            height: max(1, image.size.height * scale)
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

@MainActor @Observable
final class TaskAttachmentDraft {
    nonisolated static let maximumItemCount = 10
    private static weak var currentInstance: TaskAttachmentDraft?

    private(set) var items: [PendingAttachment] = []
    var isLoading = false
    var error: String?

    init() {
        if let dir = try? PendingAttachment.directory(),
           let data = try? Data(contentsOf: dir.appendingPathComponent("composer-draft.json")),
           let items = try? JSONDecoder().decode([PendingAttachment].self, from: data) {
            self.items = items
        }
        Self.currentInstance = self
    }

    var remainingCapacity: Int {
        max(0, Self.maximumItemCount - items.count)
    }

    var isFull: Bool { remainingCapacity == 0 }
    var photoPickerSelectionLimit: Int { max(1, remainingCapacity) }
    var ordinaryCameraCaptureCapacity: Int {
        min(Self.maximumItemCount, remainingCapacity)
    }

    @discardableResult
    func add(data: Data, name: String, mediaType: String) throws -> PendingAttachment {
        guard items.count < Self.maximumItemCount else {
            throw MaterialsError.message("每次最多添加 \(Self.maximumItemCount) 份附件。")
        }
        guard !data.isEmpty, data.count <= TaskImageAttachmentProcessor.maximumStoredBytes else {
            throw MaterialsError.message("每份非图片附件最大 12 MB。")
        }
        let id = UUID().uuidString
        let suffix = TaskAttachmentFormat.storedExtension(for: mediaType)
        let fileName = id + "." + suffix
        let dir = try PendingAttachment.directory()
        try data.write(to: dir.appendingPathComponent(fileName), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var cleanName = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        if cleanName.isEmpty { cleanName = "附件.\(suffix)" }
        let attachment = PendingAttachment(
            id: id, name: cleanName, mediaType: mediaType, sizeBytes: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), storedName: fileName
        )
        items.append(attachment)
        try persist()
        return attachment
    }

    @discardableResult
    func importFile(_ url: URL) throws -> PendingAttachment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let ext = url.pathExtension.lowercased()
        let isImage = UTType(filenameExtension: ext)?.conforms(to: .image) == true
        let sourceLimit = isImage
            ? TaskImageAttachmentProcessor.maximumSourceImageBytes
            : TaskImageAttachmentProcessor.maximumStoredBytes
        guard (values.fileSize ?? 0) <= sourceLimit else {
            throw MaterialsError.message(isImage
                ? "这张图片异常大，暂时无法安全处理。"
                : "文件超过 12 MB。")
        }
        let data = try Data(contentsOf: url)
        if ext == "pdf" {
            return try add(data: data, name: url.lastPathComponent, mediaType: "application/pdf")
        } else if ext == "docx" {
            return try add(data: data, name: url.lastPathComponent, mediaType: TaskAttachmentFormat.docxMIME)
        } else if ["txt", "md"].contains(ext) {
            return try add(data: data, name: url.lastPathComponent, mediaType: "text/plain")
        } else {
            return try addImage(data, name: url.deletingPathExtension().lastPathComponent)
        }
    }

    @discardableResult
    func addImage(_ data: Data, name: String = "图片") throws -> PendingAttachment {
        let bytes = try TaskImageAttachmentProcessor.compressedJPEG(from: data)
        return try add(data: bytes, name: name + ".jpg", mediaType: "image/jpeg")
    }

    func remove(_ id: String) {
        // Keep bytes here: an in-flight persist-first submission may reference
        // them. Explicit discard below owns destructive cleanup.
        items.removeAll { $0.id == id }
        do { try persist() } catch { self.error = RuntimeTaskStore.userMessage(for: error) }
    }

    func clearSubmitted(_ ids: Set<String>) {
        items.removeAll { ids.contains($0.id) }
        do { try persist() } catch { self.error = RuntimeTaskStore.userMessage(for: error) }
    }

    func discard(_ ids: Set<String>) {
        let doomed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        for item in doomed {
            if let url = try? item.fileURL() { try? FileManager.default.removeItem(at: url) }
        }
        do { try persist() } catch { self.error = RuntimeTaskStore.userMessage(for: error) }
    }

    /// Persist-first recovery can finish before Home explicitly handles the
    /// successful send. Remove only composer references; keep local bytes so
    /// the accepted user message can still render its thumbnail.
    static func clearAcceptedReferences(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        if let currentInstance {
            currentInstance.clearSubmitted(ids)
            return
        }
        guard let directory = try? PendingAttachment.directory() else { return }
        let url = directory.appendingPathComponent("composer-draft.json")
        guard let data = try? Data(contentsOf: url),
              var persisted = try? JSONDecoder().decode([PendingAttachment].self, from: data)
        else { return }
        let before = persisted.count
        persisted.removeAll { ids.contains($0.id) }
        guard persisted.count != before,
              let encoded = try? JSONEncoder().encode(persisted)
        else { return }
        try? encoded.write(to: url, options: .atomic)
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(items)
        try data.write(to: PendingAttachment.directory().appendingPathComponent("composer-draft.json"), options: .atomic)
    }
}
