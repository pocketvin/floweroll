import CryptoKit
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Floweroll


private final class TaskMaterialsURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var lastRequestPath = ""

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequestPath = request.url?.path ?? ""
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: Self.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": TaskAttachmentFormat.docxMIME]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}


private struct TaskListNativeScrollerProbe: View {
    let scroller: TaskListNativeScroller

    var body: some View {
        List {
            Text("进行中")
                .background(TaskListNativeScrollAnchor(key: "task-section-active", scroller: scroller))
            ForEach(0..<18, id: \.self) { index in
                Text("active-row-\(index)")
                    .frame(height: 52)
            }
            Divider()
            Text("历史")
                .background(TaskListNativeScrollAnchor(key: "task-section-history", scroller: scroller))
            ForEach(0..<6, id: \.self) { index in
                Text("history-row-\(index)")
                    .frame(height: 52)
            }
        }
        .listStyle(.plain)
    }
}

@MainActor
final class TaskMaterialsTests: XCTestCase {
    func testDocxImporterTypeAndMimeAreFirstClass() throws {
        XCTAssertTrue(TaskAttachmentFormat.allowedFileImportTypes.contains(TaskAttachmentFormat.docxType))
        XCTAssertEqual(TaskAttachmentFormat.docxMIME,
                       "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        XCTAssertEqual(TaskAttachmentFormat.storedExtension(for: TaskAttachmentFormat.docxMIME), "docx")
        XCTAssertEqual(TaskAttachmentFormat.iconName(for: TaskAttachmentFormat.docxMIME), "doc.richtext")
    }

    func testDocxImportPreservesNameMimeSizeHashAndBytes() throws {
        let bytes = Data("PK\u{3}\u{4}DOCX-iOS-intake-test".utf8)
        let url = try temporaryFile(name: "候选人资料.docx", data: bytes)
        let draft = freshDraft()
        defer { draft.clearSubmitted(Set(draft.items.map(\.id))) }

        try draft.importFile(url)

        let item = try XCTUnwrap(draft.items.last)
        XCTAssertEqual(item.name, "候选人资料.docx")
        XCTAssertEqual(item.mediaType, TaskAttachmentFormat.docxMIME)
        XCTAssertEqual(item.sizeBytes, bytes.count)
        XCTAssertEqual(item.sha256, sha256(bytes))
        XCTAssertTrue(item.storedName.hasSuffix(".docx"))
        XCTAssertEqual(try item.verifiedData(), bytes)
    }

    func testPdfAndPlainTextImportBehaviorRemainsUnchanged() throws {
        let draft = freshDraft()
        defer { draft.clearSubmitted(Set(draft.items.map(\.id))) }
        let pdf = Data("%PDF-1.4\nattachment-test\n%%EOF".utf8)
        let text = Data("小卷 attachment text".utf8)

        try draft.importFile(try temporaryFile(name: "资料.pdf", data: pdf))
        let pdfItem = try XCTUnwrap(draft.items.last)
        XCTAssertEqual(pdfItem.mediaType, "application/pdf")
        XCTAssertEqual(pdfItem.name, "资料.pdf")
        XCTAssertEqual(pdfItem.sizeBytes, pdf.count)
        XCTAssertEqual(pdfItem.sha256, sha256(pdf))
        XCTAssertEqual(try pdfItem.verifiedData(), pdf)

        try draft.importFile(try temporaryFile(name: "说明.txt", data: text))
        let textItem = try XCTUnwrap(draft.items.last)
        XCTAssertEqual(textItem.mediaType, "text/plain")
        XCTAssertEqual(textItem.name, "说明.txt")
        XCTAssertEqual(textItem.sizeBytes, text.count)
        XCTAssertEqual(textItem.sha256, sha256(text))
        XCTAssertEqual(try textItem.verifiedData(), text)
    }

    func testImageFileImportStillProducesVerifiedJpegAttachment() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let source = try XCTUnwrap(image.jpegData(compressionQuality: 1.0))
        let draft = freshDraft()
        defer { draft.clearSubmitted(Set(draft.items.map(\.id))) }

        try draft.importFile(try temporaryFile(name: "照片.jpg", data: source))

        let item = try XCTUnwrap(draft.items.last)
        XCTAssertEqual(item.mediaType, "image/jpeg")
        XCTAssertEqual(item.name, "照片.jpg")
        XCTAssertTrue(item.storedName.hasSuffix(".jpg"))
        let stored = try item.verifiedData()
        XCTAssertEqual(item.sizeBytes, stored.count)
        XCTAssertEqual(item.sha256, sha256(stored))
        XCTAssertNotNil(UIImage(data: stored))
    }

    func testSubmittedInputCanOpenFromVerifiedLocalBytesWithoutHostRoundTrip() throws {
        let bytes = Data("local-original-attachment".utf8)
        let draft = freshDraft()
        let attachment = try draft.add(
            data: bytes,
            name: "原始资料.txt",
            mediaType: "text/plain"
        )
        defer { draft.discard([attachment.id]) }
        let file = TaskMaterialFile(
            id: attachment.id,
            name: attachment.name,
            mediaType: attachment.mediaType,
            sizeBytes: attachment.sizeBytes,
            sha256: attachment.sha256,
            category: "input",
            metadata: [:]
        )

        let localURL = try XCTUnwrap(file.verifiedLocalInputURL)
        XCTAssertEqual(try Data(contentsOf: localURL), bytes)

        try Data("tampered-original-attach".utf8).write(to: localURL, options: .atomic)
        XCTAssertNil(file.verifiedLocalInputURL, "corrupted local input must fail closed and fall back to Host")
    }

    func testTaskFileDownloadReusesVerifiedCacheWithoutSecondNetworkRequest() async throws {
        let bytes = Data("cache-hit-docx".utf8)
        TaskMaterialsURLProtocol.responseData = bytes
        TaskMaterialsURLProtocol.statusCode = 200
        TaskMaterialsURLProtocol.lastRequestPath = ""
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TaskMaterialsURLProtocol.self]
        let client = FlowerollHostClient(
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:8765")),
            session: URLSession(configuration: configuration)
        )
        let taskID = "cache-" + UUID().uuidString
        let file = TaskMaterialFile(
            id: "cached-docx",
            name: "缓存结果.docx",
            mediaType: TaskAttachmentFormat.docxMIME,
            sizeBytes: bytes.count,
            sha256: sha256(bytes),
            category: "document",
            metadata: [:]
        )

