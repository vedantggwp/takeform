import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import TakeformMedia

struct TakeformMediaTests {
    private let probe = MediaProbe()

    @Test func validStillReportsEncodedAndDisplayedDimensionsAndHash() async throws {
        let result = await probe.inspect(try fixture("M/media/station.heic"))
        let facts = try success(result)
        #expect(facts.source.sha256 == "57d04c4d43065b238a879e70142e08471c7c34bd04516cb1da17650f93247f1d")
        #expect(facts.image?.encodedWidth == 1920)
        #expect(facts.image?.encodedHeight == 1080)
        #expect(facts.image?.displayedWidth == 1080)
        #expect(facts.image?.displayedHeight == 1920)
        #expect(facts.image?.orientation == 6)
        #expect(facts.measurement.hashChunkBytes == MediaProbe.defaultHashChunkBytes)
        #expect(facts.measurement.elapsedNanoseconds > 0)
        #expect(facts.measurement.processPeakResidentBytes != nil)
    }

    @Test func vfrVideoRetainsMeasuredPresentationTimes() async throws {
        let facts = try success(await probe.inspect(try fixture("T/media/take2.mp4")))
        let video = try #require(facts.video)
        #expect(video.nominalFrameRate != nil)
        #expect(video.codecFourCC == "avc1")
        #expect(video.presentationTimestamps.count > 2)
        #expect(video.observedPresentationDeltaCount > 0)
        #expect(video.isVariableFrameRate == true)
        #expect(video.timeRange?.duration.timescale ?? 0 > 0)
        #expect(facts.duration?.timescale ?? 0 > 0)
        #expect(facts.measurement.presentationSamplesScanned > video.presentationTimestamps.count)
    }

