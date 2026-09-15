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
        case .authorityUnavailable: "The project authority is unavailable. No changes were made."
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

public protocol WorkspaceClient: Sendable {
    func open(packageURL: URL, rebindMovedPackage: Bool) async throws -> WorkspaceSnapshot
    func execute(packageURL: URL, envelope: CommandEnvelope) async throws -> CommandResult
    func pairCLI(packageURL: URL, label: String, expiresAt: Date) async throws
    func revokeCLI(packageURL: URL) async throws
}

/// Deliberately refuses to simulate authority writes until the app-owned service is available.
public struct UnavailableWorkspaceClient: WorkspaceClient {
    public init() {}

    public func open(packageURL: URL, rebindMovedPackage: Bool) async throws -> WorkspaceSnapshot {
        throw WorkspaceFailure.authorityUnavailable
    }

    public func execute(packageURL: URL, envelope: CommandEnvelope) async throws -> CommandResult {
        throw WorkspaceFailure.authorityUnavailable
    }

    public func pairCLI(packageURL: URL, label: String, expiresAt: Date) async throws {
        throw WorkspaceFailure.authorityUnavailable
    }

    public func revokeCLI(packageURL: URL) async throws {
        throw WorkspaceFailure.authorityUnavailable
    }
}

public enum WorkspacePresentation {
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

