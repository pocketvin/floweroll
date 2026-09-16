import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct ImageOpsNativeError: Error, CustomStringConvertible {
    let code: String
    let message: String
    var description: String { "\(code): \(message)" }
}

func fail(_ code: String, _ message: String) -> ImageOpsNativeError {
    ImageOpsNativeError(code: code, message: message)
}

struct Request: Decodable {
    let command: String
    let inputPath: String
    let outputPath: String?
    let operation: String?
    let outputFormat: String?
    let maxDimension: Int?
    let width: Int?
    let height: Int?
    let offsetX: Int?
    let offsetY: Int?
    let jpegQuality: Int?
    let alphaPolicy: String?
    let maxInputBytes: Int64
    let maxOutputBytes: Int64
    let maxPixels: Int64
    let maxDecodeBytes: Int64
    let maxSide: Int

    enum CodingKeys: String, CodingKey {
        case command
        case inputPath = "input_path"
        case outputPath = "output_path"
        case operation
        case outputFormat = "output_format"
        case maxDimension = "max_dimension"
        case width, height
        case offsetX = "offset_x"
        case offsetY = "offset_y"
        case jpegQuality = "jpeg_quality"
        case alphaPolicy = "alpha_policy"
        case maxInputBytes = "max_input_bytes"
        case maxOutputBytes = "max_output_bytes"
        case maxPixels = "max_pixels"
        case maxDecodeBytes = "max_decode_bytes"
        case maxSide = "max_side"
    }
}

struct ImageInspection {
    let format: String
    let typeIdentifier: String
    let pixelWidth: Int
    let pixelHeight: Int
    let displayWidth: Int
    let displayHeight: Int
    let orientation: Int
    let hasAlpha: Bool
    let fileSize: Int64
    let pixelCount: Int64
    let decodeCostBytes: Int64
    let hasExif: Bool
    let hasGPS: Bool
    let hasTIFF: Bool
    let hasIPTC: Bool
    let privacyMetadataFields: [String]
    let dpiWidth: Double?
    let dpiHeight: Double?
    let depth: Int?
    let colorModel: String?

    var privacyMetadataPresent: Bool { !privacyMetadataFields.isEmpty }

    func asDictionary() -> [String: Any] {
        var value: [String: Any] = [
            "format": format,
            "type_identifier": typeIdentifier,
            "pixel_width": pixelWidth,
            "pixel_height": pixelHeight,
            "display_width": displayWidth,
            "display_height": displayHeight,
            "orientation": orientation,
            "has_alpha": hasAlpha,
            "file_size": fileSize,
            "pixel_count": pixelCount,
            "decode_cost_bytes": decodeCostBytes,
            "has_exif": hasExif,
            "has_gps": hasGPS,
            "has_tiff": hasTIFF,
            "has_iptc": hasIPTC,
            "privacy_metadata_present": privacyMetadataPresent,
            "privacy_metadata_fields": privacyMetadataFields,
        ]
        if let dpiWidth { value["dpi_width"] = dpiWidth }
        if let dpiHeight { value["dpi_height"] = dpiHeight }
        if let depth { value["depth"] = depth }
        if let colorModel { value["color_model"] = colorModel }
        return value
    }
}

func jsonPrint(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard let text = String(data: data, encoding: .utf8) else {
        throw fail("ENCODE_FAILED", "could not encode JSON response")
    }
    print(text)
}

func readRequest() throws -> Request {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty, data.count <= 64 * 1024 else {
        throw fail("INVALID_REQUEST", "request must be 1..65536 bytes")
    }
    do {
        return try JSONDecoder().decode(Request.self, from: data)
    } catch {
        throw fail("INVALID_REQUEST", "request JSON does not match native contract")
    }
}

func fileSize(_ url: URL) throws -> Int64 {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let number = attrs[.size] as? NSNumber else {
        throw fail("INPUT_NOT_FOUND", "file size unavailable")
    }
    return number.int64Value
}

