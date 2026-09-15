import AVFoundation
import Foundation
import Observation

@Observable
@MainActor
final class RenderedPreviewStore {
    private(set) var state: RenderedPreviewState

    init(currentRevision: String, unavailableMessage: String = "A current-plan renderer is not connected.") {
        state = RenderedPreviewState(currentRevision: currentRevision, unavailableMessage: unavailableMessage)
    }

    var status: RenderPreviewJobStatus { state.status }
    var artifact: VerifiedRenderArtifact? { state.currentArtifact }

    func begin(key: RenderedPreviewKey) throws -> UUID { try state.begin(key) }
    func reportProgress(jobID: UUID, value: RendererProgress) throws { try state.progress(jobID: jobID, value: value) }
    func cancel(jobID: UUID, stagedURL: URL?, cache: RenderArtifactCache?) {
        guard stagedURL == nil || cache != nil else {
            state.fail(jobID: jobID, message: "Rendered preview cancellation could not clean its owned partial artifact.")
            return
        }
        if let stagedURL, let cache {
            do {
                try cache.removeStaged(stagedURL)
            } catch {
                state.fail(jobID: jobID, message: "Rendered preview cancellation could not clean its owned partial artifact: \(error.localizedDescription)")
                return
            }
        }
        state.cancel(jobID: jobID)
    }
    func fail(jobID: UUID, message: String) { state.fail(jobID: jobID, message: message) }
    func advanceRevision(to revision: String) { state.advanceRevision(to: revision) }

    @discardableResult
    func publish(jobID: UUID, stagedURL: URL, cache: RenderArtifactCache) throws -> VerifiedRenderArtifact {
        guard let job = state.job, job.id == jobID, job.key.revision == state.currentRevision, job.status.acceptsResult else {
            do {
                try cache.removeStaged(stagedURL)
            } catch {
                throw RenderedPreviewFailure.artifactUnavailable("A stale rendered result could not clean its owned partial artifact: \(error.localizedDescription)")
            }
            throw RenderedPreviewFailure.staleJob
        }
        let artifact = try cache.publish(staged: stagedURL, key: job.key)
        do {
            try state.complete(jobID: jobID, artifact: artifact)
            return artifact
        } catch {
            try? FileManager.default.removeItem(at: artifact.url)
            throw error
        }
    }
}

@Observable
@MainActor
final class RenderedPreviewPlaybackStore {
    private(set) var state: PreviewState?
    private(set) var errorMessage: String?
    private var nextRequestID: UInt64 = 0

    var session: PreviewSession? { state?.session }
    var status: PreviewResponseStatus? { state?.acknowledgementStatus }

    func load(artifact: VerifiedRenderArtifact, player: RenderedPreviewPlayer) async {
        do {
            let session = try PreviewSession(
                snapshotID: artifact.key.snapshotDigest,
                backend: "Rendered preview",
                frameRate: artifact.key.frameRate,
                totalFrames: artifact.key.totalFrames
            )
            state = PreviewState(session: session)
            errorMessage = nil
            try await submit(.load(requestID: requestID(), sessionID: session.id, snapshotID: session.snapshotID, frame: 0), artifact: artifact, player: player)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func seek(frame: Int, artifact: VerifiedRenderArtifact, player: RenderedPreviewPlayer) async {
        guard let session else { return }
        await run(.seek(requestID: requestID(), sessionID: session.id, snapshotID: session.snapshotID, frame: frame), artifact: artifact, player: player)
    }

    func play(artifact: VerifiedRenderArtifact, player: RenderedPreviewPlayer) async {
        guard let session else { return }
        await run(.play(requestID: requestID(), sessionID: session.id, snapshotID: session.snapshotID), artifact: artifact, player: player)
    }

    func pause(artifact: VerifiedRenderArtifact, player: RenderedPreviewPlayer) async {
        guard let session else { return }
        let current = CMTimeGetSeconds(player.player.currentTime())
        let currentFrame = min(max(Int((current / session.frameRate.secondsPerFrame).rounded()), 0), session.totalFrames - 1)
        do {
            try state?.setRequestedFrame(currentFrame)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        await run(.pause(requestID: requestID(), sessionID: session.id, snapshotID: session.snapshotID), artifact: artifact, player: player)
    }

    private func run(_ command: PreviewCommand, artifact: VerifiedRenderArtifact, player: RenderedPreviewPlayer) async {
        do {
            errorMessage = nil
            try await submit(command, artifact: artifact, player: player)
        } catch {
            state?.fail(error)
            errorMessage = error.localizedDescription
        }
    }

    private func submit(_ command: PreviewCommand, artifact: VerifiedRenderArtifact, player: RenderedPreviewPlayer) async throws {
        guard artifact.key.snapshotDigest == state?.session.snapshotID else { throw RenderedPreviewFailure.staleJob }
        try state?.request(command)
        let frame: Int
        let playback: PlaybackState
        switch command {
        case let .load(_, _, _, requested), let .seek(_, _, _, requested):
            frame = requested
            playback = .paused
            if command.kind == .load { try await player.load(artifact) }
            _ = try await player.seek(frame: frame, key: artifact.key)
            player.pause()
        case .play:
            guard let session else { throw RenderedPreviewFailure.staleJob }
            frame = session.requestedFrame
            playback = .playing
            _ = try await player.seek(frame: frame, key: artifact.key)
            player.play()
        case .pause:
            guard let session else { throw RenderedPreviewFailure.staleJob }
            frame = session.requestedFrame
            playback = .paused
            player.pause()
            _ = try await player.seek(frame: frame, key: artifact.key)
        }
        guard let session else { throw RenderedPreviewFailure.staleJob }
        _ = try state?.acknowledge(PreviewResponse(
            requestID: command.requestID,
            sessionID: session.id,
            snapshotID: session.snapshotID,
            displayedFrame: frame,
            playback: playback,
            status: .decoded
        ))
    }

    private func requestID() -> UInt64 {
        nextRequestID &+= 1
        return nextRequestID
    }
}
