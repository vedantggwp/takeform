import Foundation
import CryptoKit
import Darwin
import TakeformAuthorityEngine
import TakeformCore
import TakeformWorkspace

public enum AuthorityFailure: Error, Equatable, LocalizedError {
    case corruptDatabase
    case missingObject(String)
    case projectionDrift
    case newerSchema(Int)
    case copyDecisionRequired
    case unauthorized
    case creationCollision
    case creationCleanupFailed
    case invalidComposition(CompositionValidationFailure)
    case missingRenderRequest
    case renderUnavailable
    public var errorDescription: String? { String(describing: self) }
}

public struct ProjectOpenState: Equatable, Sendable {
    public let document: ProjectDocument
    public let projectionMatches: Bool
}

private struct MachineState: Codable {
    var binding: MachineBinding?
    var grants: [Grant] = []
    var creatorCredentialDigest: String?
}

private struct MachineBinding: Codable {
    var canonicalPath: String
    var epoch: Int
}

private struct PortableManifest: Codable {
    let projectID: UUID
    let schema: Int
    let objects: [String]
}

private struct RenderCommandFingerprint: Codable {
    let expectedRevision: Revision
    let episodeID: UUID
    let requestedDigest: String
    let format: EpisodeRenderFormat
}

/// The operation table is portable, so it retains only a digest of a chosen
/// export location, never the location itself. This still prevents a caller
/// from reusing one operation ID for a different export request.
private struct RenderOperationFingerprint: Codable {
    let kind: String
    let jobID: UUID
    let destinationDigest: String?
    let exportDecision: EpisodeRenderExportDecision?
}

/// This is internal service input, not a portable public descriptor. The JSON
/// bytes are exactly those stored in project.sqlite and are hashed verbatim in
/// the worker request/receipt handshake.
struct RenderAttemptInput: Sendable {
    let status: EpisodeRenderRequestStatus
    let snapshot: EpisodeRenderSnapshot
    let snapshotJSON: Data
    /// Digest of the current machine binding, retained only by the service to
    /// prevent a machine-local artifact being reused after rebind or move.
    let machineBindingDigest: String
}

public final class ProjectAuthority {
    private let packageURL: URL
    private let initialProjectID: UUID?
    private let afterInitialBind: (() throws -> Void)?
    private var database: SQLiteDatabase!
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Internal to the app-service core. The worker coordinator resolves only
    /// assets that this authority has already revalidated for its package.
    var packageURLForRender: URL { packageURL }

    public convenience init(packageURL: URL) throws {
        try self.init(packageURL: packageURL, initialProjectID: nil, afterInitialBind: nil)
    }

    private init(packageURL: URL, initialProjectID: UUID?, afterInitialBind: (() throws -> Void)?) throws {
        // A newly selected package does not exist when its initial binding is
        // written. Resolving the whole URL at that point is path-stateful: the
        // same spelling can resolve differently once the package directory is
        // created. Resolve the existing parent instead, then retain the leaf,
        // so /tmp and /private/tmp agree across the UDS boundary without
        // silently adopting a package symlink as the selected project.
        self.packageURL = Self.canonicalPackageURL(packageURL)
        self.initialProjectID = initialProjectID
        self.afterInitialBind = afterInitialBind
        guard !self.packageURL.path.contains("/.takeform/") else { throw AuthorityFailure.unauthorized }
        encoder.outputFormatting = [.sortedKeys]
    }

    private static func canonicalPackageURL(_ input: URL) -> URL {
        let standardized = input.standardizedFileURL
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        return parent.appendingPathComponent(standardized.lastPathComponent, isDirectory: true).standardizedFileURL
    }

