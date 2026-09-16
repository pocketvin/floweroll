import Foundation
import AppKit
import PDFKit
import CoreText
import Vision
import CoreImage
import ImageIO

struct Failure: Error, CustomStringConvertible { let description: String }
func fail(_ text: String) -> Failure { Failure(description: text) }
let context = CIContext(options: [.cacheIntermediates: false])

func loadImage(_ path: String) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int,
          w > 0, h > 0, w <= 20000, h <= 20000, w * h <= 60000000,
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 3200
          ] as CFDictionary) else { throw fail("无法读取图片或图片尺寸过大。") }
    return image
}

private struct PixelMetrics {
    let nearBlackRatio: Double
    let redRatio: Double
    let chromaticRatio: Double
    let whiteRatio: Double
    let edgeChromatic: [String: Double]
    let edgeWhite: [String: Double]

    var json: [String: Any] {
        [
            "near_black_ratio": nearBlackRatio,
            "red_ratio": redRatio,
            "chromatic_ratio": chromaticRatio,
            "white_ratio": whiteRatio,
            "edge_chromatic_ratio": edgeChromatic,
            "edge_white_ratio": edgeWhite,
        ]
    }
}

private func pixelMetrics(_ image: CGImage) throws -> PixelMetrics {
    let width = min(256, image.width)
    let height = min(256, image.height)
    guard width > 0, height > 0 else { throw fail("图片像素无效。") }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { throw fail("无法建立扫描质量像素缓冲。") }
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    struct Counts { var total = 0; var nearBlack = 0; var red = 0; var chromatic = 0; var white = 0 }
    var all = Counts()
    var edges = ["top": Counts(), "bottom": Counts(), "left": Counts(), "right": Counts()]
    let stripX = max(2, Int(Double(width) * 0.04))
    let stripY = max(2, Int(Double(height) * 0.04))

    func add(_ r: Int, _ g: Int, _ b: Int, to c: inout Counts) {
        c.total += 1
        let luminance = (2126 * r + 7152 * g + 722 * b) / 10000
        if luminance <= 24 { c.nearBlack += 1 }
        if r >= 150 && r >= g + 45 && r >= b + 45 { c.red += 1 }
        if max(r, g, b) - min(r, g, b) >= 32 { c.chromatic += 1 }
        if r >= 245 && g >= 245 && b >= 245 { c.white += 1 }
    }

    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            let r = Int(bytes[offset]); let g = Int(bytes[offset + 1]); let b = Int(bytes[offset + 2])
            add(r, g, b, to: &all)
            if y < stripY { add(r, g, b, to: &edges["bottom"]!) }
            if y >= height - stripY { add(r, g, b, to: &edges["top"]!) }
            if x < stripX { add(r, g, b, to: &edges["left"]!) }
            if x >= width - stripX { add(r, g, b, to: &edges["right"]!) }
        }
    }

    func ratio(_ value: Int, _ total: Int) -> Double { total == 0 ? 0 : Double(value) / Double(total) }
    var edgeChromatic: [String: Double] = [:]
    var edgeWhite: [String: Double] = [:]
    for (name, c) in edges {
        edgeChromatic[name] = ratio(c.chromatic, c.total)
        edgeWhite[name] = ratio(c.white, c.total)
    }
    return PixelMetrics(
        nearBlackRatio: ratio(all.nearBlack, all.total),
        redRatio: ratio(all.red, all.total),
        chromaticRatio: ratio(all.chromatic, all.total),
        whiteRatio: ratio(all.white, all.total),
        edgeChromatic: edgeChromatic,
        edgeWhite: edgeWhite
    )
}

private func maxCornerInset(_ rect: VNRectangleObservation) -> Double {
    let values = [
        max(rect.topLeft.x, 1 - rect.topLeft.y),
        max(1 - rect.topRight.x, 1 - rect.topRight.y),
        max(rect.bottomLeft.x, rect.bottomLeft.y),
        max(1 - rect.bottomRight.x, rect.bottomRight.y),
    ]
    return values.map(Double.init).max() ?? 1.0
}

private func pointDistance(_ a: CGPoint, _ b: CGPoint) -> Double {
    let dx = Double(a.x - b.x)
    let dy = Double(a.y - b.y)
    return (dx * dx + dy * dy).squareRoot()
}

