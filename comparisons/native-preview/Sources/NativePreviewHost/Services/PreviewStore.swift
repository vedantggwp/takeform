import Foundation
import Observation

@Observable
@MainActor
final class PreviewStore {
    var state: PreviewState
    var helperStatus = "Choose a local bundle and Node executable to load a renderer page."
    var origin: URL?
    var nodeURL: URL?
    var bundleRoot: URL?
    var fixtureRoot: URL?
    var selectedPage = "diagnostic"
    var pendingCommand: PreviewCommand?
    var commandVersion = 0
    private var helper: LoopbackHelper?

    init(session: PreviewSession) {
        state = PreviewState(session: session)
        let environment = ProcessInfo.processInfo.environment
        nodeURL = environment["TAKEFORM_NODE"].map(URL.init(fileURLWithPath:))
        bundleRoot = environment["TAKEFORM_BUNDLE_ROOT"].map(URL.init(fileURLWithPath:))
        fixtureRoot = environment["TAKEFORM_FIXTURE_ROOT"].map(URL.init(fileURLWithPath:))
    }

    static func diagnostic() -> PreviewStore {
        let rate = try! Rational(24_000, 1_001)
        return PreviewStore(session: try! PreviewSession(snapshotID: "diagnostic-v1", backend: "Diagnostic", frameRate: rate, totalFrames: 240))
    }

    var session: PreviewSession { state.session }

    func startDiagnostic() {
        do {
            let helper = try LoopbackHelper(nodeURL: nodeURL, bundleRoot: bundleRoot, fixtureRoot: fixtureRoot)
            self.helper = helper
            helper.start { [weak self] origin, error in
                if let origin {
                    self?.origin = origin
                    self?.helperStatus = "Diagnostic page loaded from the owned loopback origin. This is not renderer proof."
                } else {
                    self?.helperStatus = error ?? "The loopback helper did not start."
                }
            }
        } catch { helperStatus = error.localizedDescription }
    }

    func stopHelper() { helper?.stop(); helper = nil; origin = nil }

    func commandForRequestedFrame(load: Bool = false) -> PreviewCommand {
        load
            ? .load(sessionID: session.id, snapshotID: session.snapshotID, frame: session.requestedFrame)
            : .seek(sessionID: session.id, snapshotID: session.snapshotID, frame: session.requestedFrame)
    }

    func setRequestedFrame(_ frame: Int) {
        do { try state.setRequestedFrame(frame) } catch { state.fail(error) }
    }

    func markSent(_ command: PreviewCommand) {
        do {
            try state.request(command)
            pendingCommand = command
            commandVersion += 1
        } catch { state.fail(error) }
    }

    func acknowledge(_ response: PreviewResponse) {
        do { try state.acknowledge(response) } catch { state.fail(error) }
    }

    func play() { markSent(.play(sessionID: session.id, snapshotID: session.snapshotID)) }
    func pause() { markSent(.pause(sessionID: session.id, snapshotID: session.snapshotID)) }
}
