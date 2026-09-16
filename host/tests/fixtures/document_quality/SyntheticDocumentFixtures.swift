import AppKit
import CoreImage
import Foundation

struct FixtureSpec: Codable {
    let id: String
    let filename: String
    let expectedTokens: [String]
    let notes: String
}

let args = CommandLine.arguments
if args.count != 2 {
    fputs("usage: FixtureGenerator <output-dir>\n", stderr)
    exit(2)
}
let outputDir = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func savePNG(_ image: NSImage, name: String) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
    }
    try data.write(to: outputDir.appendingPathComponent(name))
}

func cgImage(_ image: NSImage) throws -> CGImage {
    var rect = CGRect(origin: .zero, size: image.size)
    guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
        throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "CGImage conversion failed"])
    }
    return cg
}

func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat = 42, color: NSColor = .black, bold: Bool = false, width: CGFloat = 1000) {
    let font = bold ? NSFont.monospacedSystemFont(ofSize: size, weight: .bold) : NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    (value as NSString).draw(in: NSRect(x: x, y: y, width: width, height: size * 1.45), withAttributes: attrs)
}

func makePage(id: String, pageToken: String, includeColor: Bool = false, includeStamp: Bool = false, edgeMarkers: Bool = false) -> NSImage {
    let width: CGFloat = 1200
    let height: CGFloat = 1600
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    if edgeMarkers {
        NSColor.systemBlue.setFill(); NSRect(x: 0, y: height - 26, width: width, height: 26).fill()
        NSColor.systemGreen.setFill(); NSRect(x: 0, y: 0, width: width, height: 26).fill()
        NSColor.systemOrange.setFill(); NSRect(x: 0, y: 0, width: 26, height: height).fill()
        NSColor.systemPurple.setFill(); NSRect(x: width - 26, y: 0, width: 26, height: height).fill()
        text("EDGETOP", x: 120, y: height - 78, size: 36, bold: true)
        text("EDGEBOTTOM", x: 120, y: 32, size: 36, bold: true)
        text("EDGELEFT", x: 30, y: 780, size: 30, bold: true, width: 300)
        text("EDGERIGHT", x: 900, y: 780, size: 30, bold: true, width: 280)
    }

    text(id, x: 95, y: 1400, size: 58, bold: true)
    text(pageToken, x: 95, y: 1315, size: 50, bold: true)
    text("ORIGINALHASH BLACKTEXT", x: 95, y: 1210, size: 42)
    text("FLOWEROLL SYNTHETIC DOCUMENT", x: 95, y: 1125, size: 40)
    text("小卷扫描测试 合成文档", x: 95, y: 1040, size: 38)
    text("Line A keeps exact page order and content.", x: 95, y: 940, size: 34)
    text("Line B checks OCR retention after scan PDF.", x: 95, y: 875, size: 34)
    text("Line C checks crop, edge, color and render.", x: 95, y: 810, size: 34)

    if includeColor {
        NSColor.systemBlue.setFill(); NSRect(x: 95, y: 620, width: 420, height: 110).fill()
        text("BLUEBOX", x: 125, y: 647, size: 38, color: .white, bold: true, width: 350)
        NSColor.systemGreen.setFill(); NSRect(x: 575, y: 620, width: 420, height: 110).fill()
        text("GREENBOX", x: 605, y: 647, size: 38, color: .white, bold: true, width: 350)
    }

    if includeStamp {
        let center = NSPoint(x: 900, y: 330)
        let radius: CGFloat = 145
        let oval = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        NSColor.systemRed.setStroke(); oval.lineWidth = 16; oval.stroke()
        let inner = NSBezierPath(ovalIn: NSRect(x: center.x - 105, y: center.y - 105, width: 210, height: 210))
        inner.lineWidth = 8; inner.stroke()
        // Keep the red OCR label inside the inner ring. Drawing the glyphs across
        // the circular stroke makes Vision merge the final letters with the ring
        // on some macOS revisions, which tests the fixture ambiguity rather than
        // whether the scan pipeline preserves the stamp.
        text("REDSTAMP", x: 815, y: 305, size: 34, color: .systemRed, bold: true, width: 210)
    }

    if edgeMarkers {
        text("CENTERKEEP", x: 390, y: 360, size: 46, bold: true, width: 450)
    } else {
        text("BODYKEEP", x: 95, y: 390, size: 44, bold: true)
    }

    NSColor.black.setStroke()
    let frame = NSBezierPath(rect: NSRect(x: 55, y: 55, width: width - 110, height: height - 110))
    frame.lineWidth = 3
    frame.stroke()
    image.unlockFocus()
    return image
}

