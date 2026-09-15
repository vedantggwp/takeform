import Foundation
import Testing
@testable import NativePreviewHost

struct PreviewStateTests {
    private func state() throws -> PreviewState {
        try PreviewState(session: PreviewSession(snapshotID: "snapshot-a", backend: "Diagnostic", frameRate: Rational(24_000, 1_001), totalFrames: 3))
    }

    @Test func matchingAcknowledgementUpdatesDisplayedFrameAndLatency() throws {
        var value = try state()
        let clock = ContinuousClock()
        let sent = clock.now
        let command = PreviewCommand.seek(requestID: 1, sessionID: value.session.id, snapshotID: "snapshot-a", frame: 2)
        try value.request(command, sentAt: sent)
        let disposition = try value.acknowledge(PreviewResponse(requestID: 1, sessionID: value.session.id, snapshotID: "snapshot-a", displayedFrame: 2, playback: .paused, status: .painted), acknowledgedAt: sent.advanced(by: .milliseconds(25)))
        #expect(disposition == .accepted)
        #expect(value.session.acknowledgedFrame == 2)
        #expect(value.lastLatency?.milliseconds == 25)
    }

    @Test func supersededSeekAcknowledgementIsStale() throws {
        var value = try state()
        try value.request(.seek(requestID: 1, sessionID: value.session.id, snapshotID: "snapshot-a", frame: 1))
        try value.request(.seek(requestID: 2, sessionID: value.session.id, snapshotID: "snapshot-a", frame: 2))
        let disposition = try value.acknowledge(PreviewResponse(requestID: 1, sessionID: value.session.id, snapshotID: "snapshot-a", displayedFrame: 1, playback: .paused, status: .painted))
        #expect(disposition == .stale)
        #expect(value.session.requestedFrame == 2)
        #expect(value.session.acknowledgedFrame == nil)
        #expect(value.session.staleNotice != nil)
    }

    @Test func playbackChangesOnlyAfterExactAcknowledgement() throws {
        var value = try state()
        try value.request(.play(requestID: 7, sessionID: value.session.id, snapshotID: "snapshot-a"))
        #expect(value.session.playback == .paused)
        let stale = try value.acknowledge(PreviewResponse(requestID: 6, sessionID: value.session.id, snapshotID: "snapshot-a", displayedFrame: 0, playback: .playing, status: .painted))
        #expect(stale == .stale)
        #expect(value.session.playback == .paused)
        let accepted = try value.acknowledge(PreviewResponse(requestID: 7, sessionID: value.session.id, snapshotID: "snapshot-a", displayedFrame: 0, playback: .playing, status: .painted))
        #expect(accepted == .accepted)
        #expect(value.session.playback == .playing)
    }

    @Test func responseStatusIsClosedAndFramesAreBounded() throws {
        let session = try state().session
        let json = "{\"requestID\":1,\"sessionID\":\"\(session.id.uuidString)\",\"snapshotID\":\"snapshot-a\",\"displayedFrame\":0,\"playback\":\"paused\",\"status\":\"unknown\"}"
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(PreviewResponse.self, from: Data(json.utf8)) }
        var value = PreviewState(session: session)
        #expect(throws: PreviewFailure.invalidFrame(3)) { try value.setRequestedFrame(3) }
    }
}

@MainActor
final class FakeLoopbackHelper: LoopbackServing {
    var onUnexpectedExit: (@MainActor @Sendable (Int32) -> Void)?
    var completion: (@MainActor @Sendable (URL?, String?) -> Void)?
    var stopCount = 0
    var terminationStopCount = 0

    func start(completion: @escaping @MainActor @Sendable (URL?, String?) -> Void) { self.completion = completion }
    func stop() async { stopCount += 1 }
    func stopForApplicationTermination() { terminationStopCount += 1 }
}

@Suite @MainActor
struct PreviewStoreLifecycleTests {
    @Test func expectedMainDocumentIsBoundToSelectionAndOrigin() throws {
        let session = try PreviewSession(snapshotID: "snapshot-a", backend: "Diagnostic", frameRate: Rational(30, 1), totalFrames: 3)
        let store = PreviewStore(session: session)
        store.origin = URL(string: "http://127.0.0.1:8000/")
        #expect(store.isExpectedMainDocument(URL(string: "http://127.0.0.1:8000/diagnostic.html")))
        #expect(!store.isExpectedMainDocument(URL(string: "http://127.0.0.1:8000/fixtures/page.html")))
        #expect(!store.isExpectedMainDocument(URL(string: "http://127.0.0.1:8001/diagnostic.html")))
        store.selectedPage = "bundle"
        #expect(store.isExpectedMainDocument(URL(string: "http://127.0.0.1:8000/bundle/index.html")))
        #expect(!store.isExpectedMainDocument(URL(string: "http://127.0.0.1:8000/diagnostic.html")))
    }

