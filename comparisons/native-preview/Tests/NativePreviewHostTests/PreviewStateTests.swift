import Foundation
import Testing
@testable import NativePreviewHost

struct PreviewStateTests {
    private func state() throws -> PreviewState {
        try PreviewState(session: PreviewSession(snapshotID: "snapshot-a", backend: "Diagnostic", frameRate: Rational(24_000, 1_001), totalFrames: 3))
    }

    @Test func acknowledgementUpdatesDisplayedFrameOnlyForCurrentSession() throws {
        var value = try state()
        let command = PreviewCommand.seek(sessionID: value.session.id, snapshotID: "snapshot-a", frame: 2)
        try value.request(command)
        try value.acknowledge(PreviewResponse(sessionID: value.session.id, snapshotID: "snapshot-a", displayedFrame: 2, playback: .paused, status: "painted"))
        #expect(value.session.requestedFrame == 2)
        #expect(value.session.acknowledgedFrame == 2)
    }

    @Test func staleSessionDoesNotOverwriteDisplayedFrame() throws {
        var value = try state()
        let response = PreviewResponse(sessionID: UUID(), snapshotID: "snapshot-a", displayedFrame: 1, playback: .paused, status: "painted")
        #expect(throws: PreviewFailure.staleSession) { try value.acknowledge(response) }
        #expect(value.session.acknowledgedFrame == nil)
    }

    @Test func invalidFramesAreRejected() throws {
        var value = try state()
        #expect(throws: PreviewFailure.invalidFrame(3)) { try value.setRequestedFrame(3) }
    }
}