    public func open(rebindMovedPackage: Bool = false) throws -> ProjectOpenState {
        let stateURL = packageURL.appendingPathComponent(".takeform", isDirectory: true)
        let manifestURL = stateURL.appendingPathComponent("manifest.json")
        let manifest: PortableManifest
        let document: ProjectDocument
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            do { manifest = try decoder.decode(PortableManifest.self, from: Data(contentsOf: manifestURL)) }
            catch { throw AuthorityFailure.corruptDatabase }
            guard manifest.schema <= 1 else { throw AuthorityFailure.newerSchema(manifest.schema) }
            let state = try bind(projectID: manifest.projectID, rebindMovedPackage: rebindMovedPackage)
            if state.binding?.canonicalPath != packageURL.path { throw AuthorityFailure.copyDecisionRequired }
            guard FileManager.default.fileExists(atPath: stateURL.appendingPathComponent("project.sqlite").path) else { throw AuthorityFailure.missingObject("project.sqlite") }
            try openDatabase()
            document = try loadDocument()
            try validateManifest(document, manifest: manifest)
            try validateManagedAssets(document)
            try validateEpisodeCompositions(document)
        } else {
            guard !FileManager.default.fileExists(atPath: stateURL.appendingPathComponent("project.sqlite").path) else { throw AuthorityFailure.corruptDatabase }
            document = ProjectDocument(projectID: initialProjectID ?? UUID())
            _ = try bind(projectID: document.projectID, rebindMovedPackage: rebindMovedPackage)
            try afterInitialBind?()
            try openDatabase()
            try initialize(document)
            manifest = PortableManifest(projectID: document.projectID, schema: 1, objects: [])
        }
        _ = manifest
        let state = try loadMachineState(for: document.projectID)
        let binding = state.binding
        guard binding?.canonicalPath == packageURL.path else { throw AuthorityFailure.copyDecisionRequired }
        let projectionURL = packageURL.appendingPathComponent(".takeform/projection.json")
        let projection: ProjectDocument?
        do {
            projection = try decoder.decode(ProjectDocument.self, from: Data(contentsOf: projectionURL))
        } catch {
            projection = nil
        }
        return ProjectOpenState(document: document, projectionMatches: projection == document)
    }

    public func execute(_ envelope: CommandEnvelope, grantID: UUID?, token: String?) throws -> CommandResult {
        let openState = try open()
        let document = openState.document
        let bindingState = try loadMachineState(for: document.projectID)
        let binding = bindingState.binding
        let grant = grantID.flatMap { id in bindingState.grants.first(where: { $0.id == id }) }
        let presentedTokenDigest = token.map({ tokenDigest($0) })
        guard grant?.isActive == true, grant?.authorityEpoch == binding?.epoch, grant?.tokenDigest == presentedTokenDigest, grant?.scopes.contains(envelope.command.requiredScope) == true else { return CommandResult(id: envelope.id, outcome: .rejected(reason: "unauthorized")) }
        return try executeAuthorized(envelope)
    }

    func importManagedSources(_ sources: [URL], credential: String, shouldCancel: (() -> Bool)? = nil) throws -> [ManagedImportOutcome] {
        try importManagedSources(sources, shouldCancel: shouldCancel, authorize: {
            try self.openForAuthenticatedCreator(credential: credential, rebindMovedPackage: false)
        }, commit: { asset, opened in
            try self.executeForAuthenticatedCreator(CommandEnvelope(expectedRevision: opened.document.revision, command: .addManagedAsset(asset)), credential: credential)
        })
    }

    func importManagedSources(_ sources: [URL], grantID: UUID, token: String, shouldCancel: (() -> Bool)? = nil) throws -> [ManagedImportOutcome] {
        try importManagedSources(sources, shouldCancel: shouldCancel, authorize: {
            try self.openForPairedImport(grantID: grantID, token: token)
        }, commit: { asset, _ in
            let current = try self.openForPairedImport(grantID: grantID, token: token)
            return try self.executeAuthorized(CommandEnvelope(expectedRevision: current.document.revision, command: .addManagedAsset(asset)))
        })
    }

    private func importManagedSources(_ sources: [URL], shouldCancel: (() -> Bool)?, authorize: () throws -> ProjectOpenState, commit: (ManagedAsset, ProjectOpenState) throws -> CommandResult) throws -> [ManagedImportOutcome] {
        var outcomes: [ManagedImportOutcome] = []
        for (index, source) in sources.enumerated() {
            do {
                // Authenticate before allocating staging or touching package state.
                let opened = try authorize()
                let asset = try ManagedImport.stageAndPromoteSync(source: source, package: packageURL, shouldCancel: shouldCancel)
                if opened.document.assets.contains(where: { $0.digest == asset.digest }) { outcomes.append(.duplicate(digest: asset.digest, filename: asset.filename)); continue }
                let result = try commit(asset, opened)
                if case .applied = result.outcome { outcomes.append(.imported(asset)) } else { outcomes.append(.failed(filename: asset.filename, reason: "catalog conflict")) }
            } catch is CancellationError {
                outcomes.append(.cancelled(filename: source.lastPathComponent))
                outcomes.append(contentsOf: sources.dropFirst(index + 1).map { .cancelled(filename: $0.lastPathComponent) })
                break
            }
            catch { outcomes.append(.failed(filename: source.lastPathComponent, reason: String(describing: error))) }
        }
        return outcomes
    }

    private func openForPairedImport(grantID: UUID, token: String) throws -> ProjectOpenState {
        let opened = try open()
        let state = try loadMachineState(for: opened.document.projectID)
        let grant = state.grants.first(where: { $0.id == grantID })
        guard grant?.isActive == true,
              grant?.authorityEpoch == state.binding?.epoch,
              grant?.tokenDigest == tokenDigest(token),
              grant?.scopes.contains(.editProject) == true else { throw AuthorityFailure.unauthorized }
        return opened
    }

    private func executeAuthorized(_ envelope: CommandEnvelope) throws -> CommandResult {
        let result = try database.transaction {
            let before = try loadDocument()
            let fingerprint = try commandFingerprint(envelope, document: before)
            if let stored = try database.value("SELECT result FROM command_results WHERE id = ?", bindings: [envelope.id.value.uuidString]) {
                guard let existing = try database.value("SELECT fingerprint FROM command_results WHERE id = ?", bindings: [envelope.id.value.uuidString]), existing == fingerprint else {
                    return CommandResult(id: envelope.id, outcome: .rejected(reason: "command-id-reused-with-different-request"))
                }
                return try decode(CommandResult.self, stored)
            }
            guard before.revision == envelope.expectedRevision else {
                let result = CommandResult(id: envelope.id, outcome: .conflict(currentRevision: before.revision))
                try store(result, id: envelope.id, fingerprint: fingerprint)
                return result
            }
            if case let .requestEpisodeRender(episodeID, requestedDigest, format) = envelope.command {
                let result: CommandResult
                do {
                    result = try requestEpisodeRender(envelopeID: envelope.id, document: before, episodeID: episodeID, requestedDigest: requestedDigest, format: format)
                } catch let failure as CompositionValidationFailure {
                    result = CommandResult(id: envelope.id, outcome: .rejected(reason: failure.reason))
                } catch {
                    // The immutable snapshot cannot be handed to a worker when
                    // a referenced managed object fails authority verification.
                    result = CommandResult(id: envelope.id, outcome: .rejected(reason: "render-input-unavailable"))
                }
                try store(result, id: envelope.id, fingerprint: fingerprint)
                return result
            }
            let after: ProjectDocument
            do {
                after = try apply(envelope.command, to: before)
            } catch let failure as CompositionValidationFailure {
                let result = CommandResult(id: envelope.id, outcome: .rejected(reason: failure.reason))
                try store(result, id: envelope.id, fingerprint: fingerprint)
                return result
            }
            let result = CommandResult(id: envelope.id, outcome: .applied(document: after))
            try save(after)
            if case .undo = envelope.command {
                try database.execute("UPDATE history SET undone = 1 WHERE revision = (SELECT MAX(revision) FROM history WHERE undone = 0)")
            } else if case .redo = envelope.command {
                try database.execute("UPDATE history SET undone = 0 WHERE revision = (SELECT MAX(revision) FROM history WHERE undone = 1)")
            } else {
                try database.execute("INSERT INTO history(revision, before_state, after_state) VALUES (?, ?, ?)", bindings: [String(after.revision.value), try encode(before), try encode(after)])
            }
            try store(result, id: envelope.id, fingerprint: fingerprint)
            return result
        }
        if case .applied(let document) = result.outcome { try writeProjection(document) }
        return result
    }

    /// The only portable render operation is the logical request. It does not
    /// start a process or claim that an artifact is available on this machine.
    private func requestEpisodeRender(envelopeID: CommandID, document: ProjectDocument, episodeID: UUID, requestedDigest: String, format: EpisodeRenderFormat) throws -> CommandResult {
        guard let composition = document.episodeCompositions.first(where: { $0.episodeID == episodeID }) else {
            return CommandResult(id: envelopeID, outcome: .rejected(reason: "render-composition-missing"))
        }
        try composition.validate(episodes: document.episodes, assets: document.assets)
        let digest = digest(of: try composition.canonicalData())
        guard requestedDigest == digest else {
            return CommandResult(id: envelopeID, outcome: .rejected(reason: "render-composition-digest-mismatch"))
        }
        let referencedIDs = Set(composition.occurrences.map(\.assetID))
        let assets = document.assets.filter { referencedIDs.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
        guard assets.count == referencedIDs.count else {
            return CommandResult(id: envelopeID, outcome: .rejected(reason: "render-asset-missing"))
        }
        for asset in assets { try ManagedImport.verifyObject(asset, package: packageURL) }
        let snapshot = EpisodeRenderSnapshot(projectID: document.projectID, episodeID: episodeID, requestedRevision: document.revision, compositionDigest: digest, format: format, composition: composition, assets: assets.map(EpisodeRenderSnapshot.Asset.init(asset:)))
        let status = EpisodeRenderRequestStatus(jobID: UUID(), episodeID: episodeID, requestedRevision: document.revision, compositionDigest: digest, format: format, logicalState: .requested, progress: .indeterminate, availability: .unavailable)
        try database.execute("INSERT INTO render_requests(job_id, command_id, episode_id, expected_revision, composition_digest, format, snapshot, logical_state) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", bindings: [status.jobID.uuidString, envelopeID.value.uuidString, episodeID.uuidString, String(document.revision.value), digest, format.rawValue, try encode(snapshot), status.logicalState.rawValue])
        return CommandResult(id: envelopeID, outcome: .renderRequested(status))
    }

    private func commandFingerprint(_ envelope: CommandEnvelope, document: ProjectDocument) throws -> String {
        guard case let .requestEpisodeRender(episodeID, requestedDigest, format) = envelope.command else { return try encode(envelope) }
        return try encode(RenderCommandFingerprint(expectedRevision: envelope.expectedRevision, episodeID: episodeID, requestedDigest: requestedDigest, format: format))
    }

    private func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func initialize(_ document: ProjectDocument) throws {
        try save(document)
        let manifest = PortableManifest(projectID: document.projectID, schema: 1, objects: [])
        let data = try encoder.encode(manifest)
        try data.write(to: packageURL.appendingPathComponent(".takeform/manifest.json"), options: .atomic)
        try writeProjection(document)
    }

    private func validateManifest(_ document: ProjectDocument, manifest: PortableManifest) throws {
        guard manifest.projectID == document.projectID else { throw AuthorityFailure.corruptDatabase }
        guard manifest.schema <= 1 else { throw AuthorityFailure.newerSchema(manifest.schema) }
        for object in manifest.objects {
            let components = URL(fileURLWithPath: object).pathComponents
            guard !object.isEmpty, !object.hasPrefix("/"), !components.contains("..") else {
                throw AuthorityFailure.missingObject("invalid relative object inventory")
            }
            guard FileManager.default.fileExists(atPath: packageURL.appendingPathComponent(".takeform/\(object)").path) else {
                throw AuthorityFailure.missingObject(object)
            }
        }
    }

    /// The SQLite document is the portable catalog. Object paths are never
    /// stored in it: each is derived from the validated digest and hashed on
    /// reopen so a damaged package cannot quietly appear empty.
    private func validateManagedAssets(_ document: ProjectDocument) throws {
        var digests = Set<String>()
        for asset in document.assets {
            guard digests.insert(asset.digest).inserted else { throw AuthorityFailure.corruptDatabase }
            try ManagedImport.verifyObject(asset, package: packageURL)
        }
    }

    private func validateEpisodeCompositions(_ document: ProjectDocument) throws {
        var episodeIDs = Set<UUID>()
        for composition in document.episodeCompositions {
            guard episodeIDs.insert(composition.episodeID).inserted else { throw AuthorityFailure.corruptDatabase }
            do { try composition.validate(episodes: document.episodes, assets: document.assets) }
            catch { throw AuthorityFailure.corruptDatabase }
        }
    }

    private func apply(_ command: ProjectCommand, to document: ProjectDocument) throws -> ProjectDocument {
        var next = document
        switch command {
        case .createChannel(let name, let values):
            guard next.channel == nil, !name.isEmpty else { return document }
            next.channel = Channel(name: name)
            next.recipes = [RecipeVersion(id: 1, values: values)]
        case .renameChannel(let name):
            guard !name.isEmpty, var channel = next.channel else { return document }
            channel.name = name; next.channel = channel
        case .publishRecipe(let values):
            guard next.channel != nil else { return document }
            next.recipes.append(RecipeVersion(id: (next.recipes.map(\.id).max() ?? 0) + 1, values: values))
        case .createEpisode(let name, let recipeVersion):
            guard !name.isEmpty, next.recipes.contains(where: { $0.id == recipeVersion }) else { return document }
            next.episodes.append(Episode(name: name, recipeVersion: recipeVersion))
        case .setOverride(let episodeID, let key, let value):
            guard next.episodes.contains(where: { $0.id == episodeID }), !key.isEmpty else { return document }
            next.overrides.removeAll { $0.episodeID == episodeID && $0.key == key }
            next.overrides.append(Override(episodeID: episodeID, key: key, value: value))
        case .resetOverride(let episodeID, let key):
            next.overrides.removeAll { $0.episodeID == episodeID && $0.key == key }
        case .addManagedAsset(let asset):
            guard asset.digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, asset.byteLength > 0, !asset.filename.isEmpty, !next.assets.contains(where: { $0.digest == asset.digest }) else { return document }
            next.assets.append(asset)
        case .replaceEpisodeComposition(let episodeID, let composition):
            guard episodeID == composition.episodeID else { throw CompositionValidationFailure.episodeMismatch }
            try composition.validate(episodes: next.episodes, assets: next.assets)
            next.episodeCompositions.removeAll { $0.episodeID == episodeID }
            next.episodeCompositions.append(composition)
        case .requestEpisodeRender:
            return document
        case .undo:
            guard let row = try database.row("SELECT before_state FROM history WHERE undone = 0 ORDER BY revision DESC LIMIT 1") else { return document }
            var restored = try decode(ProjectDocument.self, row[0])
            restored.revision = Revision(document.revision.value + 1)
            return restored
        case .redo:
            guard let row = try database.row("SELECT after_state FROM history WHERE undone = 1 ORDER BY revision DESC LIMIT 1") else { return document }
            var restored = try decode(ProjectDocument.self, row[0])
            restored.revision = Revision(document.revision.value + 1)
            return restored
        }
        next.revision = Revision(document.revision.value + 1)
        return next
    }

    /// Internal app-service input for the machine worker. It stays outside the
    /// portable public authority API and carries no local worker descriptor.
    func renderAttemptInput(jobID: UUID) throws -> RenderAttemptInput {
        guard let row = try database.row("SELECT episode_id, expected_revision, composition_digest, format, logical_state, snapshot FROM render_requests WHERE job_id = ?", bindings: [jobID.uuidString]),
              row.count == 6,
              let episodeID = UUID(uuidString: row[0]),
              let revision = Int64(row[1]),
              let format = EpisodeRenderFormat(rawValue: row[3]),
              let logicalState = EpisodeRenderLogicalState(rawValue: row[4]) else { throw AuthorityFailure.missingRenderRequest }
        let snapshotJSON = Data(row[5].utf8)
        let snapshot = try decode(EpisodeRenderSnapshot.self, row[5])
        guard snapshot.episodeID == episodeID,
              snapshot.requestedRevision == Revision(revision),
              snapshot.compositionDigest == row[2],
              snapshot.format == format else { throw AuthorityFailure.corruptDatabase }
        let machine = try loadMachineState(for: snapshot.projectID)
        guard let binding = machine.binding, binding.canonicalPath == packageURL.path else { throw AuthorityFailure.copyDecisionRequired }
        let status = EpisodeRenderRequestStatus(jobID: jobID, episodeID: episodeID, requestedRevision: Revision(revision), compositionDigest: row[2], format: format, logicalState: logicalState, progress: .indeterminate, availability: .unavailable)
        return RenderAttemptInput(status: status, snapshot: snapshot, snapshotJSON: snapshotJSON, machineBindingDigest: digest(of: try encoder.encode(binding)))
    }

    private func renderStatus(jobID: UUID) throws -> EpisodeRenderRequestStatus {
        try renderAttemptInput(jobID: jobID).status
    }

    /// Called only by the app-service-owned worker coordinator. A late receipt
    /// cannot change a cancelled or superseded logical request.
    func transitionRenderRequest(jobID: UUID, snapshotSHA256: String, to state: EpisodeRenderLogicalState) throws -> EpisodeRenderRequestStatus {
        try database.transaction {
            let input = try renderAttemptInput(jobID: jobID)
            guard digest(of: input.snapshotJSON) == snapshotSHA256 else { throw AuthorityFailure.unauthorized }
            guard input.status.logicalState == .requested else { return input.status }
            try database.execute("UPDATE render_requests SET logical_state = ? WHERE job_id = ?", bindings: [state.rawValue, jobID.uuidString])
            return EpisodeRenderRequestStatus(jobID: input.status.jobID, episodeID: input.status.episodeID, requestedRevision: input.status.requestedRevision, compositionDigest: input.status.compositionDigest, format: input.status.format, logicalState: state, progress: .indeterminate, availability: .unavailable)
        }
    }

    private func cancelRender(jobID: UUID, operationID: CommandID) throws -> EpisodeRenderRequestStatus {
        try database.transaction {
            let fingerprint = "cancel:\(jobID.uuidString)"
            if let stored = try database.value("SELECT result FROM render_operation_results WHERE id = ?", bindings: [operationID.value.uuidString]) {
                guard let previousFingerprint = try database.value("SELECT fingerprint FROM render_operation_results WHERE id = ?", bindings: [operationID.value.uuidString]), previousFingerprint == fingerprint else { throw AuthorityFailure.unauthorized }
                return try decode(EpisodeRenderRequestStatus.self, stored)
            }
            let current = try renderStatus(jobID: jobID)
            let nextState: EpisodeRenderLogicalState = current.logicalState == .requested ? .cancelled : current.logicalState
            try database.execute("UPDATE render_requests SET logical_state = ? WHERE job_id = ?", bindings: [nextState.rawValue, jobID.uuidString])
            let status = EpisodeRenderRequestStatus(jobID: current.jobID, episodeID: current.episodeID, requestedRevision: current.requestedRevision, compositionDigest: current.compositionDigest, format: current.format, logicalState: nextState, progress: .indeterminate, availability: .unavailable)
            try database.execute("INSERT INTO render_operation_results(id, fingerprint, result) VALUES (?, ?, ?)", bindings: [operationID.value.uuidString, fingerprint, try encode(status)])
            return status
        }
    }

    private func recordReadOperation(jobID: UUID, operationID: CommandID, kind: String, destination: URL? = nil, exportDecision: EpisodeRenderExportDecision? = nil) throws -> EpisodeRenderRequestStatus {
        try database.transaction {
            let destinationDigest = destination.map { digest(of: Data($0.standardizedFileURL.path.utf8)) }
            let fingerprint = try encode(RenderOperationFingerprint(kind: kind, jobID: jobID, destinationDigest: destinationDigest, exportDecision: exportDecision))
            if let stored = try database.value("SELECT result FROM render_operation_results WHERE id = ?", bindings: [operationID.value.uuidString]) {
                guard let previousFingerprint = try database.value("SELECT fingerprint FROM render_operation_results WHERE id = ?", bindings: [operationID.value.uuidString]), previousFingerprint == fingerprint else { throw AuthorityFailure.unauthorized }
                return try decode(EpisodeRenderRequestStatus.self, stored)
            }
            let status = try renderStatus(jobID: jobID)
            try database.execute("INSERT INTO render_operation_results(id, fingerprint, result) VALUES (?, ?, ?)", bindings: [operationID.value.uuidString, fingerprint, try encode(status)])
            return status
        }
    }

    /// Materialization and export persist their own typed operation result so
    /// an idempotent retry never changes from an unavailable response into a
    /// descriptor merely because a later worker attempt finished.
    func recordRenderMaterialization(jobID: UUID, operationID: CommandID, result: EpisodeRenderMaterialization) throws -> EpisodeRenderMaterialization {
        try recordTypedRenderOperation(table: "render_materialization_results", jobID: jobID, operationID: operationID, fingerprint: try encode(RenderOperationFingerprint(kind: "materialize", jobID: jobID, destinationDigest: nil, exportDecision: nil)), result: result)
    }

    func recordRenderExport(jobID: UUID, operationID: CommandID, destination: URL, decision: EpisodeRenderExportDecision, result: EpisodeRenderExportResult) throws -> EpisodeRenderExportResult {
        let destinationDigest = digest(of: Data(destination.standardizedFileURL.path.utf8))
        let fingerprint = try encode(RenderOperationFingerprint(kind: "export", jobID: jobID, destinationDigest: destinationDigest, exportDecision: decision))
        return try recordTypedRenderOperation(table: "render_export_results", jobID: jobID, operationID: operationID, fingerprint: fingerprint, result: result)
    }

    func existingRenderExport(jobID: UUID, operationID: CommandID, destination: URL, decision: EpisodeRenderExportDecision) throws -> EpisodeRenderExportResult? {
        let destinationDigest = digest(of: Data(destination.standardizedFileURL.path.utf8))
        let fingerprint = try encode(RenderOperationFingerprint(kind: "export", jobID: jobID, destinationDigest: destinationDigest, exportDecision: decision))
        guard let stored = try database.value("SELECT result FROM render_export_results WHERE id = ?", bindings: [operationID.value.uuidString]) else { return nil }
        guard let previousFingerprint = try database.value("SELECT fingerprint FROM render_export_results WHERE id = ?", bindings: [operationID.value.uuidString]), previousFingerprint == fingerprint else { throw AuthorityFailure.unauthorized }
        return try decode(EpisodeRenderExportResult.self, stored)
    }

    private func recordTypedRenderOperation<Result: Codable>(table: String, jobID: UUID, operationID: CommandID, fingerprint: String, result: Result) throws -> Result {
        try database.transaction {
            if let stored = try database.value("SELECT result FROM \(table) WHERE id = ?", bindings: [operationID.value.uuidString]) {
                guard let previousFingerprint = try database.value("SELECT fingerprint FROM \(table) WHERE id = ?", bindings: [operationID.value.uuidString]), previousFingerprint == fingerprint else { throw AuthorityFailure.unauthorized }
                return try decode(Result.self, stored)
            }
            _ = try renderStatus(jobID: jobID)
            try database.execute("INSERT INTO \(table)(id, fingerprint, result) VALUES (?, ?, ?)", bindings: [operationID.value.uuidString, fingerprint, try encode(result)])
            return result
        }
    }

    private func loadDocument() throws -> ProjectDocument {
        guard let value = try database.value("SELECT value FROM project_state WHERE key = 'document'") else { throw AuthorityFailure.corruptDatabase }
        return try decode(ProjectDocument.self, value)
    }

    private func save(_ document: ProjectDocument) throws { try database.execute("INSERT OR REPLACE INTO project_state(key, value) VALUES ('document', ?)", bindings: [try encode(document)]) }
    private func store(_ result: CommandResult, id: CommandID, fingerprint: String) throws { try database.execute("INSERT INTO command_results(id, fingerprint, result) VALUES (?, ?, ?)", bindings: [id.value.uuidString, fingerprint, try encode(result)]) }
    private func writeProjection(_ document: ProjectDocument) throws { try encoder.encode(document).write(to: packageURL.appendingPathComponent(".takeform/projection.json"), options: .atomic) }
    private func encode<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    private func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T { try decoder.decode(type, from: Data(value.utf8)) }
    private func machineURL(for projectID: UUID) throws -> URL {
        let url = try Self.machineStateURL(for: projectID)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func machineStateURL(for projectID: UUID) throws -> URL {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw AuthorityFailure.unauthorized }
        return root.appendingPathComponent("Takeform/Authority/\(projectID.uuidString)", isDirectory: true)
    }
    private func bind(projectID: UUID, rebindMovedPackage: Bool) throws -> MachineState {
        var state = try loadMachineState(for: projectID)
        let binding = state.binding
        if let binding, binding.canonicalPath != packageURL.path, !rebindMovedPackage { throw AuthorityFailure.copyDecisionRequired }
        if binding?.canonicalPath != packageURL.path {
            state.binding = MachineBinding(canonicalPath: packageURL.path, epoch: (binding?.epoch ?? 0) + 1)
            if binding != nil { state.grants = [] }
            try saveMachineState(state, for: projectID)
        }
        return state
    }
    private func openDatabase() throws {
        guard database == nil else { return }
        let stateURL = packageURL.appendingPathComponent(".takeform", isDirectory: true)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        do {
            let opened = try SQLiteDatabase(path: stateURL.appendingPathComponent("project.sqlite"))
            try opened.execute("CREATE TABLE IF NOT EXISTS project_state (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try opened.execute("CREATE TABLE IF NOT EXISTS command_results (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, result TEXT NOT NULL)")
            try opened.execute("CREATE TABLE IF NOT EXISTS history (revision INTEGER PRIMARY KEY, before_state TEXT NOT NULL, after_state TEXT NOT NULL, undone INTEGER NOT NULL DEFAULT 0)")
            try opened.execute("CREATE TABLE IF NOT EXISTS render_requests (job_id TEXT PRIMARY KEY, command_id TEXT UNIQUE NOT NULL, episode_id TEXT NOT NULL, expected_revision INTEGER NOT NULL, composition_digest TEXT NOT NULL, format TEXT NOT NULL, snapshot TEXT NOT NULL, logical_state TEXT NOT NULL)")
            try opened.execute("CREATE TABLE IF NOT EXISTS render_operation_results (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, result TEXT NOT NULL)")
            try opened.execute("CREATE TABLE IF NOT EXISTS render_materialization_results (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, result TEXT NOT NULL)")
            try opened.execute("CREATE TABLE IF NOT EXISTS render_export_results (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, result TEXT NOT NULL)")
            database = opened
        } catch { throw AuthorityFailure.corruptDatabase }
    }
    private func loadMachineState(for projectID: UUID) throws -> MachineState {
        let url = try machineURL(for: projectID).appendingPathComponent("binding.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return MachineState() }
        return try decoder.decode(MachineState.self, from: Data(contentsOf: url))
    }
    private func saveMachineState(_ state: MachineState, for projectID: UUID) throws { try encoder.encode(state).write(to: machineURL(for: projectID).appendingPathComponent("binding.json"), options: .atomic) }
    private func tokenDigest(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }
}

extension ProjectAuthority {
    static func createChannelPackage(at destination: URL, name: String, initialRecipe: [String: String], credential: String, temporaryDirectoryName: String? = nil, afterInitialBind: (() throws -> Void)? = nil, afterInitialize: (() throws -> Void)? = nil) throws -> WorkspaceSnapshot {
        let destination = destination.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destination.path), !name.isEmpty else { throw AuthorityFailure.unauthorized }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).creating-\(temporaryDirectoryName ?? UUID().uuidString)")
        let temporaryProjectID = UUID()
        var temporaryOwned = false
        var movedToDestination = false
        func removeOwnedArtifacts() -> Bool {
            guard temporaryOwned else { return false }
            let ownedURLs = [temporary] + (movedToDestination ? [destination] : [])
            var cleanupFailed = false
            for url in ownedURLs where FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.removeItem(at: url) }
                catch { cleanupFailed = true }
            }
            do {
                let machineStateURL = try Self.machineStateURL(for: temporaryProjectID)
                if FileManager.default.fileExists(atPath: machineStateURL.path) { try FileManager.default.removeItem(at: machineStateURL) }
            } catch {
                cleanupFailed = true
            }
            return cleanupFailed
        }
        do {
            try reserveTemporaryDirectory(at: temporary)
            temporaryOwned = true
            let authority = try ProjectAuthority(packageURL: temporary, initialProjectID: temporaryProjectID, afterInitialBind: afterInitialBind)
            let opened = try authority.openForAuthenticatedCreator(credential: credential, rebindMovedPackage: false)
            try afterInitialize?()
            let result = try authority.executeForAuthenticatedCreator(CommandEnvelope(expectedRevision: opened.document.revision, command: .createChannel(name: name, initialRecipe: initialRecipe)), credential: credential)
            guard case let .applied(document) = result.outcome else { throw AuthorityFailure.unauthorized }
            try FileManager.default.moveItem(at: temporary, to: destination)
            movedToDestination = true
            let moved = try ProjectAuthority(packageURL: destination)
            _ = try moved.openForAuthenticatedCreator(credential: credential, rebindMovedPackage: true)
            return WorkspaceSnapshot(document: document, projectionMatches: true, packageURL: destination.standardizedFileURL)
        } catch {
            if removeOwnedArtifacts() { throw AuthorityFailure.creationCleanupFailed }
            throw error
        }
    }

    private static func reserveTemporaryDirectory(at url: URL) throws {
        guard Darwin.mkdir(url.path, S_IRWXU) == 0 else {
            if errno == EEXIST { throw AuthorityFailure.creationCollision }
            throw AuthorityFailure.unauthorized
        }
    }
}

