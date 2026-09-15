import CryptoKit
import Darwin
import Foundation
import TakeformCore
import TakeformMedia

/// Authority-only copy/promotion primitive. It never mutates a source and only
/// removes the UUID staging directory it created. The catalog commit remains a
/// separate revisioned command after this result has a durable object.
enum ManagedImport {
    enum Failure: Error, Equatable {
        case invalidSource
        case sourceChanged
        case objectCollision
        case unsafePackagePath
        case unsupportedMedia
        case durability
    }

    /// The hooks are internal so focused fault tests can change state at a
    /// known byte boundary. The app-service route supplies neither hook.
    static func stageAndPromoteSync(
        source: URL,
        package: URL,
        shouldCancel: (() -> Bool)? = nil,
        afterChunk: ((Int) -> Void)? = nil
    ) throws -> ManagedAsset {
        let sourceBefore = try sourceStat(source)
        let state = package.appendingPathComponent(".takeform", isDirectory: true)
        try requireRegularDirectory(state)
        let stagingRoot = state.appendingPathComponent("staging", isDirectory: true)
        try ensureRegularDirectory(stagingRoot)

        let token = UUID().uuidString
        let staging = stagingRoot.appendingPathComponent(token, isDirectory: true)
        try createOwnedDirectory(staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        try requireRegularDirectory(staging)

        let stagedName = source.pathExtension.isEmpty ? "bytes" : "bytes.\(source.pathExtension.lowercased())"
        let staged = staging.appendingPathComponent(stagedName)
        let input = try openRegularFile(source, flags: O_RDONLY, failure: .invalidSource)
        defer { try? input.close() }
        var sourceFDBefore = stat()
        guard fstat(input.fileDescriptor, &sourceFDBefore) == 0, sameIdentity(sourceBefore, sourceFDBefore) else {
            throw Failure.invalidSource
        }

        let output = try createStagedFile(staged)
        var digest = SHA256()
        var count: UInt64 = 0
        var chunk = 0
        do {
            while true {
                if shouldCancel?() == true { throw CancellationError() }
                let data = try input.read(upToCount: 64 * 1024) ?? Data()
                if data.isEmpty { break }
                digest.update(data: data)
                count += UInt64(data.count)
                try output.write(contentsOf: data)
                chunk += 1
                afterChunk?(chunk)
            }
            try output.synchronize()
            try output.close()
        } catch {
            try? output.close()
            throw error
        }

        var sourceFDAfter = stat()
        let sourceAfter = try sourceStat(source)
        guard fstat(input.fileDescriptor, &sourceFDAfter) == 0,
              sameIdentity(sourceBefore, sourceAfter),
              sameIdentity(sourceFDBefore, sourceFDAfter),
              sameIdentity(sourceBefore, sourceFDBefore) else { throw Failure.sourceChanged }

        // Before linking, every package-owned path must still be the expected
        // non-symlink type. A hard link then preserves immutable staged bytes;
        // the closed staging file descriptor cannot keep a writable alias open.
        _ = try regularStat(staged, failure: .unsafePackagePath)
        try requireRegularDirectory(stagingRoot)
        let objects = state.appendingPathComponent("objects", isDirectory: true)
        try ensureRegularDirectory(objects)
        try syncDirectory(objects)
        let hash = hex(digest.finalize())
        let object = objects.appendingPathComponent(hash)
        if link(staged.path, object.path) != 0 {
            guard errno == EEXIST else { throw Failure.durability }
            do {
                guard try fileFacts(at: object) == (hash, count) else { throw Failure.objectCollision }
            } catch let failure as Failure {
                if failure == .unsafePackagePath { throw failure }
                throw Failure.objectCollision
            }
        }
        try syncDirectory(objects)
        let unvalidated = ManagedAsset(digest: hash, byteLength: count, filename: source.lastPathComponent, mediaType: "unvalidated")
        return try validatePromotedMedia(unvalidated, probeURL: staged)
    }

    /// The catalog is allowed to reference only bytes that were successfully
    /// measured from the immutable promoted object, never from the mutable
    /// source pathname. The matching digest binds the persisted media type to
    /// those exact object bytes.
    static func validatePromotedMedia(_ asset: ManagedAsset, probeURL: URL) throws -> ManagedAsset {
        let result = waitForProbe(probeURL)
        guard case let .success(facts) = result,
              facts.source.byteLength == asset.byteLength,
              facts.source.byteLength > 0,
              facts.source.sha256 == asset.digest else { throw Failure.unsupportedMedia }
        let mediaType: String
        if facts.image != nil { mediaType = "image" }
        else if facts.video != nil { mediaType = "video" }
        else if !facts.audio.isEmpty { mediaType = "audio" }
        else { throw Failure.unsupportedMedia }
        return ManagedAsset(digest: asset.digest, byteLength: asset.byteLength, filename: asset.filename, mediaType: mediaType, probe: portableProbe(facts))
    }

    static func verifyObject(_ asset: ManagedAsset, package: URL) throws {
        guard asset.digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              asset.byteLength > 0,
              !asset.filename.isEmpty else { throw AuthorityFailure.corruptDatabase }
        let objectName = "objects/\(asset.digest)"
        let state = package.appendingPathComponent(".takeform", isDirectory: true)
        let objects = state.appendingPathComponent("objects", isDirectory: true)
        do {
            try requireRegularDirectory(state)
            try requireRegularDirectory(objects)
            let object = objects.appendingPathComponent(asset.digest)
            guard try fileFacts(at: object) == (asset.digest, asset.byteLength) else { throw Failure.objectCollision }
        } catch {
            // A catalog must never follow an object or storage-root symlink to
            // make outside bytes appear to be portable media.
            throw AuthorityFailure.missingObject(objectName)
        }
    }

    private static func sourceStat(_ url: URL) throws -> stat {
        try regularStat(url, failure: .invalidSource)
    }

    private static func regularStat(_ url: URL, failure: Failure) throws -> stat {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw failure }
        return info
    }

