import CoreGraphics
import CoreImage
import Foundation
import ImageIO

enum PrepError: Error {
  case invalidArguments
  case decodeFailed(String)
  case unsupported(String)
  case encodeFailed(String)
}

func shaLikePixels(_ image: CGImage) throws -> String {
  let width = image.width
  let height = image.height
  let bytesPerRow = width * 4
  var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
  guard let context = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
  ) else { throw PrepError.decodeFailed("unable to create pixel context") }
  context.interpolationQuality = .none
  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  var hash: UInt64 = 14695981039346656037
  for byte in pixels {
    hash ^= UInt64(byte)
    hash &*= 1099511628211
  }
  return String(format: "%016llx", hash)
}

func alphaState(_ image: CGImage) -> Bool {
  switch image.alphaInfo {
  case .first, .last, .premultipliedFirst, .premultipliedLast: return true
  default: return false
  }
}

func colorDescription(_ space: CGColorSpace?) -> [String: Any] {
  guard let space else { return ["interpretation": "untagged-decoded-sRGB"] }
  var result: [String: Any] = [
    "model": space.model.rawValue,
    "components": space.numberOfComponents,
    "interpretation": "embedded-or-system-decoded-color-space"
  ]
  if let name = space.name { result["name"] = name as String }
  if let icc = space.copyICCData() as Data? { result["iccData"] = icc.base64EncodedString() }
  return result
}

func sameColorInterpretation(_ source: CGColorSpace?, _ output: CGColorSpace?) -> Bool {
  if source == nil { return output?.name == CGColorSpace.sRGB }
  guard let source, let output else { return false }
  if let sourceICC = source.copyICCData() as Data?, let outputICC = output.copyICCData() as Data? { return sourceICC == outputICC }
  return source.name == output.name && source.model == output.model
}

func orient(_ image: CGImage, exif: Int) throws -> CGImage {
  if image.bitsPerComponent > 8 { throw PrepError.unsupported("high-bit-depth source requires an explicit HDR contract") }
  let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
  let ciImage = CIImage(cgImage: image).oriented(forExifOrientation: Int32(exif))
  let context = CIContext(options: [.outputColorSpace: colorSpace])
  guard let output = context.createCGImage(ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: colorSpace) else {
    throw PrepError.decodeFailed("unable to bake orientation")
  }
  return output
}

func metadata(input: URL, output: URL) throws -> [String: Any] {
  guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { throw PrepError.decodeFailed("ImageIO could not open source") }
  let count = CGImageSourceGetCount(source)
  guard count > 0, let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw PrepError.decodeFailed("ImageIO could not decode primary image") }
  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
  let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
  guard (1...8).contains(orientation) else { throw PrepError.unsupported("invalid EXIF orientation") }
  let prepared = try orient(decoded, exif: orientation)
  guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) else { throw PrepError.encodeFailed("ImageIO could not create PNG destination") }
  CGImageDestinationAddImage(destination, prepared, [kCGImagePropertyOrientation: 1] as CFDictionary)
  guard CGImageDestinationFinalize(destination) else { throw PrepError.encodeFailed("ImageIO could not finalize PNG") }
  guard let outputSource = CGImageSourceCreateWithURL(output as CFURL, nil), let outputImage = CGImageSourceCreateImageAtIndex(outputSource, 0, nil) else { throw PrepError.encodeFailed("ImageIO could not re-open PNG") }
  let expectedPixels = try shaLikePixels(prepared)
  let actualPixels = try shaLikePixels(outputImage)
  guard expectedPixels == actualPixels else { throw PrepError.encodeFailed("decoded PNG pixels differ from prepared pixels") }
  let outputProperties = CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil) as? [CFString: Any] ?? [:]
  let outputOrientation = (outputProperties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
  guard outputOrientation == 1 else { throw PrepError.encodeFailed("PNG retains non-normalized orientation") }
  guard alphaState(decoded) == alphaState(outputImage) else { throw PrepError.encodeFailed("PNG alpha state differs from source") }
  guard sameColorInterpretation(decoded.colorSpace, outputImage.colorSpace) else { throw PrepError.encodeFailed("PNG color interpretation differs from source") }
  return [
    "sourceDimensions": ["width": decoded.width, "height": decoded.height],
    "outputDimensions": ["width": outputImage.width, "height": outputImage.height],
    "sourceBitDepth": decoded.bitsPerComponent,
    "outputBitDepth": outputImage.bitsPerComponent,
    "primaryImageIndex": 0,
    "primaryImageCount": count,
    "orientation": ["sourceExif": orientation, "outputExif": outputOrientation, "treatment": "baked-into-pixels"],
    "alpha": ["source": alphaState(decoded), "output": alphaState(outputImage)],
    "color": ["source": colorDescription(decoded.colorSpace), "output": colorDescription(outputImage.colorSpace), "treatment": decoded.colorSpace == nil ? "untagged-decoded-as-sRGB" : "preserved-decoded-profile"],
    "decodedPixelDigest": actualPixels,
    "sourceType": CGImageSourceGetType(source).map { $0 as String } ?? "unknown",
    "outputType": CGImageSourceGetType(outputSource).map { $0 as String } ?? "unknown"
  ]
}

