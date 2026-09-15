import Foundation
import TakeformCore

public enum WorkspaceFailure: Error, Equatable, LocalizedError, Sendable, Codable {
    case authorityUnavailable
    case creatorAuthorizationRequired
    case copyDecisionRequired
    case corruptProject
    case newerSchema(Int)
    case missingObject(String)
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .authorityUnavailable: "The project authority is unavailable. Open Takeform, then try again. No changes were made."
        case .creatorAuthorizationRequired: "Creator authorization is required before Takeform can change this project."
        case .copyDecisionRequired: "This project identity is already bound at another location. Choose how to reopen it before editing."
        case .corruptProject: "Takeform could not read this project. Its files were left unchanged."
        case .newerSchema(let schema): "This project uses newer schema \(schema). Update Takeform before opening it."
        case .missingObject(let object): "This project is missing \(object). Its files were left unchanged."
        case .rejected(let reason): "The authority rejected this change: \(reason)."
        }
    }
}

public struct WorkspaceSnapshot: Equatable, Sendable, Codable {
    public let document: ProjectDocument
    public let projectionMatches: Bool
    public let packageURL: URL

    public init(document: ProjectDocument, projectionMatches: Bool, packageURL: URL) {
        self.document = document
        self.projectionMatches = projectionMatches
        self.packageURL = packageURL
    }
}

public struct CLIPairingSummary: Equatable, Sendable, Codable, Identifiable {
    public let id: UUID
    public let label: String
    public let scopes: Set<GrantScope>
    public let expiresAt: Date
    public let revokedAt: Date?
    public init(id: UUID, label: String, scopes: Set<GrantScope>, expiresAt: Date, revokedAt: Date?) { self.id = id; self.label = label; self.scopes = scopes; self.expiresAt = expiresAt; self.revokedAt = revokedAt }
}

public protocol WorkspaceClient: Sendable {
    func importMedia(packageURL: URL, sources: [URL]) async throws -> [ManagedImportOutcome]
    func createChannelPackage(packageURL: URL, name: String, initialRecipe: [String: String]) async throws -> WorkspaceSnapshot
    func open(packageURL: URL, rebindMovedPackage: Bool) async throws -> WorkspaceSnapshot
    func execute(packageURL: URL, envelope: CommandEnvelope) async throws -> CommandResult
    func pairCLI(packageURL: URL, label: String, expiresAt: Date) async throws
    func listCLIGrants(packageURL: URL) async throws -> [CLIPairingSummary]
    func revokeCLI(packageURL: URL, grantID: UUID) async throws
}

/// Deliberately refuses to simulate authority writes until the app-owned service is available.
public struct UnavailableWorkspaceClient: WorkspaceClient {
    public init() {}
    public func importMedia(packageURL: URL, sources: [URL]) async throws -> [ManagedImportOutcome] { throw WorkspaceFailure.authorityUnavailable }

    public func createChannelPackage(packageURL: URL, name: String, initialRecipe: [String: String]) async throws -> WorkspaceSnapshot {
        throw WorkspaceFailure.authorityUnavailable
    }

    public func open(packageURL: URL, rebindMovedPackage: Bool) async throws -> WorkspaceSnapshot {
        throw WorkspaceFailure.authorityUnavailable
    }

    public func execute(packageURL: URL, envelope: CommandEnvelope) async throws -> CommandResult {
        throw WorkspaceFailure.authorityUnavailable
    }

    public func pairCLI(packageURL: URL, label: String, expiresAt: Date) async throws {
        throw WorkspaceFailure.authorityUnavailable
    }

    public func listCLIGrants(packageURL: URL) async throws -> [CLIPairingSummary] {
        throw WorkspaceFailure.authorityUnavailable
    }
    public func revokeCLI(packageURL: URL, grantID: UUID) async throws {
        throw WorkspaceFailure.authorityUnavailable
    }
}

public enum WorkspacePresentation {
    /// A preview has no file URL until this returns an asset from the current
    /// authority-opened snapshot. The app sets `selectedAssetID` only after a
    /// fresh `open` has revalidated the catalog object's digest and length.
    public static func assetForVerifiedPreview(document: ProjectDocument?, selectedAssetID: UUID?) -> ManagedAsset? {
        guard let selectedAssetID else { return nil }
        return document?.assets.first { $0.id == selectedAssetID }
    }

    public static func resolvedValues(document: ProjectDocument, episodeID: UUID) -> [EffectiveValue] {
        document.effectiveValues(for: episodeID) ?? []
    }

    public static func commandMessage(_ result: CommandResult) -> String {
        switch result.outcome {
        case .applied(let document): "Committed revision \(document.revision.value)."
        case .conflict(let revision): "This project changed first. Reload revision \(revision.value) and try again."
        case .rejected(let reason): "No change was committed: \(reason)."
        }
    }
}
