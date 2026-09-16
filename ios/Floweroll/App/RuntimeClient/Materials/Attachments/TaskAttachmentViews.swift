import Foundation
import CryptoKit
import ImageIO
import CoreTransferable
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import PDFKit
import QuickLook


struct AttachmentThumbnailView: View {
    let url: URL?
    let mediaType: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.09))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: TaskAttachmentFormat.iconName(for: mediaType))
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: url?.path) {
            guard let url else { image = nil; return }
            if mediaType.hasPrefix("image/") {
                image = UIImage(contentsOfFile: url.path)
            } else if mediaType == "application/pdf",
                      let document = PDFDocument(url: url),
                      let page = document.page(at: 0) {
                image = page.thumbnail(of: CGSize(width: 160, height: 210), for: .cropBox)
            } else {
                image = nil
            }
        }
    }
}


struct TaskAttachmentBar: View {
    @Bindable var draft: TaskAttachmentDraft
    let states: [String: AttachmentUploadState]
    let disabled: Bool
    let onRemove: (PendingAttachment) -> Void

    init(
        draft: TaskAttachmentDraft,
        states: [String: AttachmentUploadState],
        disabled: Bool,
        onRemove: @escaping (PendingAttachment) -> Void = { _ in }
    ) {
        self.draft = draft
        self.states = states
        self.disabled = disabled
        self.onRemove = onRemove
    }

