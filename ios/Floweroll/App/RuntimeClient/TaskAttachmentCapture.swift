import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import SwiftUI
import UIKit
import Vision


enum TaskAttachmentCaptureMode: String, Identifiable {
    case photo
    case document
    var id: String { rawValue }
}


enum TaskAttachmentCaptureLimits {
    static let maximumPhotoCount = TaskAttachmentDraft.maximumItemCount
    static let maximumDocumentPageCount = 10
}


struct TaskAttachmentCaptureSheet: UIViewControllerRepresentable {
    let mode: TaskAttachmentCaptureMode
    let photoCapacity: Int
    let onPhoto: (Data) -> Void
    let onDocumentPDF: (Data) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        makeProductCaptureViewController()
    }

    func makeProductCaptureViewController() -> UIViewController {
        // Keep document capture inside Floweroll's own manual camera UI.
        // VNDocumentCameraViewController intentionally is not used here: its
        // system-owned UI/localization and automatic capture behavior do not
        // match the product contract (Chinese controls + explicit shutter).
        TaskAttachmentCaptureViewController(
            mode: mode,
            photoCapacity: photoCapacity,
            onPhoto: onPhoto,
            onDocumentPDF: onDocumentPDF,
            onError: onError
        )
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}


struct TaskAttachmentPhotoSession {
    static let maximumPhotoCount = TaskAttachmentCaptureLimits.maximumPhotoCount

    let capacity: Int
    private(set) var photos: [Data] = []

    init(maximumPhotoCount: Int = Self.maximumPhotoCount) {
        capacity = min(max(0, maximumPhotoCount), Self.maximumPhotoCount)
    }

    var count: Int { photos.count }
    var isEmpty: Bool { photos.isEmpty }
    var canCaptureMore: Bool { photos.count < capacity }
    var latestPhoto: Data? { photos.last }

    @discardableResult
    mutating func append(_ data: Data?) -> Bool {
        guard let data, !data.isEmpty, canCaptureMore else { return false }
        photos.append(data)
        return true
    }

    @discardableResult
    mutating func deleteLast() -> Data? {
        photos.popLast()
    }

    mutating func cancel() {
        photos.removeAll(keepingCapacity: false)
    }

    @discardableResult
    mutating func finish(deliver: (Data) -> Void) -> Bool {
        guard !photos.isEmpty else { return false }
        let completed = photos
        photos.removeAll(keepingCapacity: false)
        completed.forEach(deliver)
        return true
    }
}


struct DocumentRectangleCorners: Equatable {
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomLeft: CGPoint
    let bottomRight: CGPoint

    init(_ observation: VNRectangleObservation) {
        topLeft = observation.topLeft
        topRight = observation.topRight
        bottomLeft = observation.bottomLeft
        bottomRight = observation.bottomRight
    }

    init(topLeft: CGPoint, topRight: CGPoint, bottomLeft: CGPoint, bottomRight: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    var isPlausibleDocument: Bool {
        let points = [topLeft, topRight, bottomRight, bottomLeft]
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max()
        else { return false }

        let width = maxX - minX
        let height = maxY - minY
        let center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let closedPoints = Array(points.dropFirst()) + [points[0]]
        let polygonArea = abs(zip(points, closedPoints).reduce(CGFloat.zero) { partial, pair in
            partial + ((pair.0.x * pair.1.y) - (pair.1.x * pair.0.y))
        }) / 2

        return width >= 0.34
            && height >= 0.34
            && polygonArea >= 0.17
            && (0.25...0.75).contains(center.x)
            && (0.25...0.75).contains(center.y)
    }

    func isGeometricallyClose(to other: DocumentRectangleCorners, tolerance: CGFloat = 0.085) -> Bool {
        let lhs = [topLeft, topRight, bottomLeft, bottomRight]
        let rhs = [other.topLeft, other.topRight, other.bottomLeft, other.bottomRight]
        return zip(lhs, rhs).allSatisfy { a, b in
            hypot(a.x - b.x, a.y - b.y) <= tolerance
        }
    }
}


struct DocumentLiveDetectionState: Equatable {
    enum Phase: Equatable {
        case searching
        case locking
        case detected
    }

