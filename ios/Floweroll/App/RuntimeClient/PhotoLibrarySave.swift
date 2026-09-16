import Foundation
import Observation
import Photos
import UniformTypeIdentifiers


enum TaskPhotoSaveError: Error, LocalizedError, Sendable, Equatable {
    case missingVerifiedSource
    case unsupportedMediaType
    case operationStoreUnavailable
    case permissionDenied
    case permissionRestricted
    case unexpectedLimitedAuthorization
    case unknownAuthorization
    case sourceVerificationFailed
    case invalidOperationState

    var errorDescription: String? {
        switch self {
        case .missingVerifiedSource:
            return "这个图片还没有成为已验证的任务成果，暂时不能保存到照片。"
        case .unsupportedMediaType:
            return "目前只支持把 JPEG 或 PNG 任务成果保存到照片。"
        case .operationStoreUnavailable:
            return "暂时无法安全记录这次保存操作，没有开始写入照片。"
        case .permissionDenied:
            return "没有照片添加权限。可以到系统设置允许小卷添加照片后再试。"
        case .permissionRestricted:
            return "这台设备限制了照片添加权限，暂时无法保存。"
        case .unexpectedLimitedAuthorization:
            return "系统返回了不符合“仅添加照片”权限模型的状态，没有扩大权限或继续保存。"
        case .unknownAuthorization:
            return "无法确认照片添加权限，没有开始保存。"
        case .sourceVerificationFailed:
            return "图片在保存前校验失败，没有写入照片。请重新取回后再试。"
        case .invalidOperationState:
            return "这次保存操作状态已经变化，请重新点击“保存到照片”。"
        }
    }

    var code: String {
        switch self {
        case .missingVerifiedSource: return "missing_verified_photo_source"
        case .unsupportedMediaType: return "unsupported_photo_media_type"
        case .operationStoreUnavailable: return "photo_operation_store_unavailable"
        case .permissionDenied: return "photos_add_permission_denied"
        case .permissionRestricted: return "photos_add_permission_restricted"
        case .unexpectedLimitedAuthorization: return "photos_add_permission_unexpected_limited"
        case .unknownAuthorization: return "photos_add_permission_unknown"
        case .sourceVerificationFailed: return "photo_source_verification_failed"
        case .invalidOperationState: return "photo_invalid_operation_state"
        }
    }
}


enum TaskPhotoSavePolicy {
    static let supportedMediaTypes: Set<String> = ["image/jpeg", "image/jpg", "image/png"]

    static func eligibleOutput(
        sourceArtifactID: String,
        manifest: TaskMaterialManifest
    ) -> TaskMaterialFile? {
        guard let file = manifest.outputs.first(where: { $0.id == sourceArtifactID }),
              supportedMediaTypes.contains(file.mediaType.lowercased())
        else { return nil }
        return file
    }

    static func contentType(for mediaType: String) -> UTType? {
        switch mediaType.lowercased() {
        case "image/jpeg", "image/jpg": return .jpeg
        case "image/png": return .png
        default: return nil
        }
    }
}


enum PhotoLibraryAddAuthorization: String, Sendable, Equatable {
    case notDetermined = "not_determined"
    case authorized
    case denied
    case restricted
    case limited
    case unknown

    static func current() -> PhotoLibraryAddAuthorization {
        from(PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    static func from(_ status: PHAuthorizationStatus) -> PhotoLibraryAddAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .limited: return .limited
        @unknown default: return .unknown
        }
    }
}


protocol PhotoLibraryClient: Sendable {
    func authorizationStatus() async -> PhotoLibraryAddAuthorization
    func requestAddOnlyAuthorization() async -> PhotoLibraryAddAuthorization
    func saveImage(source: TaskMaterialExportSource) async throws -> String?
}


private final class PhotoSaveIdentifierBox: @unchecked Sendable {
    var value: String?
}


struct SystemPhotoLibraryClient: PhotoLibraryClient {
    func authorizationStatus() async -> PhotoLibraryAddAuthorization {
        PhotoLibraryAddAuthorization.current()
    }

    func requestAddOnlyAuthorization() async -> PhotoLibraryAddAuthorization {
        PhotoLibraryAddAuthorization.from(
            await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        )
    }

