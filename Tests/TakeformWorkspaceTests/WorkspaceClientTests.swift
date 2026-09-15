import XCTest
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import TakeformWorkspace
@_spi(Testing) import TakeformAppServiceClient
@_spi(Testing) @testable import TakeformAppAuthorityWire
@testable import TakeformAuthorityAppServiceCore
import TakeformCore
@testable import TakeformApp

private actor DelayedOpenWorkspaceClient: WorkspaceClient {
    private var openContinuations: [CheckedContinuation<WorkspaceSnapshot, Error>] = []
    private var importContinuations: [CheckedContinuation<[ManagedImportOutcome], Error>] = []

    func open(packageURL: URL, rebindMovedPackage: Bool) async throws -> WorkspaceSnapshot {
        try await withCheckedThrowingContinuation { openContinuations.append($0) }
    }

    func waitForOpenCount(_ count: Int) async {
        while openContinuations.count < count { await Task.yield() }
    }

    func finishOpen(_ index: Int, with snapshot: WorkspaceSnapshot) {
        openContinuations[index].resume(returning: snapshot)
    }

    func importMedia(packageURL: URL, sources: [URL]) async throws -> [ManagedImportOutcome] {
        try await withCheckedThrowingContinuation { importContinuations.append($0) }
    }

    func waitForImportCount(_ count: Int) async {
        while importContinuations.count < count { await Task.yield() }
    }

    func finishImport(_ index: Int, with outcomes: [ManagedImportOutcome]) {
        importContinuations[index].resume(returning: outcomes)
    }
    func createChannelPackage(packageURL: URL, name: String, initialRecipe: [String: String]) async throws -> WorkspaceSnapshot { throw WorkspaceFailure.authorityUnavailable }
    func execute(packageURL: URL, envelope: CommandEnvelope) async throws -> CommandResult { throw WorkspaceFailure.authorityUnavailable }
    func pairCLI(packageURL: URL, label: String, expiresAt: Date) async throws { throw WorkspaceFailure.authorityUnavailable }
    func listCLIGrants(packageURL: URL) async throws -> [CLIPairingSummary] { [] }
    func revokeCLI(packageURL: URL, grantID: UUID) async throws { throw WorkspaceFailure.authorityUnavailable }
}

final class WorkspaceClientTests: XCTestCase {
    func testVerifiedPreviewAssetRequiresCurrentAuthoritySelection() {
        let asset = ManagedAsset(digest: String(repeating: "a", count: 64), byteLength: 1, filename: "still.png", mediaType: "image")
        let document = ProjectDocument(assets: [asset])

        XCTAssertNil(WorkspacePresentation.assetForVerifiedPreview(document: document, selectedAssetID: nil))
        XCTAssertNil(WorkspacePresentation.assetForVerifiedPreview(document: document, selectedAssetID: UUID()))
        XCTAssertEqual(WorkspacePresentation.assetForVerifiedPreview(document: document, selectedAssetID: asset.id), asset)
    }

