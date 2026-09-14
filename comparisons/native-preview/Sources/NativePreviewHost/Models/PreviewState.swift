import Foundation

struct PreviewLatency: Equatable, Sendable {
    let requestID: UInt64
    let kind: PreviewCommandKind
    let requestSentAt: ContinuousClock.Instant
    let acknowledgementAt: ContinuousClock.Instant
    let duration: Duration

    var milliseconds: Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1_000_000_000_000_000
    }
}

struct PendingPreviewRequest: Equatable, Sendable {
    let command: PreviewCommand
    let sentAt: ContinuousClock.Instant
}

enum AcknowledgementDisposition: Equatable, Sendable { case accepted, stale }

struct PreviewState: Equatable, Sendable {
    private(set) var session: PreviewSession
    private(set) var pendingRequest: PendingPreviewRequest?
    private(set) var lastLatency: PreviewLatency?
    private(set) var acknowledgementStatus: PreviewResponseStatus?

    init(session: PreviewSession) { self.session = session }

    mutating func request(_ command: PreviewCommand, sentAt: ContinuousClock.Instant = ContinuousClock().now) throws {
        try validateCommandIdentity(command)
        switch command {
        case let .load(_, _, _, frame), let .seek(_, _, _, frame):
            try session.validates(frame: frame)
            session.requestedFrame = frame
        case .play, .pause:
            break
        }
        session.staleNotice = nil
        session.error = nil
        pendingRequest = PendingPreviewRequest(command: command, sentAt: sentAt)
    }

    mutating func setRequestedFrame(_ frame: Int) throws {
        try session.validates(frame: frame)
        session.requestedFrame = frame
    }

    mutating func acknowledge(_ response: PreviewResponse, acknowledgedAt: ContinuousClock.Instant = ContinuousClock().now) throws -> AcknowledgementDisposition {
        guard let pending = pendingRequest,
              response.requestID == pending.command.requestID,
              response.sessionID == session.id,
              response.snapshotID == session.snapshotID else {
            session.staleNotice = "Ignored a stale preview acknowledgement."
            return .stale
        }
        try session.validates(frame: response.displayedFrame)
        guard responseMatches(response, command: pending.command) else {
            session.staleNotice = "Ignored a stale preview acknowledgement."
            return .stale
        }
        session.acknowledgedFrame = response.displayedFrame
        session.playback = response.playback
        session.staleNotice = nil
        session.error = nil
        lastLatency = PreviewLatency(requestID: response.requestID, kind: pending.command.kind, requestSentAt: pending.sentAt, acknowledgementAt: acknowledgedAt, duration: pending.sentAt.duration(to: acknowledgedAt))
        acknowledgementStatus = response.status
        pendingRequest = nil
        return .accepted
    }

    mutating func fail(_ error: Error) { session.error = error.localizedDescription }

    private func validateCommandIdentity(_ command: PreviewCommand) throws {
        let identity: (UUID, String)
        switch command {
        case let .load(_, sessionID, snapshotID, _), let .seek(_, sessionID, snapshotID, _), let .play(_, sessionID, snapshotID), let .pause(_, sessionID, snapshotID): identity = (sessionID, snapshotID)
        }
        guard identity.0 == session.id, identity.1 == session.snapshotID else { throw PreviewFailure.malformedResponse }
    }

    private func responseMatches(_ response: PreviewResponse, command: PreviewCommand) -> Bool {
        switch command {
        case let .load(_, _, _, frame), let .seek(_, _, _, frame): response.displayedFrame == frame
        case .play: response.playback == .playing
        case .pause: response.playback == .paused
        }
    }
}
