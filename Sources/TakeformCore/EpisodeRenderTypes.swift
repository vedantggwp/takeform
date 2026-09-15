import Foundation

/// The only supported first-slice render container.
public enum EpisodeRenderFormat: String, Codable, Equatable, Sendable { case mp4 }

/// Logical request state is portable with the project. It deliberately says
/// nothing about a local process or artifact being available on this machine.
public enum EpisodeRenderLogicalState: String, Codable, Equatable, Sendable {
    case requested
    case cancelled
    case interrupted
    case failed
    /// A worker attempt completed logically. Artifact availability is still a
    /// machine-local observation that must be revalidated before use.
    case completed
}

/// Worker progress is either reported by the producer or honestly unknown.
public enum EpisodeRenderProgress: Codable, Equatable, Sendable {
    case indeterminate
    case fraction(Double)
}

/// Machine availability is a current observation. It is never persisted in
/// project.sqlite and cannot survive a move or rebind by assertion alone.
public enum EpisodeRenderAvailability: String, Codable, Equatable, Sendable {
    case queued
    case running
    case available
    case unavailable
}

public struct EpisodeRenderRequestStatus: Codable, Equatable, Sendable, Identifiable {
    public let jobID: UUID
    public let episodeID: UUID
    public let requestedRevision: Revision
    public let compositionDigest: String
    public let format: EpisodeRenderFormat
    public let logicalState: EpisodeRenderLogicalState
    public let progress: EpisodeRenderProgress
    public let availability: EpisodeRenderAvailability

    public var id: UUID { jobID }

    public init(jobID: UUID, episodeID: UUID, requestedRevision: Revision, compositionDigest: String, format: EpisodeRenderFormat, logicalState: EpisodeRenderLogicalState, progress: EpisodeRenderProgress, availability: EpisodeRenderAvailability) {
        self.jobID = jobID
        self.episodeID = episodeID
        self.requestedRevision = requestedRevision
        self.compositionDigest = compositionDigest
        self.format = format
        self.logicalState = logicalState
        self.progress = progress
        self.availability = availability
    }
}

/// A path-free, immutable render input. The service derives and revalidates
/// object locations only when it creates a machine-local worker attempt.
public struct EpisodeRenderSnapshot: Codable, Equatable, Sendable {
    public struct Asset: Codable, Equatable, Sendable {
        public let id: UUID
        public let digest: String
        public let byteLength: UInt64
        public let mediaType: String
        public let probe: ManagedAssetProbe?

        public init(asset: ManagedAsset) {
            id = asset.id
            digest = asset.digest
            byteLength = asset.byteLength
            mediaType = asset.mediaType
            probe = asset.probe
        }
    }

    public let projectID: UUID
    public let episodeID: UUID
    public let requestedRevision: Revision
    public let compositionDigest: String
    public let format: EpisodeRenderFormat
    public let composition: EpisodeComposition
    public let assets: [Asset]

    public init(projectID: UUID, episodeID: UUID, requestedRevision: Revision, compositionDigest: String, format: EpisodeRenderFormat, composition: EpisodeComposition, assets: [Asset]) {
        self.projectID = projectID
        self.episodeID = episodeID
        self.requestedRevision = requestedRevision
        self.compositionDigest = compositionDigest
        self.format = format
        self.composition = composition
        self.assets = assets
    }
}

/// Materialization is intentionally unavailable until a machine-local worker
/// receipt and artifact are connected and revalidated by the authority.
public struct EpisodeRenderDescriptor: Codable, Equatable, Sendable {
    public let jobID: UUID
    public let format: EpisodeRenderFormat
    public let byteLength: UInt64
    public let sha256: String
    public init(jobID: UUID, format: EpisodeRenderFormat, byteLength: UInt64, sha256: String) {
        self.jobID = jobID
        self.format = format
        self.byteLength = byteLength
        self.sha256 = sha256
    }
}

public enum EpisodeRenderMaterialization: Codable, Equatable, Sendable {
    case unavailable(EpisodeRenderRequestStatus)
    case descriptor(EpisodeRenderDescriptor)
}

/// The caller must explicitly acknowledge that an existing destination is not
/// to be replaced. This initial authority slice always refuses that collision.
public enum EpisodeRenderExportDecision: String, Codable, Equatable, Sendable { case refuseExisting }

public enum EpisodeRenderExportResult: Codable, Equatable, Sendable {
    case unavailable(EpisodeRenderRequestStatus)
    case exported(EpisodeRenderDescriptor)
}