    func saveImage(source: TaskMaterialExportSource) async throws -> String? {
        guard let type = TaskPhotoSavePolicy.contentType(for: source.sourceMediaType) else {
            throw TaskPhotoSaveError.unsupportedMediaType
        }
        let identifier = PhotoSaveIdentifierBox()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            options.originalFilename = source.displayFilename
            options.contentType = type
            request.addResource(with: .photo, fileURL: source.localURL, options: options)
            identifier.value = request.placeholderForCreatedAsset?.localIdentifier
        }
        return identifier.value
    }
}


enum TaskPhotoSaveOperationState: String, Codable, Sendable {
    case prepared = "PREPARED"
    case verified = "VERIFIED"
    case definitelyNotStarted = "DEFINITELY_NOT_STARTED"
    case inFlightMayHaveCommitted = "IN_FLIGHT_MAY_HAVE_COMMITTED"
    case completedSystemWrite = "COMPLETED_SYSTEM_WRITE"
    case definitelyFailed = "DEFINITELY_FAILED"
    case unknownMayHaveCommitted = "UNKNOWN_MAY_HAVE_COMMITTED"

    var isTerminal: Bool {
        switch self {
        case .definitelyNotStarted, .completedSystemWrite, .definitelyFailed, .unknownMayHaveCommitted:
            return true
        case .prepared, .verified, .inFlightMayHaveCommitted:
            return false
        }
    }
}


struct TaskPhotoSaveOperationRecord: Codable, Sendable, Equatable, Identifiable {
    let saveOperationID: String
    let operationKind: String
    let taskID: String
    let sourceArtifactID: String
    let sourceSHA256: String
    let sourceSizeBytes: Int
    let sourceMediaType: String
    let sourceDisplayFilename: String
    var state: TaskPhotoSaveOperationState
    let preparedAt: Date
    var inFlightAt: Date?
    var terminalAt: Date?
    var nativeLocalIdentifier: String?
    var authorizationScope: String?
    var errorCode: String?

    var id: String { saveOperationID }
}


