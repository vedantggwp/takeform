import Foundation
import AVFoundation
import CoreMedia

let args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
guard let input = flag("--input"), let output = flag("--output"), let identifier = flag("--id") else {
    fputs("usage: ContentIdWriter --input mov --output mov --id UUID\n", stderr)
    exit(2)
}
let inURL = URL(fileURLWithPath: input)
let outURL = URL(fileURLWithPath: output)
let fm = FileManager.default
if fm.fileExists(atPath: outURL.path) { try fm.removeItem(at: outURL) }
try fm.copyItem(at: inURL, to: outURL)
let movie = AVMutableMovie(url: outURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
let item = AVMutableMetadataItem()
item.identifier = .quickTimeMetadataContentIdentifier
item.dataType = kCMMetadataBaseDataType_UTF8 as String
item.value = identifier as NSString
let existing = movie.metadata
movie.metadata = existing.filter { $0.identifier != .quickTimeMetadataContentIdentifier } + [item]
try movie.writeHeader(to: outURL, fileType: .mov, options: .addMovieHeaderToDestination)
