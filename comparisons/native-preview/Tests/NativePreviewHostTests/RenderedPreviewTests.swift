import AVFoundation
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import NativePreviewHost

struct RenderedPreviewTests {
    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func key(revision: String = "rev-a", bytes: Data = Data("rendered-preview".utf8)) throws -> RenderedPreviewKey {
        try RenderedPreviewKey(
            planID: "episode-a", revision: revision, snapshotDigest: String(repeating: "a", count: 64),
            rendererID: "hyperframes", rendererDigest: String(repeating: "b", count: 64), settingsDigest: String(repeating: "c", count: 64),
            inputManifestDigest: String(repeating: "d", count: 64), outputSHA256: digest(bytes), byteCount: Int64(bytes.count),
            frameRate: try Rational(30, 1), totalFrames: 480, videoStreamCount: 1, audioStreamCount: 0, validatedGatesReceipt: "receipt-a"
        )
    }

    @Test func cachePublishesOnlyHashVerifiedNoClobberArtifact() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rendered-preview-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("rendered-preview".utf8)
        let source = root.appending(path: "source.mp4")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: source)
        let cache = try RenderArtifactCache(root: root)
        let descriptor = try key(bytes: bytes)
        let first = try cache.publish(staged: cache.stageCopy(from: source), key: descriptor)
        #expect(first.url.lastPathComponent == descriptor.artifactFilename)
        #expect(try Data(contentsOf: first.url) == bytes)
        #expect(throws: RenderedPreviewFailure.self) {
            try cache.publish(staged: cache.stageCopy(from: source), key: descriptor)
        }
        #expect(try Data(contentsOf: first.url) == bytes)
    }

    @Test func cacheNeverReplacesAnAdversarialExistingDestination() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rendered-preview-existing-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("rendered-preview".utf8)
        let source = root.appending(path: "source.mp4")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: source)
        let cache = try RenderArtifactCache(root: root)
        let descriptor = try key(bytes: bytes)
        let destination = root.appending(path: "artifacts", directoryHint: .isDirectory).appending(path: descriptor.artifactFilename)
        let adversarial = Data("do-not-replace".utf8)
        try adversarial.write(to: destination)
        #expect(throws: RenderedPreviewFailure.self) {
            try cache.publish(staged: cache.stageCopy(from: source), key: descriptor)
        }
        #expect(try Data(contentsOf: destination) == adversarial)
    }

    @Test func cacheRejectsAFileThatWasNotCreatedInOwnedStaging() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rendered-preview-staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("rendered-preview".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "source.mp4")
        try bytes.write(to: source)
        let cache = try RenderArtifactCache(root: root)
        #expect(throws: RenderedPreviewFailure.self) {
            try cache.publish(staged: source, key: try key(bytes: bytes))
        }
    }

    @Test func cacheRejectsSymlinkedArtifactDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rendered-preview-symlink-\(UUID().uuidString)", directoryHint: .isDirectory)
        let outside = FileManager.default.temporaryDirectory.appending(path: "rendered-preview-outside-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let bytes = Data("rendered-preview".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let source = root.appending(path: "source.mp4")
        try bytes.write(to: source)
        let cache = try RenderArtifactCache(root: root)
        try FileManager.default.removeItem(at: root.appending(path: "artifacts", directoryHint: .isDirectory))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "artifacts"), withDestinationURL: outside)
        #expect(throws: RenderedPreviewFailure.self) {
            try cache.publish(staged: cache.stageCopy(from: source), key: try key(bytes: bytes))
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appending(path: try! key(bytes: bytes).artifactFilename).path))
    }

    @Test func staleRevisionCannotPublishOrBecomeCurrent() throws {
        let bytes = Data("rendered-preview".utf8)
        var state = RenderedPreviewState(currentRevision: "rev-a")
        let oldKey = try key(revision: "rev-a", bytes: bytes)
        let job = try state.begin(oldKey)
        try state.progress(jobID: job, value: .units(completed: 1, total: 2))
        state.advanceRevision(to: "rev-b")
        let artifact = VerifiedRenderArtifact(key: oldKey, url: URL(fileURLWithPath: "/tmp/old.mp4"))
        #expect(throws: RenderedPreviewFailure.staleJob) { try state.complete(jobID: job, artifact: artifact) }
        #expect(state.currentArtifact == nil)
        #expect(state.status == .superseded)
    }

    @Test func progressIsCallbackBoundAndCancellationIsTerminal() throws {
        let bytes = Data("rendered-preview".utf8)
        var state = RenderedPreviewState(currentRevision: "rev-a")
        let job = try state.begin(key(bytes: bytes))
        try state.progress(jobID: job, value: .indeterminate)
        #expect(throws: RenderedPreviewFailure.invalidProgress) { try state.progress(jobID: job, value: .units(completed: 2, total: 1)) }
        state.cancel(jobID: job)
        #expect(state.status == .cancelled)
        #expect(throws: RenderedPreviewFailure.staleJob) {
            try state.progress(jobID: job, value: .units(completed: 1, total: 1))
        }
    }

    @Test @MainActor func cancelledStoreCannotPublishAStagedArtifact() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rendered-preview-cancel-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("rendered-preview".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "source.mp4")
        try bytes.write(to: source)
        let cache = try RenderArtifactCache(root: root)
        let store = RenderedPreviewStore(currentRevision: "rev-a")
        let job = try store.begin(key: try key(bytes: bytes))
        let staged = try cache.stageCopy(from: source)
        store.cancel(jobID: job, stagedURL: staged, cache: cache)
        #expect(throws: RenderedPreviewFailure.self) {
            try store.publish(jobID: job, stagedURL: staged, cache: cache)
        }
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "artifacts", directoryHint: .isDirectory).appending(path: try! key(bytes: bytes).artifactFilename).path))
    }

    @Test @MainActor func failedCancellationCleanupIsAnHonestTerminalError() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rendered-preview-cancel-failure-\(UUID().uuidString)", directoryHint: .isDirectory)
        let outside = FileManager.default.temporaryDirectory.appending(path: "rendered-preview-cancel-outside-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let bytes = Data("rendered-preview".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let source = root.appending(path: "source.mp4")
        try bytes.write(to: source)
        let cache = try RenderArtifactCache(root: root)
        let store = RenderedPreviewStore(currentRevision: "rev-a")
        let job = try store.begin(key: try key(bytes: bytes))
        let staged = try cache.stageCopy(from: source)
        try FileManager.default.removeItem(at: staged)
        try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: outside)
        store.cancel(jobID: job, stagedURL: staged, cache: cache)
        guard case let .failed(message) = store.status else {
            Issue.record("Expected failed cleanup state, got \(store.status)")
            return
        }
        #expect(message.contains("could not clean"))
    }
}

