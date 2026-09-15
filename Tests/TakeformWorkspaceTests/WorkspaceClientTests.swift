import XCTest
@testable import TakeformWorkspace
@_spi(Testing) import TakeformAppServiceClient
@_spi(Testing) @testable import TakeformAppAuthorityWire
import TakeformCore

final class WorkspaceClientTests: XCTestCase {
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        try FileManager.default.copyItem(at: sourceRoot.appendingPathComponent(".build/debug/takeform"), to: root.appendingPathComponent("takeform"))
        try FileManager.default.copyItem(at: sourceRoot.appendingPathComponent(".build/debug/TakeformAuthorityAppService"), to: root.appendingPathComponent("TakeformAuthorityAppService"))
        let package = root.appendingPathComponent("Unchanged.takeform")
        let command = CommandEnvelope(expectedRevision: Revision(0), command: .createChannel(name: "Denied", initialRecipe: [:]))
        let process = Process(); let stderr = Pipe(); process.executableURL = root.appendingPathComponent("takeform")
        process.arguments = ["execute", package.path, UUID().uuidString, String(decoding: try JSONEncoder().encode(command), as: UTF8.self)]
        process.environment = ["TAKEFORM_AUTHORITY_SOCKET": socket.path]
        process.standardError = stderr; try process.run(); process.waitUntilExit()
        let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(message.contains("open Takeform"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
    }
}
