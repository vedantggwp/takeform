import Foundation

struct PreviewState: Equatable, Sendable {
    private(set) var session: PreviewSession
    private(set) var requestSentAt: ContinuousClock.Instant?
    private(set) var acknowledgementAt: ContinuousClock.Instant?

    init(session: PreviewSession) { self.session = session }

    mutating func request(_ command: PreviewCommand, clock: ContinuousClock = .init()) throws {
        switch command {
        case let .load(sessionID, snapshotID, frame), let .seek(sessionID, snapshotID, frame):
            try validates(sessionID: sessionID, snapshotID: snapshotID, frame: frame)
            session.requestedFrame = frame
        case let .play(sessionID, snapshotID):
            try validates(sessionID: sessionID, snapshotID: snapshotID, frame: nil)
            session.playback = .playing
        case let .pause(sessionID, snapshotID):
            try validates(sessionID: sessionID, snapshotID: snapshotID, frame: nil)
            session.playback = .paused
        }
        session.staleNotice = nil
        session.error = nil
        requestSentAt = clock.now
    }

    mutating func setRequestedFrame(_ frame: Int) throws {
        try session.validates(frame: frame)
        session.requestedFrame = frame
    }

    mutating func acknowledge(_ response: PreviewResponse, clock: ContinuousClock = .init()) throws {
        try validates(sessionID: response.sessionID, snapshotID: response.snapshotID, frame: response.displayedFrame)
        session.acknowledgedFrame = response.displayedFrame
        session.playback = response.playback
        session.staleNotice = response.status == "stale" ? "The page reported a stale preview acknowledgement." : nil
        acknowledgementAt = clock.now
    }

    mutating func fail(_ error: Error) { session.error = error.localizedDescription }

    private func validates(sessionID: UUID, snapshotID: String, frame: Int?) throws {
        guard sessionID == session.id else { throw PreviewFailure.staleSession }
        guard snapshotID == session.snapshotID else { throw PreviewFailure.staleSnapshot }
        if let frame { try session.validates(frame: frame) }
    }
}
