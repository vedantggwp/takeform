import CryptoKit
import Darwin
import Foundation
import TakeformAppAuthorityWire
import TakeformCore

/// All paths and process ownership below are machine-local. Nothing in this
/// coordinator is written to project.sqlite or returned as a portable value.
struct RenderWorkerRuntime: Sendable {
    let node: URL
    let worker: URL
    let runtimeRoot: URL
    let browser: URL
    let ffmpeg: URL
    let ffprobe: URL
}

private struct RenderWorkerObject: Codable {
    let assetID: UUID
    let digest: String
    let byteLength: UInt64
    let localPath: String
}

private struct RenderWorkerRequest: Encodable {
    let schemaVersion = 1
    let jobID: UUID
    let attemptID: UUID
    let snapshotSHA256: String
    let snapshot: EpisodeRenderSnapshot
    let resolvedObjects: [RenderWorkerObject]
    let stageDirectory: String
    let outputFileName: String
    let runtime: Runtime

    struct Runtime: Codable {
        let runtimeRoot: String
        let nodeVersion: String
        let browserExecutable: String
        let ffmpegExecutable: String
        let ffprobeExecutable: String
    }
}

private struct RenderWorkerReceipt: Codable {
    let schemaVersion: Int
    let jobID: UUID
    let attemptID: UUID
    let outcome: String
    let input: Input?
    let artifact: Artifact?

    struct Input: Codable {
        let compositionDigest: String
        let snapshotSHA256: String
        let assets: [Asset]
        struct Asset: Codable { let id: UUID; let digest: String }
    }

    struct Artifact: Codable {
        let fileName: String
        let byteLength: UInt64
        let sha256: String
    }
}

private struct RenderMachineArtifact: Codable {
    let attemptID: UUID
    let snapshotSHA256: String
    let machineBindingDigest: String
    let descriptor: EpisodeRenderDescriptor
    let artifactDirectory: String
    let fileName: String
    /// This remains local with the artifact. It is rechecked before a
    /// descriptor is exposed, never stored in the portable request row.
    let ffprobeExecutable: String
}

/// A stage-local ownership proof for recovery. It contains no PID, path
/// outside its own directory, credential, or portable project state.
private struct RenderAttemptMarker: Codable {
    let schemaVersion: Int
    let projectID: UUID
    let jobID: UUID
    let attemptID: UUID
    let snapshotSHA256: String
    let machineBindingDigest: String
}

/// Canonical executable locations are machine-only configuration. A binding
/// digest prevents a copied/rebound package from inheriting this selection.
private struct PersistedRenderRuntimeSelectors: Codable {
    let browser: String
    let ffmpeg: String
    let ffprobe: String
    let machineBindingDigest: String
    let runtimeIdentity: RenderRuntimeIdentity
}

private struct RenderRuntimeIdentity: Codable, Equatable {
    let nodeVersion: String
    let workerSHA256: String
}

/// Operation responses are retained separately from the configuration itself:
/// they contain no executable paths and replay a completed request without
/// launching tools or rewriting selectors.
private struct RenderRuntimeOperation: Codable {
    let fingerprint: String
    let readiness: RenderRuntimeReadiness
}

/// This is deliberately a single-purpose process owner, not a scheduler. A
/// process is signalled only while this running service retains its `Process`.
final class RenderExecutionCoordinator: @unchecked Sendable {
    /// Production selection is loaded only after the current machine binding
    /// has been checked in `selectedRuntime` below.
    static let shared = RenderExecutionCoordinator(runtime: { _ in nil })

    private struct Key: Hashable { let projectID: UUID; let jobID: UUID }
    private struct Active { let process: Process; let attemptID: UUID; let snapshotSHA256: String; let stage: URL; let runtime: RenderWorkerRuntime }

    private let lock = NSLock()
    private var active: [Key: Active] = [:]
    private var completionFailure: [Key: String] = [:]
    private var reapedPID: [Key: pid_t] = [:]
    private let runtime: @Sendable (UUID) -> RenderWorkerRuntime?
#if DEBUG
    private var testRuntime: (@Sendable (UUID) -> RenderWorkerRuntime?)?
#endif

    init(runtime: @escaping @Sendable (UUID) -> RenderWorkerRuntime?) {
        self.runtime = runtime
    }

