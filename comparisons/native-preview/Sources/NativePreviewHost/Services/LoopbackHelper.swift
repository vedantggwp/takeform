import Darwin
import Foundation

@MainActor
protocol LoopbackServing: AnyObject {
    var onUnexpectedExit: (@MainActor @Sendable (Int32) -> Void)? { get set }
    func start(completion: @escaping @MainActor @Sendable (URL?, String?) -> Void)
    func stop() async
    func stopForApplicationTermination()
}

@MainActor
final class LoopbackHelper: LoopbackServing {
    var onUnexpectedExit: (@MainActor @Sendable (Int32) -> Void)?
    private let process = Process()
    private let output = Pipe()
    private let nodeURL: URL
    private let bundleRoot: URL?
    private let fixtureRoot: URL?
    private let helperURL: URL?
    private var readinessBuffer = Data()
    private var startupCompletion: (@MainActor @Sendable (URL?, String?) -> Void)?
    private var startupTimeout: Task<Void, Never>?
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []
    private var started = false
    private var stopped = false
    private var becameReady = false

    init(nodeURL: URL?, bundleRoot: URL?, fixtureRoot: URL?, helperURL: URL? = nil) throws {
        guard let nodeURL else { throw PreviewFailure.helperUnavailable("Node is required. Set TAKEFORM_NODE or choose a Node executable.") }
        guard FileManager.default.isExecutableFile(atPath: nodeURL.path) else { throw PreviewFailure.helperUnavailable("The selected Node executable cannot run.") }
        self.nodeURL = nodeURL
        self.bundleRoot = bundleRoot
        self.fixtureRoot = fixtureRoot
        self.helperURL = helperURL
    }

    func start(completion: @escaping @MainActor @Sendable (URL?, String?) -> Void) {
        guard !started else {
            completion(nil, "The loopback helper was already started.")
            return
        }
        started = true
        startupCompletion = completion
        guard let helperURL = helperURL ?? Bundle.module.url(forResource: "preview-helper", withExtension: "mjs") else {
            completeStartup(origin: nil, error: "The bundled loopback helper is missing.")
            return
        }
        process.executableURL = nodeURL
        var arguments = [helperURL.path, "--port", "0"]
        if let bundleRoot { arguments += ["--bundle-root", bundleRoot.path] }
        if let fixtureRoot { arguments += ["--fixture-root", fixtureRoot.path] }
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in self?.didTerminate(status: process.terminationStatus) }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                if data.isEmpty { self?.reachedEOF() }
                else { self?.consume(data) }
            }
        }
        do {
            try process.run()
            startupTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.startupCompletion != nil else { return }
                self.completeStartup(origin: nil, error: "The loopback helper did not become ready within five seconds.")
                await self.stop()
            }
        } catch {
            completeStartup(origin: nil, error: error.localizedDescription)
        }
    }

    func stop() async {
        stopped = true
        onUnexpectedExit = nil
        completeStartup(origin: nil, error: "The loopback helper stopped before it became ready.")
        output.fileHandleForReading.readabilityHandler = nil
        guard process.isRunning else { return }
        await withCheckedContinuation { continuation in
            terminationWaiters.append(continuation)
            process.terminate()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.process.isRunning else { return }
                kill(self.process.processIdentifier, SIGKILL)
            }
        }
    }

    func stopForApplicationTermination() {
        stopped = true
        onUnexpectedExit = nil
        startupTimeout?.cancel()
        startupTimeout = nil
        startupCompletion = nil
        output.fileHandleForReading.readabilityHandler = nil
        guard process.isRunning else { return }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        process.terminate()
        if exited.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    private func consume(_ data: Data) {
        guard startupCompletion != nil else { return }
        readinessBuffer.append(data)
        while let newline = readinessBuffer.firstIndex(of: 0x0A) {
            let line = readinessBuffer[..<newline]
            readinessBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let payload = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                completeStartup(origin: nil, error: "The loopback helper returned malformed readiness data.")
                Task { await stop() }
                return
            }
            if payload["status"] as? String == "ready", let port = payload["port"] as? Int, (1...65_535).contains(port) {
                becameReady = true
                completeStartup(origin: URL(string: "http://127.0.0.1:\(port)/"), error: nil)
            } else {
                completeStartup(origin: nil, error: payload["message"] as? String ?? "The loopback helper failed before it became ready.")
                Task { await stop() }
            }
            return
        }
    }

    private func reachedEOF() {
        guard startupCompletion != nil else { return }
        let detail = readinessBuffer.isEmpty ? "The loopback helper exited before reporting readiness." : "The loopback helper returned truncated readiness data."
        completeStartup(origin: nil, error: detail)
    }

    private func didTerminate(status: Int32) {
        output.fileHandleForReading.readabilityHandler = nil
        if startupCompletion != nil {
            let detail = readinessBuffer.isEmpty ? "The loopback helper exited with status \(status) before reporting readiness." : "The loopback helper exited with truncated readiness data."
            completeStartup(origin: nil, error: detail)
        } else if becameReady && !stopped {
            onUnexpectedExit?(status)
            onUnexpectedExit = nil
        }
        let waiters = terminationWaiters
        terminationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func completeStartup(origin: URL?, error: String?) {
        guard let completion = startupCompletion else { return }
        startupCompletion = nil
        startupTimeout?.cancel()
        startupTimeout = nil
        if stopped && origin != nil { completion(nil, "The loopback helper stopped before it became ready.") }
        else { completion(origin, error) }
    }
}
