import XCTest
import TakeformCore
import TakeformWorkspace
@testable import TakeformApp

@MainActor
final class EpisodeCompositionEditorStateTests: XCTestCase {
    func testValidDraftSavesAndReopensCanonicalComposition() throws {
        let fixture = makeFixture()
        var draft = EpisodeCompositionEditorState.Draft(document: fixture.document, episode: fixture.episode)
        draft.add(asset: fixture.asset)

        let composition = try draft.composition(assets: fixture.document.assets)
        XCTAssertEqual(composition.episodeID, fixture.episode.id)
        XCTAssertEqual(composition.clipAudioPolicy, .muted)
        XCTAssertEqual(composition.occurrences.count, 1)
        XCTAssertEqual(composition.occurrences[0].outputRect, .fullCanvas)

        var saved = fixture.document
        saved.episodeCompositions = [composition]
        saved.revision = Revision(1)
        XCTAssertEqual(EpisodeCompositionEditorState.Draft(document: saved, episode: fixture.episode), draft)
    }

    func testInvalidOutputRangeFailsBeforeAnyWorkspaceSubmissionCanStart() throws {
        let fixture = makeFixture()
        var draft = EpisodeCompositionEditorState.Draft(document: fixture.document, episode: fixture.episode)
        draft.add(asset: fixture.asset)
        draft.clips[0].outputDuration = -1

        XCTAssertThrowsError(try draft.composition(assets: fixture.document.assets)) { error in
            XCTAssertEqual((error as? CompositionValidationFailure)?.reason, "composition-invalid-range")
        }
    }

    func testConflictKeepsLocalDraftForResolution() {
        let fixture = makeFixture()
        let state = EpisodeCompositionEditorState()
        let package = URL(fileURLWithPath: "/private/tmp/editor-conflict.takeform", isDirectory: true)
        state.synchronize(document: fixture.document, packageURL: package, episode: fixture.episode)
        state.add(asset: fixture.asset)
        let draftBeforeConflict = state.draft
        let request = state.context!

        state.receive(.conflict(Revision(1)), for: request, packageURL: package, episode: fixture.episode)

        XCTAssertEqual(state.draft, draftBeforeConflict)
        XCTAssertTrue(state.needsResolution)
        XCTAssertTrue(state.message?.contains("draft is still here") == true)
    }

    func testDelayedResponseForOldPackageCannotReplaceCurrentDraft() {
        let fixture = makeFixture()
        let secondEpisode = Episode(name: "Second", recipeVersion: 1)
        let secondDocument = ProjectDocument(
            projectID: fixture.document.projectID,
            channel: fixture.document.channel,
            recipes: fixture.document.recipes,
            episodes: [fixture.episode, secondEpisode],
            assets: fixture.document.assets,
            revision: Revision(2)
        )
        let state = EpisodeCompositionEditorState()
        let oldPackage = URL(fileURLWithPath: "/private/tmp/old-editor.takeform", isDirectory: true)
        let newPackage = URL(fileURLWithPath: "/private/tmp/new-editor.takeform", isDirectory: true)
        state.synchronize(document: fixture.document, packageURL: oldPackage, episode: fixture.episode)
        let oldRequest = state.context!
        state.synchronize(document: secondDocument, packageURL: newPackage, episode: secondEpisode)
        state.add(asset: fixture.asset)
        let currentDraft = state.draft

        state.receive(.applied(fixture.document), for: oldRequest, packageURL: oldPackage, episode: fixture.episode)

        XCTAssertEqual(state.context?.packageURL, newPackage)
        XCTAssertEqual(state.context?.episodeID, secondEpisode.id)
        XCTAssertEqual(state.draft, currentDraft)
    }

    private func makeFixture() -> (document: ProjectDocument, episode: Episode, asset: ManagedAsset) {
        let episode = Episode(name: "Opening", recipeVersion: 1)
        let asset = ManagedAsset(
            digest: String(repeating: "a", count: 64),
            byteLength: 32,
            filename: "opening.png",
            mediaType: "image",
            probe: ManagedAssetProbe(imageEncodedWidth: 8, imageEncodedHeight: 4, imageDisplayedWidth: 8, imageDisplayedHeight: 4, imageOrientation: 1)
        )
        let document = ProjectDocument(
            channel: Channel(name: "North"),
            recipes: [RecipeVersion(id: 1, values: ["tone": "warm"])],
            episodes: [episode],
            assets: [asset]
        )
        return (document, episode, asset)
    }
}

