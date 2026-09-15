import AVFoundation
import CryptoKit
import Dispatch
import Foundation
import Testing
@testable import TakeformMedia

struct TakeformMediaTests {
    private let probe = MediaProbe()

    @Test func validStillReportsEncodedAndDisplayedDimensionsAndHash() async throws {
        let fixtures = try SyntheticMediaFixtures()
        defer { fixtures.cleanup() }
        let source = try fixtures.orientationStill(named: "orientation.heic")
        let facts = try success(await probe.inspect(source))
        let expectedHash = try sha256(of: source)
        #expect(facts.source.sha256 == expectedHash)
        #expect(facts.image?.encodedWidth == 8)
        #expect(facts.image?.encodedHeight == 4)
        #expect(facts.image?.displayedWidth == 4)
        #expect(facts.image?.displayedHeight == 8)
        #expect(facts.image?.orientation == 6)
        #expect(facts.measurement.hashChunkBytes == MediaProbe.defaultHashChunkBytes)
        #expect(facts.measurement.elapsedNanoseconds > 0)
        #expect(facts.measurement.processPeakResidentBytes != nil)
    }

    @Test func realSamplesDriveVFRAndCFRPresentationFacts() async throws {
        let fixtures = try SyntheticMediaFixtures()
        defer { fixtures.cleanup() }
        let facts = try success(await probe.inspect(try await fixtures.video(named: "vfr.mov")))
        let video = try #require(facts.video)
        let authoredTimestamps = [0, 20, 73, 160, 230, 400].map {
            RationalTime(value: Int64($0), timescale: 600)!
        }
        #expect(video.nominalFrameRate != nil)
        #expect(video.codecFourCC == "avc1")
        #expect(video.presentationTimestamps == authoredTimestamps)
        #expect(video.presentationTimestamps.count == 6)
        #expect(containsOrderedSubsequence(authoredTimestamps, in: video.presentationTimestamps))
        let authoredDeltas = zip(authoredTimestamps.dropFirst(), authoredTimestamps)
            .map { later, earlier in
                Double(later.value) / Double(later.timescale) - Double(earlier.value) / Double(earlier.timescale)
            }
        #expect(Set(authoredDeltas).count > 1)
        #expect(video.observedPresentationDeltaCount > 0)
        #expect(video.isVariableFrameRate == true)
        #expect(video.timeRange?.duration.timescale ?? 0 > 0)
        #expect(facts.duration?.timescale ?? 0 > 0)
        #expect(facts.measurement.presentationSamplesScanned == video.presentationTimestamps.count)

        let cfrFacts = try success(await probe.inspect(try await fixtures.video(
            named: "cfr.mov",
            presentationTimes: [0, 100, 200, 300]
        )))
        let cfr = try #require(cfrFacts.video)
        let cfrTimestamps = [0, 100, 200, 300].map {
            RationalTime(value: Int64($0), timescale: 600)!
        }
        #expect(cfr.presentationTimestamps == cfrTimestamps)
        #expect(cfr.presentationTimestamps.count == 4)
        #expect(cfr.observedPresentationDeltaCount == 3)
        #expect(cfr.isVariableFrameRate == false)
        #expect(cfrFacts.measurement.presentationSamplesScanned == cfr.presentationTimestamps.count)
    }

    @Test func generatedRotatedVideoReportsEncodedAndDisplayedDimensions() async throws {
        let fixtures = try SyntheticMediaFixtures()
        defer { fixtures.cleanup() }
        let facts = try success(await probe.inspect(try await fixtures.video(named: "rotated.mov", rotated: true)))
        let video = try #require(facts.video)
        #expect(video.encodedWidth == 8)
        #expect(video.encodedHeight == 4)
        #expect(video.displayedWidth == 4)
        #expect(video.displayedHeight == 8)
    }

