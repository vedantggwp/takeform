import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

let args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
guard let input = flag("--input"), let output = flag("--output") else {
    fputs("usage: HeicWriter --input png --output heic [--orientation N] [--content-id ID]\n", stderr)
    exit(2)
}
let orientation = Int(flag("--orientation") ?? "1") ?? 1
let srcURL = URL(fileURLWithPath: input)
let dstURL = URL(fileURLWithPath: output)
guard let src = CGImageSourceCreateWithURL(srcURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    fputs("cannot read \(input)\n", stderr)
    exit(1)
}
guard let dest = CGImageDestinationCreateWithURL(dstURL as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
    fputs("cannot create HEIC destination\n", stderr)
    exit(1)
}
var props: [CFString: Any] = [
    kCGImageDestinationLossyCompressionQuality: 0.9,
    kCGImagePropertyOrientation: orientation
]
if let contentId = flag("--content-id") {
    props[kCGImagePropertyMakerAppleDictionary] = ["17": contentId]
}
CGImageDestinationAddImage(dest, image, props as CFDictionary)
if !CGImageDestinationFinalize(dest) {
    fputs("HEIC finalize failed\n", stderr)
    exit(1)
}
