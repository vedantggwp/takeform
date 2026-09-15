import AVFoundation
import CoreVideo
import Foundation
import TakeformAppAuthorityWire
import TakeformCore

/// A copied pixel buffer proves the requested encoded item time decoded. It does
/// not make a claim about physical audio presentation.
public struct RenderedPreviewIdentity: Equatable, Sendable {
    public let jobID: UUID
    public let requestedRevision: Revision
    public let compositionDigest: String

    public init(jobID: UUID, requestedRevision: Revision, compositionDigest: String) {
        self.jobID = jobID
        self.requestedRevision = requestedRevision
        self.compositionDigest = compositionDigest
    }
}

public struct DecodedRenderedFrame {
    public let requestedFrame: Int
    public let itemTime: CMTime
    public let pixelBuffer: CVPixelBuffer

    public init(requestedFrame: Int, itemTime: CMTime, pixelBuffer: CVPixelBuffer) {
        self.requestedFrame = requestedFrame
        self.itemTime = itemTime
        self.pixelBuffer = pixelBuffer
    }
}

public enum RenderedPreviewFailure: Error, Equatable, LocalizedError {
    case sourceInvalid(String)
    case artifactUnavailable(String)
    case decodedFrameUnavailable(Int)
    case staleSource

    public var errorDescription: String? {
        switch self {
        case .sourceInvalid(let detail), .artifactUnavailable(let detail): return detail
        case .decodedFrameUnavailable(let frame): return "Rendered frame \(frame) did not decode."
        case .staleSource: return "The selected render is no longer current."
        }
    }
}

/// App-local playback over an authority-derived artifact URL. This type owns no
/// artifact cache, job state, renderer process, or caller-selected file path.
@MainActor
public final class RenderedPreviewPlayer: NSObject {
    public let player = AVPlayer()

    private var item: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var sourceGeneration = UUID()
    private var seekGeneration = UUID()
    private var source: EpisodeRenderPlaybackSource?
    private let testAssetVerifier: (@Sendable (EpisodeRenderPlaybackSource) async throws -> Void)?

    public private(set) var sourceIdentity: RenderedPreviewIdentity?

    public override init() {
        testAssetVerifier = nil
        super.init()
    }

    @_spi(Testing) public init(assetVerifier: @escaping @Sendable (EpisodeRenderPlaybackSource) async throws -> Void) {
        testAssetVerifier = assetVerifier
        super.init()
    }

    /// Loads one freshly authority-validated artifact. Call `clear()` before a
    /// revision/digest mismatch becomes selectable in the UI.
    public func load(_ source: EpisodeRenderPlaybackSource) async throws {
        // A newly selected authority source supersedes any prior revision before
        // asynchronous asset inspection begins.
        clear()
        let loadToken = sourceGeneration
        try validate(source)
        try await verifyEncodedAsset(source)
        guard loadToken == sourceGeneration else {
            throw RenderedPreviewFailure.staleSource
        }

        seekGeneration = UUID()
        self.source = source
        sourceIdentity = RenderedPreviewIdentity(
            jobID: source.jobID,
            requestedRevision: source.requestedRevision,
            compositionDigest: source.compositionDigest
        )

        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        let item = AVPlayerItem(url: source.artifactURL)
        item.add(videoOutput)
        self.item = item
        self.videoOutput = videoOutput
        player.replaceCurrentItem(with: item)
    }

    /// Invalidates outstanding readiness and seek work before releasing the
    /// app-local item. It never deletes the authority artifact.
    public func clear() {
        sourceGeneration = UUID()
        seekGeneration = UUID()
        player.pause()
        player.replaceCurrentItem(with: nil)
        item = nil
        videoOutput = nil
        source = nil
        sourceIdentity = nil
    }

    public func play() { player.play() }
    public func pause() { player.pause() }

    /// A zero-tolerance seek is acknowledged only after AVFoundation supplies a
    /// new copied video buffer for the requested item time.
    public func seek(frame: Int) async throws -> DecodedRenderedFrame {
        guard let source, let item, let videoOutput else {
            throw RenderedPreviewFailure.artifactUnavailable("No authority-validated render is loaded.")
        }
        let totalFrames = try frameCount(for: source.output)
        guard (0..<totalFrames).contains(frame) else {
            throw RenderedPreviewFailure.decodedFrameUnavailable(frame)
        }

        let sourceToken = sourceGeneration
        let requestToken = UUID()
        seekGeneration = requestToken
        try await waitUntilReady(item, sourceToken: sourceToken, requestToken: requestToken)

        let itemTime = try frameTime(frame, frameRate: source.output.frameRate)
        let completed = await player.seek(to: itemTime, toleranceBefore: .zero, toleranceAfter: .zero)
        guard completed, isCurrent(sourceToken: sourceToken, requestToken: requestToken, item: item) else {
            throw RenderedPreviewFailure.staleSource
        }
        return try await copiedDecodedFrame(
            output: videoOutput,
            requestedFrame: frame,
            itemTime: itemTime,
            sourceToken: sourceToken,
            requestToken: requestToken
        )
    }

