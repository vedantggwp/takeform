import Foundation
import Security
import TakeformAuthorityEngine
import TakeformAppAuthorityWire
import TakeformCore
import TakeformWorkspace

/// Exists only in the app-service target. The shipping CLI has no dependency on this target or the engine.
public enum CreatorAuthorityService {
    public enum PeerRole: Sendable { case app, cli }
    private static let importLock = NSLock()
    private nonisolated(unsafe) static var cancelledImports = Set<UUID>()

    public static func allows(_ request: AppAuthorityRequest, for role: PeerRole) -> Bool {
        switch (role, request) {
        case (.app, .open), (.app, .create), (.app, .importMedia), (.app, .cancelImport), (.app, .execute), (.app, .pair), (.app, .revoke), (.app, .listGrants), (.app, .requestRender), (.app, .renderStatus), (.app, .cancelRender), (.app, .materializeRender), (.app, .exportRender), (.app, .playbackSource), (.app, .configureRenderRuntime), (.app, .renderRuntimeReadiness), (.cli, .pairedExecute), (.cli, .pairedImport), (.cli, .pairedRequestRender), (.cli, .pairedRenderStatus), (.cli, .pairedCancelRender), (.cli, .pairedMaterializeRender), (.cli, .pairedExportRender), (.cli, .pairedRenderContext): true
        default: false
        }
    }

    public static func respond(to request: AppAuthorityRequest, from role: PeerRole) -> AppAuthorityResponse {
        guard allows(request, for: role) else { return .failure(.creatorAuthorizationRequired) }
        do { return try handle(request) }
        catch { return .failure(workspaceFailure(error)) }
    }

