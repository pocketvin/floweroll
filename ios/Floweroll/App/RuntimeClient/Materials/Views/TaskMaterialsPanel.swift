import Foundation
import CryptoKit
import ImageIO
import CoreTransferable
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import PDFKit
import QuickLook


struct TaskMaterialsPanel: View {
    let taskID: String
    let store: RuntimeTaskStore
    let revision: String
    @Environment(\.flowerollThemePalette) private var themePalette
    @State private var manifest: TaskMaterialManifest?
    @State private var expanded = true
    @State private var showInputs = false
    @State private var showAllOutputs = false
    @State private var error: String?
    @State private var isOpeningFile = false
    @State private var previewItem: TaskMaterialPreviewItem?
    @State private var fileExport = TaskFileExportCoordinator()
    @State private var photoSave = TaskPhotoSaveCoordinator()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let manifest, !manifest.inputs.isEmpty || !manifest.presentedOutputs.isEmpty || manifest.plan != nil {
                VStack(alignment: .leading, spacing: 12) {
                    Button { withAnimation { expanded.toggle() } } label: {
                        HStack {
                            Image(systemName: "square.stack.3d.up")
                            Text(manifest.plan?.title ?? "资料与成果").font(.subheadline.weight(.semibold))
                            Spacer()
                            if let work = manifest.workSummary, work.hasVerifiedCounts {
                                Text("已完成 \(work.completed)/\(work.total) 项")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            } else {
                                Text("\(primaryOutputs(manifest).count) 份文件").font(.caption).foregroundStyle(.secondary)
                            }
                            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                        }
                    }.buttonStyle(.plain)
                    if expanded {
                        if let work = manifest.workSummary, !work.items.isEmpty {
                            if let fraction = work.fraction {
                                ProgressView(value: fraction)
                                    .accessibilityLabel("任务完成进度")
                                    .accessibilityValue("已完成 \(work.completed) 项，共 \(work.total) 项")
                            }
                            ForEach(work.items) { item in
                                workItemRow(item)
                            }
                        } else if let plan = manifest.plan {
                            ForEach(plan.items) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "circle").foregroundStyle(.secondary)
                                    Text(item.title).font(.caption)
                                    Spacer()
                                    Text("等待状态同步").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        let outputs = primaryOutputs(manifest)
                        if !outputs.isEmpty {
                            Text(manifest.hasProgressiveDelivery ? "文件交付 · \(outputs.count)" : "任务产物 · \(outputs.count)")
                                .font(.caption.weight(.semibold))
                                .padding(.top, 4)
                        }
                        if let progressive = manifest.progressiveOutputs, !progressive.isEmpty {
                            let stillProcessing = progressive.contains { $0.progress?.status == "processing" }
                            Label(
                                stillProcessing
                                    ? "文件已经可以打开、分享或保存；文字识别仍在继续。"
                                    : "文件已经可以打开、分享或保存；文字识别结果仍需核对。",
                                systemImage: stillProcessing ? "doc.badge.clock" : "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("task-progressive-file-availability")
                        }
                        ForEach(showAllOutputs ? outputs : Array(outputs.prefix(3))) { file in
                            fileRow(
                                file,
                                isOutput: true,
                                manifest: manifest,
                                exportFile: TaskFileExportPolicy.verifiedOutput(
                                    sourceArtifactID: file.id,
                                    manifest: manifest
                                ),
                                photoFile: TaskPhotoSavePolicy.eligibleOutput(
                                    sourceArtifactID: file.id,
                                    manifest: manifest
                                )
                            )
                        }
                        if outputs.count > 3 {
                            Button(showAllOutputs ? "收起其余成果" : "查看其余 \(outputs.count - 3) 份成果") {
                                withAnimation { showAllOutputs.toggle() }
                            }.font(.caption)
                        }
                        let alternate = manifest.outputs.filter { $0.mediaType == "text/markdown" }
                        if !alternate.isEmpty {
                            DisclosureGroup("其他文件格式") {
                                ForEach(alternate) { file in
                                    fileRow(
                                        file,
                                        isOutput: true,
                                        manifest: manifest,
                                        exportFile: TaskFileExportPolicy.verifiedOutput(
                                            sourceArtifactID: file.id,
                                            manifest: manifest
                                        ),
                                        photoFile: TaskPhotoSavePolicy.eligibleOutput(
                                            sourceArtifactID: file.id,
                                            manifest: manifest
                                        )
                                    )
                                }
                            }.font(.caption)
                        }
                        if !manifest.inputs.isEmpty {
                            DisclosureGroup("原始附件 · \(manifest.inputs.count)", isExpanded: $showInputs) {
                                ForEach(manifest.inputs) { file in
                                    fileRow(file, isOutput: false, manifest: manifest, exportFile: nil, photoFile: nil)
                                }
                            }.font(.caption)
                        }
                        if isOpeningFile { ProgressView("正在打开文件…").font(.caption) }
                        if fileExport.isPreparing { ProgressView("正在准备文件…").font(.caption) }
                        if let feedback = fileExport.feedback {
                            Label(feedback.message, systemImage: feedback.systemImage)
                                .font(.caption)
                                .foregroundStyle(feedback.kind == .failure ? Color.orange : Color.secondary)
                                .accessibilityIdentifier("task-file-export-feedback")
                        }
                        if photoSave.isSaving { ProgressView("正在保存到照片…").font(.caption) }
                        if let feedback = photoSave.feedback {
                            Label(feedback.message, systemImage: feedback.systemImage)
                                .font(.caption)
                                .foregroundStyle(feedback.kind == .failure ? Color.orange : Color.secondary)
                                .accessibilityIdentifier("task-photo-save-feedback")
                        }
                        if let error {
                            HStack {
                                Text(error).font(.caption).foregroundStyle(.orange)
                                Button("重试") { Task { await reload() } }.font(.caption)
                            }
                        }
                    }
                }
                .padding(14)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("task-materials-panel")
            }
        }
        .task(id: taskID + ":" + revision) { await reloadWithProgressiveWindow() }
        .task(id: "file-export-recovery:" + taskID) { await fileExport.loadRecoveredState(taskID: taskID) }
        .task(id: "photo-save-recovery:" + taskID) { await photoSave.loadRecoveredState(taskID: taskID) }
        .fileExporter(
            isPresented: Binding(
                get: { fileExport.isPresented },
                set: { fileExport.isPresented = $0 }
            ),
            item: fileExport.item,
            contentTypes: fileExport.item?.contentType.map { [$0] } ?? [],
            defaultFilename: fileExport.item?.source.displayFilename,
            onCompletion: { result in
                Task { @MainActor in await fileExport.handleCompletion(result) }
            },
            onCancellation: {
                Task { @MainActor in await fileExport.handleCancellation() }
            }
        )
        .alert(
            "保存到文件",
            isPresented: Binding(
                get: { fileExport.feedback != nil },
                set: { if !$0 { fileExport.clearFeedback() } }
            )
        ) {
            Button("知道了", role: .cancel) { fileExport.clearFeedback() }
        } message: {
            Text(fileExport.feedback?.message ?? "")
        }
        .alert(
            "保存到照片",
            isPresented: Binding(
                get: { photoSave.feedback != nil },
                set: { if !$0 { photoSave.clearFeedback() } }
            )
        ) {
            Button("知道了", role: .cancel) { photoSave.clearFeedback() }
        } message: {
            Text(photoSave.feedback?.message ?? "")
        }
        .sheet(item: $previewItem) { item in
            NavigationStack {
                TaskMaterialQuickLook(url: item.url)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle(item.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            ShareLink(item: item.url, subject: Text(item.name)) {
                                Label("分享/保存", systemImage: "square.and.arrow.up")
                            }
                            .accessibilityIdentifier("task-file-share")
                            Button("关闭") { previewItem = nil }
                        }
                    }
            }
            .presentationDragIndicator(.visible)
        }
    }

    private func workItemRow(_ item: HostWorkSummary.Item) -> some View {
        let color: Color = item.state == "completed" ? .green
            : ["waiting_approval", "needs_input", "needs_review", "handoff_required", "failed"].contains(item.state) ? .orange
            : item.state == "running" ? themePalette.accent : .secondary
        let symbol = item.state == "completed" ? "checkmark.circle.fill"
            : item.state == "running" ? "arrow.trianglehead.2.clockwise.rotate.90"
            : ["waiting_approval", "needs_input", "needs_review", "handoff_required"].contains(item.state) ? "exclamationmark.circle"
            : item.state == "failed" ? "arrow.clockwise.circle"
            : item.state == "blocked" ? "clock" : item.state == "cancelled" ? "minus.circle" : "circle"
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title).font(.subheadline.weight(.medium))
                    Spacer(minLength: 6)
                    Text(item.label).font(.caption).foregroundStyle(color)
                }
                if let reason = item.reason, !reason.isEmpty {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                if let summary = item.resultSummary, !summary.isEmpty {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                if !item.missingInformation.isEmpty {
                    Text("还需要：" + item.missingInformation.joined(separator: "、"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("work-item-" + item.id)
    }

    private func fileRow(
        _ file: TaskMaterialFile,
        isOutput: Bool,
        manifest: TaskMaterialManifest,
        exportFile: TaskMaterialFile?,
        photoFile: TaskMaterialFile?
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                guard !isOpeningFile else { return }
                if let localURL = file.verifiedLocalInputURL {
                    previewItem = TaskMaterialPreviewItem(url: localURL, name: file.name)
                    error = nil
                    return
                }
                isOpeningFile = true
                Task { @MainActor in
                    defer { isOpeningFile = false }
                    do {
                        let url = try await store.makeClient().downloadTaskFile(taskID: taskID, file: file)
                        previewItem = TaskMaterialPreviewItem(url: url, name: file.name)
                        error = nil
                    } catch {
                        if !Task.isCancelled { self.error = error.localizedDescription }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: TaskAttachmentFormat.iconName(for: file.mediaType))
                        .font(.title3).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.name).font(.subheadline.weight(.medium)).lineLimit(2)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.sizeBytes), countStyle: .file)
                             + " · " + (isOutput ? file.userFacingDeliveryStatus : "原件保留"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text("预览").font(.caption).foregroundStyle(.tint)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .disabled(isOpeningFile)
            .accessibilityIdentifier("task-file-" + file.id)

            if let exportFile {
                Button {
                    startFileExport(exportFile, manifest: manifest)
                } label: {
                    Label("保存到文件", systemImage: "folder.badge.plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(fileExport.isBusy || photoSave.isSaving)
                .accessibilityIdentifier("task-file-export-" + exportFile.id)
            }

            if let photoFile {
                Button {
                    startPhotoSave(photoFile, manifest: manifest)
                } label: {
                    Label("存照片", systemImage: "photo.badge.plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(photoSave.isSaving || fileExport.isBusy)
                .accessibilityIdentifier("task-photo-save-" + photoFile.id)
            }
        }
    }

    private func startFileExport(_ file: TaskMaterialFile, manifest: TaskMaterialManifest) {
        Task { @MainActor in
            do {
                let client = try store.makeClient()
                await fileExport.prepareExport(
                    taskID: taskID,
                    sourceArtifactID: file.id,
                    manifest: manifest,
                    client: client
                )
            } catch {
                fileExport.reportPreparationFailure(error)
            }
        }
    }

    private func startPhotoSave(_ file: TaskMaterialFile, manifest: TaskMaterialManifest) {
        Task { @MainActor in
            do {
                let client = try store.makeClient()
                await photoSave.save(
                    taskID: taskID,
                    sourceArtifactID: file.id,
                    manifest: manifest,
                    client: client
                )
            } catch {
                // The Host client is only needed to retrieve the already-verified bytes.
                // No PhotoKit mutation starts when that prerequisite is unavailable.
                photoSave.clearFeedback()
                self.error = RuntimeTaskStore.userMessage(for: error)
            }
        }
    }

    private func primaryOutputs(_ manifest: TaskMaterialManifest) -> [TaskMaterialFile] {
        let presented = manifest.presentedOutputs
        let htmlActions = Set(presented.filter { $0.mediaType == "text/html" }
            .map { string($0.metadata["action_id"]) })
        return presented.filter {
            $0.mediaType != "text/markdown" || !htmlActions.contains(string($0.metadata["action_id"]))
        }
    }

    private func string(_ value: JSONValue?) -> String {
        if case .string(let text) = value { return text }
        return ""
    }
    @MainActor private func reloadWithProgressiveWindow() async {
        for delayMilliseconds in TaskMaterialProgressiveRefreshPolicy.delayMilliseconds {
            if delayMilliseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: delayMilliseconds * 1_000_000)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await reload()
            guard TaskMaterialProgressiveRefreshPolicy.shouldContinue(after: manifest) else { return }
        }
    }

    @MainActor private func reload() async {
        do {
            let value = try await store.makeClient().fetchTaskMaterials(taskID: taskID)
            guard !Task.isCancelled else { return }
            manifest = value; error = nil
        } catch {
            if !Task.isCancelled, (error as? URLError)?.code != .cancelled {
                self.error = "暂未取到任务附件"
            }
        }
    }
}

private struct TaskMaterialPreviewItem: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
}

private struct TaskMaterialQuickLook: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