    private(set) var phase: Phase = .searching
    private(set) var corners: DocumentRectangleCorners?
    private var hitCount = 0
    private var missCount = 0
    private static let requiredStableHitCount = 4
    private static let toleratedDetectedMissCount = 4

    mutating func ingest(_ candidate: DocumentRectangleCorners?) {
        guard let candidate, candidate.isPlausibleDocument else {
            missCount += 1
            if phase == .detected, missCount < Self.toleratedDetectedMissCount {
                return
            }
            hitCount = 0
            phase = .searching
            corners = nil
            return
        }

        let wasDetected = phase == .detected
        missCount = 0
        if wasDetected, let corners, corners.isGeometricallyClose(to: candidate) {
            self.corners = candidate
            return
        }

        if let corners, corners.isGeometricallyClose(to: candidate) {
            hitCount += 1
        } else {
            hitCount = 1
        }
        corners = candidate
        phase = hitCount >= Self.requiredStableHitCount ? .detected : .locking
    }
}


final class DocumentLiveRectangleDetector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "floweroll.document-live-rectangle", qos: .userInitiated)
    private var lastAnalysisUptime: TimeInterval = 0
    var onRectangle: ((DocumentRectangleCorners?) -> Void)?

    func attach(to output: AVCaptureVideoDataOutput) {
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAnalysisUptime >= 0.22 else { return }
        lastAnalysisUptime = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            onRectangle?(nil)
            return
        }

        let rectangle = Self.bestRectangle(in: pixelBuffer).map(DocumentRectangleCorners.init)
        onRectangle?(rectangle)
    }

    private static func bestRectangle(in pixelBuffer: CVPixelBuffer) -> VNRectangleObservation? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 6
        rectangles.minimumConfidence = 0.34
        rectangles.minimumSize = 0.12
        rectangles.quadratureTolerance = 50
        if (try? handler.perform([rectangles])) != nil,
           let best = rectangles.results?.max(by: { lhs, rhs in
               lhs.boundingBox.width * lhs.boundingBox.height < rhs.boundingBox.width * rhs.boundingBox.height
           }) {
            return best
        }

        // The cheap quadrilateral detector normally wins. Document segmentation
        // is a fallback for pale paper/background combinations that still have a
        // real page boundary but weak edge contrast.
        let document = VNDetectDocumentSegmentationRequest()
        let segmentationHandler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .right,
            options: [:]
        )
        guard (try? segmentationHandler.perform([document])) != nil else { return nil }
        return document.results?.first
    }
}