func number(_ props: [CFString: Any], _ key: CFString) -> NSNumber? {
    props[key] as? NSNumber
}

func nestedDictionary(_ value: Any?) -> NSDictionary? {
    value as? NSDictionary
}

func nestedNonEmpty(_ props: [CFString: Any], _ key: CFString) -> Bool {
    guard let value = props[key] else { return false }
    if let dict = value as? NSDictionary { return dict.count > 0 }
    return true
}

func nestedHas(_ dict: NSDictionary?, _ key: CFString) -> Bool {
    guard let dict else { return false }
    return dict.object(forKey: key) != nil || dict.object(forKey: key as String) != nil
}

func privacyFields(_ props: [CFString: Any]) -> [String] {
    var fields: [String] = []
    if nestedNonEmpty(props, kCGImagePropertyGPSDictionary) {
        fields.append("gps")
    }
    let tiff = nestedDictionary(props[kCGImagePropertyTIFFDictionary])
    let tiffKeys: [(CFString, String)] = [
        (kCGImagePropertyTIFFMake, "tiff.make"),
        (kCGImagePropertyTIFFModel, "tiff.model"),
        (kCGImagePropertyTIFFArtist, "tiff.artist"),
        (kCGImagePropertyTIFFImageDescription, "tiff.description"),
        (kCGImagePropertyTIFFCopyright, "tiff.copyright"),
    ]
    for (key, label) in tiffKeys where nestedHas(tiff, key) {
        fields.append(label)
    }
    let exif = nestedDictionary(props[kCGImagePropertyExifDictionary])
    if nestedHas(exif, kCGImagePropertyExifUserComment) {
        fields.append("exif.user_comment")
    }
    if nestedNonEmpty(props, kCGImagePropertyIPTCDictionary) {
        fields.append("iptc")
    }
    return fields.sorted()
}

func formatName(_ identifier: String) -> String {
    if let type = UTType(identifier) {
        if type.conforms(to: .jpeg) { return "jpeg" }
        if type.conforms(to: .png) { return "png" }
        if type.conforms(to: .tiff) { return "tiff" }
        if type == .heic || identifier == "public.heic" || identifier == "public.heif" { return "heic" }
    }
    return "unsupported"
}

func typeForFormat(_ value: String) throws -> UTType {
    switch value {
    case "jpeg": return .jpeg
    case "png": return .png
    case "tiff": return .tiff
    case "heic": return .heic
    default: throw fail("UNSUPPORTED_FORMAT", "unsupported output format")
    }
}

func formatSupportsAlpha(_ value: String) -> Bool {
    value == "png" || value == "tiff"
}

func alphaPresent(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .first, .last, .premultipliedFirst, .premultipliedLast:
        return true
    default:
        return false
    }
}

func checkedGeometry(
    props: [CFString: Any],
    fileBytes: Int64,
    byteLimit: Int64,
    request: Request
) throws -> (Int, Int, Int64, Int64) {
    guard fileBytes > 0, fileBytes <= byteLimit else {
        throw fail("INPUT_TOO_LARGE", "image byte size exceeds bounded limit")
    }
    guard let widthNumber = number(props, kCGImagePropertyPixelWidth),
          let heightNumber = number(props, kCGImagePropertyPixelHeight) else {
        throw fail("DECODE_FAILED", "image dimensions unavailable")
    }
    let width = widthNumber.intValue
    let height = heightNumber.intValue
    guard width > 0, height > 0, width <= request.maxSide, height <= request.maxSide else {
        throw fail("PIXEL_LIMIT_EXCEEDED", "image dimensions exceed bounded side limit")
    }
    let pixels = Int64(width) * Int64(height)
    guard pixels > 0, pixels <= request.maxPixels else {
        throw fail("PIXEL_LIMIT_EXCEEDED", "image pixel count exceeds bounded limit")
    }
    let decodeBytes = pixels.multipliedReportingOverflow(by: 4)
    guard !decodeBytes.overflow, decodeBytes.partialValue <= request.maxDecodeBytes else {
        throw fail("DECODE_COST_EXCEEDED", "estimated RGBA decode cost exceeds bounded limit")
    }
    return (width, height, pixels, decodeBytes.partialValue)
}