    @Test func audioReportsMonoAndStereoWithoutInventingValues() async throws {
        let fixtures = try SyntheticMediaFixtures()
        defer { fixtures.cleanup() }
        let mono = try success(await probe.inspect(try fixtures.monoAIFF(named: "mono.aiff")))
        let stereo = try success(await probe.inspect(try fixtures.stereoM4A(named: "stereo.m4a")))
        #expect(mono.audio.first?.codecFourCC == "lpcm")
        #expect(mono.audio.first?.channels == 1)
        #expect(mono.audio.first?.sampleRate == 22_050)
        #expect(mono.audio.first?.timeRange?.duration.timescale ?? 0 > 0)
        #expect(stereo.audio.first?.codecFourCC == "aac ")
        #expect(stereo.audio.first?.channels == 2)
        #expect(stereo.audio.first?.sampleRate == 48_000)
    }

    @Test func exactDuplicateIsSourceIdentityNotMomentIdentity() async throws {
        let fixtures = try SyntheticMediaFixtures()
        defer { fixtures.cleanup() }
        let firstURL = try fixtures.png(named: "source.png")
        let duplicateURL = fixtures.root.appending(path: "same-bytes-different-name.png")
        try FileManager.default.copyItem(at: firstURL, to: duplicateURL)
        let first = try success(await probe.inspect(firstURL))
        let duplicate = try success(await probe.inspect(duplicateURL))
        let expectedHash = try sha256(of: firstURL)
        #expect(first.source.sha256 == expectedHash)
        #expect(MediaProbe.hasSameBytes(first, duplicate))
    }

    @Test func livePhotoIdentityConfirmsMatchingAndRefusesMismatch() async throws {
        let fixtures = try SyntheticMediaFixtures()
        defer { fixtures.cleanup() }
        let matchedStill = try fixtures.orientationStill(named: "matched.heic", contentIdentifier: "matched-id....")
        let matchedMotion = try await fixtures.motion(named: "matched.mov", contentIdentifier: "matched-id")
        let mismatchStill = try fixtures.orientationStill(named: "mismatch.heic", contentIdentifier: "still-id")
        let mismatchMotion = try await fixtures.motion(named: "mismatch.mov", contentIdentifier: "motion-id")
        let still = try success(await probe.inspect(matchedStill))
        let motion = try success(await probe.inspect(matchedMotion))
        let otherStill = try success(await probe.inspect(mismatchStill))
        let otherMotion = try success(await probe.inspect(mismatchMotion))
        #expect(still.livePhotoContentIdentifier?.provenance == .imageIOMakerApple17)
        #expect(motion.livePhotoContentIdentifier?.provenance == .quickTimeContentIdentifier)
        #expect(still.livePhotoContentIdentifier?.normalization == .trailingMakerApplePeriodPadding)
        #expect(still.livePhotoContentIdentifier?.comparisonValue == motion.livePhotoContentIdentifier?.comparisonValue)
        #expect(otherStill.livePhotoContentIdentifier?.comparisonValue != otherMotion.livePhotoContentIdentifier?.comparisonValue)
        if case .confirmed = MediaProbe.pairLivePhoto(still: still, motion: motion) {
        } else { Issue.record("Matching measured Live Photo identifiers were not confirmed") }
        if case .candidate = MediaProbe.pairLivePhoto(still: otherStill, motion: otherMotion) {
        } else { Issue.record("Mismatched measured Live Photo identifiers were incorrectly confirmed") }
    }

    @Test func wrongKindsAndMissingLivePhotoIDsDoNotConfirmPairs() async throws {
        let fixtures = try SyntheticMediaFixtures()
        defer { fixtures.cleanup() }
        let identifiedStill = try success(await probe.inspect(try fixtures.orientationStill(named: "identified.heic", contentIdentifier: "same-id")))
        let noIDStill = try success(await probe.inspect(try fixtures.orientationStill(named: "no-id.heic")))
        let noIDMotion = try success(await probe.inspect(try await fixtures.video(named: "no-id.mov")))
        if case .candidate(let reason) = MediaProbe.pairLivePhoto(still: identifiedStill, motion: identifiedStill) {
            #expect(reason == "Live Photo motion must be a video source")
        } else { Issue.record("Image/image pair was not kept as a candidate") }
        if case .unavailable = MediaProbe.pairLivePhoto(still: noIDStill, motion: noIDMotion) {
        } else { Issue.record("Absent measured IDs created a pair") }
    }

