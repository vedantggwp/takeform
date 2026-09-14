import Foundation
import AVFoundation

let args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
guard let textFile = flag("--text-file"),
      let aiffPath = flag("--output-aiff"),
      let wordsPath = flag("--output-words") else {
    fputs("usage: SpeechWriter --text-file txt --output-aiff aiff --output-words json\n", stderr)
    exit(2)
}

final class Job: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    let text: String
    let aiff: URL
    let wordsURL: URL
    let synth = AVSpeechSynthesizer()
    var file: AVAudioFile?
    var sampleRate = 22050.0
    var frames: AVAudioFramePosition = 0
    var pending: [(String, Double, NSRange)] = []
    var finished = false
    var error: Error?

    init(text: String, aiff: URL, wordsURL: URL) {
        self.text = text
        self.aiff = aiff
        self.wordsURL = wordsURL
        super.init()
        synth.delegate = self
    }

    func run() {
        try? FileManager.default.removeItem(at: aiff)
        speak(Self.parts(text), 0)
        while !finished { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        if let error { fputs("\(error)\n", stderr); exit(1) }
    }

    static func parts(_ raw: String) -> [(String, String)] {
        let re = try! NSRegularExpression(pattern: "\\[PAUSE:([0-9.]+)\\]")
        let ns = raw as NSString
        var out: [(String, String)] = []
        var cursor = 0
        for m in re.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                let chunk = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !chunk.isEmpty { out.append(("speak", chunk)) }
            }
            out.append(("pause", ns.substring(with: m.range(at: 1))))
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            let chunk = ns.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { out.append(("speak", chunk)) }
        }
        return out
    }

    func speak(_ parts: [(String, String)], _ i: Int) {
        if i >= parts.count { finish(); return }
        let (kind, value) = parts[i]
        if kind == "pause" {
            silence(Double(value) ?? 2)
            speak(parts, i + 1)
            return
        }
        let u = AVSpeechUtterance(string: value)
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        synth.write(u) { [weak self] buffer in
            guard let self else { return }
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                DispatchQueue.main.async { self.speak(parts, i + 1) }
                return
            }
            do { try self.append(pcm) } catch { self.error = error; self.finished = true }
        }
    }

    func append(_ buffer: AVAudioBuffer) throws {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if file == nil {
            sampleRate = pcm.format.sampleRate
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: pcm.format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: true,
                AVLinearPCMIsNonInterleaved: false
            ]
            file = try AVAudioFile(forWriting: aiff, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        }
        try file?.write(from: pcm)
        frames += AVAudioFramePosition(pcm.frameLength)
    }

    func silence(_ seconds: Double) {
        guard let file, seconds > 0 else { return }
        let n = AVAudioFrameCount(seconds * sampleRate)
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n) else { return }
        buf.frameLength = n
        if let ch = buf.int16ChannelData {
            for i in 0..<(Int(n) * Int(file.processingFormat.channelCount)) { ch[0][i] = 0 }
        }
        try? file.write(from: buf)
        frames += AVAudioFramePosition(n)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let start = Double(frames) / max(sampleRate, 1)
        let word = (utterance.speechString as NSString).substring(with: characterRange)
        pending.append((word, start, characterRange))
    }

    func finish() {
        file = nil
        let duration = Double(frames) / max(sampleRate, 1)
        var words: [[String: Any]] = []
        for (i, w) in pending.enumerated() {
            let end = i + 1 < pending.count ? pending[i + 1].1 : duration
            words.append([
                "index": i,
                "text": w.0,
                "sourceStartSeconds": w.1,
                "sourceEndSeconds": max(end, w.1),
                "characterRange": ["location": w.2.location, "length": w.2.length]
            ])
        }
        let receipt: [String: Any] = [
            "origin": "AVSpeechSynthesizer.willSpeakRangeOfSpeechString",
            "isHumanGroundTruth": false,
            "sampleRate": sampleRate,
            "durationSeconds": duration,
            "wordCount": words.count,
            "words": words
        ]
        let data = try! JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: wordsURL)
        if words.isEmpty { fputs("warning: no word-boundary callbacks fired\n", stderr) }
        finished = true
    }
}

let text = try String(contentsOf: URL(fileURLWithPath: textFile), encoding: .utf8)
Job(text: text, aiff: URL(fileURLWithPath: aiffPath), wordsURL: URL(fileURLWithPath: wordsPath)).run()