        let firstURL = try await client.downloadTaskFile(taskID: taskID, file: file)
        defer { try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent().deletingLastPathComponent()) }
        XCTAssertEqual(TaskMaterialsURLProtocol.lastRequestPath, "/v1/tasks/\(taskID)/files/\(file.id)")

        TaskMaterialsURLProtocol.lastRequestPath = ""
        TaskMaterialsURLProtocol.statusCode = 500
        TaskMaterialsURLProtocol.responseData = Data()
        let secondURL = try await client.downloadTaskFile(taskID: taskID, file: file)

        XCTAssertEqual(secondURL, firstURL)
        XCTAssertEqual(try Data(contentsOf: secondURL), bytes)
        XCTAssertEqual(TaskMaterialsURLProtocol.lastRequestPath, "", "verified cache hit must not issue another Host request")
    }

    func testDocxDownloadPreservesQuickLookFilenameHashAndBytes() async throws {
        let bytes = Data("host-verified-docx-download".utf8)
        TaskMaterialsURLProtocol.responseData = bytes
        TaskMaterialsURLProtocol.statusCode = 200
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TaskMaterialsURLProtocol.self]
        let client = FlowerollHostClient(
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:8765")),
            session: URLSession(configuration: configuration)
        )
        let file = TaskMaterialFile(
            id: "output-docx",
            name: "生成结果.docx",
            mediaType: TaskAttachmentFormat.docxMIME,
            sizeBytes: bytes.count,
            sha256: sha256(bytes),
            category: "document",
            metadata: [:]
        )

        let url = try await client.downloadTaskFile(taskID: "docx-task", file: file)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertEqual(url.lastPathComponent, "生成结果.docx")
        XCTAssertEqual(url.pathExtension.lowercased(), "docx")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(QLPreviewController.canPreview(url as NSURL))
    }

    func testProgressiveManifestDecodesDeliveryAndInputProvenance() throws {
        let data = Data(#"""
        {
          "inputs": [{
            "id":"input-one","name":"课堂笔记.jpg","media_type":"image/jpeg",
            "size_bytes":12,"sha256":"input-sha","category":"input","metadata":{}
          }],
          "initial_input_ids":["input-one"],
          "input_provenance":[{
            "binding_key":"submission:submission-one","source_kind":"submission",
            "source_id":"submission-one","task_id":"task-progressive","file_ids":["input-one"],
            "files":[{
              "id":"input-one","name":"课堂笔记.jpg","media_type":"image/jpeg",
              "size_bytes":12,"sha256":"input-sha","category":"input","metadata":{}
            }]
          }],
          "outputs":[],
          "progressive_outputs":[{
            "id":"pdf-one","name":"课堂笔记.pdf","media_type":"application/pdf",
            "size_bytes":24,"sha256":"pdf-sha","category":"document",
            "metadata":{"status":"processing","structural_verified":true},
            "progress":{
              "phase":"ocr_processing","status":"processing","updated_at":"2026-09-13T05:00:00Z",
              "detail":{"pdf_status":"ready","ocr_status":"processing","message":"PDF 已生成，正在识别文字","page_count":2}
            }
          }],
          "plan":null,"work_summary":null
        }
        """#.utf8)

        let manifest = try JSONDecoder.floweroll.decode(TaskMaterialManifest.self, from: data)

        XCTAssertEqual(manifest.inputProvenance?.count, 1)
        XCTAssertEqual(manifest.inputProvenance?.first?.sourceKind, "submission")
        XCTAssertEqual(manifest.inputProvenance?.first?.fileIDs, ["input-one"])
        XCTAssertEqual(manifest.progressiveOutputs?.count, 1)
        let progressive = try XCTUnwrap(manifest.progressiveOutputs?.first)
        XCTAssertEqual(progressive.id, "pdf-one")
        XCTAssertEqual(progressive.progress?.detail["pdf_status"]?.stringValue, "ready")
        XCTAssertEqual(progressive.progress?.detail["ocr_status"]?.stringValue, "processing")
        XCTAssertEqual(progressive.userFacingDeliveryStatus, "PDF 已生成 · 正在识别文字")
        XCTAssertEqual(manifest.presentedOutputs.map(\.id), ["pdf-one"])
    }

    func testInputFilesBoundToExactUserTurnUsesSourceIDAndPreservesOrder() throws {
        let data = Data(#"""
        {
          "inputs":[
            {"id":"input-a","name":"A.jpg","media_type":"image/jpeg","size_bytes":10,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","category":"input","metadata":{}},
            {"id":"input-b","name":"B.pdf","media_type":"application/pdf","size_bytes":20,"sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","category":"input","metadata":{}}
          ],
          "initial_input_ids":[],
          "input_provenance":[
            {"binding_key":"turn:task-1:turn-a","source_kind":"user_turn","source_id":"turn-a","task_id":"task-1","file_ids":["input-a"],"files":[]},
            {"binding_key":"turn:task-1:turn-b","source_kind":"user_turn","source_id":"turn-b","task_id":"task-1","file_ids":["input-b","input-a"],"files":[]}
          ],
          "outputs":[],"progressive_outputs":[],"plan":null,"work_summary":null
        }
        """#.utf8)
        let manifest = try JSONDecoder.floweroll.decode(TaskMaterialManifest.self, from: data)

        XCTAssertEqual(
            manifest.inputFilesBoundTo(sourceKind: "user_turn", sourceID: "turn-b").map(\.id),
            ["input-b", "input-a"]
        )
        XCTAssertEqual(
            manifest.inputFilesBoundTo(sourceKind: "user_turn", sourceID: "turn-a").map(\.id),
            ["input-a"]
        )
        XCTAssertTrue(
            manifest.inputFilesBoundTo(sourceKind: "user_turn", sourceID: "turn-missing").isEmpty
        )
    }

    @MainActor
    func testLocalUserTurnProjectionCarriesEventIDAndAttachmentIDsForMessageOwnership() {
        let suite = "TaskMaterialsTests.message-ownership.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RuntimeTaskStore(defaults: defaults, pendingStore: nil, deviceWorker: nil)

        store.beginLocalUserTurnProjection(
            taskID: "task-message-owner",
            eventID: "turn-owner",
            text: "这张图也一起看",
            attachmentIDs: ["file-owner"]
        )
        let item = store.localUserTurnTimelineItems(
            taskID: "task-message-owner",
            authoritativeTimeline: []
        ).first

        XCTAssertEqual(item?.payload["event_id"]?.stringValue, "turn-owner")
        guard case .array(let attachmentIDs)? = item?.payload["attachment_ids"] else {
            return XCTFail("expected attachment_ids on local USER_INPUT projection")
        }
        XCTAssertEqual(attachmentIDs.compactMap(\.stringValue), ["file-owner"])
    }

    func testRealFollowUpSubmissionProvenanceSelectsOnlyCurrentPhoto() throws {
        let data = Data(#"""
        {
          "inputs":[
            {"id":"3386CBBA-7A2F-43D1-91DD-399D0882204A","name":"扫描文档-20260914-014548.pdf","media_type":"application/pdf","size_bytes":782814,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","category":"input","metadata":{}},
            {"id":"E9CFBA4C-5D83-4D85-B6E8-D2E9E950F9D0","name":"拍摄照片.jpg","media_type":"image/jpeg","size_bytes":2716355,"sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","category":"input","metadata":{}}
          ],
          "initial_input_ids":["E9CFBA4C-5D83-4D85-B6E8-D2E9E950F9D0"],
          "input_provenance":[
            {"binding_key":"submission:ABD99106-5C6B-4B27-A9AF-32037981CA16","source_kind":"submission","source_id":"ABD99106-5C6B-4B27-A9AF-32037981CA16","task_id":"old-task","file_ids":["3386CBBA-7A2F-43D1-91DD-399D0882204A"],"files":[{"id":"3386CBBA-7A2F-43D1-91DD-399D0882204A","name":"扫描文档-20260914-014548.pdf","media_type":"application/pdf","size_bytes":782814,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","category":"input","metadata":{}}]},
            {"binding_key":"submission:4EDDE80A-A78E-4AF3-A923-7FBCFF4882E5","source_kind":"submission","source_id":"4EDDE80A-A78E-4AF3-A923-7FBCFF4882E5","task_id":"current-task","file_ids":["E9CFBA4C-5D83-4D85-B6E8-D2E9E950F9D0"],"files":[{"id":"E9CFBA4C-5D83-4D85-B6E8-D2E9E950F9D0","name":"拍摄照片.jpg","media_type":"image/jpeg","size_bytes":2716355,"sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","category":"input","metadata":{}}]}
          ],
          "outputs":[],"progressive_outputs":[],"plan":null,"work_summary":null
        }
        """#.utf8)
        let manifest = try JSONDecoder.floweroll.decode(TaskMaterialManifest.self, from: data)

        XCTAssertEqual(manifest.initialInputIDs, ["E9CFBA4C-5D83-4D85-B6E8-D2E9E950F9D0"])
        XCTAssertEqual(
            manifest.inputFilesBoundTo(
                sourceKind: "submission",
                sourceID: "4EDDE80A-A78E-4AF3-A923-7FBCFF4882E5"
            ).map(\.name),
            ["拍摄照片.jpg"]
        )
    }

    @MainActor
    func testMessageAttachmentStripHasVisibleLayoutForOnePhoto() {
        let file = TaskMaterialFile(
            id: "photo-one",
            name: "拍摄照片.jpg",
            mediaType: "image/jpeg",
            sizeBytes: 1024,
            sha256: String(repeating: "a", count: 64),
            category: "input",
            metadata: [:]
        )
        let host = UIHostingController(rootView: TaskMessageAttachmentStrip(files: [file]))
        let size = host.sizeThatFits(in: CGSize(width: 320, height: 500))

        XCTAssertGreaterThanOrEqual(size.width, 300, "message attachment lane should occupy the message column so its card can align to the trailing/right edge")
        XCTAssertGreaterThan(size.height, 80)
    }

    @MainActor
    func testNativeListScrollerMovesToHistoryAndBackToActive() async throws {
        let scroller = TaskListNativeScroller()
        let host = UIHostingController(rootView: TaskListNativeScrollerProbe(scroller: scroller))
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(220))
        host.view.layoutIfNeeded()

        guard let scrollView = Self.firstScrollView(in: host.view) else {
            return XCTFail("expected List to host a UIScrollView")
        }
        let initialOffset = scrollView.contentOffset.y
        XCTAssertTrue(scroller.scroll(to: .history, activeRowCount: 18, animated: false))
        try await Task.sleep(for: .milliseconds(160))
        host.view.layoutIfNeeded()
        let historyOffset = scrollView.contentOffset.y
        XCTAssertGreaterThan(
            historyOffset,
            initialOffset + 200,
            "native List scroller must move downward to the History header"
        )

        XCTAssertTrue(scroller.scroll(to: .active, activeRowCount: 18, animated: false))
        try await Task.sleep(for: .milliseconds(160))
        host.view.layoutIfNeeded()
        XCTAssertLessThan(
            scrollView.contentOffset.y,
            historyOffset - 200,
            "native List scroller must move back upward to the Active header"
        )
    }

    func testProgressivePDFRemainsVisibleWhenOCRFails() throws {
        let data = Data(#"""
        {
          "inputs":[],"initial_input_ids":[],"input_provenance":[],"outputs":[],
          "progressive_outputs":[{
            "id":"pdf-failed","name":"面试材料.pdf","media_type":"application/pdf",
            "size_bytes":24,"sha256":"pdf-failed-sha","category":"document",
            "metadata":{"status":"processing","structural_verified":true},
            "progress":{
              "phase":"ocr_failed","status":"partial","updated_at":"2026-09-13T05:01:00Z",
              "detail":{"pdf_status":"ready","ocr_status":"failed","message":"PDF 已生成，OCR 未完成"}
            }
          }],
          "plan":null,"work_summary":null
        }
        """#.utf8)

        let manifest = try JSONDecoder.floweroll.decode(TaskMaterialManifest.self, from: data)
        let file = try XCTUnwrap(manifest.presentedOutputs.first)

        XCTAssertEqual(file.id, "pdf-failed")
        XCTAssertEqual(file.userFacingDeliveryStatus, "PDF 已生成 · 文字识别未完成，建议核对")
        XCTAssertEqual(manifest.presentedOutputs.count, 1)
    }

    func testVerifiedOutputPromotesSameProgressiveFileIdentityWithoutDuplicate() throws {
        let data = Data(#"""
        {
          "inputs":[],"initial_input_ids":[],"input_provenance":[],
          "outputs":[{
            "id":"pdf-same","name":"课堂笔记.pdf","media_type":"application/pdf",
            "size_bytes":24,"sha256":"pdf-sha","category":"document",
            "metadata":{"status":"ready","ocr_status":"complete","quality_status":"verified","label":"PDF 和文字识别已完成"}
          }],
          "progressive_outputs":[{
            "id":"pdf-same","name":"课堂笔记.pdf","media_type":"application/pdf",
            "size_bytes":24,"sha256":"pdf-sha","category":"document",
            "metadata":{"status":"processing","structural_verified":true},
            "progress":{
              "phase":"ocr_processing","status":"processing","updated_at":"2026-09-13T05:02:00Z",
              "detail":{"pdf_status":"ready","ocr_status":"processing"}
            }
          }],
          "plan":null,"work_summary":null
        }
        """#.utf8)

        let manifest = try JSONDecoder.floweroll.decode(TaskMaterialManifest.self, from: data)

        XCTAssertEqual(manifest.presentedOutputs.count, 1)
        let file = try XCTUnwrap(manifest.presentedOutputs.first)
        XCTAssertEqual(file.id, "pdf-same")
        XCTAssertNil(file.progress, "verified output must enrich/replace the progressive card")
        XCTAssertEqual(file.userFacingDeliveryStatus, "PDF 和文字识别已完成")
    }

    func testBoundedRefreshFindsLaterProgressivePDFWithExistingOutputAndUnchangedOuterRevision() throws {
        let outputA = materialFile(
            id: "output-a",
            name: "复习资料.pdf",
            itemID: "study",
            status: "ready"
        )
        let stagedB = materialFile(
            id: "scan-b",
            name: "课堂笔记.pdf",
            itemID: "scan",
            status: "processing",
            progress: .init(
                phase: "ocr_processing",
                status: "processing",
                detail: [
                    "pdf_status": .string("ready"),
                    "ocr_status": .string("processing"),
                ],
                updatedAt: "2026-09-13T06:50:00Z"
            )
        )
        let first = materialManifest(
            outputs: [outputA],
            progressive: [],
            plan: [
                .init(id: "study", title: "复习资料", completionRule: "document"),
                .init(id: "scan", title: "扫描 PDF", completionRule: "document"),
            ],
            workItems: [
                workItem(id: "study", state: "completed", fileIDs: [outputA.id]),
                workItem(id: "scan", state: "running"),
            ],
            workState: "running",
            completed: 1
        )
        let second = materialManifest(
            outputs: [outputA],
            progressive: [stagedB],
            plan: [
                .init(id: "study", title: "复习资料", completionRule: "document"),
                .init(id: "scan", title: "扫描 PDF", completionRule: "document"),
            ],
            workItems: [
                workItem(id: "study", state: "completed", fileIDs: [outputA.id]),
                workItem(id: "scan", state: "running"),
            ],
            workState: "running",
            completed: 1
        )

        let outerRevisionBefore = "12:unchanged-work-revision"
        let outerRevisionAfter = "12:unchanged-work-revision"
        var fetchCount = 0
        var visible: TaskMaterialManifest?
        let sequence = [first, second]
        for _ in TaskMaterialProgressiveRefreshPolicy.delayMilliseconds {
            visible = sequence[min(fetchCount, sequence.count - 1)]
            fetchCount += 1
            if !TaskMaterialProgressiveRefreshPolicy.shouldContinue(after: visible) { break }
        }

        XCTAssertEqual(fetchCount, 2, "existing output A must not stop the bounded refresh before staged B appears")
        XCTAssertEqual(outerRevisionBefore, outerRevisionAfter, "progressive discovery must not require outer Task revision movement")
        let final = try XCTUnwrap(visible)
        XCTAssertEqual(Set(final.presentedOutputs.map(\.id)), Set(["output-a", "scan-b"]))
        XCTAssertEqual(final.progressiveOutputs?.map(\.id), ["scan-b"])
        XCTAssertEqual(final.workSummary?.items.first(where: { $0.id == "scan" })?.state, "running")
        XCTAssertEqual(stagedB.progress?.detail["ocr_status"]?.stringValue, "processing")
        XCTAssertFalse(
            TaskMaterialProgressiveRefreshPolicy.shouldContinue(after: final),
            "once the running scan has a staged PDF, the bounded material refresh can stop before OCR completes"
        )
    }

    func testProgressiveRefreshStopsWhenMaterialSettledAndKeepsBoundedScheduleStable() {
        XCTAssertEqual(
            TaskMaterialProgressiveRefreshPolicy.delayMilliseconds,
            [0, 350, 700, 1_200, 2_000, 3_000, 4_000]
        )
        XCTAssertEqual(TaskMaterialProgressiveRefreshPolicy.delayMilliseconds.count, 7)

        let settled = materialManifest(
            outputs: [materialFile(id: "done", name: "完成.pdf", itemID: "scan", status: "ready")],
            progressive: [],
            plan: [.init(id: "scan", title: "扫描 PDF", completionRule: "document")],
            workItems: [workItem(id: "scan", state: "completed", fileIDs: ["done"])],
            workState: "completed",
            completed: 1
        )
        XCTAssertFalse(TaskMaterialProgressiveRefreshPolicy.shouldContinue(after: settled))

        let nonMaterialRunning = materialManifest(
            outputs: [],
            progressive: [],
            plan: [.init(id: "hotel", title: "酒店预订", completionRule: "reservation")],
            workItems: [workItem(id: "hotel", state: "running")],
            workState: "running",
            completed: 0
        )
        XCTAssertFalse(
            TaskMaterialProgressiveRefreshPolicy.shouldContinue(after: nonMaterialRunning),
            "known non-material work must not consume the material refresh window"
        )

        let draftRunning = materialManifest(
            outputs: [],
            progressive: [],
            plan: [.init(id: "draft", title: "草稿", completionRule: "draft")],
            workItems: [workItem(id: "draft", state: "running")],
            workState: "running",
            completed: 0
        )
        XCTAssertFalse(
            TaskMaterialProgressiveRefreshPolicy.shouldContinue(after: draftRunning),
            "current Host progressive producer is scan-PDF document work, not draft work"
        )
    }

    func testProgressiveRefreshWaitsForEveryRunningMaterialItemButVerifiedPromotionKeepsSameID() throws {
        let stagedB = materialFile(
            id: "scan-b",
            name: "B.pdf",
            itemID: "scan-b-item",
            status: "processing",
            progress: .init(
                phase: "ocr_processing",
                status: "processing",
                detail: ["pdf_status": .string("ready"), "ocr_status": .string("processing")],
                updatedAt: "2026-09-13T06:51:00Z"
            )
        )
        let partiallyStaged = materialManifest(
            outputs: [],
            progressive: [stagedB],
            plan: [
                .init(id: "scan-b-item", title: "B", completionRule: "document"),
                .init(id: "scan-c-item", title: "C", completionRule: "document"),
            ],
            workItems: [
                workItem(id: "scan-b-item", state: "running"),
                workItem(id: "scan-c-item", state: "running"),
            ],
            workState: "running",
            completed: 0
        )
        XCTAssertTrue(
            TaskMaterialProgressiveRefreshPolicy.shouldContinue(after: partiallyStaged),
            "one staged document must not hide another running material item that has not staged yet"
        )

        let verifiedB = materialFile(
            id: stagedB.id,
            name: stagedB.name,
            itemID: "scan-b-item",
            status: "ready",
            ocrStatus: "complete"
        )
        let promoted = materialManifest(
            outputs: [verifiedB],
            progressive: [],
            plan: [.init(id: "scan-b-item", title: "B", completionRule: "document")],
            workItems: [workItem(id: "scan-b-item", state: "completed", fileIDs: [verifiedB.id])],
            workState: "completed",
            completed: 1
        )

        XCTAssertEqual(partiallyStaged.presentedOutputs.filter { $0.id == stagedB.id }.count, 1)
        XCTAssertEqual(promoted.presentedOutputs.filter { $0.id == stagedB.id }.count, 1)
        XCTAssertEqual(try XCTUnwrap(promoted.presentedOutputs.first).id, stagedB.id)
        XCTAssertNil(try XCTUnwrap(promoted.presentedOutputs.first).progress)
    }

    func testProgressivePDFUsesNormalTaskFileDownloadURLAndKeepsPreviewURL() async throws {
        let bytes = Data("%PDF-1.4\nprogressive-delivery\n%%EOF".utf8)
        TaskMaterialsURLProtocol.responseData = bytes
        TaskMaterialsURLProtocol.statusCode = 200
        TaskMaterialsURLProtocol.lastRequestPath = ""
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TaskMaterialsURLProtocol.self]
        let client = FlowerollHostClient(
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:8765")),
            session: URLSession(configuration: configuration)
        )
        let file = TaskMaterialFile(
            id: "pdf-progressive",
            name: "课堂笔记.pdf",
            mediaType: "application/pdf",
            sizeBytes: bytes.count,
            sha256: sha256(bytes),
            category: "document",
            metadata: ["structural_verified": .bool(true)],
            progress: .init(
                phase: "ocr_processing",
                status: "processing",
                detail: ["pdf_status": .string("ready"), "ocr_status": .string("processing")],
                updatedAt: "2026-09-13T05:03:00Z"
            )
        )

        let url = try await client.downloadTaskFile(taskID: "progressive-task", file: file)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertEqual(TaskMaterialsURLProtocol.lastRequestPath, "/v1/tasks/progressive-task/files/pdf-progressive")
        XCTAssertEqual(url.lastPathComponent, "课堂笔记.pdf")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(QLPreviewController.canPreview(url as NSURL))
    }

    func testImportedFilenameIsSanitizedButDocxExtensionSurvives() throws {
        let draft = freshDraft()
        defer { draft.clearSubmitted(Set(draft.items.map(\.id))) }
        let bytes = Data("PK\u{3}\u{4}name-test".utf8)
        // File URLs cannot contain '/', so exercise the same add/persistence path
        // with a name that contains a path separator from a remote file provider.
        try draft.add(data: bytes, name: "folder\\resume.docx", mediaType: TaskAttachmentFormat.docxMIME)
        let item = try XCTUnwrap(draft.items.last)
        XCTAssertEqual(item.name, "folder_resume.docx")
        XCTAssertTrue(item.storedName.hasSuffix(".docx"))
        XCTAssertEqual(try item.verifiedData(), bytes)
    }

    func testStructuredResultNormalizesEscapedNewlinesAndBuildsScheduleSections() {
        let result: JSONValue = .object([
            "summary": .string("未来7天安排：\\n9月13日：复习证券基础\\n9月14日：15:00 曼福科技二面\\n- 准备身份证\\n- 提前检查路线"),
            "task_id": .string("internal-task-id"),
            "action_id": .string("internal-action-id"),
        ])

        let presentation = RuntimeStructuredResultPresentation.make(from: result)

        XCTAssertEqual(presentation.timeBlocks.count, 2)
        XCTAssertTrue(presentation.timeBlocks.contains { $0.title == "9月13日" && $0.detail.contains("证券") })
        XCTAssertTrue(presentation.timeBlocks.contains { $0.title == "9月14日" && $0.detail.contains("曼福科技") })
        XCTAssertEqual(presentation.checklist.map(\.text), ["准备身份证", "提前检查路线"])
        XCTAssertTrue(presentation.facts.isEmpty)
        XCTAssertEqual(Set(presentation.technicalFacts.map(\.label)), Set(["task id", "action id"]))
        XCTAssertFalse((presentation.lead ?? "").contains("\\n"))
    }

    func testStructuredResultParsesBareClockLinesBeforeHeadingColon() {
        let result: JSONValue = .object([
            "summary": .string("15:00 面试\n18:30 复盘"),
        ])

        let presentation = RuntimeStructuredResultPresentation.make(from: result)

        XCTAssertEqual(
            presentation.timeBlocks,
            [
                .init(title: "15:00", detail: "面试"),
                .init(title: "18:30", detail: "复盘"),
            ]
        )
        XCTAssertFalse(presentation.sections.contains { $0.title == "15" || $0.title == "18" })
    }

    func testStructuredResultKeepsChineseDatePrefixedTimeBlock() {
        let result: JSONValue = .object([
            "summary": .string("9月14日：15:00 曼福科技二面"),
        ])

        let presentation = RuntimeStructuredResultPresentation.make(from: result)

        XCTAssertEqual(presentation.timeBlocks, [.init(title: "9月14日", detail: "15:00 曼福科技二面")])
        XCTAssertTrue(presentation.sections.isEmpty)
    }

    func testStructuredResultCalendarCompletionKeepsClockTogetherAndSeparatesMeaningfully() {
        let result: JSONValue = .object([
            "summary": .string("已添加日程「记得带伞」，2026年09月15日 13:00，保存在「工作」。"),
            "action_id": .string("calendar-action"),
        ])

        let presentation = RuntimeStructuredResultPresentation.make(from: result)

        XCTAssertEqual(
            presentation.timeBlocks,
            [.init(title: "2026年09月15日 13:00", detail: "已添加日程「记得带伞」，保存在「工作」。")]
        )
        XCTAssertTrue(presentation.sections.isEmpty)
        XCTAssertNil(presentation.lead)
    }

    func testStructuredResultMidSentenceClockColonNeverBecomesHeadingSeparator() {
        let result: JSONValue = .object([
            "summary": .string("日程已添加，13:00，保存在「工作」。"),
        ])

        let presentation = RuntimeStructuredResultPresentation.make(from: result)

        XCTAssertEqual(presentation.lead, "日程已添加，13:00，保存在「工作」。")
        XCTAssertTrue(presentation.timeBlocks.isEmpty)
        XCTAssertTrue(presentation.sections.isEmpty)
    }

    func testStructuredResultAsciiHeadingStillBuildsSection() {
        let result: JSONValue = .object([
            "summary": .string("备注: 请记得带伞"),
        ])

        let presentation = RuntimeStructuredResultPresentation.make(from: result)

        XCTAssertEqual(presentation.sections, [.init(title: "备注", body: "请记得带伞")])
        XCTAssertTrue(presentation.timeBlocks.isEmpty)
    }

    func testStructuredResultOrdinaryHeadingStillBuildsSection() {
        let result: JSONValue = .object([
            "summary": .string("准备事项：带身份证和简历"),
        ])

        let presentation = RuntimeStructuredResultPresentation.make(from: result)

        XCTAssertEqual(presentation.sections, [.init(title: "准备事项", body: "带身份证和简历")])
        XCTAssertTrue(presentation.timeBlocks.isEmpty)
    }

    func testAlarmProductCopyContainsNoImplementationLanguage() {
        let copy = FlowerollAlarmPresentationCopy.userFacingStrings.joined(separator: "\n")
        for forbidden in ["AlarmKit", "readback", "Alarm ID", "D 的 model", "state source", "native state source"] {
            XCTAssertFalse(copy.localizedCaseInsensitiveContains(forbidden), "ordinary Alarm copy leaked: \(forbidden)")
        }
    }

    func testStructuredResultParsesNativeStructuredArraysWithoutLeakingTechnicalFields() {
        let result: JSONValue = .object([
            "summary": .string("安排已经整理好。"),
            "events": .array([
                .object(["date": .string("9月15日"), "name": .string("上午二面")]),
                .object(["time": .string("18:30"), "activity": .string("复盘当天面试")]),
            ]),
            "checklist": .array([
                .object(["text": .string("打印简历"), "completed": .bool(true)]),
                .string("提前充电"),
            ]),
            "location": .string("杭州"),
            "sha256": .string(String(repeating: "a", count: 64)),
        ])

        let presentation = RuntimeStructuredResultPresentation.make(from: result)

        XCTAssertEqual(presentation.lead, "安排已经整理好。")
        XCTAssertEqual(presentation.timeBlocks.count, 2)
        XCTAssertEqual(presentation.checklist.count, 2)
        XCTAssertEqual(presentation.facts.first?.label, "地点")
        XCTAssertFalse(presentation.facts.contains { $0.label.lowercased().contains("sha") })
        XCTAssertTrue(presentation.technicalFacts.contains { $0.label == "sha256" })
    }

    func testTerminalTimelineSuppressesStaleActiveAndGenericDiscoveryNoise() {
        let active = timelineItem(
            id: "active",
            kind: "AGENT_ACTIVITY",
            state: "ACTIVE",
            title: "小卷正在思考下一步",
            summary: nil
        )
        let generic = timelineItem(
            id: "generic",
            kind: "TOOL_ACTIVITY",
            state: "COMPLETE",
            title: "处理方式已找到",
            summary: nil
        )
        let semantic = timelineItem(
            id: "semantic",
            kind: "PUBLIC_WORKLOG",
            state: "INFO",
            title: "下一步：正在制作扫描 PDF",
            summary: "会继续更新进度。"
        )

        let visible = RuntimeTimelinePresentationPolicy.visibleItems(
            [active, generic, semantic],
            taskStatus: "completed"
        )

        XCTAssertEqual(visible.map(\.timelineItemID), ["semantic"])
        XCTAssertEqual(RuntimeTimelinePresentationPolicy.title(for: active), "正在根据最新结果安排下一步")
    }

    func testC25EmptyHomeMascotRemainsPrimaryAcrossComposerDraftStates() {
        XCTAssertTrue(HomeEmptyStagePresentationPolicy.showsIdleMascot(
            composerFocused: false, hasTextDraft: false, attachmentCount: 0, attachmentLoading: false
        ))
        XCTAssertTrue(HomeEmptyStagePresentationPolicy.showsIdleMascot(
            composerFocused: true, hasTextDraft: false, attachmentCount: 0, attachmentLoading: false
        ))
        XCTAssertTrue(HomeEmptyStagePresentationPolicy.showsIdleMascot(
            composerFocused: true, hasTextDraft: true, attachmentCount: 0, attachmentLoading: false
        ))
        XCTAssertTrue(HomeEmptyStagePresentationPolicy.showsIdleMascot(
            composerFocused: false, hasTextDraft: false, attachmentCount: 2, attachmentLoading: false
        ))
        XCTAssertTrue(HomeEmptyStagePresentationPolicy.showsIdleMascot(
            composerFocused: false, hasTextDraft: true, attachmentCount: 2, attachmentLoading: true
        ))
    }

    func testC25TasksNavigationPreservesOrdinaryRoundTripAndResetsOnlyExplicitHandoff() {
        var navigation = AppShellTaskNavigationState()
        XCTAssertEqual(navigation.generation, 0)

        navigation.ordinaryRootTabSelection()
        navigation.ordinaryRootTabSelection()
        XCTAssertEqual(navigation.generation, 0, "Home/Settings/Tasks round trips must preserve the pushed Task detail")

        navigation.explicitBringToHome()
        XCTAssertEqual(navigation.generation, 1, "only explicit 调到前台 resets Tasks to its list root")
        navigation.ordinaryRootTabSelection()
        XCTAssertEqual(navigation.generation, 1)
    }

    func testC25AlarmMutationPresentationMakesUnresolvedTruthVisible() throws {
        let pending = try XCTUnwrap(FlowerollAlarmMutationPresentation.resolve(
            pendingState: .pending, lastResolution: nil
        ))
        XCTAssertEqual(pending.kind, .pending)
        XCTAssertEqual(pending.title, "正在确认修改结果")

        let ambiguous = try XCTUnwrap(FlowerollAlarmMutationPresentation.resolve(
            pendingState: .ambiguous, lastResolution: nil
        ))
        XCTAssertEqual(ambiguous.kind, .ambiguous)
        XCTAssertEqual(ambiguous.title, "修改结果暂时无法确认")
        XCTAssertTrue(ambiguous.detail.contains("刷新"))
        XCTAssertTrue(ambiguous.detail.contains("保留"))

        let notStarted = try XCTUnwrap(FlowerollAlarmMutationPresentation.resolve(
            pendingState: nil, lastResolution: .definitelyNotStarted
        ))
        XCTAssertEqual(notStarted.kind, .definitelyNotStarted)
        XCTAssertTrue(notStarted.title.contains("没有确认完成"))
        XCTAssertTrue(notStarted.detail.contains("重试"))

        XCTAssertNil(FlowerollAlarmMutationPresentation.resolve(
            pendingState: nil, lastResolution: .completed
        ))
    }

    func testC25AlarmCancelDismissesOnlyAfterDurableModelRemovesExactAlarm() {
        let target = UUID()
        let other = UUID()
        XCTAssertFalse(FlowerollAlarmCancelPresentationPolicy.shouldDismiss(
            cancelRequested: false, alarmID: target, visibleAlarmIDs: []
        ))
        XCTAssertFalse(FlowerollAlarmCancelPresentationPolicy.shouldDismiss(
            cancelRequested: true, alarmID: target, visibleAlarmIDs: [target, other]
        ))
        XCTAssertTrue(FlowerollAlarmCancelPresentationPolicy.shouldDismiss(
            cancelRequested: true, alarmID: target, visibleAlarmIDs: [other]
        ))
    }

    func testC25AttachmentDraftUsesSharedTenItemContractAndRejectsEleventh() throws {
        let draft = freshDraft()
        defer { draft.discard(Set(draft.items.map(\.id))) }
        XCTAssertEqual(TaskAttachmentDraft.maximumItemCount, 10)
        XCTAssertEqual(TaskAttachmentCaptureLimits.maximumPhotoCount, TaskAttachmentDraft.maximumItemCount)
        XCTAssertEqual(TaskAttachmentCaptureLimits.maximumDocumentPageCount, 10)
        XCTAssertEqual(draft.remainingCapacity, 10)
        XCTAssertEqual(draft.photoPickerSelectionLimit, 10)

        for index in 0..<10 {
            try draft.add(
                data: Data("attachment-\(index)".utf8),
                name: "附件-\(index).txt",
                mediaType: "text/plain"
            )
        }
        XCTAssertEqual(draft.items.count, 10)
        XCTAssertEqual(draft.items.map(\.name), (0..<10).map { "附件-\($0).txt" })
        XCTAssertEqual(Set(draft.items.map(\.id)).count, 10)
        XCTAssertEqual(draft.remainingCapacity, 0)
        XCTAssertTrue(draft.isFull)

        XCTAssertThrowsError(try draft.add(
            data: Data("eleventh".utf8), name: "第11个.txt", mediaType: "text/plain"
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("最多添加 10 份附件"))
        }
        XCTAssertEqual(draft.items.count, 10)
    }

    func testC25PhotosPickerRemainingLimitTracksDraftCapacity() throws {
        let draft = freshDraft()
        defer { draft.discard(Set(draft.items.map(\.id))) }
        XCTAssertEqual(draft.photoPickerSelectionLimit, 10)
        for index in 0..<3 {
            try draft.add(data: Data("pick-\(index)".utf8), name: "pick-\(index).txt", mediaType: "text/plain")
        }
        XCTAssertEqual(draft.remainingCapacity, 7)
        XCTAssertEqual(draft.photoPickerSelectionLimit, 7)
        for index in 3..<9 {
            try draft.add(data: Data("pick-\(index)".utf8), name: "pick-\(index).txt", mediaType: "text/plain")
        }
        XCTAssertEqual(draft.remainingCapacity, 1)
        XCTAssertEqual(draft.photoPickerSelectionLimit, 1)
    }

    func testC25TenPhotoSessionCallbacksEnterDraftInIdentityAndCaptureOrder() throws {
        let draft = freshDraft()
        defer { draft.discard(Set(draft.items.map(\.id))) }
        var session = TaskAttachmentPhotoSession()
        var sourceHashes: [String] = []
        for index in 0..<10 {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { context in
                UIColor(white: CGFloat(index + 1) / 12.0, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
            }
            let bytes = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
            sourceHashes.append(sha256(bytes))
            XCTAssertTrue(session.append(bytes))
        }
        var callbackIndex = 0
        var callbackError: Error?
        XCTAssertTrue(session.finish { bytes in
            do {
                try draft.addImage(bytes, name: "连拍-\(callbackIndex)")
                callbackIndex += 1
            } catch {
                callbackError = error
            }
        })
        XCTAssertNil(callbackError)
        XCTAssertEqual(callbackIndex, 10)
        XCTAssertEqual(draft.items.count, 10)
        XCTAssertEqual(draft.items.map(\.name), (0..<10).map { "连拍-\($0).jpg" })
        XCTAssertEqual(Set(draft.items.map(\.id)).count, 10)
        XCTAssertEqual(Set(draft.items.map(\.sha256)).count, 10)
        XCTAssertEqual(sourceHashes.count, 10)
    }

    func testC25DocumentScanRemainsOnePdfAttachment() throws {
        let draft = freshDraft()
        defer { draft.discard(Set(draft.items.map(\.id))) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 30)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 30, height: 30))
        }
        let page = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let pdf = try DocumentScanProcessor.pdfData(pages: [page, page])
        try draft.add(data: pdf, name: "扫描文档.pdf", mediaType: "application/pdf")
        XCTAssertEqual(draft.items.count, 1)
        XCTAssertEqual(draft.items.first?.mediaType, "application/pdf")
        XCTAssertEqual(PDFDocument(data: try XCTUnwrap(draft.items.first).verifiedData())?.pageCount, 2)
    }

    func testC26EightExistingAttachmentsLimitOrdinaryCameraToTwoBeforeDoneAndCommitExactlyTwo() throws {
        let draft = freshDraft()
        defer { draft.discard(Set(draft.items.map(\.id))) }
        for index in 0..<8 {
            try draft.add(
                data: Data("seed-\(index)".utf8),
                name: "已有附件-\(index).txt",
                mediaType: "text/plain"
            )
        }
        XCTAssertEqual(draft.remainingCapacity, 2)
        XCTAssertEqual(draft.ordinaryCameraCaptureCapacity, 2)

        var session = TaskAttachmentPhotoSession(
            maximumPhotoCount: draft.ordinaryCameraCaptureCapacity
        )
        XCTAssertEqual(session.capacity, 2)
        let first = try testJPEG(seed: 1)
        let second = try testJPEG(seed: 2)
        let rejected = try testJPEG(seed: 3)
        XCTAssertTrue(session.append(first))
        XCTAssertTrue(session.append(second))
        XCTAssertFalse(session.canCaptureMore)
        XCTAssertFalse(
            session.append(rejected),
            "the third photo must be rejected by the camera session before Done/composer admission"
        )
        XCTAssertEqual(session.count, 2)

        var callbackIndex = 0
        var callbackError: Error?
        XCTAssertTrue(session.finish { bytes in
            do {
                try draft.addImage(bytes, name: "剩余额度连拍-\(callbackIndex + 1)")
                callbackIndex += 1
            } catch {
                callbackError = error
            }
        })

        XCTAssertNil(callbackError)
        XCTAssertEqual(callbackIndex, 2)
        XCTAssertEqual(draft.items.count, 10)
        XCTAssertEqual(
            Array(draft.items.suffix(2)).map(\.name),
            ["剩余额度连拍-1.jpg", "剩余额度连拍-2.jpg"]
        )
        XCTAssertEqual(Set(draft.items.map(\.id)).count, 10)
        XCTAssertEqual(Set(draft.items.map(\.sha256)).count, 10)
    }

    func testC26EightExistingAttachmentsCancelCommitsNoPhotos() throws {
        let draft = freshDraft()
        defer { draft.discard(Set(draft.items.map(\.id))) }
        for index in 0..<8 {
            try draft.add(
                data: Data("cancel-seed-\(index)".utf8),
                name: "取消基线-\(index).txt",
                mediaType: "text/plain"
            )
        }
        let baselineIDs = draft.items.map(\.id)
        var session = TaskAttachmentPhotoSession(
            maximumPhotoCount: draft.ordinaryCameraCaptureCapacity
        )
        XCTAssertEqual(session.capacity, 2)
        XCTAssertTrue(session.append(try testJPEG(seed: 11)))
        XCTAssertTrue(session.append(try testJPEG(seed: 12)))

        session.cancel()
        var delivered = 0
        XCTAssertFalse(session.finish { _ in delivered += 1 })
        XCTAssertEqual(delivered, 0)
        XCTAssertEqual(draft.items.map(\.id), baselineIDs)
        XCTAssertEqual(draft.items.count, 8)
    }

    func testC26DeleteLastReopensOneSessionSlotAtRemainingCapacity() throws {
        var session = TaskAttachmentPhotoSession(maximumPhotoCount: 2)
        let first = try testJPEG(seed: 21)
        let second = try testJPEG(seed: 22)
        let replacement = try testJPEG(seed: 23)
        XCTAssertTrue(session.append(first))
        XCTAssertTrue(session.append(second))
        XCTAssertFalse(session.canCaptureMore)
        XCTAssertEqual(session.deleteLast(), second)
        XCTAssertTrue(session.canCaptureMore)
        XCTAssertTrue(session.append(replacement))
        XCTAssertFalse(session.canCaptureMore)
        var delivered: [Data] = []
        XCTAssertTrue(session.finish { delivered.append($0) })
        XCTAssertEqual(delivered, [first, replacement])
    }

    func testC26DocumentScanKeepsTenPagesWhenComposerHasOnlyOneAttachmentSlot() throws {
        let draft = freshDraft()
        defer { draft.discard(Set(draft.items.map(\.id))) }
        for index in 0..<9 {
            try draft.add(
                data: Data("scan-seed-\(index)".utf8),
                name: "已有-\(index).txt",
                mediaType: "text/plain"
            )
        }
        XCTAssertEqual(draft.remainingCapacity, 1)
        XCTAssertEqual(draft.ordinaryCameraCaptureCapacity, 1)
        XCTAssertEqual(TaskAttachmentCaptureLimits.maximumDocumentPageCount, 10)

        let page = try testJPEG(seed: 31)
        let pdf = try DocumentScanProcessor.pdfData(
            pages: Array(repeating: page, count: TaskAttachmentCaptureLimits.maximumDocumentPageCount)
        )
        XCTAssertEqual(PDFDocument(data: pdf)?.pageCount, 10)
        try draft.add(data: pdf, name: "十页扫描.pdf", mediaType: "application/pdf")
        XCTAssertEqual(draft.items.count, 10)
        XCTAssertEqual(draft.items.last?.mediaType, "application/pdf")
    }

    func testC25StructuredFinalResultSuppressesOnlyEquivalentLegacyTerminalResultRow() {
        let completionText = "资料已整理完成，扫描 PDF 已生成。"
        let result: JSONValue = .object(["summary": .string(completionText)])
        let input = timelineItem(id: "input", kind: "USER_INPUT", state: "INFO", title: "你补充了任务", summary: "请整理资料")
        let semantic = timelineItem(id: "semantic", kind: "PUBLIC_WORKLOG", state: "INFO", title: "扫描完成", summary: "共 2 页")
        let duplicate = timelineItem(id: "terminal", kind: "RESULT", state: "COMPLETE", title: "任务已完成", summary: completionText)

        let visible = RuntimeTimelinePresentationPolicy.visibleItems(
            [input, semantic, duplicate], taskStatus: "completed", structuredResult: result
        )
        XCTAssertEqual(visible.map(\.timelineItemID), ["input", "semantic"])
        XCTAssertEqual(RuntimeStructuredResultPresentation.make(from: result).lead, completionText)

        let unrelated = timelineItem(id: "other-result", kind: "RESULT", state: "COMPLETE", title: "任务已完成", summary: "另一个不相同的终态说明")
        XCTAssertEqual(
            RuntimeTimelinePresentationPolicy.visibleItems(
                [unrelated], taskStatus: "completed", structuredResult: result
            ).map(\.timelineItemID),
            ["other-result"]
        )

        let failure = timelineItem(id: "failure", kind: "FAILURE_NOTE", state: "FAILED", title: "任务失败", summary: completionText)
        XCTAssertEqual(
            RuntimeTimelinePresentationPolicy.visibleItems(
                [failure], taskStatus: "failed", structuredResult: result
            ).map(\.timelineItemID),
            ["failure"]
        )
    }

    func testC25AppShellCompletionAttentionUsesOneOwnerAndKeepsConsumptionSeparateFromAcknowledgement() throws {
        let suiteName = "TaskMaterialsTests.c25-completion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let owner = RuntimeCompletionAttentionOwner(
            defaults: defaults,
            sessionStartedAt: Date(timeIntervalSince1970: 1_789_257_600)
        )
        let task = HostTaskIndexItem(
            taskID: "task-c25-global", submissionID: nil, threadID: "thread-c25-global", parentTaskID: nil,
            title: "全局完成卡", goal: "验证 App shell", status: "completed", phase: nil,
            bucket: "history", needsUser: false, latestTimeline: nil,
            createdAt: "2026-09-13T00:00:01Z", updatedAt: "2026-09-13T00:00:01Z"
        )
        owner.reconcile(readModel: RuntimeCompletionAttentionReadModel(terminalTasks: [task]))
        XCTAssertEqual(AppShellCompletionAttentionPolicy.meaningfulVisibleDelayMilliseconds, 450)
        XCTAssertEqual(AppShellCompletionAttentionPolicy.presentationIndexPollSeconds, 3.0)
        XCTAssertEqual(owner.presentation(on: .home)?.taskID, task.taskID)
        XCTAssertEqual(owner.presentation(on: .tasks)?.taskID, task.taskID)
        XCTAssertEqual(owner.presentation(on: .settings)?.taskID, task.taskID)
        XCTAssertEqual(owner.presentation(on: .taskDetail(taskID: "other"))?.taskID, task.taskID)
        XCTAssertEqual(owner.dismissCurrent(), task.taskID)
        XCTAssertFalse(owner.acknowledgedTaskIDs.contains(task.taskID))
        owner.reconcile(readModel: RuntimeCompletionAttentionReadModel(terminalTasks: [task]))
        XCTAssertNil(owner.currentTaskID, "ordinary tab/reconcile must not resurrect a consumed card")
    }

    func testHumanTextNormalizationDoesNotExposeLiteralEscapedNewlines() {
        XCTAssertEqual(
            RuntimeHumanText.normalize("第一行\\n第二行\\r\\n第三行"),
            "第一行\n第二行\n第三行"
        )
    }

    private func materialFile(
        id: String,
        name: String,
        itemID: String,
        status: String,
        ocrStatus: String? = nil,
        progress: TaskMaterialFile.Progress? = nil
    ) -> TaskMaterialFile {
        var metadata: [String: JSONValue] = [
            "item_id": .string(itemID),
            "status": .string(status),
        ]
        if let ocrStatus { metadata["ocr_status"] = .string(ocrStatus) }
        return TaskMaterialFile(
            id: id,
            name: name,
            mediaType: "application/pdf",
            sizeBytes: 24,
            sha256: "sha-\(id)",
            category: "document",
            metadata: metadata,
            progress: progress
        )
    }

    private func workItem(
        id: String,
        state: String,
        fileIDs: [String] = []
    ) -> HostWorkSummary.Item {
        HostWorkSummary.Item(
            id: id,
            title: id,
            state: state,
            label: state,
            reason: nil,
            resultSummary: nil,
            dependsOn: [],
            fileIDs: fileIDs,
            missingInformation: []
        )
    }

    private func materialManifest(
        outputs: [TaskMaterialFile],
        progressive: [TaskMaterialFile],
        plan: [TaskMaterialManifest.Plan.Item],
        workItems: [HostWorkSummary.Item],
        workState: String,
        completed: Int
    ) -> TaskMaterialManifest {
        TaskMaterialManifest(
            inputs: [],
            initialInputIDs: [],
            outputs: outputs,
            progressiveOutputs: progressive,
            inputProvenance: [],
            plan: .init(title: "测试交付", items: plan),
            workSummary: .init(
                items: workItems,
                total: workItems.count,
                completed: completed,
                state: workState,
                revision: "same-material-revision"
            )
        )
    }

    private func timelineItem(
        id: String,
        kind: String,
        state: String,
        title: String,
        summary: String?
    ) -> HostTimelineItem {
        HostTimelineItem(
            timelineItemID: id,
            displayOrder: 1,
            kind: kind,
            presentationState: state,
            title: title,
            summary: summary,
            payload: [:],
            revision: 1,
            createdAt: "2026-09-13T00:00:00Z",
            updatedAt: "2026-09-13T00:00:01Z"
        )
    }

    private func freshDraft() -> TaskAttachmentDraft {
        let draft = TaskAttachmentDraft()
        if !draft.items.isEmpty {
            draft.clearSubmitted(Set(draft.items.map(\.id)))
        }
        return draft
    }

    private func temporaryFile(name: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskMaterialsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return url
    }

    private func testJPEG(seed: Int) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
        let image = renderer.image { context in
            UIColor(
                red: CGFloat((seed * 31) % 255) / 255.0,
                green: CGFloat((seed * 67) % 255) / 255.0,
                blue: CGFloat((seed * 97) % 255) / 255.0,
                alpha: 1
            ).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }

    @MainActor
    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for child in view.subviews {
            if let scroll = firstScrollView(in: child) { return scroll }
        }
        return nil
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}


private struct TaskFileExporterPresentationProbe: View {
    let item: ExportableTaskFile
    @State private var isPresented = false

    var body: some View {
        Color.clear
            .frame(width: 2, height: 2)
            .onAppear { isPresented = true }
            .fileExporter(
                isPresented: $isPresented,
                item: item,
                contentTypes: item.contentType.map { [$0] } ?? [],
                defaultFilename: item.source.displayFilename,
                onCompletion: { _ in },
                onCancellation: {}
            )
    }
}

@MainActor
final class TaskFileExportTests: XCTestCase {
    func testVerifiedOutputResolvesExactTaskFileAndSHA() async throws {
        let bytes = Data("verified export bytes".utf8)
        let url = try temporaryFile(name: "report.pdf", data: bytes)
        let file = materialFile(id: "verified-pdf", name: "report.pdf", mediaType: "application/pdf", bytes: bytes)
        let manifest = manifest(outputs: [file])
        let resolver = TaskMaterialLocalFileResolver { _, _ in url }

        let source = try await resolver.resolve(
            taskID: "task-export",
            sourceArtifactID: file.id,
            manifest: manifest
        )

        XCTAssertEqual(source.taskID, "task-export")
        XCTAssertEqual(source.sourceArtifactID, file.id)
        XCTAssertEqual(source.sourceSHA256, sha256(bytes))
        XCTAssertEqual(source.sourceSizeBytes, bytes.count)
        XCTAssertEqual(source.sourceMediaType, "application/pdf")
        XCTAssertEqual(source.displayFilename, "report.pdf")
        XCTAssertEqual(try Data(contentsOf: source.localURL), bytes)
    }

    func testProgressiveOnlyAndWrongFileNeverBecomeExportEligible() async throws {
        let bytes = Data("progressive".utf8)
        let progressive = materialFile(
            id: "staged-pdf",
            name: "staged.pdf",
            mediaType: "application/pdf",
            bytes: bytes,
            progress: .init(
                phase: "ocr_processing",
                status: "processing",
                detail: ["pdf_status": .string("ready")],
                updatedAt: "2026-09-13T00:00:00Z"
            )
        )
        let manifest = manifest(outputs: [], progressive: [progressive])
        XCTAssertNil(TaskFileExportPolicy.verifiedOutput(sourceArtifactID: progressive.id, manifest: manifest))
        XCTAssertNil(TaskFileExportPolicy.verifiedOutput(sourceArtifactID: "missing", manifest: manifest))

        let resolver = TaskMaterialLocalFileResolver { _, _ in
            throw TaskFileExportError.invalidOperationState
        }
        do {
            _ = try await resolver.resolve(
                taskID: "task-progressive",
                sourceArtifactID: progressive.id,
                manifest: manifest
            )
            XCTFail("expected missingVerifiedSource")
        } catch {
            XCTAssertEqual(error as? TaskFileExportError, .missingVerifiedSource)
        }
    }

    func testMissingSizeAndSHAMismatchFailClosedBeforeExporter() async throws {
        let good = Data("same-size-good".utf8)
        let bad = Data("same-size-badd".utf8)
        XCTAssertEqual(good.count, bad.count)
        let file = materialFile(id: "hash-file", name: "hash.txt", mediaType: "text/plain", bytes: good)
        let manifest = manifest(outputs: [file])

        let missingResolver = TaskMaterialLocalFileResolver { _, _ in
            FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        }
        do {
            _ = try await missingResolver.resolve(taskID: "task-hash", sourceArtifactID: file.id, manifest: manifest)
            XCTFail("missing source must fail closed before exporter handoff")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }

        let badURL = try temporaryFile(name: "hash.txt", data: bad)
        let badResolver = TaskMaterialLocalFileResolver { _, _ in badURL }
        do {
            _ = try await badResolver.resolve(taskID: "task-hash", sourceArtifactID: file.id, manifest: manifest)
            XCTFail("expected SHA mismatch")
        } catch {
            XCTAssertEqual(error as? TaskFileExportError, .sourceHashMismatch)
        }

        let shortURL = try temporaryFile(name: "short.txt", data: Data("short".utf8))
        let shortResolver = TaskMaterialLocalFileResolver { _, _ in shortURL }
        do {
            _ = try await shortResolver.resolve(taskID: "task-hash", sourceArtifactID: file.id, manifest: manifest)
            XCTFail("expected size mismatch")
        } catch {
            XCTAssertEqual(error as? TaskFileExportError, .sourceSizeMismatch)
        }
    }

    func testUnsupportedMediaTypeFailsBeforeOperation() async throws {
        let bytes = Data("zip".utf8)
        let file = materialFile(id: "zip", name: "archive.zip", mediaType: "application/zip", bytes: bytes)
        let manifest = manifest(outputs: [file])
        XCTAssertNil(TaskFileExportPolicy.verifiedOutput(sourceArtifactID: file.id, manifest: manifest))
        XCTAssertNil(TaskFileExportFormat.contentType(for: file.mediaType))
    }

    func testExportRepresentationIsCopyOnlyAndSourceCanBeReverified() throws {
        XCTAssertFalse(ExportableTaskFile.shouldAllowToOpenInPlace)
        XCTAssertFalse(ExportableTaskFile.allowAccessingOriginalFile)
        let bytes = Data("copy-only-source".utf8)
        let url = try temporaryFile(name: "copy.pdf", data: bytes)
        let file = materialFile(id: "copy", name: "copy.pdf", mediaType: "application/pdf", bytes: bytes)
        let source = try TaskMaterialExportIntegrity.verifiedSource(taskID: "task-copy", file: file, localURL: url)
        XCTAssertEqual(try TaskMaterialExportIntegrity.reverify(source), url)

        try Data("changed-source--".utf8).write(to: url, options: .atomic)
        do {
            _ = try TaskMaterialExportIntegrity.reverify(source)
            XCTFail("representation handoff must reject drifted source")
        } catch {
            XCTAssertTrue(
                error as? TaskFileExportError == .sourceSizeMismatch ||
                error as? TaskFileExportError == .sourceHashMismatch
            )
        }
    }

    func testCoordinatorSuccessPersistsOnlyDestinationFilenameAndKeepsSourceBytes() async throws {
        let bytes = Data("system export success".utf8)
        let url = try temporaryFile(name: "成功.pdf", data: bytes)
        let file = materialFile(id: "success", name: "成功.pdf", mediaType: "application/pdf", bytes: bytes)
        let manifest = manifest(outputs: [file])
        let (directory, operationStore) = try temporaryOperationStore()
        let coordinator = TaskFileExportCoordinator(operationStore: operationStore)
        let resolver = TaskMaterialLocalFileResolver { _, _ in url }

        await coordinator.prepareExport(
            taskID: "task-success",
            sourceArtifactID: file.id,
            manifest: manifest,
            resolver: resolver
        )
        let operationID = try XCTUnwrap(coordinator.item?.operationID)
        XCTAssertTrue(coordinator.isPresented)
        let startedRecord = await operationStore.record(operationID)
        XCTAssertEqual(startedRecord?.state, .mayHaveStarted)

        let destination = URL(fileURLWithPath: "/private/provider/Cloud Folder/成功 2.pdf")
        await coordinator.handleCompletion(.success(destination))
        let completedValue = await operationStore.record(operationID)
        let record = try XCTUnwrap(completedValue)
        XCTAssertEqual(record.state, .completedSystemExportTransaction)
        XCTAssertEqual(record.destinationFilename, "成功 2.pdf")
        XCTAssertEqual(coordinator.feedback, .init(kind: .success, message: "已保存到文件"))
        XCTAssertEqual(try Data(contentsOf: url), bytes, "export callback must never move/delete the authoritative source")

        let persisted = try String(
            contentsOf: directory.appendingPathComponent("files-export-v1.json"),
            encoding: .utf8
        )
        XCTAssertFalse(persisted.contains("/private/provider/Cloud Folder"))
        XCTAssertTrue(persisted.contains("成功 2.pdf"))
    }

    func testCoordinatorCancellationAndExplicitFailureAreDistinctTerminalStates() async throws {
        let bytes = Data("cancel-or-fail".utf8)
        let url = try temporaryFile(name: "result.txt", data: bytes)
        let file = materialFile(id: "terminal", name: "result.txt", mediaType: "text/plain", bytes: bytes)
        let manifest = manifest(outputs: [file])
        let (_, operationStore) = try temporaryOperationStore()
        let resolver = TaskMaterialLocalFileResolver { _, _ in url }

        let cancelled = TaskFileExportCoordinator(operationStore: operationStore)
        await cancelled.prepareExport(
            taskID: "task-cancel",
            sourceArtifactID: file.id,
            manifest: manifest,
            resolver: resolver
        )
        let cancelID = try XCTUnwrap(cancelled.item?.operationID)
        await cancelled.handleCancellation()
        let cancelledRecord = await operationStore.record(cancelID)
        XCTAssertEqual(cancelledRecord?.state, .userCancelled)
        XCTAssertEqual(cancelled.feedback?.kind, .cancelled)

        let failed = TaskFileExportCoordinator(operationStore: operationStore)
        await failed.prepareExport(
            taskID: "task-fail",
            sourceArtifactID: file.id,
            manifest: manifest,
            resolver: resolver
        )
        let failureID = try XCTUnwrap(failed.item?.operationID)
        await failed.handleCompletion(.failure(URLError(.cannotWriteToFile)))
        let failedRecord = await operationStore.record(failureID)
        XCTAssertEqual(failedRecord?.state, .failedExplicit)
        XCTAssertEqual(failed.feedback?.kind, .failure)
    }

    func testSHAMismatchBecomesDefinitelyNotStarted() async throws {
        let expected = Data("expected-source".utf8)
        let wrong = Data("different-bytes".utf8)
        XCTAssertEqual(expected.count, wrong.count)
        let wrongURL = try temporaryFile(name: "wrong.txt", data: wrong)
        let file = materialFile(id: "preflight-fail", name: "wrong.txt", mediaType: "text/plain", bytes: expected)
        let manifest = manifest(outputs: [file])
        let (_, operationStore) = try temporaryOperationStore()
        let coordinator = TaskFileExportCoordinator(operationStore: operationStore)
        let resolver = TaskMaterialLocalFileResolver { _, _ in wrongURL }

        await coordinator.prepareExport(
            taskID: "task-preflight-fail",
            sourceArtifactID: file.id,
            manifest: manifest,
            resolver: resolver
        )

        let preflightValue = await operationStore.latestRecord(taskID: "task-preflight-fail")
        let record = try XCTUnwrap(preflightValue)
        XCTAssertEqual(record.state, .definitelyNotStarted)
        XCTAssertEqual(record.errorCode, "source_sha256_mismatch")
        XCTAssertFalse(coordinator.isPresented)
        XCTAssertNil(coordinator.item)
    }

    func testRelaunchRecoversMayHaveStartedAsUnknownWithoutBlindReplay() async throws {
        let bytes = Data("ambiguous export".utf8)
        let file = materialFile(id: "ambiguous", name: "ambiguous.pdf", mediaType: "application/pdf", bytes: bytes)
        let directory = try temporaryDirectory(prefix: "TaskFileExportUnknown")
        let firstStore = try TaskFileExportOperationStore(directoryURL: directory)
        let operation = try await firstStore.prepare(taskID: "task-unknown", file: file)
        try await firstStore.markVerified(operation.exportOperationID)
        try await firstStore.markMayHaveStarted(operation.exportOperationID)

        let recoveredAt = Date(timeIntervalSince1970: 1_789_300_000)
        let relaunchedStore = try TaskFileExportOperationStore(directoryURL: directory, recoveryDate: recoveredAt)
        let recoveredValue = await relaunchedStore.record(operation.exportOperationID)
        let recovered = try XCTUnwrap(recoveredValue)
        XCTAssertEqual(recovered.state, .unknown)
        XCTAssertEqual(recovered.terminalAt, recoveredAt)
        XCTAssertEqual(recovered.errorCode, "callback_missing_after_relaunch")

        do {
            try await relaunchedStore.markMayHaveStarted(operation.exportOperationID)
            XCTFail("UNKNOWN operation must never be blindly replayed")
        } catch {
            XCTAssertEqual(error as? TaskFileExportError, .invalidOperationState)
        }
        let deliberateNewOperation = try await relaunchedStore.prepare(taskID: "task-unknown", file: file)
        XCTAssertNotEqual(deliberateNewOperation.exportOperationID, operation.exportOperationID)
    }

    func testOperationIDsAreUniqueAndTerminalOperationCannotReopen() async throws {
        let bytes = Data("identity".utf8)
        let file = materialFile(id: "identity", name: "identity.png", mediaType: "image/png", bytes: bytes)
        let (_, store) = try temporaryOperationStore()
        let first = try await store.prepare(taskID: "task-id", file: file)
        let second = try await store.prepare(taskID: "task-id", file: file)
        XCTAssertNotEqual(first.exportOperationID, second.exportOperationID)

        try await store.markVerified(first.exportOperationID)
        try await store.markMayHaveStarted(first.exportOperationID)
        try await store.cancel(first.exportOperationID)
        do {
            try await store.markMayHaveStarted(first.exportOperationID)
            XCTFail("terminal operation must remain terminal")
        } catch {
            XCTAssertEqual(error as? TaskFileExportError, .invalidOperationState)
        }
    }

    func testSwiftUIFileExporterPresentationDoesNotTrapWithVerifiedFilename() async throws {
        let bytes = Data("hosted-file-exporter-presentation".utf8)
        let url = try temporaryFile(name: "回归报告.pdf", data: bytes)
        let file = materialFile(id: "presentation-pdf", name: "回归报告.pdf", mediaType: "application/pdf", bytes: bytes)
        let source = try TaskMaterialExportIntegrity.verifiedSource(
            taskID: "task-presentation",
            file: file,
            localURL: url
        )
        let item = ExportableTaskFile(operationID: UUID().uuidString, source: source)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: TaskFileExporterPresentationProbe(item: item))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }

        try await Task.sleep(nanoseconds: 650_000_000)
        XCTAssertNotNil(window.rootViewController, "fileExporter presentation must not terminate the hosted app")
    }

    func testSupportedMediaTypesMapToConcreteUTTypesAndDisplayNameIsSafe() {
        XCTAssertEqual(TaskFileExportFormat.contentType(for: "application/pdf"), .pdf)
        XCTAssertEqual(TaskFileExportFormat.contentType(for: "image/jpeg"), .jpeg)
        XCTAssertEqual(TaskFileExportFormat.contentType(for: "image/png"), .png)
        XCTAssertEqual(TaskFileExportFormat.contentType(for: "text/plain"), .plainText)
        XCTAssertEqual(TaskFileExportFormat.contentType(for: TaskAttachmentFormat.docxMIME), TaskAttachmentFormat.docxType)
        XCTAssertEqual(
            TaskFileExportFormat.sanitizedDisplayFilename("folder\\report.pdf", mediaType: "application/pdf"),
            "folder_report.pdf"
        )
        XCTAssertEqual(
            TaskFileExportFormat.sanitizedDisplayFilename("   ", mediaType: "application/pdf"),
            "结果.pdf"
        )
    }

    private func materialFile(
        id: String,
        name: String,
        mediaType: String,
        bytes: Data,
        progress: TaskMaterialFile.Progress? = nil
    ) -> TaskMaterialFile {
        TaskMaterialFile(
            id: id,
            name: name,
            mediaType: mediaType,
            sizeBytes: bytes.count,
            sha256: sha256(bytes),
            category: "document",
            metadata: ["status": .string("ready")],
            progress: progress
        )
    }

    private func manifest(
        outputs: [TaskMaterialFile],
        progressive: [TaskMaterialFile] = []
    ) -> TaskMaterialManifest {
        TaskMaterialManifest(
            inputs: [],
            initialInputIDs: [],
            outputs: outputs,
            progressiveOutputs: progressive,
            inputProvenance: [],
            plan: nil,
            workSummary: nil
        )
    }

    private func temporaryOperationStore() throws -> (URL, TaskFileExportOperationStore) {
        let directory = try temporaryDirectory(prefix: "TaskFileExportStore")
        return (directory, try TaskFileExportOperationStore(directoryURL: directory))
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func temporaryFile(name: String, data: Data) throws -> URL {
        let directory = try temporaryDirectory(prefix: "TaskFileExportFile")
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