    @Test func generatedRotatedVideoReportsEncodedAndDisplayedDimensions() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "rotated.mov")
        try await writeRotatedVideo(to: source)

        let facts = try success(await probe.inspect(source))
        let video = try #require(facts.video)
        #expect(video.encodedWidth == 8)
        #expect(video.encodedHeight == 4)
        #expect(video.displayedWidth == 4)
        #expect(video.displayedHeight == 8)
    }

    @Test func audioReportsMonoAndStereoWithoutInventingValues() async throws {
        let mono = try success(await probe.inspect(try fixture("T/media/take1-speech.aiff")))
        let stereo = try success(await probe.inspect(try fixture("T/media/music.m4a")))
        #expect(mono.audio.first?.codecFourCC == "lpcm")
        #expect(mono.audio.first?.channels == 1)
        #expect(mono.audio.first?.sampleRate == 22_050)
        #expect(mono.audio.first?.timeRange?.duration.timescale ?? 0 > 0)
        #expect(stereo.audio.first?.codecFourCC == "aac ")
        #expect(stereo.audio.first?.channels == 2)
        #expect(stereo.audio.first?.sampleRate == 48_000)
    }

    @Test func exactDuplicateIsSourceIdentityNotMomentIdentity() async throws {
        let first = try success(await probe.inspect(try fixture("M/media/harbor.png")))
        let duplicate = try success(await probe.inspect(try fixture("M/media/harbor-duplicate.png")))
        #expect(MediaProbe.hasSameBytes(first, duplicate))
    }

    @Test func livePhotoIdentityConfirmsMatchingAndRefusesMismatch() async throws {
        let still = try success(await probe.inspect(try fixture("M/media/lp-matched.heic")))
        let motion = try success(await probe.inspect(try fixture("M/media/lp-matched.mov")))
        let mismatchStill = try success(await probe.inspect(try fixture("M/media/lp-mismatch.heic")))
        let mismatchMotion = try success(await probe.inspect(try fixture("M/media/lp-mismatch.mov")))
        #expect(still.livePhotoContentIdentifier != nil)
        #expect(motion.livePhotoContentIdentifier != nil)
        #expect(mismatchStill.livePhotoContentIdentifier != nil)
        #expect(mismatchMotion.livePhotoContentIdentifier != nil)
        #expect(still.livePhotoContentIdentifier?.normalization == .trailingMakerApplePeriodPadding)
        #expect(still.livePhotoContentIdentifier?.comparisonValue == motion.livePhotoContentIdentifier?.comparisonValue)
        if case .confirmed = MediaProbe.pairLivePhoto(still: still, motion: motion) {
            // expected
        } else {
            Issue.record("Matching fixture was not confirmed by independently measured identifiers")
        }
        if case .candidate = MediaProbe.pairLivePhoto(still: mismatchStill, motion: mismatchMotion) {
            // expected
        } else {
            Issue.record("Mismatched fixture was incorrectly confirmed or unavailable")
        }
    }

    @Test func matchingIdentifiersWithWrongMediaKindsStayCandidates() async throws {
        let still = try success(await probe.inspect(try fixture("M/media/lp-matched.heic")))
        if case .candidate(let reason) = MediaProbe.pairLivePhoto(still: still, motion: still) {
            #expect(reason == "Live Photo motion must be a video source")
        } else {
            Issue.record("Matching identifiers cannot confirm an image/image pair")
        }
    }

    @Test func absentLivePhotoIdentityStaysUnavailable() async throws {
        let still = try success(await probe.inspect(try fixture("M/media/station.heic")))
        let motion = try success(await probe.inspect(try fixture("M/media/clip-24.mov")))
        #expect(still.livePhotoContentIdentifier == nil)
        #expect(motion.livePhotoContentIdentifier == nil)
        if case .unavailable = MediaProbe.pairLivePhoto(still: still, motion: motion) {
            // expected
        } else {
            Issue.record("Absent identifiers must not create a confirmed pair")
        }
    }

    @Test func corruptFileAndPreCancelledTaskHaveTypedFailures() async throws {
        let corrupt = await probe.inspect(try fixture("M/media/harbor-corrupt.png"))
        #expect(corrupt == .failure(.unsupportedOrCorrupt(reason: "Image metadata is unreadable")))
        let input = try fixture("T/media/take1.mp4")
        let task = Task { await MediaProbe(hashChunkBytes: 1).inspect(input) }
        task.cancel()
        #expect(await task.value == .failure(.cancelled))
    }

    @Test func largeSourceUsesBoundedHashAndTimestampStorage() async throws {
        let facts = try success(await MediaProbe(hashChunkBytes: 32 * 1024, maximumStoredPresentationTimestamps: 8).inspect(try fixture("T/media/take1.mp4")))
        #expect(facts.source.byteLength > 100_000_000)
        #expect(facts.measurement.hashChunkBytes == 32 * 1024)
        #expect(facts.video?.presentationTimestamps.count == 8)
        #expect(facts.measurement.presentationSamplesScanned > 8)
    }

    private func success(_ result: MediaProbeResult) throws -> MediaSourceFacts {
        guard case .success(let facts) = result else {
            throw TestFailure("Expected success, got \(result)")
        }
        return facts
    }

    private func fixture(_ relative: String) throws -> URL {
        if let root = ProcessInfo.processInfo.environment["TAKEFORM_FIXTURE_ROOT"] {
            return URL(fileURLWithPath: root).appending(path: relative)
        }
        let sibling = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent()
            .appending(path: "proof-19/fixtures")
        guard FileManager.default.fileExists(atPath: sibling.path) else {
            throw TestFailure("Set TAKEFORM_FIXTURE_ROOT to the immutable fixture root")
        }
        return sibling.appending(path: relative)
    }
}

private func writeRotatedVideo(to url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 8,
        AVVideoHeightKey: 4
    ])
    input.transform = CGAffineTransform(rotationAngle: .pi / 2)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 8,
            kCVPixelBufferHeightKey as String: 4
        ]
    )
    guard writer.canAdd(input) else { throw TestFailure("Cannot add video input") }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? TestFailure("Cannot start writer") }
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, 8, 4, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
          let buffer else { throw TestFailure("Cannot allocate test pixel buffer") }
    guard adaptor.append(buffer, withPresentationTime: .zero) else {
        throw writer.error ?? TestFailure("Cannot append video sample")
    }
    input.markAsFinished()
    await withCheckedContinuation { continuation in
        writer.finishWriting { continuation.resume() }
    }
    guard writer.status == .completed else {
        throw writer.error ?? TestFailure("Cannot finish test movie")
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