extension ProjectAuthority {
    /// Service-only native path. Its credential is never accepted by CLI commands.
    public func openForAuthenticatedCreator(credential: String, rebindMovedPackage: Bool) throws -> ProjectOpenState {
        let projectID = try portableProjectID()
        let state = try loadMachineState(for: projectID)
        let digest = tokenDigest(credential)
        if let binding = state.binding {
            if let existingDigest = state.creatorCredentialDigest {
                guard existingDigest == digest else { throw AuthorityFailure.unauthorized }
            } else {
                // First creator registration can only adopt the already-bound path. A
                // moved package never acquires a creator credential through rebind.
                guard binding.canonicalPath == packageURL.path else { throw AuthorityFailure.copyDecisionRequired }
            }
            if binding.canonicalPath != packageURL.path && !rebindMovedPackage { throw AuthorityFailure.copyDecisionRequired }
        }
        let opened = try open(rebindMovedPackage: rebindMovedPackage)
        var updated = try loadMachineState(for: opened.document.projectID)
        if updated.creatorCredentialDigest == nil { updated.creatorCredentialDigest = digest; try saveMachineState(updated, for: opened.document.projectID) }
        guard updated.creatorCredentialDigest == digest else { throw AuthorityFailure.unauthorized }
        return opened
    }