@Suite @MainActor
struct RenderedPreviewPlayerTests {
    @Test func retainedMDecodesFirstAndLastFrameWhenExplicitlyConfigured() async throws {
        guard let value = ProcessInfo.processInfo.environment["TAKEFORM_RENDERED_PREVIEW_M_PATH"], !value.isEmpty else { return }
        let url = URL(fileURLWithPath: value)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = try Data(contentsOf: url)
        let key = try RenderedPreviewKey(
            planID: "retained-m", revision: "developer-artifact", snapshotDigest: String(repeating: "a", count: 64),
            rendererID: "hyperframes", rendererDigest: String(repeating: "b", count: 64), settingsDigest: String(repeating: "c", count: 64),
            inputManifestDigest: String(repeating: "d", count: 64), outputSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            byteCount: (attributes[.size] as? NSNumber)?.int64Value ?? 0, frameRate: try Rational(30, 1), totalFrames: 480, videoStreamCount: 1, audioStreamCount: 0, validatedGatesReceipt: "developer-only"
        )
        let controller = RenderedPreviewPlayer()
        try await controller.load(VerifiedRenderArtifact(key: key, url: url))
        let residentBefore = residentBytes()
        let firstStarted = DispatchTime.now().uptimeNanoseconds
        let first = try await controller.seek(frame: 0, key: key)
        let firstMilliseconds = elapsedMilliseconds(since: firstStarted)
        let last = try await controller.seek(frame: 479, key: key)
        let seekFrames = (0..<20).map { $0 * 479 / 19 }
        var seekMilliseconds: [Double] = []
        for frame in seekFrames {
            let started = DispatchTime.now().uptimeNanoseconds
            _ = try await controller.seek(frame: frame, key: key)
            seekMilliseconds.append(elapsedMilliseconds(since: started))
        }
        let residentAfter = residentBytes()
        #expect(CVPixelBufferGetWidth(first.pixelBuffer) == 1_920)
        #expect(CVPixelBufferGetHeight(first.pixelBuffer) == 1_080)
        #expect(CVPixelBufferGetWidth(last.pixelBuffer) == 1_920)
        let ordered = seekMilliseconds.sorted()
        let metrics = [
            "first=\(String(format: "%.2f", firstMilliseconds))ms",
            "20-seek-p50=\(String(format: "%.2f", ordered[9]))ms",
            "p95=\(String(format: "%.2f", ordered[18]))ms",
            "resident-before=\(residentBefore)",
            "resident-after=\(residentAfter)"
        ].joined(separator: " ")
        print("RenderedPreview M pixel-buffer acknowledgements: \(metrics)")
        controller.stop()
    }

    private func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}
