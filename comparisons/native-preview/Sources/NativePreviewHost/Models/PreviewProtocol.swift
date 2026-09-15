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
enum PreviewResponseStatus: String, Codable, Sendable { case painted, decoded, rendered }
enum PreviewCommandKind: String, Codable, Sendable { case load, seek, play, pause }

enum PreviewFailure: Error, Equatable, LocalizedError, Sendable {
    case invalidFrameRate
    case invalidFrame(Int)
    case malformedResponse
    case helperUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidFrameRate: "Frame rate must be a positive rational value."
        case .invalidFrame(let frame): "Frame \(frame) is outside this snapshot."
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
        guard !snapshotID.isEmpty, !backend.isEmpty, totalFrames > 0, requestedFrame >= 0, requestedFrame < totalFrames else { throw PreviewFailure.invalidFrame(requestedFrame) }
        self.id = UUID()
        self.snapshotID = snapshotID
        self.backend = backend
        self.frameRate = frameRate
        self.totalFrames = totalFrames
        self.requestedFrame = requestedFrame
        acknowledgedFrame = nil
        playback = .paused
        staleNotice = nil
        error = nil
    }

    func validates(frame: Int) throws {
        guard (0..<totalFrames).contains(frame) else { throw PreviewFailure.invalidFrame(frame) }
    }
}

enum PreviewCommand: Codable, Equatable, Sendable {
    case load(requestID: UInt64, sessionID: UUID, snapshotID: String, frame: Int)
    case seek(requestID: UInt64, sessionID: UUID, snapshotID: String, frame: Int)
    case play(requestID: UInt64, sessionID: UUID, snapshotID: String)
    case pause(requestID: UInt64, sessionID: UUID, snapshotID: String)

    enum CodingKeys: String, CodingKey { case type, requestID, sessionID, snapshotID, frame }

    var requestID: UInt64 {
        switch self {
        case .load(let id, _, _, _), .seek(let id, _, _, _), .play(let id, _, _), .pause(let id, _, _): id
        }
    }

    var kind: PreviewCommandKind {
        switch self {
        case .load: .load
        case .seek: .seek
        case .play: .play
        case .pause: .pause
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(PreviewCommandKind.self, forKey: .type)
        let requestID = try container.decode(UInt64.self, forKey: .requestID)
        let sessionID = try container.decode(UUID.self, forKey: .sessionID)
        let snapshotID = try container.decode(String.self, forKey: .snapshotID)
        switch kind {
        case .load: self = .load(requestID: requestID, sessionID: sessionID, snapshotID: snapshotID, frame: try container.decode(Int.self, forKey: .frame))
        case .seek: self = .seek(requestID: requestID, sessionID: sessionID, snapshotID: snapshotID, frame: try container.decode(Int.self, forKey: .frame))
        case .play: self = .play(requestID: requestID, sessionID: sessionID, snapshotID: snapshotID)
        case .pause: self = .pause(requestID: requestID, sessionID: sessionID, snapshotID: snapshotID)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)
        try container.encode(requestID, forKey: .requestID)
        switch self {
        case let .load(_, sessionID, snapshotID, frame), let .seek(_, sessionID, snapshotID, frame):
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(snapshotID, forKey: .snapshotID)
            try container.encode(frame, forKey: .frame)
        case let .play(_, sessionID, snapshotID), let .pause(_, sessionID, snapshotID):
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(snapshotID, forKey: .snapshotID)
        }
    }
}

struct PreviewResponse: Codable, Equatable, Sendable {
    let requestID: UInt64
    let sessionID: UUID
    let snapshotID: String
    let displayedFrame: Int
    let playback: PlaybackState
    let status: PreviewResponseStatus
}
