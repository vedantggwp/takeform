import AppKit
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func color(_ hex: String) -> NSColor {
    var h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    if h.hasPrefix("0x") || h.hasPrefix("0X") { h = String(h.dropFirst(2)) }
    let v = UInt32(h, radix: 16) ?? 0
    let r = CGFloat((v >> 16) & 0xff) / 255
    let g = CGFloat((v >> 8) & 0xff) / 255
    let b = CGFloat(v & 0xff) / 255
    return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

guard let output = flag("--output"), let text = flag("--text"), let bg = flag("--bg") else {
    fputs("usage: LabelStill --output png --text str --bg hex [--box x,y,w,h,hex]...\n", stderr)
    exit(2)
}

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: 1920,
    pixelsHigh: 1080,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .calibratedRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
    fputs("bitmap failed\n", stderr)
    exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: 1920, height: 1080).fill()
let transparent = args.contains("--transparent")
if !transparent {
    color(bg).setFill()
    NSRect(x: 0, y: 0, width: 1920, height: 1080).fill()
}
var i = 0
while i < args.count {
    if args[i] == "--box", i + 1 < args.count {
        let parts = args[i + 1].split(separator: ",").map(String.init)
        if parts.count == 5,
           let x = Double(parts[0]), let y = Double(parts[1]),
           let w = Double(parts[2]), let h = Double(parts[3]) {
            color(parts[4]).setFill()
            NSRect(x: x, y: y, width: w, height: h).fill()
        }
        i += 2
        continue
    }
    i += 1
}
let para = NSMutableParagraphStyle()
para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 56, weight: .semibold),
    .foregroundColor: NSColor.white,
    .paragraphStyle: para,
    .strokeColor: NSColor.black,
    .strokeWidth: -2.0
]
let rect = transparent ? NSRect(x: 80, y: 40, width: 1760, height: 120) : NSRect(x: 80, y: 420, width: 1760, height: 240)
(text as NSString).draw(in: rect, withAttributes: attrs)
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("png encode failed\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: output))