    public func executeForAuthenticatedCreator(_ envelope: CommandEnvelope, credential: String) throws -> CommandResult {
        let opened = try openForAuthenticatedCreator(credential: credential, rebindMovedPackage: false)
        let state = try loadMachineState(for: opened.document.projectID)
        guard state.creatorCredentialDigest == tokenDigest(credential) else { throw AuthorityFailure.unauthorized }
        return try executeAuthorized(envelope)
    }

    public func requestEpisodeRenderForAuthenticatedCreator(_ envelope: CommandEnvelope, credential: String) throws -> CommandResult {
        guard case .requestEpisodeRender = envelope.command else { throw AuthorityFailure.unauthorized }
        return try executeForAuthenticatedCreator(envelope, credential: credential)
    }

    public func requestEpisodeRenderForPairedCLI(_ envelope: CommandEnvelope, grantID: UUID, token: String) throws -> CommandResult {
        guard case .requestEpisodeRender = envelope.command else { throw AuthorityFailure.unauthorized }
        return try execute(envelope, grantID: grantID, token: token)
    }

    public func renderStatusForAuthenticatedCreator(jobID: UUID, credential: String) throws -> EpisodeRenderRequestStatus {
        _ = try openForAuthenticatedCreator(credential: credential, rebindMovedPackage: false)
        return try renderStatus(jobID: jobID)
    }

