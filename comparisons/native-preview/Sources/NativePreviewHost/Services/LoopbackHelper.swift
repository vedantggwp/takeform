import Darwin
import Foundation

@MainActor
final class LoopbackHelper {
    private let process = Process()
    private let output = Pipe()
    private let nodeURL: URL
    private let bundleRoot: URL?
    private let fixtureRoot: URL?

    init(nodeURL: URL?, bundleRoot: URL?, fixtureRoot: URL?) throws {
        guard let nodeURL else { throw PreviewFailure.helperUnavailable("Node is required. Set TAKEFORM_NODE or choose a Node executable.") }
        guard FileManager.default.isExecutableFile(atPath: nodeURL.path) else { throw PreviewFailure.helperUnavailable("The selected Node executable cannot run.") }
        self.nodeURL = nodeURL
        self.bundleRoot = bundleRoot
        self.fixtureRoot = fixtureRoot
    }

    func start(completion: @escaping @MainActor @Sendable (URL?, String?) -> Void) {
        guard let helperURL = Bundle.module.url(forResource: "preview-helper", withExtension: "mjs") else {
            completion(nil, "The bundled loopback helper is missing.")
            return
        }
        process.executableURL = nodeURL
        var arguments = [helperURL.path, "--port", "0"]
        if let bundleRoot { arguments += ["--bundle-root", bundleRoot.path] }
        if let fixtureRoot { arguments += ["--fixture-root", fixtureRoot.path] }
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            for fragment in line.split(separator: "\n") {
                guard let payload = try? JSONSerialization.jsonObject(with: Data(fragment.utf8)) as? [String: Any] else { continue }
                handle.readabilityHandler = nil
                if let port = payload["port"] as? Int {
                    Task { @MainActor in completion(URL(string: "http://127.0.0.1:\(port)/")!, nil) }
                } else {
                    Task { @MainActor in completion(nil, payload["message"] as? String ?? "The loopback helper failed before it became ready.") }
                }
                return
            }
        }
        do { try process.run() } catch { completion(nil, error.localizedDescription) }
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