    func testLateAssetSelectionCannotReplaceNewerVerifiedSelection() async throws {
        let package = URL(fileURLWithPath: "/private/tmp/selection-race.takeform", isDirectory: true)
        let first = ManagedAsset(digest: String(repeating: "a", count: 64), byteLength: 1, filename: "first.png", mediaType: "image")
        let second = ManagedAsset(digest: String(repeating: "b", count: 64), byteLength: 2, filename: "second.png", mediaType: "image")
        let snapshot = WorkspaceSnapshot(document: ProjectDocument(assets: [first, second], revision: Revision(7)), projectionMatches: true, packageURL: package)
        let client = DelayedOpenWorkspaceClient()
        let model = await MainActor.run { WorkspaceModel(client: client) }

        await MainActor.run { model.open(package, rebind: false) }
        await client.waitForOpenCount(1)
        await client.finishOpen(0, with: snapshot)
        for _ in 0..<100 where await MainActor.run(body: { model.document == nil }) { await Task.yield() }
        let openedDocument = await MainActor.run { model.document }
        XCTAssertNotNil(openedDocument)

        await MainActor.run { model.selectAsset(first) }
        await client.waitForOpenCount(2)
        await MainActor.run { model.selectAsset(second) }
        await client.waitForOpenCount(3)

        // Complete B first, then deliver the canceled A request afterwards.
        await client.finishOpen(2, with: snapshot)
        for _ in 0..<100 where await MainActor.run(body: { model.selectedAssetID != second.id }) { await Task.yield() }
        await client.finishOpen(1, with: snapshot)
        for _ in 0..<100 { await Task.yield() }

        let selectedID = await MainActor.run { model.selectedAssetID }
        XCTAssertEqual(selectedID, second.id)
        let verified = await MainActor.run { model.verifiedAssetSelection }
        XCTAssertEqual(verified?.asset, second)
        XCTAssertEqual(verified?.packageURL, package)
        XCTAssertEqual(verified?.revision, Revision(7))
    }