final class TaskAttachmentCaptureViewController: UIViewController, @preconcurrency AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let mode: TaskAttachmentCaptureMode
    private let onPhoto: (Data) -> Void
    private let onDocumentPDF: (Data) -> Void
    private let onError: (String) -> Void

    private let captureSession = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let documentRectangleDetector = DocumentLiveRectangleDetector()
    private let sessionQueue = DispatchQueue(label: "floweroll.attachment-camera.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var scannedPages: [Data] = []
    private var photoSession: TaskAttachmentPhotoSession
    private var isCaptureInFlight = false
    private var hasEndedSession = false
    private var requestedPhotoDimensions: CMVideoDimensions?

    private let shutterButton = UIButton(type: .custom)
    private let pageLabel = UILabel()
    private let latestPageView = UIImageView()
    private let documentGuideView = UIView()
    private let scanStatusLabel = UILabel()
    private var documentDetectionState = DocumentLiveDetectionState()
    private var lastDocumentAdjustmentMessage: String?
    private let doneButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let hintLabel = UILabel()

    init(
        mode: TaskAttachmentCaptureMode,
        photoCapacity: Int = TaskAttachmentDraft.maximumItemCount,
        onPhoto: @escaping (Data) -> Void,
        onDocumentPDF: @escaping (Data) -> Void,
        onError: @escaping (String) -> Void
    ) {
        self.mode = mode
        self.photoSession = TaskAttachmentPhotoSession(maximumPhotoCount: photoCapacity)
        self.onPhoto = onPhoto
        self.onDocumentPDF = onDocumentPDF
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        documentRectangleDetector.onRectangle = { [weak self] corners in
            DispatchQueue.main.async {
                self?.handleLiveDocumentRectangle(corners)
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureOverlay()
        prepareCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [captureSession] in
            if captureSession.isRunning { captureSession.stopRunning() }
        }
    }

    private func prepareCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureCameraSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted { self.configureCameraSession() }
                else { self.failAndDismiss("没有相机权限。可以到系统设置允许相机后再试。") }
            }
        default:
            failAndDismiss("没有相机权限。可以到系统设置允许相机后再试。")
        }
    }

    private func configureCameraSession() {
        let captureMode = mode
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .photo
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: camera),
                  self.captureSession.canAddInput(input),
                  self.captureSession.canAddOutput(self.photoOutput)
            else {
                self.captureSession.commitConfiguration()
                self.failAndDismiss("暂时无法启动相机，请关闭其他正在使用相机的 App 后重试。")
                return
            }
            self.captureSession.addInput(input)
            self.captureSession.addOutput(self.photoOutput)
            if captureMode == .document, self.captureSession.canAddOutput(self.videoOutput) {
                self.captureSession.addOutput(self.videoOutput)
                self.documentRectangleDetector.attach(to: self.videoOutput)
            }
            if let dimensions = Self.preferredPhotoDimensions(
                mode: captureMode,
                supported: camera.activeFormat.supportedMaxPhotoDimensions
            ) {
                self.photoOutput.maxPhotoDimensions = dimensions
                self.requestedPhotoDimensions = dimensions
            }
            // AVCaptureSession forbids startRunning while a configuration
            // transaction is open. Commit first; physical iPhone enforces this
            // with NSGenericException even though Simulator cannot exercise it.
            self.captureSession.commitConfiguration()
            DispatchQueue.main.async { [weak self] in self?.installPreview() }
            self.captureSession.startRunning()
        }
    }

    private func installPreview() {
        guard previewLayer == nil else { return }
        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
    }

    nonisolated private static func preferredPhotoDimensions(
        mode: TaskAttachmentCaptureMode,
        supported: [CMVideoDimensions]
    ) -> CMVideoDimensions? {
        guard !supported.isEmpty else { return nil }
        if mode == .document {
            return supported.max { lhs, rhs in
                Int64(lhs.width) * Int64(lhs.height) < Int64(rhs.width) * Int64(rhs.height)
            }
        }

        // Ordinary camera sessions retain several compressed captures in memory
        // until the user taps Done. Keep the per-shot request around 12 MP when
        // the active format offers it, while preserving a deterministic fallback
        // to the smallest supported dimensions on unusual hardware.
        let ordinaryPixelBudget: Int64 = 13_000_000
        let bounded = supported.filter {
            Int64($0.width) * Int64($0.height) <= ordinaryPixelBudget
        }
        if bounded.isEmpty {
            return supported.min { lhs, rhs in
                Int64(lhs.width) * Int64(lhs.height) < Int64(rhs.width) * Int64(rhs.height)
            }
        }
        return bounded.max { lhs, rhs in
            Int64(lhs.width) * Int64(lhs.height) < Int64(rhs.width) * Int64(rhs.height)
        }
    }

    private func configureOverlay() {
        let cancel = UIButton(type: .system)
        cancel.setTitle("取消", for: .normal)
        cancel.setTitleColor(.white, for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancel.accessibilityIdentifier = "attachment.capture.cancel"
        cancel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancel)

        let title = UILabel()
        title.text = mode == .photo ? "拍照" : "扫描文档"
        title.textColor = .white
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(title)

        hintLabel.text = mode == .photo ? "可连续拍摄，最后点完成" : "将整张纸放入取景框 · 拍摄后自动裁边、拉直并增强"
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.82)
        hintLabel.font = .systemFont(ofSize: 13, weight: .medium)
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 2
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hintLabel)

        if mode == .document {
            scanStatusLabel.text = "把整张纸放进框内"
            scanStatusLabel.textColor = .white
            scanStatusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            scanStatusLabel.textAlignment = .center
            scanStatusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.46)
            scanStatusLabel.layer.cornerRadius = 12
            scanStatusLabel.layer.masksToBounds = true
            scanStatusLabel.layer.zPosition = 20
            scanStatusLabel.accessibilityIdentifier = "attachment.scan.live-status"
            scanStatusLabel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(scanStatusLabel)

            documentGuideView.isUserInteractionEnabled = false
            documentGuideView.layer.cornerRadius = 14
            documentGuideView.layer.borderWidth = 1.5
            documentGuideView.layer.borderColor = UIColor.white.withAlphaComponent(0.58).cgColor
            documentGuideView.backgroundColor = .clear
            documentGuideView.accessibilityIdentifier = "attachment.scan.document-guide"
            documentGuideView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(documentGuideView)
        }

        shutterButton.backgroundColor = .white
        shutterButton.layer.cornerRadius = 35
        shutterButton.layer.borderWidth = 5
        shutterButton.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
        shutterButton.addTarget(self, action: #selector(shutterTapped), for: .touchUpInside)
        shutterButton.accessibilityIdentifier = "attachment.capture.shutter"
        shutterButton.accessibilityLabel = mode == .photo ? "拍摄照片" : "拍摄扫描页"
        shutterButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shutterButton)

        pageLabel.textColor = .white
        pageLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        pageLabel.textAlignment = .center
        pageLabel.accessibilityIdentifier = "attachment.capture.page-count"
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageLabel)

        latestPageView.contentMode = .scaleAspectFill
        latestPageView.clipsToBounds = true
        latestPageView.accessibilityIdentifier = "attachment.capture.latest-preview"
        latestPageView.layer.cornerRadius = 8
        latestPageView.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        latestPageView.layer.borderWidth = 1
        latestPageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(latestPageView)

        doneButton.setTitle("完成", for: .normal)
        doneButton.setTitleColor(.white, for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .bold)
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        doneButton.accessibilityIdentifier = "attachment.capture.done"
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(doneButton)

        deleteButton.setTitle("删除上一页", for: .normal)
        deleteButton.setTitleColor(.white, for: .normal)
        deleteButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        deleteButton.accessibilityIdentifier = "attachment.capture.delete-page"
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(deleteButton)

        NSLayoutConstraint.activate([
            cancel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: cancel.centerYAnchor),
            hintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            hintLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            shutterButton.widthAnchor.constraint(equalToConstant: 70),
            shutterButton.heightAnchor.constraint(equalToConstant: 70),
            shutterButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutterButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
            latestPageView.widthAnchor.constraint(equalToConstant: 56),
            latestPageView.heightAnchor.constraint(equalToConstant: 72),
            latestPageView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            latestPageView.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),
            pageLabel.leadingAnchor.constraint(equalTo: latestPageView.leadingAnchor),
            pageLabel.trailingAnchor.constraint(equalTo: latestPageView.trailingAnchor),
            pageLabel.bottomAnchor.constraint(equalTo: latestPageView.topAnchor, constant: -5),
            doneButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -22),
            doneButton.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),
            deleteButton.centerXAnchor.constraint(equalTo: latestPageView.centerXAnchor),
            deleteButton.topAnchor.constraint(equalTo: latestPageView.bottomAnchor, constant: 4),
        ])
        if mode == .document {
            NSLayoutConstraint.activate([
                scanStatusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                scanStatusLabel.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 10),
                scanStatusLabel.heightAnchor.constraint(equalToConstant: 32),
                scanStatusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 170),
                documentGuideView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
                documentGuideView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
                documentGuideView.topAnchor.constraint(equalTo: scanStatusLabel.bottomAnchor, constant: 12),
                documentGuideView.bottomAnchor.constraint(equalTo: shutterButton.topAnchor, constant: -24),
            ])
        }
        updateCaptureControls()
    }

    private func updateCaptureControls() {
        let scanning = mode == .document
        let count = scanning ? scannedPages.count : photoSession.count
        let hasCaptures = count > 0
        let canCaptureMore = scanning
            ? scannedPages.count < TaskAttachmentCaptureLimits.maximumDocumentPageCount
            : photoSession.canCaptureMore

        latestPageView.isHidden = !hasCaptures
        if scanning, let last = scannedPages.last {
            latestPageView.image = UIImage(data: last)
        } else if let last = photoSession.latestPhoto {
            latestPageView.image = UIImage(data: last)
        } else {
            latestPageView.image = nil
        }

        pageLabel.isHidden = false
        pageLabel.text = scanning ? "已扫描 \(count) 页" : "已拍 \(count) 张"
        doneButton.isHidden = false
        doneButton.isEnabled = hasCaptures && !isCaptureInFlight && !hasEndedSession
        doneButton.alpha = doneButton.isEnabled ? 1 : 0.45
        deleteButton.isHidden = !hasCaptures
        deleteButton.isEnabled = hasCaptures && !isCaptureInFlight && !hasEndedSession
        deleteButton.setTitle(scanning ? "删除上一页" : "删除上一张", for: .normal)
        deleteButton.accessibilityIdentifier = scanning
            ? "attachment.capture.delete-page"
            : "attachment.capture.delete-photo"

        shutterButton.isEnabled = canCaptureMore && !isCaptureInFlight && !hasEndedSession
        shutterButton.alpha = shutterButton.isEnabled ? 1 : 0.55
        if scanning {
            if scannedPages.count >= TaskAttachmentCaptureLimits.maximumDocumentPageCount {
                hintLabel.text = "已扫描满 \(TaskAttachmentCaptureLimits.maximumDocumentPageCount) 页，可完成或删除上一页"
            } else if let lastDocumentAdjustmentMessage, hasCaptures {
                hintLabel.text = lastDocumentAdjustmentMessage + " · 继续对准下一页"
            } else {
                hintLabel.text = "将整张纸放入取景框 · 拍摄后自动裁边、拉直并增强"
            }
            updateDocumentDetectionPresentation()
        } else {
            hintLabel.text = photoSession.canCaptureMore
                ? "可连续拍摄，最多 \(photoSession.capacity) 张，最后点完成"
                : "已拍满 \(photoSession.capacity) 张，可完成或删除上一张"
        }
    }


    private func handleLiveDocumentRectangle(_ corners: DocumentRectangleCorners?) {
        guard mode == .document, !hasEndedSession else { return }
        let wasDetected = documentDetectionState.phase == .detected
        documentDetectionState.ingest(corners)
        if !wasDetected, documentDetectionState.phase == .detected {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        updateDocumentDetectionPresentation()
    }

    private func updateDocumentDetectionPresentation() {
        guard mode == .document else { return }

        if scannedPages.count >= TaskAttachmentCaptureLimits.maximumDocumentPageCount {
            scanStatusLabel.text = "已扫描满 10 页"
            scanStatusLabel.textColor = .white
            scanStatusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.58)
            shutterButton.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
            return
        }
        if isCaptureInFlight {
            scanStatusLabel.text = "正在拍摄并自动拉直…"
            scanStatusLabel.textColor = .white
            scanStatusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.58)
            return
        }

        switch documentDetectionState.phase {
        case .searching:
            scanStatusLabel.text = "把整张纸放进框内"
            scanStatusLabel.textColor = .white
            scanStatusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.46)
            documentGuideView.layer.borderColor = UIColor.white.withAlphaComponent(0.58).cgColor
            shutterButton.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
            shutterButton.accessibilityValue = "尚未稳定识别纸张"
        case .locking:
            scanStatusLabel.text = "正在识别纸张…"
            scanStatusLabel.textColor = UIColor.systemYellow
            scanStatusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.52)
            documentGuideView.layer.borderColor = UIColor.systemYellow.withAlphaComponent(0.58).cgColor
            shutterButton.layer.borderColor = UIColor.systemYellow.withAlphaComponent(0.82).cgColor
            shutterButton.accessibilityValue = "正在稳定识别纸张"
        case .detected:
            scanStatusLabel.text = "已识别纸张 · 可拍摄，拍后自动拉直四角"
            scanStatusLabel.textColor = UIColor.systemGreen
            scanStatusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.58)
            documentGuideView.layer.borderColor = UIColor.systemGreen.withAlphaComponent(0.58).cgColor
            shutterButton.layer.borderColor = UIColor.systemGreen.cgColor
            shutterButton.accessibilityValue = "已稳定识别纸张，可以拍摄"
        }
    }

    @objc private func cancelTapped() {
        guard !hasEndedSession else { return }
        hasEndedSession = true
        photoSession.cancel()
        dismiss(animated: true)
    }

    @objc private func shutterTapped() {
        guard !hasEndedSession, !isCaptureInFlight else { return }
        if mode == .photo, !photoSession.canCaptureMore {
            updateCaptureControls()
            return
        }
        if mode == .document, scannedPages.count >= TaskAttachmentCaptureLimits.maximumDocumentPageCount {
            updateCaptureControls()
            return
        }
        isCaptureInFlight = true
        updateCaptureControls()
        let settings = AVCapturePhotoSettings()
        // AVCapturePhotoOutput defaults to a maximum prioritization of
        // .balanced. Requesting .quality without opting the output into that
        // level throws NSInvalidArgumentException on physical iPhone. Balanced
        // keeps manual capture responsive and deterministic for both ordinary
        // photos and document pages.
        settings.photoQualityPrioritization = .balanced
        if let requestedPhotoDimensions {
            settings.maxPhotoDimensions = requestedPhotoDimensions
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    @objc private func deleteTapped() {
        guard !isCaptureInFlight, !hasEndedSession else { return }
        if mode == .photo {
            photoSession.deleteLast()
        } else {
            guard !scannedPages.isEmpty else { return }
            scannedPages.removeLast()
            if scannedPages.isEmpty { lastDocumentAdjustmentMessage = nil }
        }
        updateCaptureControls()
    }

    @objc private func doneTapped() {
        guard !isCaptureInFlight, !hasEndedSession else { return }
        if mode == .photo {
            guard !photoSession.isEmpty else {
                updateCaptureControls()
                return
            }
            hasEndedSession = true
            _ = photoSession.finish(deliver: onPhoto)
            dismiss(animated: true)
            return
        }
        guard !scannedPages.isEmpty else { return }
        do {
            let pdf = try DocumentScanProcessor.pdfData(pages: scannedPages)
            hasEndedSession = true
            onDocumentPDF(pdf)
            dismiss(animated: true)
        } catch {
            onError("生成扫描 PDF 失败，请重新拍摄。")
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if error != nil {
            captureFailed("照片拍摄失败，请再试一次。")
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            captureFailed("没有取得照片数据，请再试一次。")
            return
        }
        if mode == .photo {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.hasEndedSession else { return }
                self.isCaptureInFlight = false
                if !self.photoSession.append(data) {
                    self.onError("这次拍照没有保存，请再试一次。")
                }
                self.updateCaptureControls()
            }
            return
        }
        do {
            let processed = try DocumentScanProcessor.processPageResult(data)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.hasEndedSession else { return }
                self.isCaptureInFlight = false
                self.scannedPages.append(processed.data)
                self.lastDocumentAdjustmentMessage = processed.wasPerspectiveCorrected
                    ? "上一页已自动裁边、拉正并增强"
                    : "上一页未完成边缘校正；建议等上方显示“已识别纸张”后重拍"
                self.updateCaptureControls()
            }
        } catch {
            captureFailed("没有正确处理这一页，请重新拍摄。")
        }
    }

    private func captureFailed(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.hasEndedSession else { return }
            self.isCaptureInFlight = false
            self.updateCaptureControls()
            self.onError(message)
        }
    }

    private func failAndDismiss(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onError(message)
            self.dismiss(animated: true)
        }
    }
}