    func start(authority: ProjectAuthority, input: RenderAttemptInput) -> EpisodeRenderAvailability {
        let key = Key(projectID: input.snapshot.projectID, jobID: input.status.jobID)
        lock.lock()
        if active[key] != nil { lock.unlock(); return .running }
        lock.unlock()
        guard input.status.logicalState == .requested, let runtime = selectedRuntime(for: input.snapshot.projectID, machineBindingDigest: input.machineBindingDigest), preflight(runtime) else { return .unavailable }
        var ownedStage: URL?
        do {
            let stage = try makeStage(projectID: input.snapshot.projectID, jobID: input.status.jobID)
            ownedStage = stage
            let attemptID = UUID()
            let snapshotSHA256 = digest(input.snapshotJSON)
            let objects = try input.snapshot.assets.map { asset -> RenderWorkerObject in
                let object = try ManagedImport.verifiedObjectURL(ManagedAsset(id: asset.id, digest: asset.digest, byteLength: asset.byteLength, filename: "render-input", mediaType: asset.mediaType, probe: asset.probe), package: authority.packageURLForRender)
                return RenderWorkerObject(assetID: asset.id, digest: asset.digest, byteLength: asset.byteLength, localPath: object.path)
            }
            let request = RenderWorkerRequest(jobID: input.status.jobID, attemptID: attemptID, snapshotSHA256: snapshotSHA256, snapshot: input.snapshot, resolvedObjects: objects, stageDirectory: stage.path, outputFileName: "render.mp4", runtime: .init(runtimeRoot: runtime.runtimeRoot.path, nodeVersion: try version(runtime.node, arguments: ["--version"]), browserExecutable: runtime.browser.path, ffmpegExecutable: runtime.ffmpeg.path, ffprobeExecutable: runtime.ffprobe.path))
            let requestURL = stage.appendingPathComponent("attempt-request.json")
            try JSONEncoder.sorted.encode(request).write(to: requestURL, options: .atomic)
            let marker = RenderAttemptMarker(schemaVersion: 1, projectID: input.snapshot.projectID, jobID: input.status.jobID, attemptID: attemptID, snapshotSHA256: snapshotSHA256, machineBindingDigest: input.machineBindingDigest)
            try JSONEncoder.sorted.encode(marker).write(to: stage.appendingPathComponent("attempt-owner.json"), options: .atomic)
            let process = Process()
            process.executableURL = runtime.node
            process.arguments = [runtime.worker.path, "--request", requestURL.path]
            process.environment = [
                "HOME": stage.path,
                "TMPDIR": stage.path,
                // Non-secret ownership markers make a fixture worker
                // inspectable without granting it authority credentials.
                "TAKEFORM_RENDER_STAGE": stage.path,
                "TAKEFORM_RENDER_JOB": input.status.jobID.uuidString,
                "TAKEFORM_RENDER_ATTEMPT": attemptID.uuidString,
                "TAKEFORM_RENDER_SNAPSHOT_SHA256": snapshotSHA256,
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let activeAttempt = Active(process: process, attemptID: attemptID, snapshotSHA256: snapshotSHA256, stage: stage, runtime: runtime)
            let packageURL = authority.packageURLForRender
            process.terminationHandler = { [weak self] terminated in
                guard let self else { return }
                guard let authority = try? ProjectAuthority(packageURL: packageURL),
                      (try? authority.open()) != nil else {
                    self.cleanup(stage: activeAttempt.stage)
                    self.recordReaped(terminated.processIdentifier, for: key)
                    return
                }
                self.finish(authority: authority, key: key, attempt: activeAttempt)
                self.recordReaped(terminated.processIdentifier, for: key)
            }
            lock.lock()
            if active[key] != nil {
                lock.unlock()
                cleanup(stage: stage)
                return .running
            }
            active[key] = activeAttempt
            lock.unlock()
            do {
                try process.run()
            } catch {
                lock.lock()
                if active[key]?.attemptID == attemptID { active.removeValue(forKey: key) }
                lock.unlock()
                cleanup(stage: stage)
                return .unavailable
            }
            ownedStage = nil
            return .running
        } catch {
            if let ownedStage { cleanup(stage: ownedStage) }
            return .unavailable
        }
    }

    func cancel(projectID: UUID, jobID: UUID) {
        let key = Key(projectID: projectID, jobID: jobID)
        lock.lock(); let attempt = active[key]; lock.unlock()
        guard let attempt else { return }
        attempt.process.terminate()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.reapCancelledAttempt(attempt, for: key)
        }
    }

