import Foundation

struct Rational: Codable, Equatable, Sendable {
    let numerator: Int
    let denominator: Int

    init(_ numerator: Int, _ denominator: Int) throws {
        guard numerator > 0, denominator > 0 else { throw PreviewFailure.invalidFrameRate }
        self.numerator = numerator
        self.denominator = denominator
    }

    var secondsPerFrame: Double { Double(denominator) / Double(numerator) }
}

enum PlaybackState: String, Codable, Sendable { case paused, playing }

enum PreviewFailure: Error, Equatable, LocalizedError, Sendable {
    case invalidFrameRate
    case invalidFrame(Int)
    case staleSession
    case staleSnapshot
    case malformedResponse
    case helperUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidFrameRate: "Frame rate must be a positive rational value."
        case .invalidFrame(let frame): "Frame \(frame) is outside this snapshot."
        case .staleSession: "The page acknowledged a different preview session."
        case .staleSnapshot: "The page acknowledged an older snapshot."
        case .malformedResponse: "The page returned an invalid preview acknowledgement."
        case .helperUnavailable(let message): message
        }
    }
}

struct PreviewSession: Codable, Equatable, Sendable {
    let id: UUID
    let snapshotID: String
    let backend: String
    let frameRate: Rational
    let totalFrames: Int
    var requestedFrame: Int
    var acknowledgedFrame: Int?
    var playback: PlaybackState
    var staleNotice: String?
    var error: String?

    init(snapshotID: String, backend: String, frameRate: Rational, totalFrames: Int, requestedFrame: Int = 0) throws {
        guard !snapshotID.isEmpty, !backend.isEmpty, totalFrames > 0, requestedFrame >= 0, requestedFrame < totalFrames else {
            throw PreviewFailure.invalidFrame(requestedFrame)
        }
        self.id = UUID()
        self.snapshotID = snapshotID
        self.backend = backend
        self.frameRate = frameRate
        self.totalFrames = totalFrames
        self.requestedFrame = requestedFrame
        self.acknowledgedFrame = nil
        self.playback = .paused
        self.staleNotice = nil
        self.error = nil
    }

    func validates(frame: Int) throws {
        guard (0..<totalFrames).contains(frame) else { throw PreviewFailure.invalidFrame(frame) }
    }
}

enum PreviewCommand: Codable, Equatable, Sendable {
    case load(sessionID: UUID, snapshotID: String, frame: Int)
    case seek(sessionID: UUID, snapshotID: String, frame: Int)
    case play(sessionID: UUID, snapshotID: String)
    case pause(sessionID: UUID, snapshotID: String)

    enum CodingKeys: String, CodingKey { case type, sessionID, snapshotID, frame }
    enum Kind: String, Codable { case load, seek, play, pause }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        let sessionID = try container.decode(UUID.self, forKey: .sessionID)
        let snapshotID = try container.decode(String.self, forKey: .snapshotID)
        switch kind {
        case .load: self = .load(sessionID: sessionID, snapshotID: snapshotID, frame: try container.decode(Int.self, forKey: .frame))
        case .seek: self = .seek(sessionID: sessionID, snapshotID: snapshotID, frame: try container.decode(Int.self, forKey: .frame))
        case .play: self = .play(sessionID: sessionID, snapshotID: snapshotID)
        case .pause: self = .pause(sessionID: sessionID, snapshotID: snapshotID)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .load(sessionID, snapshotID, frame):
            try container.encode(Kind.load, forKey: .type); try container.encode(sessionID, forKey: .sessionID); try container.encode(snapshotID, forKey: .snapshotID); try container.encode(frame, forKey: .frame)
        case let .seek(sessionID, snapshotID, frame):
            try container.encode(Kind.seek, forKey: .type); try container.encode(sessionID, forKey: .sessionID); try container.encode(snapshotID, forKey: .snapshotID); try container.encode(frame, forKey: .frame)
        case let .play(sessionID, snapshotID):
            try container.encode(Kind.play, forKey: .type); try container.encode(sessionID, forKey: .sessionID); try container.encode(snapshotID, forKey: .snapshotID)
        case let .pause(sessionID, snapshotID):
            try container.encode(Kind.pause, forKey: .type); try container.encode(sessionID, forKey: .sessionID); try container.encode(snapshotID, forKey: .snapshotID)
        }
    }
}

struct PreviewResponse: Codable, Equatable, Sendable {
    let sessionID: UUID
    let snapshotID: String
    let displayedFrame: Int
    let playback: PlaybackState
    let status: String
}
