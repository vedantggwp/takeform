import Foundation
import CryptoKit
import TakeformCore

public enum AuthorityFailure: Error, Equatable, LocalizedError {
    case corruptDatabase
    case missingObject(String)
    case projectionDrift
    case newerSchema(Int)
    case copyDecisionRequired
    case unauthorized
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

public final class ProjectAuthority {
    private let packageURL: URL
    private var database: SQLiteDatabase!
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(packageURL: URL) throws {
        self.packageURL = packageURL.standardizedFileURL
        guard !self.packageURL.path.contains("/.takeform/") else { throw AuthorityFailure.unauthorized }
        encoder.outputFormatting = [.sortedKeys]
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
        } else {
            guard !FileManager.default.fileExists(atPath: stateURL.appendingPathComponent("project.sqlite").path) else { throw AuthorityFailure.corruptDatabase }
            document = ProjectDocument()
            _ = try bind(projectID: document.projectID, rebindMovedPackage: rebindMovedPackage)
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
        let result = try database.transaction {
            let fingerprint = try encode(envelope)
            if let stored = try database.value("SELECT result FROM command_results WHERE id = ?", bindings: [envelope.id.value.uuidString]) {
                guard let existing = try database.value("SELECT fingerprint FROM command_results WHERE id = ?", bindings: [envelope.id.value.uuidString]), existing == fingerprint else {
                    return CommandResult(id: envelope.id, outcome: .rejected(reason: "command-id-reused-with-different-request"))
                }
                return try decode(CommandResult.self, stored)
            }
            let before = try loadDocument()
            guard before.revision == envelope.expectedRevision else {
                let result = CommandResult(id: envelope.id, outcome: .conflict(currentRevision: before.revision))
                try store(result, id: envelope.id, fingerprint: fingerprint)
                return result
            }
            let after = try apply(envelope.command, to: before)
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
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw AuthorityFailure.unauthorized }
        let url = root.appendingPathComponent("Takeform/Authority/\(projectID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

@_spi(AuthorityAppService)
public struct AuthorityCreatorSession: Sendable {
    fileprivate let credential: String
    fileprivate init(credential: String) { self.credential = credential }
}

@_spi(AuthorityAppService)
public enum AuthorityAppServiceGate {
    /// Only the UDS service invokes this after code-identity and connection checks.
    public static func session(creatorCredential: String) -> AuthorityCreatorSession { AuthorityCreatorSession(credential: creatorCredential) }
}

extension ProjectAuthority {
    @_spi(AuthorityAppService)
    public func establishCreator(_ session: AuthorityCreatorSession) throws {
        let openState = try open()
        var state = try loadMachineState(for: openState.document.projectID)
        let digest = tokenDigest(session.credential)
        if let existing = state.creatorCredentialDigest, existing != digest { throw AuthorityFailure.unauthorized }
        state.creatorCredentialDigest = digest
        try saveMachineState(state, for: openState.document.projectID)
    }

    @_spi(AuthorityAppService)
    public func issueCLIGrant(_ session: AuthorityCreatorSession, label: String, scopes: Set<GrantScope>, expiresAt: Date, rawToken: String) throws -> Grant {
        let openState = try open()
        var state = try loadMachineState(for: openState.document.projectID)
        guard state.creatorCredentialDigest == tokenDigest(session.credential), let epoch = state.binding?.epoch else { throw AuthorityFailure.unauthorized }
        let grant = Grant(label: label, scopes: scopes, expiresAt: expiresAt, authorityEpoch: epoch, tokenDigest: tokenDigest(rawToken))
        state.grants.append(grant); try saveMachineState(state, for: openState.document.projectID); return grant
    }

    @_spi(AuthorityAppService)
    public func revokeCLIGrant(_ session: AuthorityCreatorSession, grantID: UUID) throws {
        let openState = try open(); var state = try loadMachineState(for: openState.document.projectID)
        guard state.creatorCredentialDigest == tokenDigest(session.credential) else { throw AuthorityFailure.unauthorized }
        guard let i = state.grants.firstIndex(where: { $0.id == grantID }) else { return }
        state.grants[i].revokedAt = Date(); try saveMachineState(state, for: openState.document.projectID)
    }
}