func openSource(_ url: URL) throws -> (CGImageSource, [CFString: Any], Int64) {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw fail("INPUT_NOT_FOUND", "image file not found")
    }
    let size = try fileSize(url)
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
        throw fail("DECODE_FAILED", "could not open image source")
    }
    guard CGImageSourceGetCount(source) == 1 else {
        throw fail("UNSUPPORTED_MEDIA_TYPE", "only single-frame images are supported")
    }
    guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        throw fail("DECODE_FAILED", "could not read image properties")
    }
    return (source, props, size)
}

func logicalImage(source: CGImageSource, rawWidth: Int, rawHeight: Int) throws -> CGImage {
    let maxPixel = max(rawWidth, rawHeight)
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        throw fail("DECODE_FAILED", "could not decode logical image")
    }
    return image
}

func inspect(_ url: URL, byteLimit: Int64, request: Request) throws -> (ImageInspection, CGImage) {
    let (source, props, size) = try openSource(url)
    let (rawWidth, rawHeight, pixels, decodeBytes) = try checkedGeometry(
        props: props,
        fileBytes: size,
        byteLimit: byteLimit,
        request: request
    )
    let identifier = (CGImageSourceGetType(source) as String?) ?? "unknown"
    let format = formatName(identifier)
    guard format != "unsupported" else {
        throw fail("UNSUPPORTED_MEDIA_TYPE", "unsupported image codec")
    }
    let logical = try logicalImage(source: source, rawWidth: rawWidth, rawHeight: rawHeight)
    let orientation = number(props, kCGImagePropertyOrientation)?.intValue ?? 1
    let inspection = ImageInspection(
        format: format,
        typeIdentifier: identifier,
        pixelWidth: rawWidth,
        pixelHeight: rawHeight,
        displayWidth: logical.width,
        displayHeight: logical.height,
        orientation: orientation,
        hasAlpha: alphaPresent(logical),
        fileSize: size,
        pixelCount: pixels,
        decodeCostBytes: decodeBytes,
        hasExif: nestedNonEmpty(props, kCGImagePropertyExifDictionary),
        hasGPS: nestedNonEmpty(props, kCGImagePropertyGPSDictionary),
        hasTIFF: nestedNonEmpty(props, kCGImagePropertyTIFFDictionary),
        hasIPTC: nestedNonEmpty(props, kCGImagePropertyIPTCDictionary),
        privacyMetadataFields: privacyFields(props),
        dpiWidth: number(props, kCGImagePropertyDPIWidth)?.doubleValue,
        dpiHeight: number(props, kCGImagePropertyDPIHeight)?.doubleValue,
        depth: number(props, kCGImagePropertyDepth)?.intValue,
        colorModel: props[kCGImagePropertyColorModel] as? String
    )
    return (inspection, logical)
}

func makeContext(width: Int, height: Int, alpha: Bool, background: CGColor?) throws -> CGContext {
    guard width > 0, height > 0 else {
        throw fail("INVALID_DIMENSIONS", "output dimensions must be positive")
    }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let alphaInfo: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: alphaInfo.rawValue
    ) else {
        throw fail("DECODE_COST_EXCEEDED", "could not allocate bounded bitmap context")
    }
    context.interpolationQuality = .high
    if let background {
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    } else {
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    }
    return context
}

func render(_ image: CGImage, width: Int, height: Int, background: CGColor? = nil) throws -> CGImage {
    let context = try makeContext(width: width, height: height, alpha: background == nil, background: background)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let output = context.makeImage() else {
        throw fail("ENCODE_FAILED", "could not render image")
    }
    return output
}

