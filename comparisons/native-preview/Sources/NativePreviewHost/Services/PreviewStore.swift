import Foundation
import Observation

@Observable
@MainActor
final class PreviewStore {
    typealias HelperFactory = @MainActor (URL?, URL?, URL?) throws -> any LoopbackServing

    var state: PreviewState
    var helperStatus = "Choose a local bundle and Node executable to load a renderer page."
    var origin: URL?
    var nodeURL: URL?
    var bundleRoot: URL?
    var fixtureRoot: URL?
    var selectedPage = "diagnostic"
    var pendingCommand: PreviewCommand?
    var commandVersion = 0
    private var nextRequestID: UInt64 = 0
    private var helperGeneration: UInt64 = 0
    private var helper: (any LoopbackServing)?
    private let helperFactory: HelperFactory

    init(session: PreviewSession, helperFactory: @escaping HelperFactory = { try LoopbackHelper(nodeURL: $0, bundleRoot: $1, fixtureRoot: $2) }) {
        state = PreviewState(session: session)
        self.helperFactory = helperFactory
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
    var expectedPagePath: String { selectedPage == "diagnostic" ? "/diagnostic.html" : "/bundle/index.html" }

    func isExpectedMainDocument(_ url: URL?) -> Bool {
        guard let url, let origin else { return false }
        return url.scheme == origin.scheme && url.host == origin.host && url.port == origin.port && url.path == expectedPagePath
    }

    func startDiagnostic() {
        helperGeneration &+= 1
        let generation = helperGeneration
        let previous = helper
        helper = nil
        origin = nil
        helperStatus = "Starting the owned loopback helper."
        Task {
            if let previous { await previous.stop() }
            guard generation == helperGeneration else { return }
            do {
                let replacement = try helperFactory(nodeURL, bundleRoot, fixtureRoot)
                helper = replacement
                replacement.onUnexpectedExit = { [weak self, weak replacement] status in
                    guard let self, let replacement, generation == self.helperGeneration, self.helper === replacement else { return }
                    self.origin = nil
                    self.helper = nil
                    self.helperStatus = "The loopback helper exited unexpectedly with status \(status)."
                }
                replacement.start { [weak self, weak replacement] origin, error in
                    guard let self, let replacement, generation == self.helperGeneration, self.helper === replacement else { return }
                    if let origin {
                        self.origin = origin
                        self.helperStatus = "Loopback helper ready. Waiting for the selected page acknowledgement."
                    } else {
                        self.helperStatus = error ?? "The loopback helper did not start."
                        self.helper = nil
                    }
                }
            } catch { helperStatus = error.localizedDescription }
        }
    }

    func stopHelper() {
        helperGeneration &+= 1
        let previous = helper
        helper = nil
        origin = nil
        helperStatus = "Loopback helper stopped."
        Task { if let previous { await previous.stop() } }
    }

    func stopHelperForApplicationTermination() {
        helperGeneration &+= 1
        helper?.stopForApplicationTermination()
        helper = nil
        origin = nil
    }

    private func requestID() -> UInt64 {
        nextRequestID &+= 1
        return nextRequestID
    }

    func commandForRequestedFrame(load: Bool = false) -> PreviewCommand {
        load
            ? .load(requestID: requestID(), sessionID: session.id, snapshotID: session.snapshotID, frame: session.requestedFrame)
            : .seek(requestID: requestID(), sessionID: session.id, snapshotID: session.snapshotID, frame: session.requestedFrame)
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
        do {
            if try state.acknowledge(response) == .accepted, state.lastLatency?.kind == .load {
                helperStatus = "Selected page acknowledged its first frame."
            }
        } catch { state.fail(error) }
    }

    func play() { markSent(.play(requestID: requestID(), sessionID: session.id, snapshotID: session.snapshotID)) }
    func pause() { markSent(.pause(requestID: requestID(), sessionID: session.id, snapshotID: session.snapshotID)) }
}
