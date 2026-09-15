import Darwin
import Foundation
import TakeformAppAuthorityWire
import TakeformCore
import TakeformWorkspace

private final class ProcessExit: @unchecked Sendable {
    let signal = DispatchSemaphore(value: 0)
    func wait(milliseconds: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: self.signal.wait(timeout: .now() + .milliseconds(milliseconds)) == .success)
            }
        }
    }
}

public actor AppAuthorityServiceClient: WorkspaceClient {
    private let service: URL
    private var owned: (Process, ProcessExit)?
    private var activeRequests = 0
    private var closing = false
    private var lastReapedProcessID: pid_t?

    public init() {
        let executable = Bundle.main.executableURL
        self.service = executable?.deletingLastPathComponent().appendingPathComponent("TakeformAuthorityAppService") ?? URL(fileURLWithPath: "/nonexistent")
    }

    @_spi(Testing) public init(serviceExecutable: URL) { self.service = serviceExecutable }

    private func request(_ request: AppAuthorityRequest) async throws -> AppAuthorityResponse {
        guard !closing else { throw WorkspaceFailure.authorityUnavailable }
        activeRequests += 1
        defer { activeRequests -= 1 }
        do { return try AppAuthoritySocket.verifiedRequest(request, expectedService: service) }
        catch is AppAuthoritySocketFailure { throw WorkspaceFailure.authorityUnavailable }
        catch {
            guard !AppAuthoritySocket.endpointExists else { throw WorkspaceFailure.authorityUnavailable }
            try launchIfNeeded()
            do {
                for _ in 0..<100 {
                    do { try AppAuthoritySocket.verifyService(expectedService: service); return try AppAuthoritySocket.verifiedRequest(request, expectedService: service) }
                    catch is AppAuthoritySocketFailure { await stopOwnedService(); throw WorkspaceFailure.authorityUnavailable }
                    catch { try? await Task.sleep(for: .milliseconds(20)) }
                }
                await stopOwnedService()
                throw WorkspaceFailure.authorityUnavailable
            } catch { throw error }
        }
    }

    private func launchIfNeeded() throws {
        if owned?.0.isRunning == true { return }
        guard FileManager.default.isExecutableFile(atPath: service.path) else { throw WorkspaceFailure.authorityUnavailable }
        let process = Process(); process.executableURL = service; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.environment = ["TAKEFORM_AUTHORITY_SOCKET": AppAuthoritySocket.path]
        let exited = ProcessExit()
        process.terminationHandler = { _ in exited.signal.signal() }
        try process.run(); owned = (process, exited)
    }

    @_spi(Testing) public func startAndVerifyForTesting() async throws {
        guard !closing else { throw WorkspaceFailure.authorityUnavailable }
        do { try AppAuthoritySocket.verifyService(expectedService: service); return }
        catch is AppAuthoritySocketFailure { throw WorkspaceFailure.authorityUnavailable }
        catch {
            guard !AppAuthoritySocket.endpointExists else { throw WorkspaceFailure.authorityUnavailable }
            try launchIfNeeded()
            for _ in 0..<100 {
                do { try AppAuthoritySocket.verifyService(expectedService: service); return }
                catch is AppAuthoritySocketFailure { await stopOwnedService(); throw WorkspaceFailure.authorityUnavailable }
                catch { try? await Task.sleep(for: .milliseconds(20)) }
            }
            await stopOwnedService(); throw WorkspaceFailure.authorityUnavailable
        }
    }

    @_spi(Testing) public func ownedProcessID() -> pid_t? { owned?.0.processIdentifier }
    @_spi(Testing) public func lastReapedPID() -> pid_t? { lastReapedProcessID }
    @_spi(Testing) public func launchForTesting() throws { try launchIfNeeded() }

    private func stopOwnedService() async {
        guard let (process, exited) = owned else { return }
        if process.isRunning {
            process.terminate()
            var exitedNormally = await exited.wait(milliseconds: 2_000)
            if !exitedNormally {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                exitedNormally = await exited.wait(milliseconds: 1_000)
            }
            if exitedNormally { lastReapedProcessID = process.processIdentifier }
        }
        if !process.isRunning { lastReapedProcessID = process.processIdentifier }
        if owned?.0 === process { owned = nil }
    }

    public func shutdown() async {
        closing = true
        while activeRequests > 0 { try? await Task.sleep(for: .milliseconds(10)) }
        await stopOwnedService()
    }

    private func credential() throws -> Data { try CreatorCredentialStore.loadOrCreate() }
    public func importMedia(packageURL: URL, sources: [URL]) async throws -> [ManagedImportOutcome] {
        let credential = try credential()
        let operationID = UUID()
        let service = service
        let response = try await withTaskCancellationHandler(operation: {
            try await request(.importMedia(packageURL, sources, operationID, credential))
        }, onCancel: {
            // The cancel request is authenticated and peer-verified on its own
            // connection because the original service thread may be copying.
            Task.detached {
                _ = try? AppAuthoritySocket.verifiedRequest(.cancelImport(packageURL, operationID, credential), expectedService: service)
            }
        })
        guard case let .importOutcomes(outcomes) = response else { throw WorkspaceFailure.authorityUnavailable }
        return outcomes
    }
    public func createChannelPackage(packageURL: URL, name: String, initialRecipe: [String: String]) async throws -> WorkspaceSnapshot { let r = try await request(.create(packageURL, name, initialRecipe, try credential())); guard case let .snapshot(x) = r else { if case let .failure(e) = r { throw e }; throw WorkspaceFailure.authorityUnavailable }; return x }
    public func open(packageURL: URL, rebindMovedPackage: Bool) async throws -> WorkspaceSnapshot { let r = try await request(.open(packageURL, rebindMovedPackage, try credential())); guard case let .snapshot(x) = r else { if case let .failure(e) = r { throw e }; throw WorkspaceFailure.authorityUnavailable }; return x }
    public func execute(packageURL: URL, envelope: CommandEnvelope) async throws -> CommandResult { let r = try await request(.execute(packageURL, envelope, try credential())); guard case let .result(x) = r else { if case let .failure(e) = r { throw e }; throw WorkspaceFailure.authorityUnavailable }; return x }
    public func requestEpisodeRender(packageURL: URL, envelope: CommandEnvelope) async throws -> CommandResult { let r = try await request(.requestRender(packageURL, envelope, try credential())); guard case let .result(x) = r else { if case let .failure(e) = r { throw e }; throw WorkspaceFailure.authorityUnavailable }; return x }
    public func renderStatus(packageURL: URL, jobID: UUID) async throws -> EpisodeRenderRequestStatus { let r = try await request(.renderStatus(packageURL, jobID, try credential())); guard case let .renderStatus(x) = r else { if case let .failure(e) = r { throw e }; throw WorkspaceFailure.authorityUnavailable }; return x }
    public func cancelEpisodeRender(packageURL: URL, jobID: UUID, operationID: CommandID = CommandID()) async throws -> EpisodeRenderRequestStatus { let r = try await request(.cancelRender(packageURL, jobID, operationID, try credential())); guard case let .renderStatus(x) = r else { if case let .failure(e) = r { throw e }; throw WorkspaceFailure.authorityUnavailable }; return x }
    public func materializeEpisodeRender(packageURL: URL, jobID: UUID, operationID: CommandID = CommandID()) async throws -> EpisodeRenderMaterialization { let r = try await request(.materializeRender(packageURL, jobID, operationID, try credential())); guard case let .renderMaterialization(x) = r else { if case let .failure(e) = r { throw e }; throw WorkspaceFailure.authorityUnavailable }; return x }
    public func exportEpisodeRender(packageURL: URL, jobID: UUID, operationID: CommandID = CommandID(), destination: URL, decision: EpisodeRenderExportDecision = .refuseExisting) async throws -> EpisodeRenderExportResult { let r = try await request(.exportRender(packageURL, jobID, operationID, destination, decision, try credential())); guard case let .renderExport(x) = r else { if case let .failure(e) = r { throw e }; throw WorkspaceFailure.authorityUnavailable }; return x }
    public func playbackSource(packageURL: URL, jobID: UUID, operationID: CommandID = CommandID()) async throws -> EpisodeRenderPlaybackSource {
        let response = try await request(.playbackSource(packageURL, jobID, operationID, try credential()))
        guard case let .renderPlaybackSource(source) = response else {
            if case let .failure(failure) = response { throw failure }
            throw WorkspaceFailure.authorityUnavailable
        }
        return source
    }
    public func configureRenderRuntime(packageURL: URL, selectors: RenderRuntimeSelectors, operationID: CommandID = CommandID()) async throws -> RenderRuntimeReadiness {
        let response = try await request(.configureRenderRuntime(packageURL, selectors, operationID, try credential()))
        guard case let .renderRuntimeReadiness(readiness) = response else {
            if case let .failure(failure) = response { throw failure }
            throw WorkspaceFailure.authorityUnavailable
        }
        return readiness
    }
    public func renderRuntimeReadiness(packageURL: URL) async throws -> RenderRuntimeReadiness {
        let response = try await request(.renderRuntimeReadiness(packageURL, try credential()))
        guard case let .renderRuntimeReadiness(readiness) = response else {
            if case let .failure(failure) = response { throw failure }
            throw WorkspaceFailure.authorityUnavailable
        }
        return readiness
    }
    public func pairCLI(packageURL: URL, label: String, expiresAt: Date) async throws {
        let r = try await request(.pair(packageURL, label, expiresAt, try credential()))
        guard case let .pairing(id, raw) = r else { throw WorkspaceFailure.authorityUnavailable }
        guard let cli = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("takeform") else { throw WorkspaceFailure.authorityUnavailable }
        let process = Process(); let input = Pipe(); process.executableURL = cli; process.arguments = ["import-paired-credential", id.uuidString]; process.standardInput = input
        try process.run(); input.fileHandleForWriting.write(Data(raw.utf8)); input.fileHandleForWriting.write(Data("\n".utf8)); input.fileHandleForWriting.closeFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw WorkspaceFailure.rejected("CLI credential import failed") }
    }
    public func listCLIGrants(packageURL: URL) async throws -> [CLIPairingSummary] { let r = try await request(.listGrants(packageURL, try credential())); guard case let .grants(x) = r else { throw WorkspaceFailure.authorityUnavailable }; return x }
    public func revokeCLI(packageURL: URL, grantID: UUID) async throws { let r = try await request(.revoke(packageURL, grantID, try credential())); guard case .success = r else { throw WorkspaceFailure.authorityUnavailable } }
}
