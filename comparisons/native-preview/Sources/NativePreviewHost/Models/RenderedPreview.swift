import Foundation

enum RenderedPreviewFailure: Error, Equatable, LocalizedError, Sendable {
    case invalidIdentity(String)
    case staleJob
    case invalidProgress
    case artifactUnavailable(String)
    case decodedFrameUnavailable(Int)

    var errorDescription: String? {
        switch self {
        case .invalidIdentity(let message), .artifactUnavailable(let message): message
        case .staleJob: "This rendered preview result belongs to an older plan revision."
        case .invalidProgress: "Renderer progress is invalid or moved backwards."
        case .decodedFrameUnavailable(let frame): "Frame \(frame) did not produce a decoded pixel buffer."
        }
    }
}

struct RenderedPreviewKey: Codable, Equatable, Sendable {
    let planID: String
    let revision: String
    let snapshotDigest: String
    let rendererID: String
    let rendererDigest: String
    let settingsDigest: String
    let inputManifestDigest: String
    let masteringPolicyDigest: String?
    let outputSHA256: String
    let byteCount: Int64
    let frameRate: Rational
    let totalFrames: Int
    let videoStreamCount: Int
    let audioStreamCount: Int
    let validatedGatesReceipt: String

    init(planID: String, revision: String, snapshotDigest: String, rendererID: String, rendererDigest: String, settingsDigest: String, inputManifestDigest: String, masteringPolicyDigest: String? = nil, outputSHA256: String, byteCount: Int64, frameRate: Rational, totalFrames: Int, videoStreamCount: Int, audioStreamCount: Int, validatedGatesReceipt: String) throws {
        let required = [planID, revision, snapshotDigest, rendererID, rendererDigest, settingsDigest, inputManifestDigest, outputSHA256, validatedGatesReceipt]
        guard required.allSatisfy({ !$0.isEmpty }), byteCount > 0, totalFrames > 0, videoStreamCount > 0, audioStreamCount >= 0, outputSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw RenderedPreviewFailure.invalidIdentity("Rendered preview identity is incomplete or invalid.")
        }
        self.planID = planID
        self.revision = revision
        self.snapshotDigest = snapshotDigest
        self.rendererID = rendererID
        self.rendererDigest = rendererDigest
        self.settingsDigest = settingsDigest
        self.inputManifestDigest = inputManifestDigest
        self.masteringPolicyDigest = masteringPolicyDigest
        self.outputSHA256 = outputSHA256
        self.byteCount = byteCount
        self.frameRate = frameRate
        self.totalFrames = totalFrames
        self.videoStreamCount = videoStreamCount
        self.audioStreamCount = audioStreamCount
        self.validatedGatesReceipt = validatedGatesReceipt
    }

    var artifactFilename: String { "\(outputSHA256).mp4" }
}

struct VerifiedRenderArtifact: Equatable, Sendable {
    let key: RenderedPreviewKey
    let url: URL
}

enum RendererProgress: Equatable, Sendable {
    case indeterminate
    case units(completed: Int, total: Int)

    func validates(after prior: RendererProgress?) -> Bool {
        switch self {
        case .indeterminate: return prior == nil || prior == .indeterminate
        case let .units(completed, total):
            guard total > 0, completed >= 0, completed <= total else { return false }
            guard case let .units(previous, previousTotal)? = prior else { return true }
            return previousTotal == total && completed >= previous
        }
    }
}

enum RenderPreviewJobStatus: Equatable, Sendable {
    case unavailable(String)
    case queued
    case running(RendererProgress)
    case succeeded(VerifiedRenderArtifact)
    case cancelled
    case superseded
    case failed(String)
}

struct RenderPreviewJob: Equatable, Sendable {
    let id: UUID
    let key: RenderedPreviewKey
    private(set) var status: RenderPreviewJobStatus

    init(id: UUID = UUID(), key: RenderedPreviewKey, status: RenderPreviewJobStatus = .queued) {
        self.id = id
        self.key = key
        self.status = status
    }

    mutating func update(_ status: RenderPreviewJobStatus) { self.status = status }
}

struct RenderedPreviewState: Equatable, Sendable {
    private(set) var currentRevision: String
    private(set) var job: RenderPreviewJob?
    private(set) var currentArtifact: VerifiedRenderArtifact?
    private var unavailable: String

    init(currentRevision: String, unavailableMessage: String = "A current-plan renderer is not connected.") {
        self.currentRevision = currentRevision
        job = nil
        currentArtifact = nil
        unavailable = unavailableMessage
    }

    var status: RenderPreviewJobStatus { job?.status ?? .unavailable(unavailable) }

    mutating func begin(_ key: RenderedPreviewKey) throws -> UUID {
        guard key.revision == currentRevision else { throw RenderedPreviewFailure.staleJob }
        if let job, case .queued = job.status { self.job?.update(.superseded) }
        if let job, case .running = job.status { self.job?.update(.superseded) }
        let next = RenderPreviewJob(key: key)
        job = next
        currentArtifact = nil
        return next.id
    }

    mutating func progress(jobID: UUID, value: RendererProgress) throws {
        guard var job, job.id == jobID, job.key.revision == currentRevision else { throw RenderedPreviewFailure.staleJob }
        guard isActive(job.status) else { throw RenderedPreviewFailure.staleJob }
        let prior: RendererProgress? = if case let .running(value) = job.status { value } else { nil }
        guard value.validates(after: prior) else { throw RenderedPreviewFailure.invalidProgress }
        job.update(.running(value))
        self.job = job
    }

    mutating func complete(jobID: UUID, artifact: VerifiedRenderArtifact) throws {
        guard var job, job.id == jobID, job.key == artifact.key, job.key.revision == currentRevision else { throw RenderedPreviewFailure.staleJob }
        guard isActive(job.status) else { throw RenderedPreviewFailure.staleJob }
        job.update(.succeeded(artifact))
        self.job = job
        currentArtifact = artifact
    }

    mutating func cancel(jobID: UUID) {
        guard var job, job.id == jobID else { return }
        guard isActive(job.status) else { return }
        job.update(.cancelled)
        self.job = job
    }

    mutating func fail(jobID: UUID, message: String) {
        guard var job, job.id == jobID else { return }
        guard isActive(job.status) else { return }
        job.update(.failed(message))
        self.job = job
    }

    mutating func advanceRevision(to revision: String) {
        guard revision != currentRevision else { return }
        currentRevision = revision
        if var job, job.key.revision != revision {
            job.update(.superseded)
            self.job = job
        }
        currentArtifact = nil
    }

    private func isActive(_ status: RenderPreviewJobStatus) -> Bool {
        switch status {
        case .queued, .running: true
        default: false
        }
    }
}
