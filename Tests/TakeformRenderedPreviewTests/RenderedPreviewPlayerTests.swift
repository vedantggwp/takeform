import AVFoundation
import CoreVideo
import Foundation
import XCTest
@_spi(Testing) @testable import TakeformRenderedPreview
import TakeformAppAuthorityWire
import TakeformCore

final class RenderedPreviewPlayerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("takeform-rendered-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testFirstAndLastSeekRequireCopiedVideoBuffers() async throws {
        let artifact = root.appendingPathComponent("two-frames.mp4")
        try await writeTwoFrameVideo(to: artifact)
        let source = try makeSource(url: artifact)
        let preview = RenderedPreviewPlayer()

        try await preview.load(source)
        let first = try await preview.seek(frame: 0)
        let last = try await preview.seek(frame: 1)

        XCTAssertEqual(first.requestedFrame, 0)
        XCTAssertEqual(last.requestedFrame, 1)
        XCTAssertEqual(CVPixelBufferGetWidth(first.pixelBuffer), 8)
        XCTAssertEqual(CVPixelBufferGetHeight(first.pixelBuffer), 4)
        XCTAssertEqual(CVPixelBufferGetWidth(last.pixelBuffer), 8)
        XCTAssertEqual(CVPixelBufferGetHeight(last.pixelBuffer), 4)
    }

    @MainActor
    func testClearInvalidatesSelectionAndRejectsFurtherSeeks() async throws {
        let artifact = root.appendingPathComponent("two-frames.mp4")
        try await writeTwoFrameVideo(to: artifact)
        let preview = RenderedPreviewPlayer()
        try await preview.load(try makeSource(url: artifact))

        preview.clear()
        do {
            _ = try await preview.seek(frame: 0)
            XCTFail("cleared player accepted a seek")
        } catch let failure as RenderedPreviewFailure {
            XCTAssertEqual(failure, .artifactUnavailable("No authority-validated render is loaded."))
        }
    }

    @MainActor
    func testSupersededLoadCannotOverwriteNewerSource() async throws {
        let firstDigest = String(repeating: "a", count: 64)
        let secondDigest = String(repeating: "c", count: 64)
        let gate = AssetVerificationGate(delayedDigest: firstDigest)
        let preview = RenderedPreviewPlayer(assetVerifier: { source in await gate.verify(source) })
        let first = try makeSource(url: root.appendingPathComponent("first.mp4"), digest: firstDigest)
        let second = try makeSource(url: root.appendingPathComponent("second.mp4"), digest: secondDigest)

        let firstLoad = Task { try await preview.load(first) }
        await gate.waitForDelayedLoad()
        try await preview.load(second)
        await gate.releaseDelayedLoad()

        do {
            try await firstLoad.value
            XCTFail("superseded load completed")
        } catch let failure as RenderedPreviewFailure {
            XCTAssertEqual(failure, .staleSource)
        }
        XCTAssertEqual(
            preview.sourceIdentity,
            RenderedPreviewIdentity(jobID: second.jobID, requestedRevision: second.requestedRevision, compositionDigest: second.compositionDigest)
        )
    }

    @MainActor
    func testLoadRejectsNonSilentSourceBeforeReadingArtifact() async throws {
        let preview = RenderedPreviewPlayer()
        let source = try makeSource(url: root.appendingPathComponent("not-read.mp4"), audioStreamCount: 1)

        do {
            try await preview.load(source)
            XCTFail("non-silent source was accepted")
        } catch let failure as RenderedPreviewFailure {
            XCTAssertEqual(failure, .sourceInvalid("Authority playback source does not match the silent montage contract."))
        }
    }

    private func makeSource(url: URL, audioStreamCount: Int = 0, digest: String = String(repeating: "a", count: 64)) throws -> EpisodeRenderPlaybackSource {
        let frameRate = try XCTUnwrap(CompositionTime(value: 30, timescale: 1))
        let duration = try XCTUnwrap(CompositionTime(value: 2, timescale: 30))
        let jobID = UUID()
        return EpisodeRenderPlaybackSource(
            jobID: jobID,
            requestedRevision: Revision(7),
            compositionDigest: digest,
            output: CompositionOutput(width: 8, height: 4, frameRate: frameRate, duration: duration),
            descriptor: EpisodeRenderDescriptor(jobID: jobID, format: .mp4, byteLength: 0, sha256: String(repeating: "b", count: 64)),
            videoStreamCount: 1,
            audioStreamCount: audioStreamCount,
            artifactURL: url
        )
    }

    @MainActor
    private func writeTwoFrameVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 8,
            AVVideoHeightKey: 4
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 8,
                kCVPixelBufferHeightKey as String: 4
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<2 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            let pixel = try makePixelBuffer(red: frame == 0 ? 0xFF : 0x00)
            let time = CMTime(value: Int64(frame), timescale: 30)
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: time))
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "writer failed")
    }

    @MainActor
    private func makePixelBuffer(red: UInt8) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                8,
                4,
                kCVPixelFormatType_32BGRA,
                nil,
                &result
            ),
            kCVReturnSuccess
        )
        let pixel = try XCTUnwrap(result)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixel, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
        let count = CVPixelBufferGetBytesPerRow(pixel) * CVPixelBufferGetHeight(pixel)
        for index in stride(from: 0, to: count, by: 4) {
            bytes[index] = 0
            bytes[index + 1] = 0
            bytes[index + 2] = red
            bytes[index + 3] = 0xFF
        }
        return pixel
    }
}

private actor AssetVerificationGate {
    private let delayedDigest: String
    private var delayedLoadStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(delayedDigest: String) { self.delayedDigest = delayedDigest }

    func verify(_ source: EpisodeRenderPlaybackSource) async {
        guard source.compositionDigest == delayedDigest else { return }
        delayedLoadStarted = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitForDelayedLoad() async {
        while !delayedLoadStarted { await Task.yield() }
    }

    func releaseDelayedLoad() {
        continuation?.resume()
        continuation = nil
    }
}