    func testImportSnapshotInvalidatesSelectionVerifiedWhileImportWasPending() async throws {
        let package = URL(fileURLWithPath: "/private/tmp/import-selection-race.takeform", isDirectory: true)
        let asset = ManagedAsset(digest: String(repeating: "c", count: 64), byteLength: 3, filename: "source.png", mediaType: "image")
        let initial = WorkspaceSnapshot(document: ProjectDocument(assets: [asset], revision: Revision(7)), projectionMatches: true, packageURL: package)
        let refreshed = WorkspaceSnapshot(document: ProjectDocument(assets: [asset], revision: Revision(8)), projectionMatches: true, packageURL: package)
        let client = DelayedOpenWorkspaceClient()
        let model = await MainActor.run { WorkspaceModel(client: client) }

        await MainActor.run { model.open(package, rebind: false) }
        await client.waitForOpenCount(1)
        await client.finishOpen(0, with: initial)
        for _ in 0..<100 where await MainActor.run(body: { model.document == nil }) { await Task.yield() }

        await MainActor.run { model.importDroppedMedia([URL(fileURLWithPath: "/private/tmp/source.png")]) }
        await client.waitForImportCount(1)
        await MainActor.run { model.selectAsset(asset) }
        await client.waitForOpenCount(2)
        await client.finishOpen(1, with: initial)
        for _ in 0..<100 where await MainActor.run(body: { model.verifiedAssetSelection == nil }) { await Task.yield() }
        let selectionBeforeImportRefresh = await MainActor.run { model.verifiedAssetSelection }
        XCTAssertEqual(selectionBeforeImportRefresh?.revision, Revision(7))

        await client.finishImport(0, with: [])
        await client.waitForOpenCount(3)
        await client.finishOpen(2, with: refreshed)
        for _ in 0..<100 where await MainActor.run(body: { model.document?.revision != Revision(8) }) { await Task.yield() }

        let selection = await MainActor.run { model.verifiedAssetSelection }
        let refreshedRevision = await MainActor.run { model.document?.revision }
        XCTAssertNil(selection)
        XCTAssertEqual(refreshedRevision, Revision(8))
    }
    private func validPNG() -> Data {
        let data = NSMutableData()
        let context = CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    private func runBounded(_ executable: URL, arguments: [String], input: String? = nil, environment: [String: String] = [:]) throws -> (status: Int32, output: Data, error: Data) {
        let process = Process(); let output = Pipe(); let error = Pipe(); let standardInput = Pipe()
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = executable; process.arguments = arguments; process.standardOutput = output; process.standardError = error; process.standardInput = standardInput
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, replacement in replacement }
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if let input { standardInput.fileHandleForWriting.write(Data("\(input)\n".utf8)) }
        standardInput.fileHandleForWriting.closeFile()
        guard exited.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            _ = exited.wait(timeout: .now() + 1)
            XCTFail("bounded child did not exit: \(executable.lastPathComponent)")
            throw WorkspaceFailure.authorityUnavailable
        }
        return (process.terminationStatus, output.fileHandleForReading.readDataToEndOfFile(), error.fileHandleForReading.readDataToEndOfFile())
    }

    private func stopBounded(_ process: Process, exited: DispatchSemaphore) -> Bool {
        guard process.isRunning else { return true }
        process.terminate()
        if exited.wait(timeout: .now() + 2) == .success { return true }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        return exited.wait(timeout: .now() + 1) == .success
    }

    func testUnavailableClientNeverSimulatesAnEdit() async {
        let client = UnavailableWorkspaceClient()
        let envelope = CommandEnvelope(expectedRevision: Revision(0), command: .createChannel(name: "North", initialRecipe: [:]))
        do {
            _ = try await client.execute(packageURL: URL(fileURLWithPath: "/tmp/Channel.takeform"), envelope: envelope)
            XCTFail("unavailable authority must not produce a simulated result")
        } catch let failure as WorkspaceFailure {
            XCTAssertEqual(failure, .authorityUnavailable)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testResolvedValuesShowsOverrideProvenance() {
        let episode = Episode(name: "Episode", recipeVersion: 1)
        let document = ProjectDocument(
            channel: Channel(name: "North"),
            recipes: [RecipeVersion(id: 1, values: ["font": "Serif", "tone": "Warm"])],
            episodes: [episode],
            overrides: [Override(episodeID: episode.id, key: "font", value: "Mono")]
        )
        let values = WorkspacePresentation.resolvedValues(document: document, episodeID: episode.id)
        XCTAssertEqual(values.map(\.key), ["font", "tone"])
        XCTAssertEqual(values.map(\.source), [.override, .recipe])
    }

    func testOwnedServiceStartsOnceAndIsReapedOnShutdown() async throws {
        let socket = URL(fileURLWithPath: "/private/tmp/takeform-owned-service-\(UUID().uuidString).sock")
        AppAuthoritySocket.setTestingPath(socket.path)
        defer { AppAuthoritySocket.setTestingPath(nil); try? FileManager.default.removeItem(at: socket) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let service = root.appendingPathComponent(".build/debug/TakeformAuthorityAppService")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: service.path))
        let client = AppAuthorityServiceClient(serviceExecutable: service)
        async let first: Void = client.startAndVerifyForTesting()
        async let second: Void = client.startAndVerifyForTesting()
        try await first; try await second
        let pid = await client.ownedProcessID()
        XCTAssertNotNil(pid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
        await client.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        let reapedPID = await client.lastReapedPID()
        XCTAssertEqual(reapedPID, pid)
        if let pid { XCTAssertEqual(Darwin.kill(pid, 0), -1) }
    }

    func testWrongPeerSocketIsNotReplacedOrAdopted() async throws {
        let socket = URL(fileURLWithPath: "/private/tmp/takeform-wrong-peer-\(UUID().uuidString).sock")
        AppAuthoritySocket.setTestingPath(socket.path)
        defer { AppAuthoritySocket.setTestingPath(nil); try? FileManager.default.removeItem(at: socket) }
        let listener = try AppAuthoritySocket.makeListener()
        defer { listener.close() }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let client = AppAuthorityServiceClient(serviceExecutable: root.appendingPathComponent(".build/debug/TakeformAuthorityAppService"))
        do { try await client.startAndVerifyForTesting(); XCTFail("wrong peer must not be adopted") }
        catch let failure as WorkspaceFailure { XCTAssertEqual(failure, .authorityUnavailable) }
        let ownedPID = await client.ownedProcessID()
        XCTAssertNil(ownedPID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
    }

    func testReadinessTimeoutReapsOwnedChild() async throws {
        let socket = URL(fileURLWithPath: "/private/tmp/takeform-readiness-timeout-\(UUID().uuidString).sock")
        AppAuthoritySocket.setTestingPath(socket.path)
        defer { AppAuthoritySocket.setTestingPath(nil); try? FileManager.default.removeItem(at: socket) }
        let client = AppAuthorityServiceClient(serviceExecutable: URL(fileURLWithPath: "/usr/bin/yes"))
        try await client.launchForTesting()
        let livePID = await client.ownedProcessID()
        XCTAssertNotNil(livePID)
        if let livePID { XCTAssertEqual(Darwin.kill(livePID, 0), 0) }
        do { try await client.startAndVerifyForTesting(); XCTFail("service without a socket must time out") }
        catch let failure as WorkspaceFailure { XCTAssertEqual(failure, .authorityUnavailable) }
        let ownedPID = await client.ownedProcessID()
        XCTAssertNil(ownedPID)
        let reapedPID = await client.lastReapedPID()
        XCTAssertEqual(reapedPID, livePID)
        if let livePID { XCTAssertEqual(Darwin.kill(livePID, 0), -1) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
    }

    func testCopiedCLIAfterServiceShutdownReportsActionableUnavailableWithoutMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("takeform-cli-after-stop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let socket = URL(fileURLWithPath: "/private/tmp/tf-cli-after-stop-\(UUID().uuidString).sock")
        AppAuthoritySocket.setTestingPath(socket.path)
        defer { AppAuthoritySocket.setTestingPath(nil); try? FileManager.default.removeItem(at: socket) }
        let owner = AppAuthorityServiceClient(serviceExecutable: sourceRoot.appendingPathComponent(".build/debug/TakeformAuthorityAppService"))
        try await owner.startAndVerifyForTesting()
        let ownedPID = await owner.ownedProcessID()
        XCTAssertNotNil(ownedPID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
        await owner.shutdown()
        let reapedPID = await owner.lastReapedPID()
        XCTAssertEqual(reapedPID, ownedPID)
        if let ownedPID { XCTAssertEqual(Darwin.kill(ownedPID, 0), -1) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        try FileManager.default.copyItem(at: sourceRoot.appendingPathComponent(".build/debug/takeform"), to: root.appendingPathComponent("takeform"))
        try FileManager.default.copyItem(at: sourceRoot.appendingPathComponent(".build/debug/TakeformAuthorityAppService"), to: root.appendingPathComponent("TakeformAuthorityAppService"))
        let package = root.appendingPathComponent("Committed.takeform")
        let authority = try ProjectAuthority(packageURL: package)
        let opened = try authority.openForAuthenticatedCreator(credential: "creator", rebindMovedPackage: false)
        let created = try authority.executeForAuthenticatedCreator(CommandEnvelope(expectedRevision: opened.document.revision, command: .createChannel(name: "Kept", initialRecipe: [:])), credential: "creator")
        guard case let .applied(document) = created.outcome else { return XCTFail("fixture project was not committed") }
        let database = package.appendingPathComponent(".takeform/project.sqlite")
        let manifest = package.appendingPathComponent(".takeform/manifest.json")
        let binding = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Takeform/Authority/\(document.projectID.uuidString)/binding.json")
        let before = [try Data(contentsOf: database), try Data(contentsOf: manifest), try Data(contentsOf: binding)]
        let command = CommandEnvelope(expectedRevision: document.revision, command: .renameChannel(name: "Denied"))
        let process = Process(); let stderr = Pipe(); process.executableURL = root.appendingPathComponent("takeform")
        process.arguments = ["execute", package.path, UUID().uuidString, String(decoding: try JSONEncoder().encode(command), as: UTF8.self)]
        process.environment = ["TAKEFORM_AUTHORITY_SOCKET": socket.path]
        process.standardError = stderr; try process.run()
        for _ in 0..<100 where process.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        if process.isRunning {
            process.terminate()
            for _ in 0..<100 where process.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
            XCTFail("copied CLI did not complete within the bounded unavailable check")
        }
        let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(message.contains("open Takeform"))
        XCTAssertEqual(try Data(contentsOf: database), before[0])
        XCTAssertEqual(try Data(contentsOf: manifest), before[1])
        XCTAssertEqual(try Data(contentsOf: binding), before[2])
    }

    func testCopiedPairedCLIExecutesThroughVerifiedPersistentService() async throws {
        // Keep this on the same /private/tmp spelling used by the independent
        // copied-release runner. A package binding must survive the actual UDS
        // process boundary without treating an equivalent selected path as a
        // moved copy.
        let root = URL(fileURLWithPath: "/private/tmp/takeform-paired-positive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let artifacts = root.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        for name in ["TakeformApp", "takeform", "TakeformAuthorityAppService"] {
            try FileManager.default.copyItem(at: sourceRoot.appendingPathComponent(".build/debug/\(name)"), to: artifacts.appendingPathComponent(name))
        }
        let socket = URL(fileURLWithPath: "/private/tmp/tf-positive-\(UUID().uuidString).sock")
        AppAuthoritySocket.setTestingPath(socket.path)
        defer { AppAuthoritySocket.setTestingPath(nil); try? FileManager.default.removeItem(at: socket) }
        let package = root.appendingPathComponent("Paired.takeform")
        XCTAssertEqual(package.path, package.resolvingSymlinksInPath().standardizedFileURL.path)
        let authority = try ProjectAuthority(packageURL: package)
        let credential = "creator-\(UUID().uuidString)"
        let initial = try authority.openForAuthenticatedCreator(credential: credential, rebindMovedPackage: false).document
        let rawToken = "paired-\(UUID().uuidString)"
        let grant = try authority.issuePairedCLIGrant(credential: credential, label: "process test", scopes: [.editProject], expiresAt: .distantFuture, rawToken: rawToken)
        let readOnlyToken = "paired-read-\(UUID().uuidString)"
        let readOnlyGrant = try authority.issuePairedCLIGrant(credential: credential, label: "read only", scopes: [.readProject], expiresAt: .distantFuture, rawToken: readOnlyToken)
        let probe = CommandEnvelope(expectedRevision: initial.revision, command: .createChannel(name: "Wire probe", initialRecipe: [:]))
        let encodedRequest = try JSONEncoder().encode(AppAuthorityRequest.pairedExecute(package, probe, grant.id, rawToken))
        guard case let .pairedExecute(decodedPackage, _, decodedGrant, decodedToken) = try JSONDecoder().decode(AppAuthorityRequest.self, from: encodedRequest) else {
            return XCTFail("paired request did not round-trip")
        }
        XCTAssertEqual(decodedPackage.path, package.path)
        XCTAssertEqual(decodedPackage.resolvingSymlinksInPath().standardizedFileURL.path, package.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(decodedGrant, grant.id)
        XCTAssertEqual(decodedToken, rawToken)
        XCTAssertEqual(try ProjectAuthority(packageURL: decodedPackage).open().document, initial)
        defer {
            _ = try? runBounded(artifacts.appendingPathComponent("takeform"), arguments: ["forget-paired-credential", grant.id.uuidString], environment: ["TAKEFORM_AUTHORITY_SOCKET": socket.path])
            _ = try? runBounded(artifacts.appendingPathComponent("takeform"), arguments: ["forget-paired-credential", readOnlyGrant.id.uuidString], environment: ["TAKEFORM_AUTHORITY_SOCKET": socket.path])
            try? FileManager.default.removeItem(at: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Takeform/Authority/\(initial.projectID.uuidString)"))
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: socket)
        }
        let imported = try runBounded(artifacts.appendingPathComponent("takeform"), arguments: ["import-paired-credential", grant.id.uuidString], input: rawToken, environment: ["TAKEFORM_AUTHORITY_SOCKET": socket.path])
        XCTAssertEqual(imported.status, 0, String(decoding: imported.error, as: UTF8.self))
        let importedReadOnly = try runBounded(artifacts.appendingPathComponent("takeform"), arguments: ["import-paired-credential", readOnlyGrant.id.uuidString], input: readOnlyToken, environment: ["TAKEFORM_AUTHORITY_SOCKET": socket.path])
        XCTAssertEqual(importedReadOnly.status, 0, String(decoding: importedReadOnly.error, as: UTF8.self))

        let service = Process(); let serviceExited = DispatchSemaphore(value: 0); service.executableURL = artifacts.appendingPathComponent("TakeformAuthorityAppService"); service.standardOutput = FileHandle.nullDevice; service.standardError = FileHandle.nullDevice; service.environment = ProcessInfo.processInfo.environment.merging(["TAKEFORM_AUTHORITY_SOCKET": socket.path]) { _, replacement in replacement }; service.terminationHandler = { _ in serviceExited.signal() }
        try service.run()
        defer { XCTAssertTrue(stopBounded(service, exited: serviceExited), "copied service did not terminate after TERM/KILL") }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socket.path) { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
        try AppAuthoritySocket.verifyService(expectedService: artifacts.appendingPathComponent("TakeformAuthorityAppService"))

        let command = CommandEnvelope(expectedRevision: initial.revision, command: .createChannel(name: "Paired", initialRecipe: ["fixture": "persistent-service"]))
        let invoked = try runBounded(artifacts.appendingPathComponent("takeform"), arguments: ["execute", package.path, grant.id.uuidString, String(decoding: try JSONEncoder().encode(command), as: UTF8.self)], environment: ["TAKEFORM_AUTHORITY_SOCKET": socket.path])
        XCTAssertEqual(invoked.status, 0, String(decoding: invoked.error, as: UTF8.self))
        let result = try JSONDecoder().decode(CommandResult.self, from: invoked.output)
        guard case let .applied(document) = result.outcome else { return XCTFail("paired CLI did not receive applied result") }
        XCTAssertEqual(document.channel?.name, "Paired")
        XCTAssertEqual(document.revision, Revision(1))

        let source = root.appendingPathComponent("paired-import.png")
        let bytes = validPNG()
        try bytes.write(to: source)
        let pairedImport = try runBounded(artifacts.appendingPathComponent("takeform"), arguments: ["import", package.path, grant.id.uuidString, source.path], environment: ["TAKEFORM_AUTHORITY_SOCKET": socket.path])
        XCTAssertEqual(pairedImport.status, 0, String(decoding: pairedImport.error, as: UTF8.self))
        let importOutcomes = try JSONDecoder().decode([ManagedImportOutcome].self, from: pairedImport.output)
        guard case let .imported(asset) = importOutcomes.first else { return XCTFail("paired CLI did not import its source") }
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent(".takeform/objects/\(asset.digest)")), bytes)

        let afterImport = try authority.open().document
        guard case let .applied(withEpisode) = try authority.executeForAuthenticatedCreator(CommandEnvelope(expectedRevision: afterImport.revision, command: .createEpisode(name: "Render", recipeVersion: 1)), credential: credential).outcome,
              let renderEpisode = withEpisode.episodes.first else { return XCTFail("render episode setup failed") }
        let one = CompositionTime(value: 1, timescale: 1)!
        let composition = EpisodeComposition(
            episodeID: renderEpisode.id,
            output: CompositionOutput(width: 2, height: 2, frameRate: one, duration: one),
            occurrences: [CompositionOccurrence(assetID: asset.id, assetDigest: asset.digest, source: .still, outputRange: CompositionRange(start: .init(value: 0, timescale: 1)!, duration: one), layer: 0, order: 0, crop: CompositionCrop(x: .init(value: 0, timescale: 1)!, y: .init(value: 0, timescale: 1)!, width: one, height: one))],
            captions: []
        )
        guard case let .applied(composed) = try authority.executeForAuthenticatedCreator(CommandEnvelope(expectedRevision: withEpisode.revision, command: .replaceEpisodeComposition(episodeID: renderEpisode.id, composition: composition)), credential: credential).outcome else { return XCTFail("render composition setup failed") }
        let compositionDigest = SHA256.hash(data: try composition.canonicalData()).map { String(format: "%02x", $0) }.joined()
        let renderEnvelope = CommandEnvelope(expectedRevision: composed.revision, command: .requestEpisodeRender(episodeID: renderEpisode.id, compositionDigest: compositionDigest, format: .mp4))
        let pairedRender = try runBounded(artifacts.appendingPathComponent("takeform"), arguments: ["render-request", package.path, grant.id.uuidString, String(decoding: try JSONEncoder().encode(renderEnvelope), as: UTF8.self)], environment: ["TAKEFORM_AUTHORITY_SOCKET": socket.path])
        XCTAssertEqual(pairedRender.status, 0, String(decoding: pairedRender.error, as: UTF8.self))
        let renderResult = try JSONDecoder().decode(CommandResult.self, from: pairedRender.output)
        guard case let .renderRequested(renderStatus) = renderResult.outcome else { return XCTFail("paired CLI did not receive a render request") }
        XCTAssertEqual(renderStatus.availability, .unavailable, "CLI must not pretend an adapter published an artifact")
        let pairedStatus = try runBounded(artifacts.appendingPathComponent("takeform"), arguments: ["render-status", package.path, grant.id.uuidString, renderStatus.jobID.uuidString], environment: ["TAKEFORM_AUTHORITY_SOCKET": socket.path])
        XCTAssertEqual(pairedStatus.status, 0, String(decoding: pairedStatus.error, as: UTF8.self))
        let recoveredStatus = try JSONDecoder().decode(EpisodeRenderRequestStatus.self, from: pairedStatus.output)
        XCTAssertEqual(recoveredStatus.jobID, renderStatus.jobID)
        XCTAssertEqual(recoveredStatus.logicalState, .interrupted, "a service with no retained worker must not leave a portable request appearing runnable after restart")
        XCTAssertEqual(recoveredStatus.availability, .unavailable)
        let destination = root.appendingPathComponent("existing-export.mp4")
        try Data("do not clobber".utf8).write(to: destination)
        let pairedExport = try runBounded(artifacts.appendingPathComponent("takeform"), arguments: ["render-export", package.path, grant.id.uuidString, renderStatus.jobID.uuidString, UUID().uuidString, destination.path], environment: ["TAKEFORM_AUTHORITY_SOCKET": socket.path])
        XCTAssertEqual(pairedExport.status, 0, String(decoding: pairedExport.error, as: UTF8.self))
        guard case .unavailable = try JSONDecoder().decode(EpisodeRenderExportResult.self, from: pairedExport.output) else { return XCTFail("unavailable renderer claimed paired export") }
        XCTAssertEqual(try Data(contentsOf: destination), Data("do not clobber".utf8))

        let scopedImport = try runBounded(artifacts.appendingPathComponent("takeform"), arguments: ["import", package.path, readOnlyGrant.id.uuidString, source.path], environment: ["TAKEFORM_AUTHORITY_SOCKET": socket.path])
        XCTAssertEqual(scopedImport.status, 0, String(decoding: scopedImport.error, as: UTF8.self))
        let scopedOutcomes = try JSONDecoder().decode([ManagedImportOutcome].self, from: scopedImport.output)
        guard case .failed = scopedOutcomes.first else { return XCTFail("read-only paired grant imported media") }
        try authority.revokePairedCLIGrant(credential: credential, grantID: grant.id)
        let revokedImport = try runBounded(artifacts.appendingPathComponent("takeform"), arguments: ["import", package.path, grant.id.uuidString, source.path], environment: ["TAKEFORM_AUTHORITY_SOCKET": socket.path])
        XCTAssertEqual(revokedImport.status, 0, String(decoding: revokedImport.error, as: UTF8.self))
        let revokedOutcomes = try JSONDecoder().decode([ManagedImportOutcome].self, from: revokedImport.output)
        guard case .failed = revokedOutcomes.first else { return XCTFail("revoked paired grant imported media") }
        XCTAssertEqual(try authority.open().document.assets, [asset])
    }
}
