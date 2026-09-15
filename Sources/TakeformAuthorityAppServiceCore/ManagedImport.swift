import CryptoKit
import Darwin
import Foundation
import TakeformCore

/// Authority-only copy/promotion primitive. It never mutates the source and only
/// removes the UUID staging directory it created. Catalog commit is deliberately
/// a separate revisioned command after this result has a durable object.
enum ManagedImport {
    enum Failure: Error, Equatable {
        case invalidSource
        case sourceChanged
        case objectCollision
        case durability
    }

    /// The hooks are internal so focused fault tests can make the copy change
    /// state at a known byte boundary. The app-service route does not supply
    /// either hook.
    static func stageAndPromoteSync(
        source: URL,
        package: URL,
        shouldCancel: (() -> Bool)? = nil,
        afterChunk: ((Int) -> Void)? = nil
    ) throws -> ManagedAsset {
        let token = UUID().uuidString
        let staging = package.appendingPathComponent(".takeform/staging/\(token)")
        let staged = staging.appendingPathComponent("bytes")
        let stagingRoot = staging.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var before = stat()
        guard fstat(input.fileDescriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else { throw Failure.invalidSource }
        FileManager.default.createFile(atPath: staged.path, contents: nil)
        let output = try FileHandle(forWritingTo: staged)
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
        var after = stat()
        guard fstat(input.fileDescriptor, &after) == 0, sameIdentity(before, after) else { throw Failure.sourceChanged }
        let hash = hex(digest.finalize())
        let objects = package.appendingPathComponent(".takeform/objects", isDirectory: true)
        try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: true)
        try syncDirectory(objects)
        let object = objects.appendingPathComponent(hash)
        if link(staged.path, object.path) != 0 {
            guard errno == EEXIST else { throw Failure.durability }
            guard try fileFacts(at: object) == (hash, count) else { throw Failure.objectCollision }
        }
        try syncDirectory(objects)
        return ManagedAsset(digest: hash, byteLength: count, filename: source.lastPathComponent, mediaType: mediaType(for: source))
    }

    static func verifyObject(_ asset: ManagedAsset, package: URL) throws {
        guard asset.digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              asset.byteLength > 0,
              !asset.filename.isEmpty else { throw AuthorityFailure.corruptDatabase }
        let object = package.appendingPathComponent(".takeform/objects/\(asset.digest)")
        guard FileManager.default.fileExists(atPath: object.path) else { throw AuthorityFailure.missingObject("objects/\(asset.digest)") }
        guard try fileFacts(at: object) == (asset.digest, asset.byteLength) else { throw AuthorityFailure.missingObject("objects/\(asset.digest)") }
    }

    private static func fileFacts(at url: URL) throws -> (String, UInt64) {
        let input = try FileHandle(forReadingFrom: url)
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

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw Failure.durability }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw Failure.durability }
    }

    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    private static func mediaType(for source: URL) -> String {
        let imageExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "gif"]
        return imageExtensions.contains(source.pathExtension.lowercased()) ? "image" : "video-or-audio"
    }
}