func crop(_ image: CGImage, width: Int, height: Int, offsetX: Int, offsetY: Int) throws -> CGImage {
    guard offsetX >= 0, offsetY >= 0,
          width > 0, height > 0,
          offsetX + width <= image.width,
          offsetY + height <= image.height else {
        throw fail("CROP_OUT_OF_BOUNDS", "crop rectangle is outside logical image bounds")
    }
    let context = try makeContext(width: width, height: height, alpha: true, background: nil)
    let sourceY = image.height - offsetY - height
    context.draw(
        image,
        in: CGRect(
            x: -offsetX,
            y: -sourceY,
            width: image.width,
            height: image.height
        )
    )
    guard let output = context.makeImage() else {
        throw fail("ENCODE_FAILED", "could not crop image")
    }
    return output
}

func geometryImage(_ source: CGImage, request: Request) throws -> CGImage {
    guard let operation = request.operation else {
        throw fail("INVALID_REQUEST", "transform operation missing")
    }
    switch operation {
    case "convert", "compress_jpeg", "normalize_orientation", "strip_metadata":
        return source
    case "resize_fit":
        guard let limit = request.maxDimension, limit > 0 else {
            throw fail("INVALID_DIMENSIONS", "max_dimension missing")
        }
        let largest = max(source.width, source.height)
        if largest <= limit { return source }
        let scale = Double(limit) / Double(largest)
        let width = max(1, Int((Double(source.width) * scale).rounded()))
        let height = max(1, Int((Double(source.height) * scale).rounded()))
        return try render(source, width: width, height: height)
    case "resize_exact":
        guard let width = request.width, let height = request.height else {
            throw fail("INVALID_DIMENSIONS", "width and height missing")
        }
        return try render(source, width: width, height: height)
    case "crop":
        guard let width = request.width, let height = request.height,
              let offsetX = request.offsetX, let offsetY = request.offsetY else {
            throw fail("INVALID_DIMENSIONS", "crop fields missing")
        }
        return try crop(source, width: width, height: height, offsetX: offsetX, offsetY: offsetY)
    default:
        throw fail("UNSUPPORTED_OPERATION", "unsupported transform operation")
    }
}

func opaqueColor(_ white: Bool) -> CGColor {
    white
        ? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        : CGColor(red: 0, green: 0, blue: 0, alpha: 1)
}

func prepareForEncoding(
    _ image: CGImage,
    sourceHasAlpha: Bool,
    outputFormat: String,
    alphaPolicy: String
) throws -> (CGImage, Bool) {
    switch alphaPolicy {
    case "preserve":
        if sourceHasAlpha && !formatSupportsAlpha(outputFormat) {
            throw fail("ALPHA_NOT_SUPPORTED_BY_OUTPUT", "output format cannot preserve source alpha; use flatten_white")
        }
        if formatSupportsAlpha(outputFormat) {
            return (image, false)
        }
        return (try render(image, width: image.width, height: image.height, background: opaqueColor(true)), false)
    case "flatten_white":
        return (try render(image, width: image.width, height: image.height, background: opaqueColor(true)), true)
    default:
        throw fail("INVALID_ALPHA_POLICY", "unsupported alpha policy")
    }
}

func writeImage(_ image: CGImage, to url: URL, format: String, quality: Double?) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let type = try typeForFormat(format)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        throw fail("ENCODE_FAILED", "could not create image destination")
    }
    var props: [CFString: Any] = [kCGImagePropertyOrientation: 1]
    if let quality {
        props[kCGImageDestinationLossyCompressionQuality] = max(0.0, min(1.0, quality))
    }
    CGImageDestinationAddImage(destination, image, props as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw fail("ENCODE_FAILED", "could not finalize image destination")
    }
}

func outputFormat(_ request: Request) throws -> String {
    guard let operation = request.operation else {
        throw fail("INVALID_REQUEST", "operation missing")
    }
    if operation == "compress_jpeg" { return "jpeg" }
    guard let format = request.outputFormat else {
        throw fail("UNSUPPORTED_FORMAT", "output_format missing")
    }
    _ = try typeForFormat(format)
    return format
}