private actor RecordingCompositionWorkspaceClient: WorkspaceClient {
    private var document: ProjectDocument
    private let packageURL: URL
    private var executeCalls = 0

    init(document: ProjectDocument, packageURL: URL) {
        self.document = document
        self.packageURL = packageURL
    }

    func open(packageURL: URL, rebindMovedPackage: Bool) async throws -> WorkspaceSnapshot {
        guard packageURL == self.packageURL else { throw WorkspaceFailure.rejected("unexpected package") }
        return WorkspaceSnapshot(document: document, projectionMatches: true, packageURL: packageURL)
    }

    func execute(packageURL: URL, envelope: CommandEnvelope) async throws -> CommandResult {
        guard packageURL == self.packageURL else { throw WorkspaceFailure.rejected("unexpected package") }
        executeCalls += 1
        guard envelope.expectedRevision == document.revision else {
            return CommandResult(id: envelope.id, outcome: .conflict(currentRevision: document.revision))
        }
        guard case let .replaceEpisodeComposition(episodeID, composition) = envelope.command,
              episodeID == composition.episodeID else {
            return CommandResult(id: envelope.id, outcome: .rejected(reason: "expected composition replacement"))
        }
        document.episodeCompositions.removeAll { $0.episodeID == episodeID }
        document.episodeCompositions.append(composition)
        document.revision = Revision(document.revision.value + 1)
        return CommandResult(id: envelope.id, outcome: .applied(document: document))
    }

    func executeCallCount() -> Int { executeCalls }

    func importMedia(packageURL: URL, sources: [URL]) async throws -> [ManagedImportOutcome] { throw WorkspaceFailure.authorityUnavailable }
    func createChannelPackage(packageURL: URL, name: String, initialRecipe: [String: String]) async throws -> WorkspaceSnapshot { throw WorkspaceFailure.authorityUnavailable }
    func pairCLI(packageURL: URL, label: String, expiresAt: Date) async throws { throw WorkspaceFailure.authorityUnavailable }
    func listCLIGrants(packageURL: URL) async throws -> [CLIPairingSummary] { [] }
    func revokeCLI(packageURL: URL, grantID: UUID) async throws { throw WorkspaceFailure.authorityUnavailable }
}

extension EpisodeCompositionEditorStateTests {
    func testValidDraftUsesCurrentWorkspaceCommandPathAndReopens() async throws {
        let fixture = makeFixture()
        let package = URL(fileURLWithPath: "/private/tmp/editor-save.takeform", isDirectory: true)
        let client = RecordingCompositionWorkspaceClient(document: fixture.document, packageURL: package)
        let model = WorkspaceModel(client: client)
        model.open(package, rebind: false)
        try await waitForOpen(model)

        let state = EpisodeCompositionEditorState()
        state.synchronize(document: model.document!, packageURL: package, episode: fixture.episode)
        state.add(asset: fixture.asset)
        state.save(using: model, document: model.document!, packageURL: package, episode: fixture.episode)
        try await waitForSave(state)

        let executeCallCount = await client.executeCallCount()
        XCTAssertEqual(executeCallCount, 1)
        let saved = try XCTUnwrap(model.document)
        XCTAssertEqual(saved.revision, Revision(1))
        XCTAssertEqual(saved.episodeCompositions.count, 1)
        XCTAssertFalse(state.isDirty)
        XCTAssertEqual(EpisodeCompositionEditorState.Draft(document: saved, episode: fixture.episode), state.draft)
    }

    func testInvalidRangeNeverSubmitsAWorkspaceCommand() async throws {
        let fixture = makeFixture()
        let package = URL(fileURLWithPath: "/private/tmp/editor-invalid.takeform", isDirectory: true)
        let client = RecordingCompositionWorkspaceClient(document: fixture.document, packageURL: package)
        let model = WorkspaceModel(client: client)
        model.open(package, rebind: false)
        try await waitForOpen(model)

        let state = EpisodeCompositionEditorState()
        state.synchronize(document: model.document!, packageURL: package, episode: fixture.episode)
        state.add(asset: fixture.asset)
        var invalid = try XCTUnwrap(state.draft?.clips.first)
        invalid.outputDuration = -1
        state.updateClip(invalid)
        state.save(using: model, document: model.document!, packageURL: package, episode: fixture.episode)
        await Task.yield()

        let executeCallCount = await client.executeCallCount()
        XCTAssertEqual(executeCallCount, 0)
        XCTAssertFalse(state.isSaving)
        XCTAssertTrue(state.needsResolution)
        XCTAssertTrue(state.message?.contains("Check clip and caption times") == true)
    }

    private func waitForOpen(_ model: WorkspaceModel) async throws {
        for _ in 0..<100 where model.document == nil { await Task.yield() }
        XCTAssertNotNil(model.document, "recording client should open the synthetic project")
        if model.document == nil { throw WorkspaceFailure.authorityUnavailable }
    }

    private func waitForSave(_ state: EpisodeCompositionEditorState) async throws {
        for _ in 0..<100 where state.isSaving { await Task.yield() }
        XCTAssertFalse(state.isSaving, "recording command should complete")
        if state.isSaving { throw WorkspaceFailure.authorityUnavailable }
    }
}
