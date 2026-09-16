import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct FixtureError: Error, CustomStringConvertible { let description: String }
func fail(_ message: String) -> FixtureError { FixtureError(description: message) }

func context(width: Int, height: Int, alpha: Bool) throws -> CGContext {
    let info: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
    guard let value = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: info.rawValue
    ) else { throw fail("context") }
    if alpha {
        value.clear(CGRect(x: 0, y: 0, width: width, height: height))
    } else {
        value.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        value.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    return value
}

func fixtureImage(width: Int, height: Int, alpha: Bool) throws -> CGImage {
    let ctx = try context(width: width, height: height, alpha: alpha)
    let w = CGFloat(width), h = CGFloat(height)
    let a: CGFloat = alpha ? 0.45 : 1
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: a))
    ctx.fill(CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: alpha ? 0.65 : 1))
    ctx.fill(CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2))
    ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: alpha ? 0.80 : 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h / 2))
    ctx.setFillColor(CGColor(red: 1, green: 0.8, blue: 0, alpha: alpha ? 0.25 : 1))
    ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2))
    guard let image = ctx.makeImage() else { throw fail("image") }
    return image
}

func writeImage(
    _ image: CGImage,
    to url: URL,
    type: UTType,
    orientation: Int = 1,
    quality: Double? = nil,
    metadata: [CFString: Any] = [:]
) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        throw fail("destination")
    }
    var properties = metadata
    properties[kCGImagePropertyOrientation] = orientation
    if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw fail("finalize") }
}

let args = CommandLine.arguments
guard args.count == 2 else { throw fail("usage: SyntheticImageFixtures <directory>") }
let directory = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

let opaque = try fixtureImage(width: 320, height: 180, alpha: false)
let alpha = try fixtureImage(width: 240, height: 160, alpha: true)
let orientedRaw = try fixtureImage(width: 180, height: 320, alpha: false)

let opaqueURL = directory.appendingPathComponent("opaque.png")
let alphaURL = directory.appendingPathComponent("alpha.png")
let orientedURL = directory.appendingPathComponent("orientation6.jpg")
let metadataURL = directory.appendingPathComponent("metadata.jpg")

try writeImage(opaque, to: opaqueURL, type: .png)
try writeImage(alpha, to: alphaURL, type: .png)
try writeImage(orientedRaw, to: orientedURL, type: .jpeg, orientation: 6, quality: 0.96)
try writeImage(
    opaque,
    to: metadataURL,
    type: .jpeg,
    quality: 0.92,
    metadata: [
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFMake: "FlowerollTest",
            kCGImagePropertyTIFFModel: "SyntheticCamera",
            kCGImagePropertyTIFFArtist: "Synthetic Tester",
            kCGImagePropertyTIFFImageDescription: "CAP-011 metadata fixture",
            kCGImagePropertyTIFFCopyright: "Synthetic only",
        ],
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifUserComment: "Synthetic EXIF comment",
        ],
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 0.0,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 0.0,
            kCGImagePropertyGPSLongitudeRef: "E",
        ],
    ]
)

let payload: [String: Any] = [
    "opaque": opaqueURL.path,
    "alpha": alphaURL.path,
    "orientation6": orientedURL.path,
    "metadata": metadataURL.path,
]
let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
