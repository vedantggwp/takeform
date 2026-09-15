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

public struct ManagedAssetProbe: Codable, Equatable, Sendable {
    public struct Rational: Codable, Equatable, Sendable { public let value: Int64; public let timescale: Int32; public init(_ value: Int64, _ timescale: Int32) { self.value = value; self.timescale = timescale } }
    public struct Video: Codable, Equatable, Sendable { public let codec: String?; public let encodedWidth: Int; public let encodedHeight: Int; public let displayedWidth: Int; public let displayedHeight: Int; public let transform: [Double]; public let nominalFrameRate: Double?; public let timeRange: [Rational]?; public let presentationTimestamps: [Rational]; public let observedPresentationDeltaCount: Int; public let isVariableFrameRate: Bool?; public init(codec: String?, encodedWidth: Int, encodedHeight: Int, displayedWidth: Int, displayedHeight: Int, transform: [Double], nominalFrameRate: Double?, timeRange: [Rational]?, presentationTimestamps: [Rational], observedPresentationDeltaCount: Int, isVariableFrameRate: Bool?) { self.codec=codec; self.encodedWidth=encodedWidth; self.encodedHeight=encodedHeight; self.displayedWidth=displayedWidth; self.displayedHeight=displayedHeight; self.transform=transform; self.nominalFrameRate=nominalFrameRate; self.timeRange=timeRange; self.presentationTimestamps=presentationTimestamps; self.observedPresentationDeltaCount=observedPresentationDeltaCount; self.isVariableFrameRate=isVariableFrameRate } }
    public struct Audio: Codable, Equatable, Sendable { public let codec: String?; public let channels: Int?; public let sampleRate: Double?; public let timeRange: [Rational]?; public init(codec: String?, channels: Int?, sampleRate: Double?, timeRange: [Rational]?) { self.codec=codec; self.channels=channels; self.sampleRate=sampleRate; self.timeRange=timeRange } }
    public let containerIdentifier: String?
    public let durationValue: Int64?
    public let durationTimescale: Int32?
    public let imageEncodedWidth: Int?
    public let imageEncodedHeight: Int?
    public let imageDisplayedWidth: Int?
    public let imageDisplayedHeight: Int?
    public let imageOrientation: Int?
    public let video: Video?
    public let audio: [Audio]
    public let livePhotoIdentifier: String?
    public let livePhotoComparisonIdentifier: String?
    public let livePhotoProvenance: String?
    public let livePhotoNormalization: String?
    public init(containerIdentifier: String? = nil, durationValue: Int64? = nil, durationTimescale: Int32? = nil, imageEncodedWidth: Int? = nil, imageEncodedHeight: Int? = nil, imageDisplayedWidth: Int? = nil, imageDisplayedHeight: Int? = nil, imageOrientation: Int? = nil, video: Video? = nil, audio: [Audio] = [], livePhotoIdentifier: String? = nil, livePhotoComparisonIdentifier: String? = nil, livePhotoProvenance: String? = nil, livePhotoNormalization: String? = nil) { self.containerIdentifier = containerIdentifier; self.durationValue = durationValue; self.durationTimescale = durationTimescale; self.imageEncodedWidth = imageEncodedWidth; self.imageEncodedHeight = imageEncodedHeight; self.imageDisplayedWidth = imageDisplayedWidth; self.imageDisplayedHeight = imageDisplayedHeight; self.imageOrientation = imageOrientation; self.video = video; self.audio = audio; self.livePhotoIdentifier = livePhotoIdentifier; self.livePhotoComparisonIdentifier = livePhotoComparisonIdentifier; self.livePhotoProvenance = livePhotoProvenance; self.livePhotoNormalization = livePhotoNormalization }