enum DocumentScanProcessor {
    struct PageResult: Equatable, Sendable {
        let data: Data
        let wasPerspectiveCorrected: Bool
    }

    static let maximumPageJPEGBytes = 900 * 1024

    static func processPage(_ data: Data) throws -> Data {
        try processPageResult(data).data
    }

    static func processPageResult(_ data: Data) throws -> PageResult {
        guard let raw = UIImage(data: data) else { throw MaterialsError.message("无法读取照片。") }
        let maxDimension: CGFloat = 2_600
        let scale = min(1, maxDimension / max(raw.size.width, raw.size.height))
        let targetSize = CGSize(width: raw.size.width * scale, height: raw.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: targetSize))
            raw.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let cgImage = image.cgImage else { throw MaterialsError.message("无法处理照片。") }

        let rectangle = try bestDocumentRectangle(in: cgImage)

        var ciImage = CIImage(cgImage: cgImage)
        var corrected = false
        if let rectangle {
            let w = ciImage.extent.width
            let h = ciImage.extent.height
            let filter = CIFilter.perspectiveCorrection()
            filter.inputImage = ciImage
            filter.topLeft = CGPoint(x: rectangle.topLeft.x * w, y: rectangle.topLeft.y * h)
            filter.topRight = CGPoint(x: rectangle.topRight.x * w, y: rectangle.topRight.y * h)
            filter.bottomLeft = CGPoint(x: rectangle.bottomLeft.x * w, y: rectangle.bottomLeft.y * h)
            filter.bottomRight = CGPoint(x: rectangle.bottomRight.x * w, y: rectangle.bottomRight.y * h)
            if let output = filter.outputImage, !output.extent.isEmpty {
                ciImage = output
                corrected = true
            }
        }