    @Test func acknowledgementLogRecordsAcceptedCurrentRequestThenStaleSupersededRequest() throws {
        let session = try PreviewSession(snapshotID: "snapshot-a", backend: "Diagnostic", frameRate: Rational(30, 1), totalFrames: 3)
        let store = PreviewStore(session: session)
        store.markSent(.seek(requestID: 1, sessionID: session.id, snapshotID: session.snapshotID, frame: 1))
        store.markSent(.seek(requestID: 2, sessionID: session.id, snapshotID: session.snapshotID, frame: 2))
        store.acknowledge(PreviewResponse(requestID: 2, sessionID: session.id, snapshotID: session.snapshotID, displayedFrame: 2, playback: .paused, status: .painted))
        store.acknowledge(PreviewResponse(requestID: 1, sessionID: session.id, snapshotID: session.snapshotID, displayedFrame: 1, playback: .paused, status: .painted))
        #expect(store.session.acknowledgedFrame == 2)
        #expect(store.acknowledgementLog == ["#2 accepted", "#1 stale"])
    }

    @Test func rapidReplacementStopsOldHelperAndIgnoresStaleReadiness() async throws {
        var helpers: [FakeLoopbackHelper] = []
        let session = try PreviewSession(snapshotID: "snapshot-a", backend: "Diagnostic", frameRate: Rational(30, 1), totalFrames: 3)
        let store = PreviewStore(session: session) { _, _, _ in
            let helper = FakeLoopbackHelper()
            helpers.append(helper)
            return helper
        }
        store.startDiagnostic()
        await Task.yield()
        #expect(helpers.count == 1)
        let first = helpers[0]
        store.startDiagnostic()
        await Task.yield()
        await Task.yield()
        #expect(first.stopCount == 1)
        #expect(helpers.count == 2)
        let second = helpers[1]
        first.completion?(URL(string: "http://127.0.0.1:1001/"), nil)
        #expect(store.origin == nil)
        second.completion?(URL(string: "http://127.0.0.1:1002/"), nil)
        #expect(store.origin?.port == 1002)
        second.onUnexpectedExit?(9)
        #expect(store.origin == nil)
        #expect(store.helperStatus.contains("status 9"))
        store.startDiagnostic()
        await Task.yield()
        let third = helpers[2]
        store.stopHelper()
        await Task.yield()
        #expect(third.stopCount == 1)
        #expect(store.origin == nil)

        store.startDiagnostic()
        await Task.yield()
        let fourth = helpers[3]
        store.stopHelperForApplicationTermination()
        #expect(fourth.terminationStopCount == 1)
    }

    @Test func silentExecutableExitCompletesWithActionableError() async throws {
        let helper = try LoopbackHelper(nodeURL: URL(fileURLWithPath: "/usr/bin/false"), bundleRoot: nil, fixtureRoot: nil)
        var results: [(URL?, String?)] = []
        helper.start { results.append(($0, $1)) }
        for _ in 0..<20 where results.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(results.count == 1)
        #expect(results.first?.0 == nil)
        #expect(results.first?.1?.contains("exited") == true)
        await helper.stop()
    }

    @Test func truncatedReadinessCompletesExactlyOnce() async throws {
        let script = FileManager.default.temporaryDirectory.appending(path: "preview-truncated-\(UUID().uuidString).sh")
        try "printf '{\"status\":'".write(to: script, atomically: true, encoding: .utf8)
        let helper = try LoopbackHelper(nodeURL: URL(fileURLWithPath: "/bin/sh"), bundleRoot: nil, fixtureRoot: nil, helperURL: script)
        var results: [(URL?, String?)] = []
        helper.start { results.append(($0, $1)) }
        for _ in 0..<20 where results.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(results.count == 1)
        #expect(results.first?.1?.contains("truncated") == true)
        await helper.stop()
    }
}
