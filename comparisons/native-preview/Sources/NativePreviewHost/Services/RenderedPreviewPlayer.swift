import AVFoundation
import CoreVideo
import Foundation

struct DecodedRenderedFrame {
    let requestedFrame: Int
    let itemTime: CMTime
    let pixelBuffer: CVPixelBuffer
}

@MainActor
final class RenderedPreviewPlayer: NSObject {
    let player = AVPlayer()
    private var item: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var generation = UUID()
    private var seekGeneration = UUID()

    func load(_ artifact: VerifiedRenderArtifact) async throws {
        try await verifyStreamMetadata(for: artifact)
        generation = UUID()
        seekGeneration = UUID()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        let item = AVPlayerItem(url: artifact.url)
        item.add(output)
        self.item = item
        videoOutput = output
        player.replaceCurrentItem(with: item)
    }

    func stop() {
        generation = UUID()
        seekGeneration = UUID()
        player.pause()
        player.replaceCurrentItem(with: nil)
        item = nil
        videoOutput = nil
    }

    func seek(frame: Int, key: RenderedPreviewKey) async throws -> DecodedRenderedFrame {
        guard (0..<key.totalFrames).contains(frame), let item, let videoOutput else {
            throw RenderedPreviewFailure.decodedFrameUnavailable(frame)
        }
        let itemToken = generation
        let requestToken = UUID()
        seekGeneration = requestToken
        try await waitUntilReady(item, itemToken: itemToken, requestToken: requestToken)
        let requested = CMTime(value: Int64(frame) * Int64(key.frameRate.denominator), timescale: Int32(key.frameRate.numerator))
        let completed = await player.seek(to: requested, toleranceBefore: .zero, toleranceAfter: .zero)
        guard completed, itemToken == generation, requestToken == seekGeneration, item === self.item else { throw RenderedPreviewFailure.staleJob }
        return try await decodedFrame(output: videoOutput, requestedFrame: frame, itemTime: requested, itemToken: itemToken, requestToken: requestToken)
    }

    func play() { player.play() }
    func pause() { player.pause() }

    private func decodedFrame(output: AVPlayerItemVideoOutput, requestedFrame: Int, itemTime: CMTime, itemToken: UUID, requestToken: UUID) async throws -> DecodedRenderedFrame {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        let clock = ContinuousClock()
        while clock.now < deadline {
            guard itemToken == generation, requestToken == seekGeneration else { throw RenderedPreviewFailure.staleJob }
            if output.hasNewPixelBuffer(forItemTime: itemTime) {
                var displayed = CMTime.invalid
                if let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayed) {
                    return DecodedRenderedFrame(requestedFrame: requestedFrame, itemTime: displayed.isValid ? displayed : itemTime, pixelBuffer: pixelBuffer)
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RenderedPreviewFailure.decodedFrameUnavailable(requestedFrame)
    }

    private func waitUntilReady(_ item: AVPlayerItem, itemToken: UUID, requestToken: UUID) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        let clock = ContinuousClock()
        while clock.now < deadline {
            guard itemToken == generation, requestToken == seekGeneration else { throw RenderedPreviewFailure.staleJob }
            switch item.status {
            case .readyToPlay: return
            case .failed: throw RenderedPreviewFailure.artifactUnavailable(item.error?.localizedDescription ?? "Rendered artifact failed to load.")
            case .unknown: try await Task.sleep(for: .milliseconds(10))
            @unknown default: throw RenderedPreviewFailure.artifactUnavailable("Rendered artifact returned an unsupported readiness state.")
            }
        }
        throw RenderedPreviewFailure.artifactUnavailable("Rendered artifact did not become ready.")
    }

    private func verifyStreamMetadata(for artifact: VerifiedRenderArtifact) async throws {
        let asset = AVURLAsset(url: artifact.url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let key = artifact.key
        guard videoTracks.count == key.videoStreamCount, audioTracks.count == key.audioStreamCount else {
            throw RenderedPreviewFailure.artifactUnavailable("Rendered artifact stream layout does not match its descriptor.")
        }
        guard let video = videoTracks.first else {
            throw RenderedPreviewFailure.artifactUnavailable("Rendered artifact has no video stream.")
        }
        let duration = try await asset.load(.duration)
        let expectedDuration = CMTime(
            value: Int64(key.totalFrames) * Int64(key.frameRate.denominator),
            timescale: Int32(key.frameRate.numerator)
        )
        guard CMTimeCompare(duration, expectedDuration) == 0 else {
            throw RenderedPreviewFailure.artifactUnavailable("Rendered artifact duration does not match its descriptor.")
        }
        let minimumFrameDuration = try await video.load(.minFrameDuration)
        let expectedFrameDuration = CMTime(value: Int64(key.frameRate.denominator), timescale: Int32(key.frameRate.numerator))
        guard CMTimeCompare(minimumFrameDuration, expectedFrameDuration) == 0 else {
            throw RenderedPreviewFailure.artifactUnavailable("Rendered artifact frame rate does not match its descriptor.")
        }
    }
}
