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
        if let pid { XCTAssertEqual(Darwin.kill(pid, 0), -1) }
    }
}