actor TaskPhotoSaveOperationStore {
    static let shared: TaskPhotoSaveOperationStore? = try? TaskPhotoSaveOperationStore()

    private let fileURL: URL
    private var records: [String: TaskPhotoSaveOperationRecord]

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
        fileURL = directory.appendingPathComponent("photos-save-v1.json")

        var loaded: [TaskPhotoSaveOperationRecord] = []
        if let data = try? Data(contentsOf: fileURL), !data.isEmpty {
            loaded = try JSONDecoder().decode([TaskPhotoSaveOperationRecord].self, from: data)
        }
        var changed = false
        for index in loaded.indices where loaded[index].state == .inFlightMayHaveCommitted {
            loaded[index].state = .unknownMayHaveCommitted
            loaded[index].terminalAt = recoveryDate
            loaded[index].errorCode = "photo_callback_missing_after_relaunch"
            changed = true
        }
        records = Dictionary(uniqueKeysWithValues: loaded.map { ($0.saveOperationID, $0) })
        if changed {
            try Self.persist(Array(records.values), to: fileURL)
        }
    }

    func prepare(taskID: String, file: TaskMaterialFile, at date: Date = Date()) throws -> TaskPhotoSaveOperationRecord {
        guard TaskPhotoSavePolicy.supportedMediaTypes.contains(file.mediaType.lowercased()) else {
            throw TaskPhotoSaveError.unsupportedMediaType
        }
        try TaskMaterialExportIntegrity.validateMetadata(file)
        let record = TaskPhotoSaveOperationRecord(
            saveOperationID: UUID().uuidString,
            operationKind: "photos_save",
            taskID: taskID,
            sourceArtifactID: file.id,
            sourceSHA256: file.sha256.lowercased(),
            sourceSizeBytes: file.sizeBytes,
            sourceMediaType: file.mediaType.lowercased(),
            sourceDisplayFilename: TaskFileExportFormat.sanitizedDisplayFilename(file.name, mediaType: file.mediaType),
            state: .prepared,
            preparedAt: date,
            inFlightAt: nil,
            terminalAt: nil,
            nativeLocalIdentifier: nil,
            authorizationScope: nil,
            errorCode: nil
        )
        records[record.saveOperationID] = record
        try persist()
        return record
    }

    @discardableResult
    func markVerified(_ operationID: String) throws -> TaskPhotoSaveOperationRecord {
        try transition(operationID, allowed: [.prepared], to: .verified)
    }

    @discardableResult
    func markDefinitelyNotStarted(
        _ operationID: String,
        authorizationScope: String?,
        errorCode: String,
        at date: Date = Date()
    ) throws -> TaskPhotoSaveOperationRecord {
        try transition(operationID, allowed: [.prepared, .verified], to: .definitelyNotStarted) { record in
            record.authorizationScope = authorizationScope
            record.errorCode = errorCode
            record.terminalAt = date
        }
    }

    @discardableResult
    func markInFlight(
        _ operationID: String,
        authorizationScope: String,
        at date: Date = Date()
    ) throws -> TaskPhotoSaveOperationRecord {
        try transition(operationID, allowed: [.verified], to: .inFlightMayHaveCommitted) { record in
            record.authorizationScope = authorizationScope
            record.inFlightAt = date
        }
    }

    @discardableResult
    func complete(
        _ operationID: String,
        nativeLocalIdentifier: String?,
        at date: Date = Date()
    ) throws -> TaskPhotoSaveOperationRecord {
        try transition(operationID, allowed: [.inFlightMayHaveCommitted], to: .completedSystemWrite) { record in
            record.nativeLocalIdentifier = nativeLocalIdentifier
            record.terminalAt = date
            record.errorCode = nil
        }
    }

    @discardableResult
    func failDefinitely(
        _ operationID: String,
        errorCode: String,
        at date: Date = Date()
    ) throws -> TaskPhotoSaveOperationRecord {
        try transition(operationID, allowed: [.inFlightMayHaveCommitted], to: .definitelyFailed) { record in
            record.errorCode = errorCode
            record.terminalAt = date
        }
    }

    func record(_ operationID: String) -> TaskPhotoSaveOperationRecord? {
        records[operationID]
    }

    func latestUnknown(taskID: String) -> TaskPhotoSaveOperationRecord? {
        records.values
            .filter { $0.taskID == taskID && $0.state == .unknownMayHaveCommitted }
            .sorted { $0.preparedAt > $1.preparedAt }
            .first
    }

    func recordsForTask(_ taskID: String) -> [TaskPhotoSaveOperationRecord] {
        records.values
            .filter { $0.taskID == taskID }
            .sorted { $0.preparedAt < $1.preparedAt }
    }

    private func transition(
        _ operationID: String,
        allowed: Set<TaskPhotoSaveOperationState>,
        to next: TaskPhotoSaveOperationState,
        mutate: (inout TaskPhotoSaveOperationRecord) -> Void = { _ in }
    ) throws -> TaskPhotoSaveOperationRecord {
        guard var record = records[operationID], allowed.contains(record.state) else {
            throw TaskPhotoSaveError.invalidOperationState
        }
        record.state = next
        mutate(&record)
        records[operationID] = record
        try persist()
        return record
    }

    private func persist() throws {
        try Self.persist(Array(records.values), to: fileURL)
    }

    private static func persist(_ records: [TaskPhotoSaveOperationRecord], to url: URL) throws {
        let data = try JSONEncoder().encode(records.sorted { $0.preparedAt < $1.preparedAt })
        try data.write(to: url, options: [.atomic])
    }
}


struct TaskPhotoSaveFeedback: Equatable {
    enum Kind: Equatable { case success, failure, unknown }
    let kind: Kind
    let message: String

    var systemImage: String {
        switch kind {
        case .success: return "checkmark.circle"
        case .failure: return "exclamationmark.triangle"
        case .unknown: return "questionmark.circle"
        }
    }
}


@MainActor
@Observable
final class TaskPhotoSaveCoordinator {
    private(set) var isSaving = false
    private(set) var feedback: TaskPhotoSaveFeedback?

    private let operationStore: TaskPhotoSaveOperationStore?
    private let photoLibrary: any PhotoLibraryClient

    init(
        operationStore: TaskPhotoSaveOperationStore? = TaskPhotoSaveOperationStore.shared,
        photoLibrary: any PhotoLibraryClient = SystemPhotoLibraryClient()
    ) {
        self.operationStore = operationStore
        self.photoLibrary = photoLibrary
    }

    func save(
        taskID: String,
        sourceArtifactID: String,
        manifest: TaskMaterialManifest,
        client: FlowerollHostClient
    ) async {
        let resolver = TaskMaterialLocalFileResolver { taskID, file in
            try await client.downloadTaskFile(taskID: taskID, file: file)
        }
        await save(
            taskID: taskID,
            sourceArtifactID: sourceArtifactID,
            manifest: manifest,
            resolver: resolver
        )
    }