private func oppositeEdgeDelta(_ rect: VNRectangleObservation) -> Double {
    let top = pointDistance(rect.topLeft, rect.topRight)
    let bottom = pointDistance(rect.bottomLeft, rect.bottomRight)
    let left = pointDistance(rect.topLeft, rect.bottomLeft)
    let right = pointDistance(rect.topRight, rect.bottomRight)
    return max(abs(top - bottom), abs(left - right))
}

func scanImage(_ image: CGImage, enabled: Bool) throws -> (CGImage, [String: Any]) {
    guard enabled else {
        return (image, [
            "perspective_corrected": false,
            "mode": "original",
            "scan_decision": "scan_disabled",
            "needs_visual_review": false,
        ])
    }

    let original = CIImage(cgImage: image)
    let sourceMetrics = try pixelMetrics(image)
    var ci = original
    let request = VNDetectDocumentSegmentationRequest()
    try VNImageRequestHandler(cgImage: image).perform([request])

    var corrected = false
    var confidence = 0.0
    var detectedArea = 0.0
    var cornerInset = 1.0
    var edgeDelta = 1.0
    var decision = "no_reliable_document"
    var needsVisualReview = true
    var reviewReason = "未可靠识别纸张四角，保留全图。"

    if let rect = request.results?.first {
        confidence = Double(rect.confidence)
        detectedArea = Double(rect.boundingBox.width * rect.boundingBox.height)
        cornerInset = maxCornerInset(rect)
        edgeDelta = oppositeEdgeDelta(rect)

        // A page that is already close to the four image corners should not be
        // re-warped merely because Vision can fit a high-confidence rectangle.
        // The gate uses three independent geometry signals rather than a single
        // area magic number. The bounded real-camera corpus currently separates
        // a camera-derived near-full frame (area≈0.869, max inset≈0.056,
        // opposite-edge delta≈0.031) from genuine perspective captures
        // (max inset≈0.167–0.227). Keep the conservative thresholds covered by
        // tests instead of promoting an experiment-only `area <= 0.95` rule.
        let looksAlreadyCropped = rect.confidence >= 0.8
            && detectedArea >= 0.80
            && cornerInset <= 0.065
            && edgeDelta <= 0.08
        let correctionCandidate = rect.confidence >= 0.8 && detectedArea >= 0.50 && !looksAlreadyCropped

        if looksAlreadyCropped {
            decision = "preserve_near_full_frame"
            needsVisualReview = false
            reviewReason = "页面已近全幅且四角贴近画面边界，保留原始边缘，避免重复透视矫正。"
        } else if correctionCandidate {
            func point(_ p: CGPoint) -> CIVector {
                CIVector(x: p.x * original.extent.width, y: p.y * original.extent.height)
            }
            let proposed = original.applyingFilter("CIPerspectiveCorrection", parameters: [
                "inputTopLeft": point(rect.topLeft), "inputTopRight": point(rect.topRight),
                "inputBottomLeft": point(rect.bottomLeft), "inputBottomRight": point(rect.bottomRight)
            ])
            if proposed.extent.width > 400 && proposed.extent.height > 400 {
                ci = proposed
                corrected = true
                decision = "perspective_corrected"
                needsVisualReview = false
                reviewReason = "已使用高置信度纸张四角进行透视矫正。"
            } else {
                decision = "candidate_too_small"
                reviewReason = "检测到纸张但矫正结果过小，已保留全图。"
            }
        } else if rect.confidence >= 0.8 {
            decision = "preserve_uncertain_geometry"
            reviewReason = detectedArea < 0.50
                ? "检测区域占画面过小，避免把局部内容误当整页裁切。"
                : "纸张几何不满足安全自动矫正条件，已保留全图。"
        }
    }

    // Gentle color-preserving enhancement; no binarisation, generative redraw,
    // background replacement, or stamp removal.
    ci = ci.applyingFilter("CIColorControls", parameters: [
        "inputBrightness": 0.025, "inputContrast": 1.07, "inputSaturation": 1.0
    ]).applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": 0.28])
    guard let output = context.createCGImage(ci, from: ci.extent) else { throw fail("扫描增强失败。") }
    let outputMetrics = try pixelMetrics(output)

    let blackBackgroundGuard = outputMetrics.nearBlackRatio <= max(0.20, sourceMetrics.nearBlackRatio + 0.12)
    var redRetention: Double? = nil
    if sourceMetrics.redRatio >= 0.001 {
        redRetention = outputMetrics.redRatio / sourceMetrics.redRatio
    }

    var edgeRetention: [String: Double] = [:]
    var whiteWedgeIntroduced = false
    if decision == "preserve_near_full_frame" {
        for edge in ["top", "bottom", "left", "right"] {
            let sourceChromatic = sourceMetrics.edgeChromatic[edge] ?? 0
            let outputChromatic = outputMetrics.edgeChromatic[edge] ?? 0
            if sourceChromatic >= 0.05 {
                edgeRetention[edge] = outputChromatic / sourceChromatic
            }
            let sourceWhite = sourceMetrics.edgeWhite[edge] ?? 0
            let outputWhite = outputMetrics.edgeWhite[edge] ?? 0
            if outputWhite - sourceWhite > 0.20 { whiteWedgeIntroduced = true }
        }
    }

    if !blackBackgroundGuard {
        needsVisualReview = true
        reviewReason = "增强后暗色像素比例异常升高，需要人工预览。"
    }
    if whiteWedgeIntroduced {
        needsVisualReview = true
        reviewReason = "近全幅页面边缘出现新增大面积白区，需要人工预览。"
    }
    if let redRetention, redRetention < 0.50 {
        needsVisualReview = true
        reviewReason = "检测到的红色内容保留比例偏低，需要人工预览。"
    }

    var visualMetrics: [String: Any] = [
        "source": sourceMetrics.json,
        "output": outputMetrics.json,
        "black_background_guard_pass": blackBackgroundGuard,
        "edge_chromatic_retention": edgeRetention,
        "white_wedge_introduced": whiteWedgeIntroduced,
    ]
    visualMetrics["red_retention_ratio"] = redRetention.map { $0 as Any } ?? NSNull()

    return (output, [
        "perspective_corrected": corrected,
        "detection_confidence": confidence,
        "detected_area": detectedArea,
        "max_corner_inset": cornerInset,
        "opposite_edge_delta": edgeDelta,
        "scan_decision": decision,
        "mode": "color_scan",
        "needs_visual_review": needsVisualReview,
        "review_reason": reviewReason,
        "source_pixel_width": image.width,
        "source_pixel_height": image.height,
        "output_pixel_width": output.width,
        "output_pixel_height": output.height,
        "visual_metrics": visualMetrics,
    ])
}