    private static func token() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AuthorityFailure.unauthorized }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func handle(_ request: AppAuthorityRequest) throws -> AppAuthorityResponse {
        switch request {
        case let .importMedia(url, sources, operationID, credential):
            let authority = try ProjectAuthority(packageURL: url)
            beginImport(operationID)
            defer { finishImport(operationID) }
            return .importOutcomes(try authority.importManagedSources(sources, credential: String(decoding: credential, as: UTF8.self), shouldCancel: { isCancelled(operationID) }))
        case let .cancelImport(url, operationID, credential):
            let authority = try ProjectAuthority(packageURL: url)
            _ = try authority.openForAuthenticatedCreator(credential: String(decoding: credential, as: UTF8.self), rebindMovedPackage: false)
            cancelImport(operationID)
            return .success
        case let .open(url, rebind, credential):
            let authority = try ProjectAuthority(packageURL: url)
            let opened = try authority.openForAuthenticatedCreator(credential: String(decoding: credential, as: UTF8.self), rebindMovedPackage: rebind)
            RenderExecutionCoordinator.shared.reconcile(authority: authority)
            return .snapshot(WorkspaceSnapshot(document: opened.document, projectionMatches: opened.projectionMatches, packageURL: url))
        case let .create(url, name, recipe, credential):
            return .snapshot(try ProjectAuthority.createChannelPackage(at: url, name: name, initialRecipe: recipe, credential: String(decoding: credential, as: UTF8.self)))
        case let .execute(url, envelope, credential):
            let authority = try ProjectAuthority(packageURL: url)
            return .result(try authority.executeForAuthenticatedCreator(envelope, credential: String(decoding: credential, as: UTF8.self)))
        case let .pair(url, label, expires, credential):
            let authority = try ProjectAuthority(packageURL: url)
            let raw = try token()
            let grant = try authority.issuePairedCLIGrant(credential: String(decoding: credential, as: UTF8.self), label: label, scopes: [.editProject], expiresAt: expires, rawToken: raw)
            return .pairing(grant.id, raw)
        case let .revoke(url, grantID, credential):
            let authority = try ProjectAuthority(packageURL: url)
            try authority.revokePairedCLIGrant(credential: String(decoding: credential, as: UTF8.self), grantID: grantID)
            return .success
        case let .listGrants(url, credential):
            let authority = try ProjectAuthority(packageURL: url)
            return .grants(try authority.pairedCLIGrants(credential: String(decoding: credential, as: UTF8.self)))
        case let .requestRender(url, envelope, credential):
            let authority = try ProjectAuthority(packageURL: url)
            let creator = String(decoding: credential, as: UTF8.self)
            _ = try authority.openForAuthenticatedCreator(credential: creator, rebindMovedPackage: false)
            RenderExecutionCoordinator.shared.reconcile(authority: authority)
            let result = try authority.requestEpisodeRenderForAuthenticatedCreator(envelope, credential: creator)
            if case let .renderRequested(status) = result.outcome {
                let input = try authority.renderAttemptInputForAuthenticatedCreator(jobID: status.jobID, credential: creator)
                _ = RenderExecutionCoordinator.shared.start(authority: authority, input: input)
            }
            return .result(result)
        case let .renderStatus(url, jobID, credential):
            let authority = try ProjectAuthority(packageURL: url)
            let creator = String(decoding: credential, as: UTF8.self)
            _ = try authority.renderAttemptInputForAuthenticatedCreator(jobID: jobID, credential: creator)
            RenderExecutionCoordinator.shared.reconcile(authority: authority)
            let input = try authority.renderAttemptInputForAuthenticatedCreator(jobID: jobID, credential: creator)
            return .renderStatus(observedRenderStatus(input))
        case let .cancelRender(url, jobID, operationID, credential):
            let authority = try ProjectAuthority(packageURL: url)
            let creator = String(decoding: credential, as: UTF8.self)
            let input = try authority.renderAttemptInputForAuthenticatedCreator(jobID: jobID, credential: creator)
            let status = try authority.cancelEpisodeRenderForAuthenticatedCreator(jobID: jobID, operationID: operationID, credential: creator)
            RenderExecutionCoordinator.shared.cancel(projectID: input.snapshot.projectID, jobID: jobID)
            return .renderStatus(status)
        case let .materializeRender(url, jobID, operationID, credential):
            let authority = try ProjectAuthority(packageURL: url)
            let input = try authority.renderAttemptInputForAuthenticatedCreator(jobID: jobID, credential: String(decoding: credential, as: UTF8.self))
            return .renderMaterialization(try authority.recordRenderMaterialization(jobID: jobID, operationID: operationID, result: RenderExecutionCoordinator.shared.materialization(for: input)))
        case let .exportRender(url, jobID, operationID, destination, decision, credential):
            let authority = try ProjectAuthority(packageURL: url)
            let input = try authority.renderAttemptInputForAuthenticatedCreator(jobID: jobID, credential: String(decoding: credential, as: UTF8.self))
            if let replay = try authority.existingRenderExport(jobID: jobID, operationID: operationID, destination: destination, decision: decision) { return .renderExport(replay) }
            let result = try RenderExecutionCoordinator.shared.export(input: input, destination: destination)
            return .renderExport(try authority.recordRenderExport(jobID: jobID, operationID: operationID, destination: destination, decision: decision, result: result))
        case let .playbackSource(url, jobID, operationID, credential):
            let authority = try ProjectAuthority(packageURL: url)
            let input = try authority.playbackAttemptInputForAuthenticatedCreator(jobID: jobID, operationID: operationID, credential: String(decoding: credential, as: UTF8.self))
            guard let source = RenderExecutionCoordinator.shared.playbackSource(for: input) else { throw AuthorityFailure.renderUnavailable }
            return .renderPlaybackSource(source)
        case let .configureRenderRuntime(url, selectors, operationID, credential):
            let authority = try ProjectAuthority(packageURL: url)
            return .renderRuntimeReadiness(try authority.configureRenderRuntimeForAuthenticatedCreator(selectors: selectors, operationID: operationID, credential: String(decoding: credential, as: UTF8.self)))
        case let .renderRuntimeReadiness(url, credential):
            let authority = try ProjectAuthority(packageURL: url)
            return .renderRuntimeReadiness(try authority.renderRuntimeReadinessForAuthenticatedCreator(credential: String(decoding: credential, as: UTF8.self)))
        case let .pairedExecute(url, envelope, grantID, token):
            let authority = try ProjectAuthority(packageURL: url)
            return .result(try authority.execute(envelope, grantID: grantID, token: token))
        case let .pairedImport(url, sources, grantID, token):
            let authority = try ProjectAuthority(packageURL: url)
            return .importOutcomes(try authority.importManagedSources(sources, grantID: grantID, token: token))
        case let .pairedRequestRender(url, envelope, grantID, token):
            let authority = try ProjectAuthority(packageURL: url)
            _ = try authority.openForPairedRender(grantID: grantID, token: token)
            RenderExecutionCoordinator.shared.reconcile(authority: authority)
            let result = try authority.requestEpisodeRenderForPairedCLI(envelope, grantID: grantID, token: token)
            if case let .renderRequested(status) = result.outcome {
                let input = try authority.renderAttemptInputForPairedCLI(jobID: status.jobID, grantID: grantID, token: token)
                _ = RenderExecutionCoordinator.shared.start(authority: authority, input: input)
            }
            return .result(result)
        case let .pairedRenderStatus(url, jobID, grantID, token):
            let authority = try ProjectAuthority(packageURL: url)
            _ = try authority.renderAttemptInputForPairedCLI(jobID: jobID, grantID: grantID, token: token)
            RenderExecutionCoordinator.shared.reconcile(authority: authority)
            return .renderStatus(observedRenderStatus(try authority.renderAttemptInputForPairedCLI(jobID: jobID, grantID: grantID, token: token)))
        case let .pairedCancelRender(url, jobID, operationID, grantID, token):
            let authority = try ProjectAuthority(packageURL: url)
            let input = try authority.renderAttemptInputForPairedCLI(jobID: jobID, grantID: grantID, token: token)
            let status = try authority.cancelEpisodeRenderForPairedCLI(jobID: jobID, operationID: operationID, grantID: grantID, token: token)
            RenderExecutionCoordinator.shared.cancel(projectID: input.snapshot.projectID, jobID: jobID)
            return .renderStatus(status)
        case let .pairedMaterializeRender(url, jobID, operationID, grantID, token):
            let authority = try ProjectAuthority(packageURL: url)
            let input = try authority.renderAttemptInputForPairedCLI(jobID: jobID, grantID: grantID, token: token)
            return .renderMaterialization(try authority.recordRenderMaterialization(jobID: jobID, operationID: operationID, result: RenderExecutionCoordinator.shared.materialization(for: input)))
        case let .pairedExportRender(url, jobID, operationID, destination, decision, grantID, token):
            let authority = try ProjectAuthority(packageURL: url)
            let input = try authority.renderAttemptInputForPairedCLI(jobID: jobID, grantID: grantID, token: token)
            if let replay = try authority.existingRenderExport(jobID: jobID, operationID: operationID, destination: destination, decision: decision) { return .renderExport(replay) }
            let result = try RenderExecutionCoordinator.shared.export(input: input, destination: destination)
            return .renderExport(try authority.recordRenderExport(jobID: jobID, operationID: operationID, destination: destination, decision: decision, result: result))
        case let .pairedRenderContext(url, episodeID, grantID, token):
            let authority = try ProjectAuthority(packageURL: url)
            return .renderContext(try authority.renderContextForPairedCLI(episodeID: episodeID, grantID: grantID, token: token))
        }
    }

    // A cancellation can reach the listener before the copy request. Keep that
    // marker so the first copy boundary observes it instead of racing it away.
    private static func beginImport(_ id: UUID) {}
    private static func finishImport(_ id: UUID) { importLock.lock(); cancelledImports.remove(id); importLock.unlock() }
    private static func cancelImport(_ id: UUID) { importLock.lock(); cancelledImports.insert(id); importLock.unlock() }
    private static func isCancelled(_ id: UUID) -> Bool { importLock.lock(); defer { importLock.unlock() }; return cancelledImports.contains(id) }

    private static func observedRenderStatus(_ input: RenderAttemptInput) -> EpisodeRenderRequestStatus {
        EpisodeRenderRequestStatus(jobID: input.status.jobID, episodeID: input.status.episodeID, requestedRevision: input.status.requestedRevision, compositionDigest: input.status.compositionDigest, format: input.status.format, logicalState: input.status.logicalState, progress: input.status.progress, availability: RenderExecutionCoordinator.shared.availability(for: input))
    }

    public static func workspaceFailure(_ error: Error) -> WorkspaceFailure {
        if let failure = error as? ManagedImport.Failure {
            switch failure {
            case .invalidSource: return .rejected("Choose a readable regular file")
            case .sourceChanged: return .rejected("The source changed while it was copied; no media was added")
            case .objectCollision: return .rejected("An existing managed object does not match its digest")
            case .unsafePackagePath: return .rejected("Takeform refused an unsafe media storage path")
            case .unsupportedMedia: return .rejected("Takeform could not read supported media from the copied bytes")
            case .durability: return .rejected("Takeform could not durably promote this media")
            }
        }
        guard let error = error as? AuthorityFailure else { return .authorityUnavailable }
        switch error {
        case .copyDecisionRequired: return .copyDecisionRequired
        case .corruptDatabase: return .corruptProject
        case .newerSchema(let schema): return .newerSchema(schema)
        case .missingObject(let object): return .missingObject(object)
        default: return .rejected(error.localizedDescription)
        }
    }
}