    func save(
        taskID: String,
        sourceArtifactID: String,
        manifest: TaskMaterialManifest,
        resolver: TaskMaterialLocalFileResolver
    ) async {
        guard !isSaving else { return }
        feedback = nil
        guard let file = TaskPhotoSavePolicy.eligibleOutput(
            sourceArtifactID: sourceArtifactID,
            manifest: manifest
        ) else {
            feedback = .init(kind: .failure, message: TaskPhotoSaveError.missingVerifiedSource.localizedDescription)
            return
        }
        guard let operationStore else {
            feedback = .init(kind: .failure, message: TaskPhotoSaveError.operationStoreUnavailable.localizedDescription)
            return
        }

        isSaving = true
        defer { isSaving = false }
        var operationID: String?
        do {
            let operation = try await operationStore.prepare(taskID: taskID, file: file)
            operationID = operation.saveOperationID
            let source = try await resolver.resolve(
                taskID: taskID,
                sourceArtifactID: sourceArtifactID,
                manifest: manifest
            )
            try await operationStore.markVerified(operation.saveOperationID)

            var authorization = await photoLibrary.authorizationStatus()
            if authorization == .notDetermined {
                authorization = await photoLibrary.requestAddOnlyAuthorization()
            }
            guard authorization == .authorized else {
                let error = Self.permissionError(authorization)
                _ = try? await operationStore.markDefinitelyNotStarted(
                    operation.saveOperationID,
                    authorizationScope: authorization.rawValue,
                    errorCode: error.code
                )
                feedback = .init(kind: .failure, message: error.localizedDescription)
                return
            }

            do {
                _ = try TaskMaterialExportIntegrity.reverify(source)
            } catch {
                _ = try? await operationStore.markDefinitelyNotStarted(
                    operation.saveOperationID,
                    authorizationScope: authorization.rawValue,
                    errorCode: TaskPhotoSaveError.sourceVerificationFailed.code
                )
                feedback = .init(kind: .failure, message: TaskPhotoSaveError.sourceVerificationFailed.localizedDescription)
                return
            }

            try await operationStore.markInFlight(
                operation.saveOperationID,
                authorizationScope: "add_only"
            )

            let nativeIdentifier: String
            do {
                nativeIdentifier = try await photoLibrary.saveImage(source: source) ?? ""
            } catch {
                _ = try? await operationStore.failDefinitely(
                    operation.saveOperationID,
                    errorCode: Self.errorCode(error)
                )
                feedback = .init(kind: .failure, message: "没有保存到照片，可以再次点击重试。")
                return
            }

            do {
                try await operationStore.complete(
                    operation.saveOperationID,
                    nativeLocalIdentifier: nativeIdentifier.isEmpty ? nil : nativeIdentifier
                )
                feedback = .init(kind: .success, message: "已保存到照片")
            } catch {
                feedback = .init(
                    kind: .unknown,
                    message: "照片已由系统完成保存，但本次保存记录未能确认。请先到“照片”里检查，不要立即重复保存。"
                )
            }
        } catch {
            if let operationID {
                _ = try? await operationStore.markDefinitelyNotStarted(
                    operationID,
                    authorizationScope: nil,
                    errorCode: Self.errorCode(error)
                )
            }
            feedback = .init(kind: .failure, message: error.localizedDescription)
        }
    }

    func loadRecoveredState(taskID: String) async {
        guard !isSaving,
              let operationStore,
              await operationStore.latestUnknown(taskID: taskID) != nil
        else { return }
        feedback = .init(
            kind: .unknown,
            message: "上次“保存到照片”的系统写入结果无法确认。请先到“照片”里检查；再次点击会创建一笔新的保存操作，可能产生重复照片。"
        )
    }

    func clearFeedback() {
        feedback = nil
    }

    private static func permissionError(_ authorization: PhotoLibraryAddAuthorization) -> TaskPhotoSaveError {
        switch authorization {
        case .denied: return .permissionDenied
        case .restricted: return .permissionRestricted
        case .limited: return .unexpectedLimitedAuthorization
        case .notDetermined, .unknown: return .unknownAuthorization
        case .authorized: return .unknownAuthorization
        }
    }

    private static func errorCode(_ error: Error) -> String {
        if let photoError = error as? TaskPhotoSaveError { return photoError.code }
        if let exportError = error as? TaskFileExportError { return exportError.code }
        return String(reflecting: type(of: error))
    }
}