// Core Text paginates actual Unicode text; PDFKit independently reads it back.
// This is a text report, NOT a fidelity conversion of a DOCX package.
func textReportPDF(_ input: [String: Any]) throws -> [String: Any] {
    guard let output = input["output"] as? String,
          let title = input["title"] as? String, !title.isEmpty, title.count <= 120,
          let body = input["text"] as? String, !body.isEmpty, body.utf8.count <= 300000 else {
        throw fail("Invalid PDF report input")
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 4
    paragraph.paragraphSpacing = 7
    let font = NSFont(name: "PingFangSC-Regular", size: 11) ?? NSFont.systemFont(ofSize: 11)
    let headingFont = NSFont(name: "PingFangSC-Semibold", size: 16) ?? NSFont.boldSystemFont(ofSize: 16)
    let base: [NSAttributedString.Key: Any] = [
        .font: font, .paragraphStyle: paragraph,
        .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1)
    ]
    let text = NSMutableAttributedString(string: "")
    for line in body.components(separatedBy: "\n") {
        var value = line
        var attrs = base
        if line.hasPrefix("# ") {
            value = String(line.dropFirst(2))
            attrs[.font] = NSFont(name: "PingFangSC-Semibold", size: 22) ?? NSFont.boldSystemFont(ofSize: 22)
        } else if line.hasPrefix("## ") {
            value = String(line.dropFirst(3))
            attrs[.font] = headingFont
        }
        text.append(NSAttributedString(string: value + "\n", attributes: attrs))
    }
    let framesetter = CTFramesetterCreateWithAttributedString(text)
    var box = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
    guard let context = CGContext(URL(fileURLWithPath: output) as CFURL, mediaBox: &box,
        [kCGPDFContextTitle as String: title] as CFDictionary) else { throw fail("无法建立 PDF 输出。") }
    var location = 0
    var pages = 0
    while location < text.length {
        guard pages < 200 else { throw fail("PDF 报告超过 200 页限制。") }
        let path = CGPath(rect: CGRect(x: 44, y: 58, width: box.width-88, height: box.height-102), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
        let visible = CTFrameGetVisibleStringRange(frame)
        guard visible.length > 0 else { throw fail("PDF 文本排版未取得进展。") }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        pages += 1
        context.endPDFPage()
        location += visible.length
    }
    context.closePDF()
    guard let verified = PDFDocument(url: URL(fileURLWithPath: output)),
          !verified.isLocked, verified.pageCount == pages, pages > 0 else { throw fail("PDF 结构读回失败。") }
    func normalized(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(String.init).joined()
    }
    guard normalized(verified.string ?? "") == normalized(text.string) else {
        throw fail("PDF 文本读回与请求内容不一致；未发布不完整成果。")
    }
    for index in 0..<pages {
        guard let page = verified.page(at: index),
              page.thumbnail(of: NSSize(width: 595, height: 842), for: .mediaBox).tiffRepresentation != nil else {
            throw fail("PDF 页面不可渲染。")
        }
    }
    return ["verified": true, "text_verified": true, "page_count": pages,
            "structural_verified": true, "verification_scope": "renderable_pdf_and_exact_text_readback"]
}

func run(_ input: [String: Any]) throws -> [String: Any] {
    if input["operation"] as? String == "text_to_pdf" { return try textReportPDF(input) }
    guard let op = input["operation"] as? String, let output = input["output"] as? String,
          let paths = input["paths"] as? [String], !paths.isEmpty, paths.count <= 32 else {
        throw fail("Invalid document request")
    }
    let result = PDFDocument()
    var metadata: [[String: Any]] = []
    if op == "images_to_pdf" {
        for path in paths {
            let (cg, meta) = try scanImage(loadImage(path), enabled: input["scan"] as? Bool ?? false)
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            guard let page = PDFPage(image: image) else { throw fail("PDF 图片页生成失败。") }
            result.insert(page, at: result.pageCount)
            metadata.append(meta)
        }
    } else if op == "pdf_select" {
        guard paths.count == 1,
              let doc = PDFDocument(url: URL(fileURLWithPath: paths[0])),
              !doc.isLocked,
              doc.pageCount <= 200,
              let pages = input["pages"] as? [Int],
              !pages.isEmpty,
              pages.count <= 200 else {
            throw fail("PDF 页码无效或文档已加密。")
        }
        for index in pages {
            guard index >= 1, index <= doc.pageCount,
                  let page = doc.page(at: index - 1)?.copy() as? PDFPage else {
                throw fail("页码超出范围。")
            }
            result.insert(page, at: result.pageCount)
        }
    } else if op == "pdf_merge" {
        for path in paths {
            guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), !doc.isLocked else {
                throw fail("无法打开 PDF 或需要密码。")
            }
            guard result.pageCount + doc.pageCount <= 200 else { throw fail("最多处理 200 页。") }
            for index in 0..<doc.pageCount {
                guard let page = doc.page(at: index)?.copy() as? PDFPage else { throw fail("读取 PDF 页失败。") }
                result.insert(page, at: result.pageCount)
            }
        }
    } else {
        throw fail("Unsupported document operation")
    }

    guard result.pageCount > 0,
          result.write(to: URL(fileURLWithPath: output)),
          let verified = PDFDocument(url: URL(fileURLWithPath: output)),
          verified.pageCount == result.pageCount else {
        throw fail("PDF 写入或读回验证失败。")
    }

    var renderedPages: [[String: Any]] = []
    for i in 0..<verified.pageCount {
        guard let page = verified.page(at: i), page.bounds(for: .mediaBox).width > 0 else {
            throw fail("无效 PDF 页面。")
        }
        let preview = page.thumbnail(of: NSSize(width: 600, height: 800), for: .mediaBox)
        guard preview.tiffRepresentation != nil else { throw fail("PDF 页面无法渲染。") }
        renderedPages.append(["page": i + 1, "renderable": true])
    }

    return [
        "page_count": result.pageCount,
        "verified": true,
        "structural_verified": true,
        "verification_scope": "pdf_structure_only",
        "rendered_pages": renderedPages,
        "pages": metadata,
        "operation": op,
    ]
}

do {
    let bytes = FileHandle.standardInput.readDataToEndOfFile()
    guard bytes.count <= 1000000,
          let input = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
        throw fail("Expected JSON request")
    }
    let data = try JSONSerialization.data(withJSONObject: run(input), options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
} catch {
    FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
    exit(2)
}