    private enum CodingKeys: String, CodingKey { case containerIdentifier, durationValue, durationTimescale, imageEncodedWidth, imageEncodedHeight, imageDisplayedWidth, imageDisplayedHeight, imageOrientation, video, audio, livePhotoIdentifier, livePhotoComparisonIdentifier, livePhotoProvenance, livePhotoNormalization }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); containerIdentifier = try c.decodeIfPresent(String.self, forKey: .containerIdentifier); durationValue = try c.decodeIfPresent(Int64.self, forKey: .durationValue); durationTimescale = try c.decodeIfPresent(Int32.self, forKey: .durationTimescale); imageEncodedWidth = try c.decodeIfPresent(Int.self, forKey: .imageEncodedWidth); imageEncodedHeight = try c.decodeIfPresent(Int.self, forKey: .imageEncodedHeight); imageDisplayedWidth = try c.decodeIfPresent(Int.self, forKey: .imageDisplayedWidth); imageDisplayedHeight = try c.decodeIfPresent(Int.self, forKey: .imageDisplayedHeight); imageOrientation = try c.decodeIfPresent(Int.self, forKey: .imageOrientation); video = try c.decodeIfPresent(Video.self, forKey: .video); audio = try c.decodeIfPresent([Audio].self, forKey: .audio) ?? []; livePhotoIdentifier = try c.decodeIfPresent(String.self, forKey: .livePhotoIdentifier); livePhotoComparisonIdentifier = try c.decodeIfPresent(String.self, forKey: .livePhotoComparisonIdentifier); livePhotoProvenance = try c.decodeIfPresent(String.self, forKey: .livePhotoProvenance); livePhotoNormalization = try c.decodeIfPresent(String.self, forKey: .livePhotoNormalization) }
}

/// Portable catalog entry. The object path is derived from this canonical digest.
public struct ManagedAsset: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let digest: String
    public let byteLength: UInt64
    public let filename: String
    public let mediaType: String
    public let probe: ManagedAssetProbe?
    public init(id: UUID = UUID(), digest: String, byteLength: UInt64, filename: String, mediaType: String, probe: ManagedAssetProbe? = nil) { self.id = id; self.digest = digest; self.byteLength = byteLength; self.filename = filename; self.mediaType = mediaType; self.probe = probe }
}

public enum ManagedImportOutcome: Codable, Equatable, Sendable, Identifiable {
    case imported(ManagedAsset)
    case duplicate(digest: String, filename: String)
    case cancelled(filename: String)
    case failed(filename: String, reason: String)
    public var id: String { switch self { case let .imported(asset): asset.id.uuidString; case let .duplicate(digest, filename): "duplicate-\(digest)-\(filename)"; case let .cancelled(filename): "cancelled-\(filename)"; case let .failed(filename, reason): "failed-\(filename)-\(reason)" } }
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
    case addManagedAsset(ManagedAsset)
    case replaceEpisodeComposition(episodeID: UUID, composition: EpisodeComposition)
    case requestEpisodeRender(episodeID: UUID, compositionDigest: String, format: EpisodeRenderFormat)
    case undo
    case redo

    public var requiredScope: GrantScope {
        switch self {
        case .undo, .redo, .createChannel, .renameChannel, .publishRecipe, .createEpisode, .setOverride, .resetOverride, .addManagedAsset, .replaceEpisodeComposition, .requestEpisodeRender: return .editProject
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
    public var assets: [ManagedAsset]
    public var episodeCompositions: [EpisodeComposition]
    public var revision: Revision
    public init(projectID: UUID = UUID(), channel: Channel? = nil, recipes: [RecipeVersion] = [], episodes: [Episode] = [], overrides: [Override] = [], assets: [ManagedAsset] = [], episodeCompositions: [EpisodeComposition] = [], revision: Revision = Revision(0)) {
        self.projectID = projectID; self.channel = channel; self.recipes = recipes; self.episodes = episodes; self.overrides = overrides; self.assets = assets; self.episodeCompositions = episodeCompositions; self.revision = revision
    }

    private enum CodingKeys: String, CodingKey { case projectID, channel, recipes, episodes, overrides, assets, episodeCompositions, revision }

    /// Catalog entries were added after the first portable document format.
    /// Opening an older project therefore means an empty catalog, not a decode
    /// failure or an inferred object inventory.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try values.decode(UUID.self, forKey: .projectID)
        channel = try values.decodeIfPresent(Channel.self, forKey: .channel)
        recipes = try values.decodeIfPresent([RecipeVersion].self, forKey: .recipes) ?? []
        episodes = try values.decodeIfPresent([Episode].self, forKey: .episodes) ?? []
        overrides = try values.decodeIfPresent([Override].self, forKey: .overrides) ?? []
        assets = try values.decodeIfPresent([ManagedAsset].self, forKey: .assets) ?? []
        episodeCompositions = try values.decodeIfPresent([EpisodeComposition].self, forKey: .episodeCompositions) ?? []
        revision = try values.decode(Revision.self, forKey: .revision)
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
    case renderRequested(EpisodeRenderRequestStatus)
    case conflict(currentRevision: Revision)
    case rejected(reason: String)
}

public struct CommandResult: Codable, Equatable, Sendable {
    public let id: CommandID
    public let outcome: CommandOutcome
    public init(id: CommandID, outcome: CommandOutcome) { self.id = id; self.outcome = outcome }
}