    @Test func corruptFileAndPreCancelledTaskHaveTypedFailures() async throws {
        let fixtures = try SyntheticMediaFixtures()
        defer { fixtures.cleanup() }
        let corrupt = await probe.inspect(try fixtures.corruptPNG(named: "corrupt.png"))
        #expect(corrupt == .failure(.unsupportedOrCorrupt(reason: "Image metadata is unreadable")))
        let input = try await fixtures.video(named: "cancel-before-start.mov")
        let task = Task { await MediaProbe(hashChunkBytes: 1).inspect(input) }
        task.cancel()
        #expect(await task.value == .failure(.cancelled))
    }

    @Test func cancellationAfterHashingStartsReturnsTypedFailure() async throws {
        let fixtures = try SyntheticMediaFixtures()
        defer { fixtures.cleanup() }
        let gate = ProgressGate()
        let release = DispatchSemaphore(value: 0)
        let input = try await fixtures.video(named: "cancel-in-flight.mov")
        let probe = MediaProbe(
            hashChunkBytes: 1024,
            maximumStoredPresentationTimestamps: 8,
            progress: { point in
                guard point == .hashChunkRead else { return }
                Task { await gate.signal() }
                release.wait()
            }
        )
        let task = Task { await probe.inspect(input) }
        await gate.waitForSignal()
        task.cancel()
        release.signal()
        #expect(await task.value == .failure(.cancelled))
    }

    @Test func largeValidSourceUsesObservedChunkBoundAndTimestampStorage() async throws {
        let fixtures = try SyntheticMediaFixtures()
        defer { fixtures.cleanup() }
        let source = try await fixtures.paddedVideo(named: "large-vfr.mov", minimumLogicalBytes: 100_000_001)
        let progress = HashChunkProgress()
        let chunkBytes = 32 * 1024
        let facts = try success(await MediaProbe(
            hashChunkBytes: chunkBytes,
            maximumStoredPresentationTimestamps: 8,
            progress: { point in if point == .hashChunkRead { progress.record() } }
        ).inspect(source))
        let byteLength = try fixtures.fileSize(source)
        #expect(byteLength > 100_000_000)
        #expect(facts.source.byteLength == byteLength)
        #expect(facts.measurement.hashChunkBytes == chunkBytes)
        #expect(progress.count == Int((byteLength + UInt64(chunkBytes) - 1) / UInt64(chunkBytes)))
        #expect(facts.video?.presentationTimestamps.count == 8)
        #expect(facts.measurement.presentationSamplesScanned > 8)
    }

    private func success(_ result: MediaProbeResult) throws -> MediaSourceFacts {
        guard case .success(let facts) = result else { throw TestFailure("Expected success, got \(result)") }
        return facts
    }

    private func sha256(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private func containsOrderedSubsequence(_ expected: [RationalTime], in observed: [RationalTime]) -> Bool {
    var expectedIndex = expected.startIndex
    for timestamp in observed where expectedIndex < expected.endIndex {
        if timestamp == expected[expectedIndex] {
            expected.formIndex(after: &expectedIndex)
        }
    }
    return expectedIndex == expected.endIndex
}

private actor ProgressGate {
    private var signalled = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        guard !signalled else { return }
        signalled = true
        waiter?.resume()
        waiter = nil
    }

    func waitForSignal() async {
        guard !signalled else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private final class HashChunkProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0
    var count: Int { lock.withLock { storedCount } }
    func record() { lock.withLock { storedCount += 1 } }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