func writeJson(_ object: [String: Any]) throws {
  let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data("\n".utf8))
}

func syntheticAlphaImage() throws -> CGImage {
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  guard let context = CGContext(
    data: nil,
    width: 2,
    height: 3,
    bitsPerComponent: 8,
    bytesPerRow: 8,
    space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
  ) else { throw PrepError.decodeFailed("unable to create synthetic alpha image") }
  context.setFillColor(red: 1, green: 0, blue: 0, alpha: 0.5)
  context.fill(CGRect(x: 0, y: 0, width: 1, height: 3))
  context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
  context.fill(CGRect(x: 1, y: 0, width: 1, height: 3))
  guard let image = context.makeImage() else { throw PrepError.decodeFailed("unable to create synthetic image") }
  return image
}

func selfTest(root: URL) throws -> [String: Any] {
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let input = root.appendingPathComponent("orientation-alpha-input.png")
  let output = root.appendingPathComponent("orientation-alpha-output.png")
  guard let destination = CGImageDestinationCreateWithURL(input as CFURL, "public.png" as CFString, 1, nil) else { throw PrepError.encodeFailed("unable to create synthetic source") }
  CGImageDestinationAddImage(destination, try syntheticAlphaImage(), [kCGImagePropertyOrientation: 6] as CFDictionary)
  guard CGImageDestinationFinalize(destination) else { throw PrepError.encodeFailed("unable to finalize synthetic source") }
  var result = try metadata(input: input, output: output)
  guard result["orientation"] as? [String: Any] != nil else { throw PrepError.decodeFailed("synthetic orientation receipt missing") }
  let synthetic = try syntheticAlphaImage()
  let cases = try (1...8).map { orientation -> [String: Any] in
    let prepared = try orient(synthetic, exif: orientation)
    let transposed = (5...8).contains(orientation)
    guard prepared.width == (transposed ? 3 : 2), prepared.height == (transposed ? 2 : 3), alphaState(prepared) else {
      throw PrepError.decodeFailed("synthetic orientation or alpha check failed")
    }
    return ["exif": orientation, "width": prepared.width, "height": prepared.height, "alpha": alphaState(prepared)]
  }
  result["orientationCases"] = cases
  return result
}

do {
  let arguments = CommandLine.arguments
  if arguments.count == 3 && arguments[1] == "--self-test" {
    try writeJson(try selfTest(root: URL(fileURLWithPath: arguments[2])))
  } else {
    guard arguments.count == 3 else { throw PrepError.invalidArguments }
    try writeJson(try metadata(input: URL(fileURLWithPath: arguments[1]), output: URL(fileURLWithPath: arguments[2])))
  }
} catch {
  FileHandle.standardError.write(Data("imageio-prep: \(error)\n".utf8))
  exit(1)
}
