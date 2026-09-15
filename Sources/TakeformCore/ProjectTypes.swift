import Foundation

public struct Channel: Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

public struct RecipeVersion: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let values: [String: String]
    public let createdAt: Date
    public init(id: Int, values: [String: String], createdAt: Date = Date()) { self.id = id; self.values = values; self.createdAt = createdAt }
}

public struct Episode: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public let recipeVersion: Int
    public init(id: UUID = UUID(), name: String, recipeVersion: Int) { self.id = id; self.name = name; self.recipeVersion = recipeVersion }
}

public struct Override: Codable, Equatable, Sendable {
    public let episodeID: UUID
    public let key: String
    public let value: String
    public init(episodeID: UUID, key: String, value: String) { self.episodeID = episodeID; self.key = key; self.value = value }
}

public struct Revision: Codable, Comparable, Equatable, Sendable {
    public let value: Int64
    public init(_ value: Int64) { self.value = value }
    public static func < (lhs: Revision, rhs: Revision) -> Bool { lhs.value < rhs.value }
}

public struct CommandID: Codable, Equatable, Hashable, Sendable {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
}

public enum GrantScope: String, Codable, CaseIterable, Sendable {
    case readProject
    case editProject
    case manageGrants
}

public struct Grant: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let label: String
    public let scopes: Set<GrantScope>
    public let expiresAt: Date
    public let authorityEpoch: Int
    public let tokenDigest: String
    public var revokedAt: Date?
    public init(id: UUID = UUID(), label: String, scopes: Set<GrantScope>, expiresAt: Date, authorityEpoch: Int, tokenDigest: String, revokedAt: Date? = nil) {
        self.id = id; self.label = label; self.scopes = scopes; self.expiresAt = expiresAt; self.authorityEpoch = authorityEpoch; self.tokenDigest = tokenDigest; self.revokedAt = revokedAt
    }
    public var isActive: Bool { revokedAt == nil && expiresAt > Date() }
}

public enum ProjectCommand: Codable, Equatable, Sendable {
    case createChannel(name: String, initialRecipe: [String: String])
    case renameChannel(name: String)
    case publishRecipe(values: [String: String])
    case createEpisode(name: String, recipeVersion: Int)
    case setOverride(episodeID: UUID, key: String, value: String)
    case resetOverride(episodeID: UUID, key: String)
    case undo
    case redo

    public var requiredScope: GrantScope {
        switch self {
        case .undo, .redo, .createChannel, .renameChannel, .publishRecipe, .createEpisode, .setOverride, .resetOverride: return .editProject
        }
    }
}

public struct CommandEnvelope: Codable, Equatable, Sendable {
    public let id: CommandID
    public let expectedRevision: Revision
    public let command: ProjectCommand
    public init(id: CommandID = CommandID(), expectedRevision: Revision, command: ProjectCommand) { self.id = id; self.expectedRevision = expectedRevision; self.command = command }
}

public struct EffectiveValue: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case recipe, override }
    public let key: String
    public let value: String
    public let source: Source
    public let recipeVersion: Int
}

public struct ProjectDocument: Codable, Equatable, Sendable {
    public let projectID: UUID
    public var channel: Channel?
    public var recipes: [RecipeVersion]
    public var episodes: [Episode]
    public var overrides: [Override]
    public var revision: Revision
    public init(projectID: UUID = UUID(), channel: Channel? = nil, recipes: [RecipeVersion] = [], episodes: [Episode] = [], overrides: [Override] = [], revision: Revision = Revision(0)) {
        self.projectID = projectID; self.channel = channel; self.recipes = recipes; self.episodes = episodes; self.overrides = overrides; self.revision = revision
    }

    public func effectiveValues(for episodeID: UUID) -> [EffectiveValue]? {
        guard let episode = episodes.first(where: { $0.id == episodeID }), let recipe = recipes.first(where: { $0.id == episode.recipeVersion }) else { return nil }
        let selected = Dictionary(uniqueKeysWithValues: overrides.filter { $0.episodeID == episodeID }.map { ($0.key, $0.value) })
        return recipe.values.keys.sorted().map { key in
            if let value = selected[key] { return EffectiveValue(key: key, value: value, source: .override, recipeVersion: recipe.id) }
            return EffectiveValue(key: key, value: recipe.values[key]!, source: .recipe, recipeVersion: recipe.id)
        }
    }
}

public enum CommandOutcome: Codable, Equatable, Sendable {
    case applied(document: ProjectDocument)
    case conflict(currentRevision: Revision)
    case rejected(reason: String)
}

public struct CommandResult: Codable, Equatable, Sendable {
    public let id: CommandID
    public let outcome: CommandOutcome
    public init(id: CommandID, outcome: CommandOutcome) { self.id = id; self.outcome = outcome }
}