    private func validate(_ source: EpisodeRenderPlaybackSource) throws {
        guard source.descriptor.jobID == source.jobID,
              source.output.width > 0,
              source.output.height > 0,
              source.output.frameRate.value > 0,
              source.output.duration.value > 0,
              source.videoStreamCount == 1,
              source.audioStreamCount == 0 else {
            throw RenderedPreviewFailure.sourceInvalid("Authority playback source does not match the silent montage contract.")
        }
        _ = try frameCount(for: source.output)
    }

    private func verifyEncodedAsset(_ source: EpisodeRenderPlaybackSource) async throws {
        if let testAssetVerifier {
            try await testAssetVerifier(source)
            return
        }
        let asset = AVURLAsset(url: source.artifactURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard videoTracks.count == source.videoStreamCount,
              audioTracks.count == source.audioStreamCount,
              let video = videoTracks.first else {
            throw RenderedPreviewFailure.artifactUnavailable("Rendered artifact stream layout does not match the authority source.")
        }
        let size = try await video.load(.naturalSize)
        guard Int(size.width.rounded()) == source.output.width,
              Int(size.height.rounded()) == source.output.height else {
            throw RenderedPreviewFailure.artifactUnavailable("Rendered artifact canvas does not match the authority source.")
        }
        // The authority has already accepted encoded duration/frame tolerance
        // during receipt validation. This player uses the frozen output only
        // for frame addressing, so it cannot silently create a stricter second
        // acceptance rule that disagrees with authority materialization.
    }

    private func waitUntilReady(_ item: AVPlayerItem, sourceToken: UUID, requestToken: UUID) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            guard isCurrent(sourceToken: sourceToken, requestToken: requestToken, item: item) else {
                throw RenderedPreviewFailure.staleSource
            }
            switch item.status {
            case .readyToPlay: return
            case .failed: throw RenderedPreviewFailure.artifactUnavailable(item.error?.localizedDescription ?? "Rendered artifact failed to load.")
            case .unknown: try await Task.sleep(for: .milliseconds(10))
            @unknown default: throw RenderedPreviewFailure.artifactUnavailable("Rendered artifact has an unsupported readiness state.")
            }
        }
        throw RenderedPreviewFailure.artifactUnavailable("Rendered artifact did not become ready.")
    }

    private func copiedDecodedFrame(output: AVPlayerItemVideoOutput, requestedFrame: Int, itemTime: CMTime, sourceToken: UUID, requestToken: UUID) async throws -> DecodedRenderedFrame {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            guard let item, isCurrent(sourceToken: sourceToken, requestToken: requestToken, item: item) else {
                throw RenderedPreviewFailure.staleSource
            }
            if output.hasNewPixelBuffer(forItemTime: itemTime) {
                var displayed = CMTime.invalid
                if let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayed) {
                    return DecodedRenderedFrame(
                        requestedFrame: requestedFrame,
                        itemTime: displayed.isValid ? displayed : itemTime,
                        pixelBuffer: pixelBuffer
                    )
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RenderedPreviewFailure.decodedFrameUnavailable(requestedFrame)
    }

    private func isCurrent(sourceToken: UUID, requestToken: UUID, item: AVPlayerItem) -> Bool {
        sourceToken == sourceGeneration && requestToken == seekGeneration && item === self.item
    }

    private func frameCount(for output: CompositionOutput) throws -> Int {
        let numerator = output.duration.value.multipliedReportingOverflow(by: output.frameRate.value)
        let denominator = Int64(output.duration.timescale).multipliedReportingOverflow(by: Int64(output.frameRate.timescale))
        guard !numerator.overflow,
              !denominator.overflow,
              denominator.partialValue > 0,
              numerator.partialValue > 0,
              numerator.partialValue % denominator.partialValue == 0,
              let frames = Int(exactly: numerator.partialValue / denominator.partialValue) else {
            throw RenderedPreviewFailure.sourceInvalid("Composition output does not derive an exact positive frame count.")
        }
        return frames
    }

    private func frameTime(_ frame: Int, frameRate: CompositionTime) throws -> CMTime {
        guard let timeScale = Int32(exactly: frameRate.value) else {
            throw RenderedPreviewFailure.sourceInvalid("Composition frame rate cannot be represented as a Core Media time scale.")
        }
        let value = Int64(frame).multipliedReportingOverflow(by: Int64(frameRate.timescale))
        guard !value.overflow else {
            throw RenderedPreviewFailure.sourceInvalid("Composition frame time overflows Core Media.")
        }
        return CMTime(value: value.partialValue, timescale: timeScale)
    }
}