    var body: some View {
        HStack(spacing: 8) {
            if draft.isLoading {
                ProgressView().controlSize(.small).accessibilityLabel("正在添加附件")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(draft.items) { item in
                        if item.mediaType.hasPrefix("image/") {
                            imageCard(item)
                        } else {
                            fileCard(item)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.6)
        }
        .accessibilityIdentifier("task-attachment-draft-tray")
    }

    private func imageCard(_ item: PendingAttachment) -> some View {
        let state = states[item.id]
        return VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topTrailing) {
                AttachmentThumbnailView(
                    url: try? item.fileURL(),
                    mediaType: item.mediaType
                )
                .frame(width: 108, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    if let state {
                        Text(shortStatus(state))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(6)
                    }
                }

                Button {
                    onRemove(item)
                    draft.remove(item.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 24, height: 24)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .padding(5)
                .accessibilityLabel("移除\(item.name)")
            }

            if let fraction = state?.fraction {
                ProgressView(value: fraction)
                    .frame(width: 108)
                    .accessibilityLabel("附件上传进度")
            } else if state == nil {
                Text(ByteCountFormatter.string(
                    fromByteCount: Int64(item.sizeBytes), countStyle: .file
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            } else if case .failed(let message) = state {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(width: 108, alignment: .leading)
            }
        }
        .frame(width: 108, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func fileCard(_ item: PendingAttachment) -> some View {
        let state = states[item.id]
        return HStack(spacing: 9) {
            AttachmentThumbnailView(
                url: try? item.fileURL(),
                mediaType: item.mediaType
            )
            .frame(width: 50, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                if let fraction = state?.fraction {
                    ProgressView(value: fraction).frame(width: 92)
                }
                Text(state.map(shortStatus) ?? ByteCountFormatter.string(
                    fromByteCount: Int64(item.sizeBytes), countStyle: .file
                ))
                .font(.caption2)
                .foregroundStyle(stateColor(state))
                .lineLimit(2)
            }
            .frame(width: 105, alignment: .leading)

            Button {
                onRemove(item)
                draft.remove(item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .accessibilityLabel("移除\(item.name)")
        }
        .padding(7)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func shortStatus(_ state: AttachmentUploadState) -> String {
        switch state {
        case .queued: return "等待"
        case .checkingHost: return "核对中"
        case .uploading: return "上传中"
        case .reconciling: return "确认中"
        case .uploaded: return "已上传"
        case .failed: return "上传失败"
        }
    }

    private func stateColor(_ state: AttachmentUploadState?) -> Color {
        guard let state else { return .secondary }
        switch state {
        case .failed: return .orange
        case .uploaded: return .green
        default: return .secondary
        }
    }
}


struct TaskAttachmentMenuButton: View {
    @Bindable var draft: TaskAttachmentDraft
    let disabled: Bool
    let onAttachmentReady: (PendingAttachment) -> Void
    @Environment(\.flowerollThemePalette) private var themePalette

    init(
        draft: TaskAttachmentDraft,
        disabled: Bool,
        onAttachmentReady: @escaping (PendingAttachment) -> Void = { _ in }
    ) {
        self.draft = draft
        self.disabled = disabled
        self.onAttachmentReady = onAttachmentReady
    }

    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var captureMode: TaskAttachmentCaptureMode?

    var body: some View {
        Menu {
            Button { showPhotos = true } label: {
                Label("从照片选择", systemImage: "photo.on.rectangle")
            }
            Button { captureMode = .photo } label: {
                Label("拍照", systemImage: "camera")
            }
            Button { captureMode = .document } label: {
                Label("扫描文档", systemImage: "doc.viewfinder")
            }
            Button { showFiles = true } label: {
                Label("从文件选择", systemImage: "folder")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(themePalette.accent)
                .frame(width: 38, height: 38)
                .background(themePalette.accent.opacity(0.10), in: Circle())
                .contentShape(Circle())
        }
        .disabled(disabled || draft.isLoading || draft.isFull)
        .accessibilityIdentifier("task-attachment-menu")
        .accessibilityLabel("添加附件")
        .accessibilityHint("添加照片、拍照、扫描文档或选择文件")
        .photosPicker(
            isPresented: $showPhotos,
            selection: $selectedPhotos,
            maxSelectionCount: draft.photoPickerSelectionLimit,
            matching: .images
        )
        .fileImporter(
            isPresented: $showFiles,
            allowedContentTypes: TaskAttachmentFormat.allowedFileImportTypes,
            allowsMultipleSelection: true
        ) { result in
            do {
                for url in try result.get() {
                    onAttachmentReady(try draft.importFile(url))
                }
            } catch {
                draft.error = RuntimeTaskStore.userMessage(for: error)
            }
        }
        .fullScreenCover(item: $captureMode) { mode in
            TaskAttachmentCaptureSheet(
                mode: mode,
                photoCapacity: mode == .photo
                    ? draft.ordinaryCameraCaptureCapacity
                    : TaskAttachmentDraft.maximumItemCount,
                onPhoto: { bytes in
                    do { onAttachmentReady(try draft.addImage(bytes, name: "拍摄照片")) }
                    catch { draft.error = RuntimeTaskStore.userMessage(for: error) }
                },
                onDocumentPDF: { pdf in
                    do {
                        onAttachmentReady(try draft.add(
                            data: pdf,
                            name: "扫描文档-\(Self.scanTimestamp()).pdf",
                            mediaType: "application/pdf"
                        ))
                    } catch { draft.error = RuntimeTaskStore.userMessage(for: error) }
                },
                onError: { draft.error = $0 }
            )
            .ignoresSafeArea()
        }
        .onChange(of: selectedPhotos) { _, photos in
            guard !photos.isEmpty else { return }
            draft.isLoading = true
            Task { @MainActor in
                defer { draft.isLoading = false; selectedPhotos = [] }
                do {
                    for photo in photos {
                        if let bytes = try await photo.loadTransferable(type: Data.self) {
                            onAttachmentReady(try draft.addImage(bytes, name: "照片-\(draft.items.count + 1)"))
                        }
                    }
                } catch {
                    draft.error = RuntimeTaskStore.userMessage(for: error)
                }
            }
        }
        .alert(
            "附件未添加",
            isPresented: Binding(
                get: { draft.error != nil },
                set: { if !$0 { draft.error = nil } }
            )
        ) {
            Button("好") { draft.error = nil }
        } message: {
            Text(draft.error ?? "")
        }
    }

    private static func scanTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}


struct TaskMessageAttachmentStrip: View {
    let files: [TaskMaterialFile]

    private let maximumLaneWidth: CGFloat = 300
    private let cardSpacing: CGFloat = 8

    private var estimatedCardsWidth: CGFloat {
        let cards = files.reduce(CGFloat.zero) { partial, file in
            partial + (file.mediaType.hasPrefix("image/") ? 128 : 94)
        }
        return cards + CGFloat(max(0, files.count - 1)) * cardSpacing
    }

    var body: some View {
        if !files.isEmpty {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 0) {
                    if estimatedCardsWidth <= maximumLaneWidth {
                        HStack(alignment: .top, spacing: cardSpacing) {
                            ForEach(files) { file in
                                attachmentCard(file)
                            }
                        }
                        .frame(maxWidth: maximumLaneWidth, alignment: .trailing)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: cardSpacing) {
                                ForEach(files) { file in
                                    attachmentCard(file)
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .frame(width: maximumLaneWidth, alignment: .trailing)
                        .defaultScrollAnchor(.trailing)
                    }
                }
                .frame(maxWidth: maximumLaneWidth, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityIdentifier("task-message-attachments")
        }
    }

    @ViewBuilder
    private func attachmentCard(_ file: TaskMaterialFile) -> some View {
        if file.mediaType.hasPrefix("image/") {
            VStack(alignment: .leading, spacing: 5) {
                AttachmentThumbnailView(
                    url: file.localInputURL,
                    mediaType: file.mediaType
                )
                .frame(width: 116, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(file.name)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 116, alignment: .leading)
            }
            .padding(6)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(file.name)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                AttachmentThumbnailView(
                    url: file.localInputURL,
                    mediaType: file.mediaType
                )
                .frame(width: 82, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(file.name)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .frame(width: 82, alignment: .leading)
            }
            .padding(6)
            .background(
                .quaternary.opacity(0.55),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
        }
    }
}
