import Foundation
import AVFoundation
import ProofWire

var cancelled = false
signal(SIGTERM) { _ in cancelled = true }

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let lease = option("--lease") ?? "none"
let seconds = Int(option("--seconds") ?? "5") ?? 5
let fixture = option("--fixture")
let startedAt = Date()

func emit(_ fields: [String: String]) {
    var f = fields
    f["lease"] = lease
    f["pid"] = "\(getpid())"
    f["at"] = Codec.iso.string(from: Date())
    let data = (try? Codec.encoder.encode(f)) ?? Data()
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

let stamp = ProcessProbe.stamp(pid: getpid())
emit(["event": "started", "startSec": "\(stamp?.startSec ?? -1)", "startUsec": "\(stamp?.startUsec ?? -1)", "seconds": "\(seconds)"])

if let path = fixture {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let duration = CMTimeGetSeconds(asset.duration)
    let tracks = asset.tracks.map { "\($0.mediaType.rawValue)" }.joined(separator: ",")
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? -1
    emit(["event": "probed", "durationSeconds": String(format: "%.3f", duration), "tracks": tracks, "bytes": "\(size)", "readable": "\(FileManager.default.isReadableFile(atPath: path))"])
} else {
    emit(["event": "probeSkipped", "reason": "no fixture path"])
}

let deadline = startedAt.addingTimeInterval(Double(seconds))
var lastTick = 0
while Date() < deadline {
    if cancelled {
        emit(["event": "cancelled", "afterMs": String(format: "%.1f", Date().timeIntervalSince(startedAt) * 1000)])
        exit(143)
    }
    let elapsed = Int(Date().timeIntervalSince(startedAt))
    if elapsed > lastTick {
        lastTick = elapsed
        emit(["event": "tick", "elapsedSeconds": "\(elapsed)"])
    }
    usleep(20_000)
}
emit(["event": "completed", "afterMs": String(format: "%.1f", Date().timeIntervalSince(startedAt) * 1000)])
exit(0)