    func renderAttemptInputForAuthenticatedCreator(jobID: UUID, credential: String) throws -> RenderAttemptInput {
        _ = try openForAuthenticatedCreator(credential: credential, rebindMovedPackage: false)
        return try renderAttemptInput(jobID: jobID)
    }

    public func renderStatusForPairedCLI(jobID: UUID, grantID: UUID, token: String) throws -> EpisodeRenderRequestStatus {
        _ = try openForPairedImport(grantID: grantID, token: token)
        return try renderStatus(jobID: jobID)
    }

    func renderAttemptInputForPairedCLI(jobID: UUID, grantID: UUID, token: String) throws -> RenderAttemptInput {
        _ = try openForPairedImport(grantID: grantID, token: token)
        return try renderAttemptInput(jobID: jobID)
    }

    public func cancelEpisodeRenderForAuthenticatedCreator(jobID: UUID, operationID: CommandID, credential: String) throws -> EpisodeRenderRequestStatus {
        _ = try openForAuthenticatedCreator(credential: credential, rebindMovedPackage: false)
        return try cancelRender(jobID: jobID, operationID: operationID)
    }

    public func cancelEpisodeRenderForPairedCLI(jobID: UUID, operationID: CommandID, grantID: UUID, token: String) throws -> EpisodeRenderRequestStatus {
        _ = try openForPairedImport(grantID: grantID, token: token)
        return try cancelRender(jobID: jobID, operationID: operationID)
    }