func transform(_ request: Request) throws -> [String: Any] {
    guard let outputPath = request.outputPath, let alphaPolicy = request.alphaPolicy else {
        throw fail("INVALID_REQUEST", "output_path and alpha_policy are required")
    }
    let inputURL = URL(fileURLWithPath: request.inputPath)
    let outputURL = URL(fileURLWithPath: outputPath)
    let (inputInspection, logical) = try inspect(inputURL, byteLimit: request.maxInputBytes, request: request)
    let geometry = try geometryImage(logical, request: request)
    let format = try outputFormat(request)
    let (prepared, flattened) = try prepareForEncoding(
        geometry,
        sourceHasAlpha: inputInspection.hasAlpha,
        outputFormat: format,
        alphaPolicy: alphaPolicy
    )
    let quality: Double?
    if request.operation == "compress_jpeg" {
        guard let requested = request.jpegQuality else {
            throw fail("INVALID_QUALITY", "jpeg_quality missing")
        }
        quality = Double(requested) / 100.0
    } else if format == "jpeg" || format == "heic" {
        quality = 0.90
    } else {
        quality = nil
    }
    try writeImage(prepared, to: outputURL, format: format, quality: quality)
    let outputBytes = try fileSize(outputURL)
    guard outputBytes > 0, outputBytes <= request.maxOutputBytes else {
        try? FileManager.default.removeItem(at: outputURL)
        throw fail("OUTPUT_TOO_LARGE", "encoded output exceeds bounded limit")
    }
    let (outputInspection, _) = try inspect(outputURL, byteLimit: request.maxOutputBytes, request: request)
    return [
        "input": inputInspection.asDictionary(),
        "output": outputInspection.asDictionary(),
        "operation": request.operation ?? "",
        "output_format": format,
        "alpha_policy": alphaPolicy,
        "flatten_white_applied": flattened,
        "engine": "ImageIO/CoreGraphics",
    ]
}

func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
    let count = image.width * image.height * 4
    var bytes = [UInt8](repeating: 0, count: count)
    guard let context = CGContext(
        data: &bytes,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw fail("DECODE_COST_EXCEEDED", "could not allocate verification buffer")
    }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
}

func whiteCompositeEvidence(alphaImage: CGImage, output: CGImage, lossy: Bool) throws -> [String: Any] {
    guard alphaImage.width == output.width, alphaImage.height == output.height else {
        return ["verified": false, "sample_count": 0, "reason": "dimension_mismatch"]
    }
    let white = try render(alphaImage, width: alphaImage.width, height: alphaImage.height, background: opaqueColor(true))
    let black = try render(alphaImage, width: alphaImage.width, height: alphaImage.height, background: opaqueColor(false))
    let alphaBytes = try rgbaBytes(alphaImage)
    let whiteBytes = try rgbaBytes(white)
    let blackBytes = try rgbaBytes(black)
    let outputBytes = try rgbaBytes(output)
    let pixels = alphaImage.width * alphaImage.height
    let stridePixels = max(1, pixels / 4096)
    var samples = 0
    var whiteDiff: Int64 = 0
    var blackDiff: Int64 = 0
    var pixel = 0
    while pixel < pixels {
        let index = pixel * 4
        if Int(alphaBytes[index + 3]) < 245 {
            for channel in 0..<3 {
                whiteDiff += Int64(abs(Int(outputBytes[index + channel]) - Int(whiteBytes[index + channel])))
                blackDiff += Int64(abs(Int(outputBytes[index + channel]) - Int(blackBytes[index + channel])))
            }
            samples += 1
        }
        pixel += stridePixels
    }
    if samples == 0 {
        return [
            "verified": true,
            "sample_count": 0,
            "white_mae": 0.0,
            "black_mae": 0.0,
            "note": "source_has_alpha_channel_but_no_transparent_samples",
        ]
    }
    let divisor = Double(samples * 3)
    let whiteMAE = Double(whiteDiff) / divisor
    let blackMAE = Double(blackDiff) / divisor
    let threshold = lossy ? 48.0 : 4.0
    let verified = whiteMAE <= threshold && whiteMAE + 2.0 < blackMAE
    return [
        "verified": verified,
        "sample_count": samples,
        "white_mae": whiteMAE,
        "black_mae": blackMAE,
        "threshold": threshold,
    ]
}

