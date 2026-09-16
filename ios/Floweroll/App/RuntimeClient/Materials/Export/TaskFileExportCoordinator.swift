import Foundation
import CryptoKit
import ImageIO
import CoreTransferable
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import PDFKit
import QuickLook



@MainActor @Observable
final class TaskFileExportCoordinator {
    var isPresented = false
    private(set) var item: ExportableTaskFile?
    private(set) var isPreparing = false
    private(set) var feedback: TaskFileExportFeedback?

    private let operationStore: TaskFileExportOperationStore?
    private var activeOperationID: String?

    init(operationStore: TaskFileExportOperationStore? = TaskFileExportOperationStore.shared) {
        self.operationStore = operationStore
    }

    var isBusy: Bool { isPreparing || activeOperationID != nil }

    func prepareExport(
        taskID: String,
        sourceArtifactID: String,
        manifest: TaskMaterialManifest,
        client: FlowerollHostClient
    ) async {
        let resolver = TaskMaterialLocalFileResolver { taskID, file in
            try await client.downloadTaskFile(taskID: taskID, file: file)
        }
        await prepareExport(
            taskID: taskID,
            sourceArtifactID: sourceArtifactID,
            manifest: manifest,
            resolver: resolver
        )
    }

    func prepareExport(
        taskID: String,
        sourceArtifactID: String,
        manifest: TaskMaterialManifest,
        resolver: TaskMaterialLocalFileResolver
    ) async {
        guard !isBusy else { return }
        feedback = nil
        guard let file = TaskFileExportPolicy.verifiedOutput(
            sourceArtifactID: sourceArtifactID,
            manifest: manifest
        ) else {
            feedback = .init(kind: .failure, message: TaskFileExportError.missingVerifiedSource.localizedDescription)
            return
        }
        guard let operationStore else {
            feedback = .init(kind: .failure, message: TaskFileExportError.operationStoreUnavailable.localizedDescription)
            return
        }

        isPreparing = true
        defer { isPreparing = false }
        var operationID: String?
        do {
            let operation = try await operationStore.prepare(taskID: taskID, file: file)
            operationID = operation.exportOperationID
            let source = try await resolver.resolve(
                taskID: taskID,
                sourceArtifactID: sourceArtifactID,
                manifest: manifest
            )
            try await operationStore.markVerified(operation.exportOperationID)
            let exportItem = ExportableTaskFile(operationID: operation.exportOperationID, source: source)
            guard exportItem.contentType != nil else { throw TaskFileExportError.unsupportedMediaType }

            try await operationStore.markMayHaveStarted(operation.exportOperationID)
            activeOperationID = operation.exportOperationID
            item = exportItem
            isPresented = true
        } catch {
            if let operationID {
                _ = try? await operationStore.markDefinitelyNotStarted(
                    operationID,
                    errorCode: Self.errorCode(error)
                )
            }
            activeOperationID = nil
            item = nil
            isPresented = false
            feedback = .init(kind: .failure, message: error.localizedDescription)
        }
    }

    func handleCompletion(_ result: Result<URL, Error>) async {
        guard let operationID = activeOperationID, let operationStore else { return }
        isPresented = false
        switch result {
        case .success(let destinationURL):
            do {
                try await operationStore.complete(
                    operationID,
                    destinationFilename: destinationURL.lastPathComponent
                )
                feedback = .init(kind: .success, message: "已保存到文件")
            } catch {
                feedback = .init(kind: .success, message: "已保存到文件，但本次保存记录未能更新。")
            }
        case .failure(let error):
            _ = try? await operationStore.failExplicit(operationID, errorCode: Self.errorCode(error))
            feedback = .init(kind: .failure, message: "没有保存成功，可以重新尝试。")
        }
        clearActiveOperation()
    }

    func handleCancellation() async {
        guard let operationID = activeOperationID, let operationStore else {
            clearActiveOperation()
            return
        }
        _ = try? await operationStore.cancel(operationID)
        feedback = .init(kind: .cancelled, message: "已取消保存")
        clearActiveOperation()
    }

    func loadRecoveredState(taskID: String) async {
        guard !isBusy, let operationStore,
              await operationStore.latestUnknown(taskID: taskID) != nil
        else { return }
        feedback = .init(
            kind: .unknown,
            message: "上次保存结果未能确认，请先到“文件”中检查；再次保存可能产生另一份副本。"
        )
    }

    func reportPreparationFailure(_ error: Error) {
        feedback = .init(kind: .failure, message: error.localizedDescription)
    }

    func clearFeedback() {
        feedback = nil
    }

    private func clearActiveOperation() {
        activeOperationID = nil
        item = nil
        isPresented = false
    }

    private static func errorCode(_ error: Error) -> String {
        if let exportError = error as? TaskFileExportError { return exportError.code }
        if let urlError = error as? URLError { return "url_error_\(urlError.code.rawValue)" }
        return String(reflecting: type(of: error))
    }
}