        // Document mode intentionally looks different from ordinary camera:
        // brighten paper, increase text separation and sharpen luminance while
        // retaining enough colour for stamps/highlights.
        let controls = CIFilter.colorControls()
        controls.inputImage = ciImage
        controls.contrast = corrected ? 1.20 : 1.15
        controls.brightness = corrected ? 0.045 : 0.03
        controls.saturation = 0.90
        if let output = controls.outputImage { ciImage = output }

        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = ciImage
        sharpen.sharpness = corrected ? 0.48 : 0.38
        if let output = sharpen.outputImage { ciImage = output }

        let context = CIContext(options: [.cacheIntermediates: false])
        guard let result = context.createCGImage(ciImage, from: ciImage.extent.integral) else {
            throw MaterialsError.message("无法生成校正后的扫描页。")
        }
        let jpeg = try TaskImageAttachmentProcessor.compressedJPEG(
            from: UIImage(cgImage: result),
            maxBytes: maximumPageJPEGBytes,
            maxPixelDimension: 2_400
        )
        return PageResult(data: jpeg, wasPerspectiveCorrected: corrected)
    }


    private static func bestDocumentRectangle(in cgImage: CGImage) throws -> VNRectangleObservation? {
        let document = VNDetectDocumentSegmentationRequest()
        let documentHandler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
        if (try? documentHandler.perform([document])) != nil, let page = document.results?.first {
            return page
        }

        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 8
        rectangles.minimumConfidence = 0.28
        rectangles.minimumSize = 0.10
        rectangles.quadratureTolerance = 55
        try VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([rectangles])
        return rectangles.results?.max(by: { lhs, rhs in
            lhs.boundingBox.width * lhs.boundingBox.height < rhs.boundingBox.width * rhs.boundingBox.height
        })
    }

    static func pdfData(pages: [Data]) throws -> Data {
        guard !pages.isEmpty else { throw MaterialsError.message("还没有扫描任何页面。") }
        guard pages.count <= TaskAttachmentCaptureLimits.maximumDocumentPageCount else {
            throw MaterialsError.message("扫描文档一次最多 10 页。")
        }
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let pdf = renderer.pdfData { context in
            for data in pages {
                guard let image = UIImage(data: data) else { continue }
                context.beginPage()
                let scale = min(pageRect.width / image.size.width, pageRect.height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let rect = CGRect(
                    x: (pageRect.width - size.width) / 2,
                    y: (pageRect.height - size.height) / 2,
                    width: size.width,
                    height: size.height
                )
                image.draw(in: rect)
            }
        }
        guard pdf.count <= TaskImageAttachmentProcessor.maximumStoredBytes else {
            throw MaterialsError.message("扫描页太多或内容过于复杂，请减少页数后再试。")
        }
        return pdf
    }
}