    public func materializeEpisodeRenderForAuthenticatedCreator(jobID: UUID, operationID: CommandID, credential: String) throws -> EpisodeRenderMaterialization {
        _ = try openForAuthenticatedCreator(credential: credential, rebindMovedPackage: false)
        return .unavailable(try recordReadOperation(jobID: jobID, operationID: operationID, kind: "materialize"))
    }

    public func materializeEpisodeRenderForPairedCLI(jobID: UUID, operationID: CommandID, grantID: UUID, token: String) throws -> EpisodeRenderMaterialization {
        _ = try openForPairedImport(grantID: grantID, token: token)
        return .unavailable(try recordReadOperation(jobID: jobID, operationID: operationID, kind: "materialize"))
    }

    public func exportEpisodeRenderForAuthenticatedCreator(jobID: UUID, operationID: CommandID, destination: URL, decision: EpisodeRenderExportDecision, credential: String) throws -> EpisodeRenderExportResult {
        _ = try openForAuthenticatedCreator(credential: credential, rebindMovedPackage: false)
        return .unavailable(try recordReadOperation(jobID: jobID, operationID: operationID, kind: "export", destination: destination, exportDecision: decision))
    }

    public func exportEpisodeRenderForPairedCLI(jobID: UUID, operationID: CommandID, destination: URL, decision: EpisodeRenderExportDecision, grantID: UUID, token: String) throws -> EpisodeRenderExportResult {
        _ = try openForPairedImport(grantID: grantID, token: token)
        return .unavailable(try recordReadOperation(jobID: jobID, operationID: operationID, kind: "export", destination: destination, exportDecision: decision))
    }

