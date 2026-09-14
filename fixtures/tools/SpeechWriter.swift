import AVFoundation
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
guard let textFile = flag("--text-file"),
      let aiffPath = flag("--output-aiff"),
      let receiptPath = flag("--output-audio-receipt") else {
    fputs("usage: SpeechWriter --text-file txt --output-aiff aiff --output-audio-receipt json\n", stderr)
    exit(2)
}

final class Job: NSObject {
    let text: String
    let aiff: URL
    let receiptURL: URL
    let synth = AVSpeechSynthesizer()
    let state = DispatchQueue(label: "fixtures.speech-writer.state")
    var file: AVAudioFile?
    var sampleRate = 0.0
    var utterances: [[String: Any]] = []
    var utteranceStarts: [Int: AVAudioFramePosition] = [:]
    var completedUtterances = Set<Int>()
    var finished = false
    var failure: Error?

    init(text: String, aiff: URL, receiptURL: URL) {
        self.text = text
        self.aiff = aiff
        self.receiptURL = receiptURL
        super.init()
    }

    func run() {
        do {
            try FileManager.default.removeItem(at: aiff)
        } catch CocoaError.fileNoSuchFile {
        } catch {
            fail(error)
        }
        speak(Self.parts(text), 0)
        while !isFinished() {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if let failure = currentFailure() {
            fputs("\(failure)\n", stderr)
            exit(1)
        }
    }

    static func parts(_ raw: String) -> [(String, String)] {
        let re = try! NSRegularExpression(pattern: "\\[PAUSE:([0-9.]+)\\]")
        let ns = raw as NSString
        var out: [(String, String)] = []
        var cursor = 0
        for match in re.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                let chunk = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !chunk.isEmpty { out.append(("speak", chunk)) }
            }
            out.append(("pause", ns.substring(with: match.range(at: 1))))
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            let chunk = ns.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { out.append(("speak", chunk)) }
        }
        return out
    }

    func speak(_ parts: [(String, String)], _ index: Int) {
        if index >= parts.count {
            finish()
            return
        }
        let (kind, value) = parts[index]
        if kind == "pause" {
            do {
                try silence(Double(value) ?? 2)
                speak(parts, index + 1)
            } catch {
                fail(error)
            }
            return
        }
        let utterance = AVSpeechUtterance(string: value)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synth.write(utterance) { [weak self] buffer in
            guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                if self.completeUtterance(utterance, index: index) {
                    DispatchQueue.main.async { self.speak(parts, index + 1) }
                }
                return
            }
            do {
                try self.append(pcm, utterance: utterance, index: index)
            } catch {
                self.fail(error)
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, utterance: AVSpeechUtterance, index: Int) throws {
        try state.sync {
            guard failure == nil else { return }
            if file == nil {
                sampleRate = buffer.format.sampleRate
                guard sampleRate > 0 else {
                    throw NSError(domain: "SpeechWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "speech buffer has no sample rate"])
                }
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: buffer.format.channelCount,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: true,
                    AVLinearPCMIsNonInterleaved: false
                ]
                file = try AVAudioFile(
                    forWriting: aiff,
                    settings: settings,
                    commonFormat: buffer.format.commonFormat,
                    interleaved: buffer.format.isInterleaved
                )
            }
            guard let file else {
                throw NSError(domain: "SpeechWriter", code: 2, userInfo: [NSLocalizedDescriptionKey: "speech output file is unavailable"])
            }
            if utteranceStarts[index] == nil { utteranceStarts[index] = file.framePosition }
            let start = file.framePosition
            try file.write(from: buffer)
            guard file.framePosition - start == AVAudioFramePosition(buffer.frameLength) else {
                throw NSError(domain: "SpeechWriter", code: 3, userInfo: [NSLocalizedDescriptionKey: "speech write did not advance by its buffer length"])
            }
        }
    }

    func completeUtterance(_ utterance: AVSpeechUtterance, index: Int) -> Bool {
        state.sync {
            guard !completedUtterances.contains(index) else { return false }
            completedUtterances.insert(index)
            guard let start = utteranceStarts[index], let file else {
                failLocked("speech utterance completed without audio")
                return false
            }
            utterances.append([
                "id": "utterance-\(index)",
                "text": utterance.speechString,
                "startFrame": start,
                "endFrame": file.framePosition,
                "sampleRate": sampleRate
            ])
            return true
        }
    }

    func silence(_ seconds: Double) throws {
        try state.sync {
            guard let file, seconds > 0 else { return }
            let frames = AVAudioFrameCount((seconds * sampleRate).rounded())
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
                throw NSError(domain: "SpeechWriter", code: 4, userInfo: [NSLocalizedDescriptionKey: "could not allocate a silence buffer"])
            }
            buffer.frameLength = frames
            let channels = Int(file.processingFormat.channelCount)
            if let samples = buffer.floatChannelData {
                for channel in 0..<channels { samples[channel].initialize(repeating: 0, count: Int(frames)) }
            } else if let samples = buffer.int16ChannelData {
                for channel in 0..<channels { samples[channel].initialize(repeating: 0, count: Int(frames)) }
            } else {
                throw NSError(domain: "SpeechWriter", code: 5, userInfo: [NSLocalizedDescriptionKey: "silence buffer uses an unsupported sample format"])
            }
            let start = file.framePosition
            try file.write(from: buffer)
            guard file.framePosition - start == AVAudioFramePosition(frames) else {
                throw NSError(domain: "SpeechWriter", code: 6, userInfo: [NSLocalizedDescriptionKey: "silence write did not advance by its buffer length"])
            }
        }
    }

    func finish() {
        state.sync {
            guard !finished else { return }
            defer { finished = true }
            guard failure == nil, let file else {
                if failure == nil { failLocked("speech synthesis produced no audio") }
                return
            }
            let writtenFrames = file.framePosition
            let finalizedFrames = file.length
            guard writtenFrames == finalizedFrames else {
                failLocked("speech output position does not equal final file length")
                return
            }
            let expectedUtteranceCount = Self.parts(text).filter { $0.0 == "speak" }.count
            guard utterances.count == expectedUtteranceCount else {
                failLocked("speech synthesis did not complete every utterance")
                return
            }
            self.file = nil
            let receipt: [String: Any] = [
                "origin": "AVSpeechSynthesizer buffer write",
                "sampleRate": sampleRate,
                "durationSeconds": Double(finalizedFrames) / sampleRate,
                "writtenFrames": writtenFrames,
                "finalizedFrames": finalizedFrames,
                "utterances": utterances
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: receiptURL)
            } catch {
                failure = error
            }
        }
    }

    func fail(_ error: Error) {
        state.sync {
            if failure == nil { failure = error }
            finished = true
        }
    }

    func failLocked(_ message: String) {
        if failure == nil {
            failure = NSError(domain: "SpeechWriter", code: 7, userInfo: [NSLocalizedDescriptionKey: message])
        }
        finished = true
    }

    func isFinished() -> Bool { state.sync { finished } }
    func currentFailure() -> Error? { state.sync { failure } }
}

let text = try String(contentsOf: URL(fileURLWithPath: textFile), encoding: .utf8)
Job(text: text, aiff: URL(fileURLWithPath: aiffPath), receiptURL: URL(fileURLWithPath: receiptPath)).run()
