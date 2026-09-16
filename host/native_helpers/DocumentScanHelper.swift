import Foundation
import AppKit
import CoreImage
import Vision
import PDFKit

// JSON stdin only; paths are supplied by the Host's task-scoped file store.
// Never redraw OCR text: the PDF contains the user's original image pixels.
struct ScanRequest: Decodable {
    let inputs: [String]
    let output: String
    let crop_mode: String
}

func run() throws {
    let request = try JSONDecoder().decode(ScanRequest.self, from: FileHandle.standardInput.readDataToEndOfFile())
    guard !request.inputs.isEmpty, request.inputs.count <= 8,
          ["auto", "preserve"].contains(request.crop_mode) else {
        throw NSError(domain: "scan", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid scan request"])
    }
    let ci = CIContext(options: [.cacheIntermediates: false])
    var pages: [(CGImage, CGRect)] = []
    var details: [[String: Any]] = []
    for path in request.inputs {
        guard var image = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]) else {
            throw NSError(domain: "scan", code: 2, userInfo: [NSLocalizedDescriptionKey: "image decoding failed"])
        }
        guard image.extent.width >= 128, image.extent.height >= 128,
              image.extent.width * image.extent.height <= 60_000_000 else {
            throw NSError(domain: "scan", code: 3, userInfo: [NSLocalizedDescriptionKey: "image dimensions outside limits"])
        }
        var corrected = false
        var confidence: Float = 0
        var warning: String? = nil
        if request.crop_mode == "auto" {
            let detection = VNDetectDocumentSegmentationRequest()
            try VNImageRequestHandler(ciImage: image).perform([detection])
            if let page = detection.results?.first {
                confidence = page.confidence
                let area = page.boundingBox.width * page.boundingBox.height
                if confidence >= 0.85, area >= 0.40, area <= 0.995 {
                    let extent = image.extent
                    func pixel(_ point: CGPoint) -> CIVector {
                        CIVector(x: extent.minX + point.x * extent.width, y: extent.minY + point.y * extent.height)
                    }
                    let candidate = image.applyingFilter("CIPerspectiveCorrection", parameters: [
                        "inputTopLeft": pixel(page.topLeft), "inputTopRight": pixel(page.topRight),
                        "inputBottomLeft": pixel(page.bottomLeft), "inputBottomRight": pixel(page.bottomRight)
                    ])
                    if candidate.extent.width >= 128, candidate.extent.height >= 128 {
                        image = candidate
                        corrected = true
                    }
                }
            }
            if !corrected { warning = "未可靠识别纸张四角，已保留完整画面，请预览或使用手机扫描入口调整。" }
        }
        // Mild color-preserving enhancement; no binarization or synthetic text.
        image = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1.0, kCIInputContrastKey: 1.04, kCIInputBrightnessKey: 0.012
        ]).applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.25])
        guard let cg = ci.createCGImage(image, from: image.extent) else {
            throw NSError(domain: "scan", code: 4, userInfo: [NSLocalizedDescriptionKey: "image rendering failed"])
        }
        let scale = min(595.0 / Double(cg.width), 842.0 / Double(cg.height))
        let bounds = CGRect(x: 0, y: 0, width: Double(cg.width) * scale, height: Double(cg.height) * scale)
        pages.append((cg, bounds))
        var detail: [String: Any] = ["perspective_corrected": corrected, "document_confidence": confidence,
                                     "pixel_width": cg.width, "pixel_height": cg.height]
        if let warning { detail["warning"] = warning }
        details.append(detail)
    }
    let destination = URL(fileURLWithPath: request.output)
    guard let consumer = CGDataConsumer(url: destination as CFURL),
          let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
        throw NSError(domain: "scan", code: 5, userInfo: [NSLocalizedDescriptionKey: "PDF writer unavailable"])
    }
    for (image, bounds) in pages {
        var mediaBox = bounds
        let boxData = NSData(bytes: &mediaBox, length: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        context.endPDFPage()
    }
    context.closePDF()
    guard let document = PDFDocument(url: destination), document.pageCount == pages.count else {
        throw NSError(domain: "scan", code: 6, userInfo: [NSLocalizedDescriptionKey: "PDF read-back failed"])
    }
    let output: [String: Any] = ["page_count": document.pageCount, "pages": details,
                                 "verified_readback": true, "needs_visual_review": true,
                                 "method": "Vision_document_detection_CoreImage_PDFKit"]
    let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
}

do { try run() }
catch {
    FileHandle.standardError.write(Data("Document conversion failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
