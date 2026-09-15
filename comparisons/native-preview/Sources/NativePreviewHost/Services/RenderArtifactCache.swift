import CryptoKit
import Darwin
import Foundation

struct RenderArtifactCache {
    let root: URL
    private let fileManager: FileManager

    init(root: URL, fileManager: FileManager = .default) throws {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
        try ensureOwnedDirectory(self.root)
        try ensureOwnedDirectory(self.root.appending(path: "staging", directoryHint: .isDirectory))
        try ensureOwnedDirectory(self.root.appending(path: "artifacts", directoryHint: .isDirectory))
    }

    func stageCopy(from source: URL) throws -> URL {
        try requireRegularNonSymlink(source)
        let staging = root.appending(path: "staging", directoryHint: .isDirectory)
        try validateContained(staging)
        let destination = staging.appending(path: UUID().uuidString + ".mp4")
        try validateContained(destination, allowMissingLeaf: true)
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }

    func publish(staged: URL, key: RenderedPreviewKey) throws -> VerifiedRenderArtifact {
        try validateStaged(staged)
        try requireRegularNonSymlink(staged)
        let attributes = try fileManager.attributesOfItem(atPath: staged.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == key.byteCount else {
            throw RenderedPreviewFailure.artifactUnavailable("Rendered artifact byte count does not match its descriptor.")
        }
        guard try sha256(of: staged) == key.outputSHA256 else {
            throw RenderedPreviewFailure.artifactUnavailable("Rendered artifact hash does not match its descriptor.")
        }
        let destination = root.appending(path: "artifacts", directoryHint: .isDirectory).appending(path: key.artifactFilename)
        try validateContained(destination, allowMissingLeaf: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw RenderedPreviewFailure.artifactUnavailable("A rendered artifact already exists at this cache identity.")
        }
        guard link(staged.path, destination.path) == 0 else {
            throw RenderedPreviewFailure.artifactUnavailable("Rendered artifact publication failed without replacing an existing cache entry.")
        }
        do {
            try fileManager.removeItem(at: staged)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        return VerifiedRenderArtifact(key: key, url: destination)
    }

    func removeStaged(_ staged: URL) throws {
        try validateStaged(staged)
        try requireRegularNonSymlink(staged)
        try fileManager.removeItem(at: staged)
    }

    private func ensureOwnedDirectory(_ directory: URL) throws {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try validateContained(directory)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RenderedPreviewFailure.artifactUnavailable("Rendered preview cache root is not an owned directory.")
        }
    }

    private func validateContained(_ url: URL, allowMissingLeaf: Bool = false) throws {
        let candidate = url.standardizedFileURL
        let rootPath = root.path
        guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/") else {
            throw RenderedPreviewFailure.artifactUnavailable("Rendered preview cache path escapes its owned root.")
        }
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw RenderedPreviewFailure.artifactUnavailable("Rendered preview cache root is not an owned directory.")
        }
        var cursor = root
        let relative = String(candidate.path.dropFirst(rootPath.count)).split(separator: "/").map(String.init)
        for (index, component) in relative.enumerated() {
            cursor.append(path: component)
            if !fileManager.fileExists(atPath: cursor.path) {
                guard allowMissingLeaf, index == relative.count - 1 else {
                    throw RenderedPreviewFailure.artifactUnavailable("Rendered preview cache path is unavailable.")
                }
                return
            }
            let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw RenderedPreviewFailure.artifactUnavailable("Rendered preview cache does not permit symbolic links.")
            }
        }
    }

    private func requireRegularNonSymlink(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw RenderedPreviewFailure.artifactUnavailable("Rendered artifact must be a regular non-symlink file.")
        }
    }

    private func validateStaged(_ staged: URL) throws {
        try validateContained(staged)
        let staging = root.appending(path: "staging", directoryHint: .isDirectory).standardizedFileURL
        guard staged.deletingLastPathComponent().standardizedFileURL == staging else {
            throw RenderedPreviewFailure.artifactUnavailable("Rendered preview publication accepts only owned staging files.")
        }
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