    /// Service restart recovery intentionally has no PID to signal. It may
    /// accept only an owned stage with a complete receipt that passes the same
    /// hash/ffprobe promotion checks as a live child. Every other stranded
    /// requested operation becomes interrupted and only its marker-proven
    /// stage is removed.
    func reconcile(authority: ProjectAuthority) {
        guard let pending = try? authority.requestedRenderAttemptInputs() else { return }
        for input in pending {
            let key = Key(projectID: input.snapshot.projectID, jobID: input.status.jobID)
            lock.lock(); let running = active[key] != nil; lock.unlock()
            guard !running else { continue }
            let attempts = recoveryAttempts(for: input)
            var accepted = false
            for attempt in attempts {
                guard FileManager.default.fileExists(atPath: attempt.stage.appendingPathComponent("attempt-receipt.json").path),
                      let runtime = selectedRuntime(for: input.snapshot.projectID, machineBindingDigest: input.machineBindingDigest), preflight(runtime) else {
                    cleanup(stage: attempt.stage)
                    continue
                }
                let recovered = Active(process: Process(), attemptID: attempt.attemptID, snapshotSHA256: attempt.snapshotSHA256, stage: attempt.stage, runtime: runtime)
                finish(authority: authority, key: key, attempt: recovered)
                if let refreshed = try? authority.renderAttemptInput(jobID: key.jobID),
                   refreshed.status.logicalState == .completed,
                   artifact(for: refreshed) != nil {
                    accepted = true
                    break
                }
            }
            if !accepted,
               let refreshed = try? authority.renderAttemptInput(jobID: key.jobID),
               refreshed.status.logicalState == .requested {
                _ = try? authority.transitionRenderRequest(jobID: key.jobID, snapshotSHA256: digest(refreshed.snapshotJSON), to: .interrupted)
            }
        }
    }

    func availability(for input: RenderAttemptInput) -> EpisodeRenderAvailability {
        lock.lock(); let running = active[Key(projectID: input.snapshot.projectID, jobID: input.status.jobID)] != nil; lock.unlock()
        if running { return .running }
        return artifact(for: input) == nil ? .unavailable : .available
    }

    func failureCode(for input: RenderAttemptInput) -> String? {
        lock.lock(); defer { lock.unlock() }
        return completionFailure[Key(projectID: input.snapshot.projectID, jobID: input.status.jobID)]
    }

    /// Test-visible evidence that the retained child terminated. This does not
    /// persist a PID or make it available to callers outside this service.
    func lastReapedPID(for input: RenderAttemptInput) -> pid_t? {
        lock.lock(); defer { lock.unlock() }
        return reapedPID[Key(projectID: input.snapshot.projectID, jobID: input.status.jobID)]
    }