func verifyTransform(_ request: Request) throws -> [String: Any] {
    guard let outputPath = request.outputPath,
          let alphaPolicy = request.alphaPolicy else {
        throw fail("INVALID_REQUEST", "output_path and alpha_policy are required")
    }
    let inputURL = URL(fileURLWithPath: request.inputPath)
    let outputURL = URL(fileURLWithPath: outputPath)
    let (inputInspection, logical) = try inspect(inputURL, byteLimit: request.maxInputBytes, request: request)
    let geometry = try geometryImage(logical, request: request)
    let format = try outputFormat(request)
    let (outputInspection, outputLogical) = try inspect(outputURL, byteLimit: request.maxOutputBytes, request: request)

    var checks: [String: Bool] = [
        "format": outputInspection.format == format,
        "width": outputInspection.displayWidth == geometry.width,
        "height": outputInspection.displayHeight == geometry.height,
        "orientation_normalized": outputInspection.orientation == 1,
        "privacy_metadata_absent": !outputInspection.privacyMetadataPresent,
        "decode_cost_bounded": outputInspection.decodeCostBytes <= request.maxDecodeBytes,
        "pixel_count_bounded": outputInspection.pixelCount <= request.maxPixels,
        "output_bytes_bounded": outputInspection.fileSize <= request.maxOutputBytes,
    ]

    var composite: [String: Any]? = nil
    if alphaPolicy == "preserve" {
        if inputInspection.hasAlpha && formatSupportsAlpha(format) {
            checks["alpha_preserved"] = outputInspection.hasAlpha
        } else if inputInspection.hasAlpha && !formatSupportsAlpha(format) {
            checks["alpha_preserved"] = false
        } else {
            checks["alpha_compatible"] = true
        }
    } else if alphaPolicy == "flatten_white" {
        checks["alpha_removed"] = !outputInspection.hasAlpha
        let evidence = try whiteCompositeEvidence(
            alphaImage: geometry,
            output: outputLogical,
            lossy: format == "jpeg" || format == "heic"
        )
        composite = evidence
        checks["flatten_white_verified"] = evidence["verified"] as? Bool == true
    } else {
        checks["alpha_policy"] = false
    }

    if request.operation == "strip_metadata" {
        checks["strip_metadata_verified"] = !outputInspection.privacyMetadataPresent
    }

    let verified = checks.values.allSatisfy { $0 }
    var result: [String: Any] = [
        "verified": verified,
        "checks": checks,
        "input": inputInspection.asDictionary(),
        "readback": outputInspection.asDictionary(),
        "operation": request.operation ?? "",
        "output_format": format,
        "alpha_policy": alphaPolicy,
        "engine": "ImageIO/CoreGraphics",
    ]
    if let composite { result["white_composite"] = composite }
    return result
}

func execute(_ request: Request) throws -> [String: Any] {
    let inputURL = URL(fileURLWithPath: request.inputPath)
    switch request.command {
    case "inspect":
        let (inspection, _) = try inspect(inputURL, byteLimit: request.maxInputBytes, request: request)
        return ["inspection": inspection.asDictionary(), "engine": "ImageIO/CoreGraphics"]
    case "transform":
        return try transform(request)
    case "verify_transform":
        return try verifyTransform(request)
    default:
        throw fail("INVALID_REQUEST", "unknown native command")
    }
}

let request: Request

do {
    request = try readRequest()
    let result = try execute(request)
    try jsonPrint(["ok": true, "result": result])
} catch let error as ImageOpsNativeError {
    try? jsonPrint(["ok": false, "error": ["code": error.code, "message": error.message]])
    exit(2)
} catch {
    try? jsonPrint(["ok": false, "error": ["code": "NATIVE_FAILURE", "message": String(describing: error)]])
    exit(2)
}
