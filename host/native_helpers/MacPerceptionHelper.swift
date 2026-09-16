import AppKit
import Foundation
import PDFKit
import Vision

private struct HelperFailure: Error, CustomStringConvertible {
    let description: String
}

private func emit(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [])
    guard let text = String(data: data, encoding: .utf8) else {
        throw HelperFailure(description: "failed to encode JSON")
    }
    print(text)
}

private func cgImage(path: String) throws -> CGImage {
    guard let image = NSImage(contentsOfFile: path) else {
        throw HelperFailure(description: "could not load image")
    }
    var rect = CGRect(origin: .zero, size: image.size)
    guard let value = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
        throw HelperFailure(description: "could not create CGImage")
    }
    return value
}

private func recognizeText(_ image: CGImage) throws -> [String: Any] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])

    let observations = (request.results ?? []).sorted { lhs, rhs in
        if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.015 {
            return lhs.boundingBox.midY > rhs.boundingBox.midY
        }
        return lhs.boundingBox.minX < rhs.boundingBox.minX
    }
    var blocks: [[String: Any]] = []
    var lines: [String] = []
    for observation in observations {
        guard let candidate = observation.topCandidates(1).first else { continue }
        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        let box = observation.boundingBox
        blocks.append([
            "text": text,
            "confidence": Double(candidate.confidence),
            "bbox": [Double(box.minX), Double(box.minY), Double(box.width), Double(box.height)],
        ])
        lines.append(text)
    }
    return [
        "text": lines.joined(separator: "\n"),
        "blocks": blocks,
        "block_count": blocks.count,
    ]
}

private func runOCR(path: String) throws {
    try emit(recognizeText(try cgImage(path: path)))
}

private func runPDF(path: String) throws {
    guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
        throw HelperFailure(description: "could not load PDF")
    }
    var pages: [[String: Any]] = []
    var combined: [String] = []
    for index in 0..<document.pageCount {
        let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        pages.append(["page": index + 1, "text": text])
        if !text.isEmpty {
            combined.append(text)
        }
    }
    try emit([
        "page_count": document.pageCount,
        "text": combined.joined(separator: "\n\n"),
        "pages": pages,
    ])
}

private func runPDFOCR(path: String) throws {
    guard let document = PDFDocument(url: URL(fileURLWithPath: path)), !document.isLocked else {
        throw HelperFailure(description: "could not load PDF")
    }
    guard document.pageCount <= 200 else {
        throw HelperFailure(description: "PDF exceeds OCR page limit")
    }

    var pages: [[String: Any]] = []
    var combined: [String] = []
    for index in 0..<document.pageCount {
        guard let page = document.page(at: index) else {
            throw HelperFailure(description: "could not load PDF page")
        }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else {
            throw HelperFailure(description: "invalid PDF page bounds")
        }
        let longEdge: CGFloat = 2200
        let scale = min(longEdge / max(bounds.width, bounds.height), 4.0)
        let target = NSSize(
            width: max(1, floor(bounds.width * scale)),
            height: max(1, floor(bounds.height * scale))
        )
        let thumbnail = page.thumbnail(of: target, for: .mediaBox)
        var rect = CGRect(origin: .zero, size: thumbnail.size)
        guard let image = thumbnail.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw HelperFailure(description: "could not rasterize PDF page for OCR")
        }
        let ocr = try recognizeText(image)
        let text = ocr["text"] as? String ?? ""
        let blocks = ocr["blocks"] as? [[String: Any]] ?? []
        pages.append([
            "page": index + 1,
            "text": text,
            "blocks": blocks,
            "block_count": blocks.count,
            "render_width": image.width,
            "render_height": image.height,
        ])
        if !text.isEmpty { combined.append(text) }
    }
    try emit([
        "page_count": document.pageCount,
        "text": combined.joined(separator: "\n\n"),
        "pages": pages,
        "ocr_complete": pages.count == document.pageCount,
        "mode": "vision_pdf_page_ocr",
    ])
}

private func run() throws {
    let args = CommandLine.arguments
    guard args.count == 3 else {
        throw HelperFailure(description: "usage: MacPerceptionHelper <ocr|pdf-text|pdf-ocr> <path>")
    }
    switch args[1] {
    case "ocr":
        try runOCR(path: args[2])
    case "pdf-text":
        try runPDF(path: args[2])
    case "pdf-ocr":
        try runPDFOCR(path: args[2])
    default:
        throw HelperFailure(description: "unknown command")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
    exit(2)
}
