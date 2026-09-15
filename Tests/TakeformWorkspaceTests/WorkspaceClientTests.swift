import XCTest
@testable import TakeformWorkspace
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
}
