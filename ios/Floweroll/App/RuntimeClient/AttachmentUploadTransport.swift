import Foundation


enum AttachmentUploadState: Equatable, Sendable {
    case queued
    case checkingHost
    case uploading(sentBytes: Int64, totalBytes: Int64)
    case reconciling
    case uploaded
    case failed(String)

    var fraction: Double? {
        guard case let .uploading(sent, total) = self, total > 0 else { return nil }
        return min(1, max(0, Double(sent) / Double(total)))
    }

    var productLabel: String {
        switch self {
        case .queued: return "等待上传"
        case .checkingHost: return "正在确认上传状态"
        case .uploading: return "正在上传"
        case .reconciling: return "正在核对服务器"
        case .uploaded: return "已上传"
        case let .failed(message): return message
        }
    }
}


struct AttachmentUploadEvent: Equatable, Sendable {
    let attachmentID: String
    let state: AttachmentUploadState
}


final class AttachmentUploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let attachmentID: String
    private let onEvent: (@Sendable (AttachmentUploadEvent) -> Void)?

    init(
        attachmentID: String,
        onEvent: (@Sendable (AttachmentUploadEvent) -> Void)?
    ) {
        self.attachmentID = attachmentID
        self.onEvent = onEvent
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onEvent?(.init(
            attachmentID: attachmentID,
            state: .uploading(
                sentBytes: totalBytesSent,
                totalBytes: totalBytesExpectedToSend
            )
        ))
    }
}