func perspectiveFixture() throws -> NSImage {
    let base = makePage(id: "PERSPECTIVEPAGE", pageToken: "PAGEFOUR")
    base.lockFocus()
    text("TILTEDDOC", x: 95, y: 700, size: 46, bold: true)
    text("CORNERKEEP", x: 770, y: 85, size: 34, bold: true, width: 350)
    base.unlockFocus()

    let source = CIImage(cgImage: try cgImage(base))
    let canvas = CGRect(x: 0, y: 0, width: 1600, height: 1900)
    let background = CIImage(color: CIColor(red: 0.28, green: 0.30, blue: 0.33, alpha: 1)).cropped(to: canvas)
    let warped = source.applyingFilter("CIPerspectiveTransform", parameters: [
        "inputTopLeft": CIVector(x: 170, y: 1715),
        "inputTopRight": CIVector(x: 1435, y: 1625),
        "inputBottomLeft": CIVector(x: 255, y: 175),
        "inputBottomRight": CIVector(x: 1370, y: 285),
    ])
    let composite = warped.composited(over: background).cropped(to: canvas)
    let ciContext = CIContext(options: [.cacheIntermediates: false])
    guard let out = ciContext.createCGImage(composite, from: canvas) else {
        throw NSError(domain: "fixture", code: 3, userInfo: [NSLocalizedDescriptionKey: "perspective render failed"])
    }
    return NSImage(cgImage: out, size: NSSize(width: canvas.width, height: canvas.height))
}

func shadowFixture() -> NSImage {
    let page = makePage(id: "SHADOWPAGE", pageToken: "PAGEFIVE")
    page.lockFocus()
    text("BRIGHTNESS UNEVENLIGHT", x: 95, y: 700, size: 40, bold: true)
    text("SHADOWKEEP", x: 95, y: 540, size: 44, bold: true)
    let gradient = NSGradient(colors: [NSColor(calibratedWhite: 0.0, alpha: 0.30), NSColor(calibratedWhite: 0.0, alpha: 0.00)])!
    gradient.draw(in: NSRect(x: 0, y: 0, width: 680, height: 1600), angle: 0)
    page.unlockFocus()

    let canvas = NSImage(size: NSSize(width: 1460, height: 1840))
    canvas.lockFocus()
    NSColor(calibratedWhite: 0.36, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 1460, height: 1840).fill()
    let shadow = NSShadow(); shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 18, height: -20); shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    NSGraphicsContext.saveGraphicsState(); shadow.set()
    NSColor.white.setFill(); NSRect(x: 130, y: 120, width: 1200, height: 1600).fill()
    NSGraphicsContext.restoreGraphicsState()
    page.draw(in: NSRect(x: 130, y: 120, width: 1200, height: 1600), from: .zero, operation: .sourceOver, fraction: 1.0)
    canvas.unlockFocus()
    return canvas
}

let clean = makePage(id: "CLEANPAGE", pageToken: "PAGEONE")
let color = makePage(id: "COLORPAGE", pageToken: "PAGETWO", includeColor: true, includeStamp: true)
let edge = makePage(id: "EDGEPAGE", pageToken: "PAGETHREE", edgeMarkers: true)
let perspective = try perspectiveFixture()
let shadow = shadowFixture()

try savePNG(clean, name: "01-clean-white-black.png")
try savePNG(color, name: "02-color-red-stamp.png")
try savePNG(edge, name: "03-edge-content.png")
try savePNG(perspective, name: "04-light-perspective.png")
try savePNG(shadow, name: "05-shadow-uneven.png")

let specs = [
    FixtureSpec(id: "clean", filename: "01-clean-white-black.png", expectedTokens: ["CLEANPAGE", "PAGEONE", "ORIGINALHASH", "BLACKTEXT", "BODYKEEP"], notes: "white background + black text"),
    FixtureSpec(id: "color_stamp", filename: "02-color-red-stamp.png", expectedTokens: ["COLORPAGE", "PAGETWO", "REDSTAMP", "BLUEBOX", "GREENBOX", "BODYKEEP"], notes: "color content + red stamp-like element"),
    FixtureSpec(id: "edge", filename: "03-edge-content.png", expectedTokens: ["EDGEPAGE", "PAGETHREE", "EDGETOP", "EDGEBOTTOM", "EDGELEFT", "EDGERIGHT", "CENTERKEEP"], notes: "content close to all page edges"),
    FixtureSpec(id: "perspective", filename: "04-light-perspective.png", expectedTokens: ["PERSPECTIVEPAGE", "PAGEFOUR", "TILTEDDOC", "CORNERKEEP", "BODYKEEP"], notes: "mild perspective on dark neutral background"),
    FixtureSpec(id: "shadow", filename: "05-shadow-uneven.png", expectedTokens: ["SHADOWPAGE", "PAGEFIVE", "BRIGHTNESS", "UNEVENLIGHT", "SHADOWKEEP"], notes: "uneven illumination + outer shadow"),
]
let manifest: [String: Any] = [
    "schema": 1,
    "fixtures": specs.map { ["id": $0.id, "filename": $0.filename, "expected_tokens": $0.expectedTokens, "notes": $0.notes] },
    "multi_page_order": specs.map { $0.id },
    "privacy": "synthetic_non_private",
]
let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try manifestData.write(to: outputDir.appendingPathComponent("manifest.json"))
print("generated \(specs.count) synthetic fixtures at \(outputDir.path)")