    public func issuePairedCLIGrant(credential: String, label: String, scopes: Set<GrantScope>, expiresAt: Date, rawToken: String) throws -> Grant {
        let opened = try openForAuthenticatedCreator(credential: credential, rebindMovedPackage: false)
        var state = try loadMachineState(for: opened.document.projectID)
        guard let epoch = state.binding?.epoch else { throw AuthorityFailure.unauthorized }
        let grant = Grant(label: label, scopes: scopes, expiresAt: expiresAt, authorityEpoch: epoch, tokenDigest: tokenDigest(rawToken))
        state.grants.append(grant); try saveMachineState(state, for: opened.document.projectID); return grant
    }

    public func revokePairedCLIGrant(credential: String, grantID: UUID) throws {
        let opened = try openForAuthenticatedCreator(credential: credential, rebindMovedPackage: false)
        var state = try loadMachineState(for: opened.document.projectID)
        guard let index = state.grants.firstIndex(where: { $0.id == grantID }) else { throw AuthorityFailure.unauthorized }
        state.grants[index].revokedAt = Date()
        try saveMachineState(state, for: opened.document.projectID)
    }

    public func pairedCLIGrants(credential: String) throws -> [CLIPairingSummary] {
        let opened = try openForAuthenticatedCreator(credential: credential, rebindMovedPackage: false)
        let state = try loadMachineState(for: opened.document.projectID)
        return state.grants.map { CLIPairingSummary(id: $0.id, label: $0.label, scopes: $0.scopes, expiresAt: $0.expiresAt, revokedAt: $0.revokedAt) }
    }

    private func portableProjectID() throws -> UUID {
        let manifestURL = packageURL.appendingPathComponent(".takeform/manifest.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            guard let manifest = try? decoder.decode(PortableManifest.self, from: Data(contentsOf: manifestURL)) else { throw AuthorityFailure.corruptDatabase }
            return manifest.projectID
        }
        return try open().document.projectID
    }
}