    /// Validates a complete app-selected runtime before it replaces existing
    /// machine configuration. A repeated operation returns its stored typed
    /// response without spawning a process or changing selectors.
    func configureRuntime(projectID: UUID, machineBindingDigest: String, selectors: RenderRuntimeSelectors, operationID: CommandID) throws -> RenderRuntimeReadiness {
        let root = Self.machineRoot(projectID: projectID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let operationsURL = root.appendingPathComponent("runtime-operations.json")
        var operations = try loadRuntimeOperations(at: operationsURL)
        let fingerprint = configurationFingerprint(selectors: selectors, machineBindingDigest: machineBindingDigest)
        if let previous = operations[operationID.value.uuidString] {
            guard previous.fingerprint == fingerprint else { throw AuthorityFailure.unauthorized }
            return previous.readiness
        }

        let readiness: RenderRuntimeReadiness
        if let canonical = canonicalSelectors(selectors), let runtime = candidateRuntime(projectID: projectID, selectors: canonical) {
            readiness = self.readiness(for: runtime)
            if case .ready = readiness {
                let record = PersistedRenderRuntimeSelectors(
                    browser: canonical.browser,
                    ffmpeg: canonical.ffmpeg,
                    ffprobe: canonical.ffprobe,
                    machineBindingDigest: machineBindingDigest,
                    runtimeIdentity: try runtimeIdentity(for: runtime)
                )
                try JSONEncoder.sorted.encode(record).write(to: root.appendingPathComponent("renderer-selectors.json"), options: .atomic)
            }
        } else {
            readiness = .unavailable(reason: "Choose regular executable browser, FFmpeg, and FFprobe files.")
        }

        operations[operationID.value.uuidString] = RenderRuntimeOperation(fingerprint: fingerprint, readiness: readiness)
        try JSONEncoder.sorted.encode(operations).write(to: operationsURL, options: .atomic)
        return readiness
    }

    /// A later rebind or bundled-runtime change invalidates the old selection
    /// by returning fresh readiness rather than trusting a stored success.
    func runtimeReadiness(projectID: UUID, machineBindingDigest: String) -> RenderRuntimeReadiness {
        let root = Self.machineRoot(projectID: projectID)
        let configurationURL = root.appendingPathComponent("renderer-selectors.json")
        guard let configuration = try? safeDecode(PersistedRenderRuntimeSelectors.self, at: configurationURL) else {
            return .unavailable(reason: "Choose a browser, FFmpeg, and FFprobe in Takeform before rendering.")
        }
        guard configuration.machineBindingDigest == machineBindingDigest,
              let runtime = candidateRuntime(projectID: projectID, selectors: configuration) else {
            return .unavailable(reason: "Renderer setup belongs to a different project location. Choose the runtime again.")
        }
        let readiness = readiness(for: runtime)
        guard case .ready = readiness,
              (try? runtimeIdentity(for: runtime)) == configuration.runtimeIdentity else {
            return .unavailable(reason: "The bundled renderer changed. Recheck runtime setup in Takeform.")
        }
        return readiness
    }

#if DEBUG
    /// Test targets can supply a disposable, explicit runtime without adding a
    /// user-configurable renderer path to the production service surface.
    func installTestRuntime(_ provider: @escaping @Sendable (UUID) -> RenderWorkerRuntime?) {
        lock.lock(); testRuntime = provider; lock.unlock()
    }

    func clearTestRuntime() {
        lock.lock(); testRuntime = nil; lock.unlock()
    }
#endif

    func artifact(for input: RenderAttemptInput) -> (descriptor: EpisodeRenderDescriptor, url: URL)? {
        let root = Self.machineRoot(projectID: input.snapshot.projectID).appendingPathComponent(input.status.jobID.uuidString, isDirectory: true)
        let recordURL = root.appendingPathComponent("current.json")
        guard isRegularDirectory(root),
              let record = try? safeDecode(RenderMachineArtifact.self, at: recordURL),
              record.snapshotSHA256 == digest(input.snapshotJSON),
              record.machineBindingDigest == input.machineBindingDigest,
              record.descriptor.jobID == input.status.jobID,
              record.descriptor.format == input.status.format,
              let directory = safeChild(record.artifactDirectory, of: root),
              isRegularDirectory(directory),
              let artifact = safeChild(record.fileName, of: directory),
              let data = try? safeRegularData(at: artifact),
              UInt64(data.count) == record.descriptor.byteLength,
              digest(data) == record.descriptor.sha256,
              FileManager.default.isExecutableFile(atPath: record.ffprobeExecutable),
              validateMP4(artifact, ffprobe: URL(fileURLWithPath: record.ffprobeExecutable), output: input.snapshot.composition.output) else { return nil }
        return (record.descriptor, artifact)
    }

    func materialization(for input: RenderAttemptInput) -> EpisodeRenderMaterialization {
        guard input.status.logicalState == .completed, let artifact = artifact(for: input) else { return .unavailable(input.status) }
        return .descriptor(artifact.descriptor)
    }

    /// This is only called after app-role authentication. The URL is derived
    /// from the current verified artifact and is not retained by the logical
    /// request or any portable response.
    func playbackSource(for input: RenderAttemptInput) -> EpisodeRenderPlaybackSource? {
        guard input.status.logicalState == .completed, let artifact = artifact(for: input) else { return nil }
        return EpisodeRenderPlaybackSource(
            jobID: input.status.jobID,
            requestedRevision: input.status.requestedRevision,
            compositionDigest: input.status.compositionDigest,
            output: input.snapshot.composition.output,
            descriptor: artifact.descriptor,
            videoStreamCount: 1,
            audioStreamCount: 0,
            artifactURL: artifact.url
        )
    }

    func export(input: RenderAttemptInput, destination: URL) throws -> EpisodeRenderExportResult {
        guard input.status.logicalState == .completed, let artifact = artifact(for: input) else { return .unavailable(input.status) }
        try copyWithoutReplacing(source: artifact.url, destination: destination)
        return .exported(artifact.descriptor)
    }

    private func finish(authority: ProjectAuthority, key: Key, attempt: Active) {
        lock.lock(); active.removeValue(forKey: key); lock.unlock()
        let receiptURL = attempt.stage.appendingPathComponent("attempt-receipt.json")
        guard FileManager.default.fileExists(atPath: receiptURL.path) else {
            recordFailure("missing-receipt", for: key)
            _ = try? authority.transitionRenderRequest(jobID: key.jobID, snapshotSHA256: attempt.snapshotSHA256, to: .failed)
            cleanup(stage: attempt.stage)
            return
        }
        guard let receipt = try? safeDecode(RenderWorkerReceipt.self, at: receiptURL) else {
            recordFailure("invalid-receipt", for: key)
            _ = try? authority.transitionRenderRequest(jobID: key.jobID, snapshotSHA256: attempt.snapshotSHA256, to: .failed)
            cleanup(stage: attempt.stage)
            return
        }
        guard receipt.schemaVersion == 1,
              receipt.jobID == key.jobID,
              receipt.attemptID == attempt.attemptID,
              receipt.input?.snapshotSHA256 == attempt.snapshotSHA256 else {
            recordFailure("mismatched-receipt", for: key)
            _ = try? authority.transitionRenderRequest(jobID: key.jobID, snapshotSHA256: attempt.snapshotSHA256, to: .failed)
            cleanup(stage: attempt.stage)
            return
        }
        guard receipt.outcome == "succeeded", let artifact = receipt.artifact else {
            recordFailure(receipt.outcome == "cancelled" ? "cancelled" : "failed-receipt", for: key)
            let state: EpisodeRenderLogicalState = receipt.outcome == "cancelled" ? .cancelled : .failed
            _ = try? authority.transitionRenderRequest(jobID: key.jobID, snapshotSHA256: attempt.snapshotSHA256, to: state)
            cleanup(stage: attempt.stage)
            return
        }
        guard let currentInput = try? authority.renderAttemptInput(jobID: key.jobID),
              currentInput.status.logicalState == .requested else {
            cleanup(stage: attempt.stage)
            return
        }
        guard artifact.fileName == "render.mp4", isLowercaseDigest(artifact.sha256),
              let artifactURL = safeChild(artifact.fileName, of: attempt.stage),
              let data = try? safeRegularData(at: artifactURL),
              UInt64(data.count) == artifact.byteLength,
              digest(data) == artifact.sha256 else {
            recordFailure("invalid-artifact-bytes", for: key)
            _ = try? authority.transitionRenderRequest(jobID: key.jobID, snapshotSHA256: attempt.snapshotSHA256, to: .failed)
            cleanup(stage: attempt.stage)
            return
        }
        guard validateMP4(artifactURL, ffprobe: attempt.runtime.ffprobe, output: currentInput.snapshot.composition.output) else {
            recordFailure("invalid-artifact-streams", for: key)
            let state: EpisodeRenderLogicalState = receipt.outcome == "cancelled" ? .cancelled : .failed
            _ = try? authority.transitionRenderRequest(jobID: key.jobID, snapshotSHA256: attempt.snapshotSHA256, to: state)
            cleanup(stage: attempt.stage)
            return
        }
        let descriptor = EpisodeRenderDescriptor(jobID: key.jobID, format: .mp4, byteLength: artifact.byteLength, sha256: artifact.sha256)
        do {
            let artifactDirectory = try promote(stage: attempt.stage, projectID: key.projectID, jobID: key.jobID, attemptID: attempt.attemptID)
            let record = RenderMachineArtifact(attemptID: attempt.attemptID, snapshotSHA256: attempt.snapshotSHA256, machineBindingDigest: currentInput.machineBindingDigest, descriptor: descriptor, artifactDirectory: artifactDirectory.lastPathComponent, fileName: artifact.fileName, ffprobeExecutable: attempt.runtime.ffprobe.path)
            let recordURL = artifactDirectory.deletingLastPathComponent().appendingPathComponent("current.json")
            try JSONEncoder.sorted.encode(record).write(to: recordURL, options: .atomic)
            let transitioned = try authority.transitionRenderRequest(jobID: key.jobID, snapshotSHA256: attempt.snapshotSHA256, to: .completed)
            guard transitioned.logicalState == .completed else {
                removePromotedArtifact(artifactDirectory, recordURL: recordURL, attemptID: attempt.attemptID)
                return
            }
        } catch {
            recordFailure("artifact-promotion-or-transition", for: key)
            _ = try? authority.transitionRenderRequest(jobID: key.jobID, snapshotSHA256: attempt.snapshotSHA256, to: .failed)
            cleanup(stage: attempt.stage)
        }
    }

    private func recordFailure(_ value: String, for key: Key) {
        lock.lock(); completionFailure[key] = value; lock.unlock()
    }

    private func recordReaped(_ pid: pid_t, for key: Key) {
        lock.lock(); reapedPID[key] = pid; lock.unlock()
    }

    private func selectedRuntime(for projectID: UUID, machineBindingDigest: String) -> RenderWorkerRuntime? {
#if DEBUG
        lock.lock(); let provider = testRuntime; lock.unlock()
        if let provider { return provider(projectID) }
#endif
        if let injected = runtime(projectID) { return injected }
        let configurationURL = Self.machineRoot(projectID: projectID).appendingPathComponent("renderer-selectors.json")
        guard let configuration = try? safeDecode(PersistedRenderRuntimeSelectors.self, at: configurationURL),
              configuration.machineBindingDigest == machineBindingDigest,
              let configured = Self.bundledRuntime(selectors: configuration),
              case .ready = readiness(for: configured),
              (try? runtimeIdentity(for: configured)) == configuration.runtimeIdentity else { return nil }
        return configured
    }

    private func recoveryAttempts(for input: RenderAttemptInput) -> [Active] {
        let root = Self.machineRoot(projectID: input.snapshot.projectID).appendingPathComponent(input.status.jobID.uuidString, isDirectory: true)
        guard isRegularDirectory(root), let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.compactMap { name in
            guard name.hasSuffix(".stage"),
                  let stage = safeChild(name, of: root), isRegularDirectory(stage),
                  let marker = try? safeDecode(RenderAttemptMarker.self, at: stage.appendingPathComponent("attempt-owner.json")),
                  marker.schemaVersion == 1,
                  marker.projectID == input.snapshot.projectID,
                  marker.jobID == input.status.jobID,
                  marker.snapshotSHA256 == digest(input.snapshotJSON),
                  marker.machineBindingDigest == input.machineBindingDigest else { return nil }
            // The process is deliberately unstarted: recovery never signals a
            // process whose ownership did not survive this service instance.
            return Active(process: Process(), attemptID: marker.attemptID, snapshotSHA256: marker.snapshotSHA256, stage: stage, runtime: RenderWorkerRuntime(node: URL(fileURLWithPath: "/dev/null"), worker: URL(fileURLWithPath: "/dev/null"), runtimeRoot: URL(fileURLWithPath: "/dev/null"), browser: URL(fileURLWithPath: "/dev/null"), ffmpeg: URL(fileURLWithPath: "/dev/null"), ffprobe: URL(fileURLWithPath: "/dev/null")))
        }
    }

    /// The app-service owns this exact `Process`; it never persists or later
    /// reconstructs a PID. TERM gives the worker a chance to write a
    /// cancellation receipt, and the bounded KILL fallback applies only while
    /// this retained handle still reports a live child.
    private func reapCancelledAttempt(_ attempt: Active, for key: Key) {
        let gracefulDeadline = Date().addingTimeInterval(1)
        while attempt.process.isRunning, Date() < gracefulDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if attempt.process.isRunning {
            _ = Darwin.kill(attempt.process.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(1)
            while attempt.process.isRunning, Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        lock.lock()
        let stillOwned = active[key]?.attemptID == attempt.attemptID
        lock.unlock()
        if stillOwned, !attempt.process.isRunning {
            // The termination handler performs the authoritative state change;
            // this only waits for it to observe the reaped child.
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private static func bundledRuntime(selectors: PersistedRenderRuntimeSelectors) -> RenderWorkerRuntime? {
        let service = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let resources = service.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/RendererRuntime", isDirectory: true)
        return RenderWorkerRuntime(node: resources.appendingPathComponent("node/bin/node"), worker: resources.appendingPathComponent("episode-render-worker.mjs"), runtimeRoot: resources, browser: URL(fileURLWithPath: selectors.browser), ffmpeg: URL(fileURLWithPath: selectors.ffmpeg), ffprobe: URL(fileURLWithPath: selectors.ffprobe))
    }

    private func candidateRuntime(projectID: UUID, selectors: PersistedRenderRuntimeSelectors) -> RenderWorkerRuntime? {
#if DEBUG
        lock.lock(); let provider = testRuntime; lock.unlock()
        if let provider { return provider(projectID) }
#endif
        if let injected = runtime(projectID) { return injected }
        return Self.bundledRuntime(selectors: selectors)
    }

    private func canonicalSelectors(_ selectors: RenderRuntimeSelectors) -> PersistedRenderRuntimeSelectors? {
        guard let browser = canonicalExecutable(selectors.browser),
              let ffmpeg = canonicalExecutable(selectors.ffmpeg),
              let ffprobe = canonicalExecutable(selectors.ffprobe) else { return nil }
        // Configuration has not been preflighted yet; identity is filled only
        // immediately before the atomically written validated record.
        return PersistedRenderRuntimeSelectors(browser: browser, ffmpeg: ffmpeg, ffprobe: ffprobe, machineBindingDigest: "", runtimeIdentity: RenderRuntimeIdentity(nodeVersion: "", workerSHA256: ""))
    }

    private func canonicalExecutable(_ url: URL) -> String? {
        guard url.isFileURL else { return nil }
        let standardized = url.standardizedFileURL
        guard standardized.path.hasPrefix("/") else { return nil }
        let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL
        // Selector values are explicit user choices, not indirections through
        // a symlink or PATH entry that can later point at another executable.
        guard canonical.path == standardized.path else { return nil }
        var info = stat()
        guard lstat(standardized.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              FileManager.default.isExecutableFile(atPath: standardized.path) else { return nil }
        return standardized.path
    }

    private func configurationFingerprint(selectors: RenderRuntimeSelectors, machineBindingDigest: String) -> String {
        let data = (try? JSONEncoder.sorted.encode(selectors)) ?? Data()
        return digest(Data(machineBindingDigest.utf8) + data)
    }

    private func loadRuntimeOperations(at url: URL) throws -> [String: RenderRuntimeOperation] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try safeDecode([String: RenderRuntimeOperation].self, at: url)
    }

    private func runtimeIdentity(for runtime: RenderWorkerRuntime) throws -> RenderRuntimeIdentity {
        RenderRuntimeIdentity(nodeVersion: try version(runtime.node, arguments: ["--version"]), workerSHA256: digest(try safeRegularData(at: runtime.worker)))
    }

    private func preflight(_ runtime: RenderWorkerRuntime) -> Bool {
        if case .ready = readiness(for: runtime) { return true }
        return false
    }

    private func readiness(for runtime: RenderWorkerRuntime) -> RenderRuntimeReadiness {
        guard [runtime.node, runtime.browser, runtime.ffmpeg, runtime.ffprobe].allSatisfy({ FileManager.default.isExecutableFile(atPath: $0.path) }),
              (try? safeRegularData(at: runtime.worker)) != nil else {
            return .unavailable(reason: "The bundled renderer or selected executable is unavailable.")
        }
        guard let nodeVersion = try? version(runtime.node, arguments: ["--version"]), nodeVersion == "v22.22.1" else {
            return .unavailable(reason: "Takeform requires its bundled Node 22.22.1 runtime.")
        }
        guard let browserVersion = try? version(runtime.browser, arguments: ["--version"]),
              let ffmpegVersion = try? version(runtime.ffmpeg, arguments: ["-version"]),
              let ffprobeVersion = try? version(runtime.ffprobe, arguments: ["-version"]) else {
            return .unavailable(reason: "Takeform could not run every selected renderer executable.")
        }
        return .ready(nodeVersion: nodeVersion, browserVersion: browserVersion, ffmpegVersion: ffmpegVersion, ffprobeVersion: ffprobeVersion)
    }
}

private extension RenderExecutionCoordinator {
    static func machineRoot(projectID: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Takeform/Authority/\(projectID.uuidString)/renders", isDirectory: true)
    }

    func makeStage(projectID: UUID, jobID: UUID) throws -> URL {
        let root = Self.machineRoot(projectID: projectID).appendingPathComponent(jobID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = root.appendingPathComponent("\(UUID().uuidString).stage", isDirectory: true)
        guard mkdir(stage.path, S_IRWXU) == 0 else { throw AuthorityFailure.unauthorized }
        return stage
    }

    func promote(stage: URL, projectID: UUID, jobID: UUID, attemptID: UUID) throws -> URL {
        let root = Self.machineRoot(projectID: projectID).appendingPathComponent(jobID.uuidString, isDirectory: true)
        let destination = root.appendingPathComponent("\(attemptID.uuidString).artifact", isDirectory: true)
        guard rename(stage.path, destination.path) == 0 else { throw AuthorityFailure.unauthorized }
        return destination
    }

    func validateMP4(_ artifact: URL, ffprobe: URL, output expected: CompositionOutput) -> Bool {
        guard let output = try? commandOutput(ffprobe, arguments: ["-v", "error", "-show_entries", "stream=codec_type,width,height,avg_frame_rate,nb_frames:format=duration", "-of", "json", artifact.path]),
              let data = output.data(using: .utf8),
              let probe = try? JSONDecoder().decode(RenderProbe.self, from: data),
              let video = probe.streams.first(where: { $0.codecType == "video" }),
              !probe.streams.contains(where: { $0.codecType == "audio" }),
              video.width == expected.width,
              video.height == expected.height,
              let frameRate = rational(video.averageFrameRate),
              let duration = Double(probe.format.duration),
              frameRate > 0,
              abs(frameRate - rational(expected.frameRate)) < 0.000_001 else { return false }
        // ISO BMFF duration may round to one encoded frame at its track
        // timebase. Anything beyond that is truncated or the wrong render.
        let expectedDuration = rational(expected.duration)
        guard abs(duration - expectedDuration) <= 1 / frameRate else { return false }
        if let count = video.frameCount, let frames = Int(count) {
            guard abs(Double(frames) - expectedDuration * frameRate) <= 1 else { return false }
        }
        return true
    }

    struct RenderProbe: Decodable {
        struct Stream: Decodable {
            let codecType: String
            let width: Int?
            let height: Int?
            let averageFrameRate: String?
            let frameCount: String?
            enum CodingKeys: String, CodingKey { case codecType = "codec_type", width, height, averageFrameRate = "avg_frame_rate", frameCount = "nb_frames" }
        }
        struct Format: Decodable { let duration: String }
        let streams: [Stream]
        let format: Format
    }

    func rational(_ value: CompositionTime) -> Double { Double(value.value) / Double(value.timescale) }
    func rational(_ value: String?) -> Double? {
        guard let value else { return nil }
        let parts = value.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator != 0 else { return nil }
        return numerator / denominator
    }

    func version(_ executable: URL, arguments: [String]) throws -> String {
        guard let line = try commandOutput(executable, arguments: arguments).split(separator: "\n").first else { throw AuthorityFailure.renderUnavailable }
        return String(line)
    }

    func commandOutput(_ executable: URL, arguments: [String]) throws -> String {
        let process = Process(); let output = Pipe(); let errors = Pipe()
        process.executableURL = executable; process.arguments = arguments; process.standardOutput = output; process.standardError = errors
        try process.run()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        if process.isRunning { process.terminate(); throw AuthorityFailure.renderUnavailable }
        guard process.terminationStatus == 0 else { throw AuthorityFailure.renderUnavailable }
        let data = output.fileHandleForReading.readDataToEndOfFile() + errors.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { throw AuthorityFailure.renderUnavailable }
        return text
    }

    func safeDecode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T { try JSONDecoder().decode(T.self, from: safeRegularData(at: url)) }

    func safeRegularData(at url: URL) throws -> Data {
        var info = stat(); guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw AuthorityFailure.unauthorized }
        return try Data(contentsOf: url)
    }

    func isRegularDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    func safeChild(_ name: String, of root: URL) -> URL? {
        guard name == URL(fileURLWithPath: name).lastPathComponent, !name.isEmpty else { return nil }
        return root.appendingPathComponent(name)
    }

    func cleanup(stage: URL) { try? FileManager.default.removeItem(at: stage) }

    func removePromotedArtifact(_ artifactDirectory: URL, recordURL: URL, attemptID: UUID) {
        if let record = try? safeDecode(RenderMachineArtifact.self, at: recordURL), record.attemptID == attemptID {
            try? FileManager.default.removeItem(at: recordURL)
        }
        try? FileManager.default.removeItem(at: artifactDirectory)
    }
    func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func isLowercaseDigest(_ value: String) -> Bool { value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }

    func copyWithoutReplacing(source: URL, destination: URL) throws {
        guard let parent = destination.deletingLastPathComponent() as URL?, isRegularDirectory(parent), !FileManager.default.fileExists(atPath: destination.path) else { throw AuthorityFailure.renderUnavailable }
        let temporary = parent.appendingPathComponent(".takeform-export-\(UUID().uuidString)")
        let sourceFD = open(source.path, O_RDONLY)
        guard sourceFD >= 0 else { throw AuthorityFailure.renderUnavailable }
        defer { close(sourceFD) }
        let outputFD = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard outputFD >= 0 else { throw AuthorityFailure.renderUnavailable }
        var shouldRemove = true
        defer { close(outputFD); if shouldRemove { _ = unlink(temporary.path) } }
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = read(sourceFD, &buffer, buffer.count)
            guard count >= 0 else { throw AuthorityFailure.renderUnavailable }
            if count == 0 { break }
            var written = 0
            while written < count {
                let amount = buffer.withUnsafeBytes { write(outputFD, $0.baseAddress!.advanced(by: written), count - written) }
                guard amount > 0 else { throw AuthorityFailure.renderUnavailable }
                written += amount
            }
        }
        guard fsync(outputFD) == 0, link(temporary.path, destination.path) == 0 else { throw AuthorityFailure.renderUnavailable }
        shouldRemove = false
        _ = unlink(temporary.path)
        let parentFD = open(parent.path, O_RDONLY)
        if parentFD >= 0 { _ = fsync(parentFD); close(parentFD) }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
}