    private static func requireRegularDirectory(_ url: URL) throws {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw Failure.unsafePackagePath }
    }

    private static func ensureRegularDirectory(_ url: URL) throws {
        var info = stat()
        if Darwin.lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else { throw Failure.unsafePackagePath }
            return
        }
        guard errno == ENOENT, Darwin.mkdir(url.path, S_IRWXU) == 0 else { throw Failure.unsafePackagePath }
        try requireRegularDirectory(url)
    }

    private static func createOwnedDirectory(_ url: URL) throws {
        guard Darwin.mkdir(url.path, S_IRWXU) == 0 else { throw Failure.durability }
        try requireRegularDirectory(url)
    }

    private static func createStagedFile(_ url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Failure.durability }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw Failure.unsafePackagePath
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func openRegularFile(_ url: URL, flags: Int32, failure: Failure) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, flags | O_NOFOLLOW)
        guard descriptor >= 0 else { throw failure }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw failure
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func fileFacts(at url: URL) throws -> (String, UInt64) {
        _ = try regularStat(url, failure: .unsafePackagePath)
        let input = try openRegularFile(url, flags: O_RDONLY, failure: .unsafePackagePath)
        defer { try? input.close() }
        var digest = SHA256()
        var count: UInt64 = 0
        while true {
            let data = try input.read(upToCount: 64 * 1024) ?? Data()
            if data.isEmpty { break }
            digest.update(data: data)
            count += UInt64(data.count)
        }
        return (hex(digest.finalize()), count)
    }

    private final class ProbeBox: @unchecked Sendable {
        var result: MediaProbeResult?
    }

    private static func waitForProbe(_ object: URL) -> MediaProbeResult {
        let box = ProbeBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.result = await MediaProbe().inspect(object)
            done.signal()
        }
        done.wait()
        return box.result ?? .failure(.unreadableFile)
    }

    private static func portableProbe(_ facts: MediaSourceFacts) -> ManagedAssetProbe {
        func rational(_ value: RationalTime?) -> ManagedAssetProbe.Rational? { value.map { .init($0.value, $0.timescale) } }
        func range(_ value: RationalTimeRange?) -> [ManagedAssetProbe.Rational]? { guard let value else { return nil }; return [.init(value.start.value, value.start.timescale), .init(value.duration.value, value.duration.timescale)] }
        let video = facts.video.map { ManagedAssetProbe.Video(codec: $0.codecFourCC, encodedWidth: $0.encodedWidth, encodedHeight: $0.encodedHeight, displayedWidth: $0.displayedWidth, displayedHeight: $0.displayedHeight, transform: $0.preferredTransform, nominalFrameRate: $0.nominalFrameRate, timeRange: range($0.timeRange), presentationTimestamps: $0.presentationTimestamps.map { .init($0.value, $0.timescale) }, observedPresentationDeltaCount: $0.observedPresentationDeltaCount, isVariableFrameRate: $0.isVariableFrameRate) }
        let audio = facts.audio.map { ManagedAssetProbe.Audio(codec: $0.codecFourCC, channels: $0.channels, sampleRate: $0.sampleRate, timeRange: range($0.timeRange)) }
        return ManagedAssetProbe(containerIdentifier: facts.containerIdentifier, durationValue: rational(facts.duration)?.value, durationTimescale: rational(facts.duration)?.timescale, imageEncodedWidth: facts.image?.encodedWidth, imageEncodedHeight: facts.image?.encodedHeight, imageDisplayedWidth: facts.image?.displayedWidth, imageDisplayedHeight: facts.image?.displayedHeight, imageOrientation: facts.image?.orientation, video: video, audio: audio, livePhotoIdentifier: facts.livePhotoContentIdentifier?.value, livePhotoComparisonIdentifier: facts.livePhotoContentIdentifier?.comparisonValue, livePhotoProvenance: facts.livePhotoContentIdentifier?.provenance.rawValue, livePhotoNormalization: facts.livePhotoContentIdentifier?.normalization.rawValue)
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    private static func syncDirectory(_ url: URL) throws {
        try requireRegularDirectory(url)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.durability }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw Failure.durability }
    }

    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

}
