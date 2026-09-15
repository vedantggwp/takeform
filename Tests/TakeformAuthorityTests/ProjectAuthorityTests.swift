import Foundation
import XCTest
@testable import TakeformAuthority
import TakeformCore

private struct TestBinding: Codable {
    let canonicalPath: String
    let epoch: Int
}

private struct TestMachineState: Codable {
    var grants: [UUID: [Grant]]
    let bindings: [UUID: TestBinding]
}

final class ProjectAuthorityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("takeform-authority-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func open() throws -> (ProjectAuthority, Grant) {
        let authority = try ProjectAuthority(packageURL: root.appendingPathComponent("Channel.takeform"), runtimeURL: root.appendingPathComponent("runtime"))
        let document = try authority.open().document
        let grant = Grant(label: "test", scopes: [.editProject], expiresAt: .distantFuture)
        try save([grant], for: document.projectID, packageURL: root.appendingPathComponent("Channel.takeform"))
        return (authority, grant)
    }

    private func save(_ grants: [Grant], for projectID: UUID, packageURL: URL) throws {
        let state = TestMachineState(grants: [projectID: grants], bindings: [projectID: TestBinding(canonicalPath: packageURL.path, epoch: 1)])
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("runtime/grants.json"), options: .atomic)
    }

    private func grants(for authority: ProjectAuthority, packageURL: URL) throws -> (ProjectDocument, [Grant]) {
        let document = try authority.open().document
        let url = root.appendingPathComponent("runtime/grants.json")
        let state = try JSONDecoder().decode(TestMachineState.self, from: Data(contentsOf: url))
        return (document, state.grants[document.projectID] ?? [])
    }

    func testRecipeVersionsPinExistingEpisodesAndReportOverrideSource() throws {
        let (authority, grant) = try open()
        let initial = try authority.open().document
        let created = try authority.execute(CommandEnvelope(expectedRevision: initial.revision, command: .createChannel(name: "North", initialRecipe: ["font": "Serif"])), grantID: grant.id)
        guard case .applied(let first) = created.outcome else { return XCTFail("create failed") }
        let episodeOne = try authority.execute(CommandEnvelope(expectedRevision: first.revision, command: .createEpisode(name: "One", recipeVersion: 1)), grantID: grant.id)
        guard case .applied(let pinned) = episodeOne.outcome else { return XCTFail("episode failed") }
        let published = try authority.execute(CommandEnvelope(expectedRevision: pinned.revision, command: .publishRecipe(values: ["font": "Sans"])), grantID: grant.id)
        guard case .applied(let secondRecipe) = published.outcome else { return XCTFail("publish failed") }
        let episodeTwo = try authority.execute(CommandEnvelope(expectedRevision: secondRecipe.revision, command: .createEpisode(name: "Two", recipeVersion: 2)), grantID: grant.id)
        guard case .applied(let document) = episodeTwo.outcome else { return XCTFail("episode failed") }

        XCTAssertEqual(document.episodes.map(\.recipeVersion), [1, 2])
        XCTAssertEqual(document.effectiveValues(for: document.episodes[0].id)?.first?.value, "Serif")
        XCTAssertEqual(document.effectiveValues(for: document.episodes[1].id)?.first?.value, "Sans")
        let overridden = try authority.execute(CommandEnvelope(expectedRevision: document.revision, command: .setOverride(episodeID: document.episodes[0].id, key: "font", value: "Mono")), grantID: grant.id)
        guard case .applied(let withOverride) = overridden.outcome else { return XCTFail("override failed") }
        XCTAssertEqual(withOverride.effectiveValues(for: withOverride.episodes[0].id)?.first?.source, .override)
    }

    func testUnauthorizedAndStaleCommandsPreserveCommittedDocument() throws {
        let (authority, grant) = try open()
        let initial = try authority.open().document
        let denied = try authority.execute(CommandEnvelope(expectedRevision: initial.revision, command: .createChannel(name: "Denied", initialRecipe: [:])), grantID: nil)
        XCTAssertEqual(denied.outcome, .rejected(reason: "unauthorized"))
        let created = try authority.execute(CommandEnvelope(expectedRevision: initial.revision, command: .createChannel(name: "Kept", initialRecipe: [:])), grantID: grant.id)
        guard case .applied(let document) = created.outcome else { return XCTFail("create failed") }
        let stale = try authority.execute(CommandEnvelope(expectedRevision: initial.revision, command: .renameChannel(name: "Lost")), grantID: grant.id)
        XCTAssertEqual(stale.outcome, .conflict(currentRevision: document.revision))
        XCTAssertEqual(try authority.open().document.channel?.name, "Kept")
    }

    func testAuthorizedDuplicateReturnsOriginalResultAndRejectsChangedRequest() throws {
        let (authority, grant) = try open()
        let initial = try authority.open().document
        let id = CommandID()
        let first = try authority.execute(CommandEnvelope(id: id, expectedRevision: initial.revision, command: .createChannel(name: "Stable", initialRecipe: [:])), grantID: grant.id)
        let replay = try authority.execute(CommandEnvelope(id: id, expectedRevision: initial.revision, command: .createChannel(name: "Stable", initialRecipe: [:])), grantID: grant.id)
        let changed = try authority.execute(CommandEnvelope(id: id, expectedRevision: initial.revision, command: .createChannel(name: "Other", initialRecipe: [:])), grantID: grant.id)
        XCTAssertEqual(replay, first)
        XCTAssertEqual(changed.outcome, .rejected(reason: "command-id-reused-with-different-request"))
    }

    func testEquivalentDictionaryRequestHasStableCommandFingerprint() throws {
        let (authority, grant) = try open()
        let initial = try authority.open().document
        let id = CommandID()
        let first = try authority.execute(CommandEnvelope(id: id, expectedRevision: initial.revision, command: .createChannel(name: "Stable", initialRecipe: ["a": "1", "b": "2"])), grantID: grant.id)
        let replay = try authority.execute(CommandEnvelope(id: id, expectedRevision: initial.revision, command: .createChannel(name: "Stable", initialRecipe: ["b": "2", "a": "1"])), grantID: grant.id)
        XCTAssertEqual(replay, first)
    }

    func testUndoAndRedoAreRevisionedChanges() throws {
        let (authority, grant) = try open()
        let initial = try authority.open().document
        let create = try authority.execute(CommandEnvelope(expectedRevision: initial.revision, command: .createChannel(name: "Before", initialRecipe: [:])), grantID: grant.id)
        guard case .applied(let document) = create.outcome else { return XCTFail("create failed") }
        let renamed = try authority.execute(CommandEnvelope(expectedRevision: document.revision, command: .renameChannel(name: "After")), grantID: grant.id)
        guard case .applied(let changed) = renamed.outcome else { return XCTFail("rename failed") }
        let undone = try authority.execute(CommandEnvelope(expectedRevision: changed.revision, command: .undo), grantID: grant.id)
        guard case .applied(let before) = undone.outcome else { return XCTFail("undo failed") }
        XCTAssertEqual(before.channel?.name, "Before")
        let redone = try authority.execute(CommandEnvelope(expectedRevision: before.revision, command: .redo), grantID: grant.id)
        guard case .applied(let after) = redone.outcome else { return XCTFail("redo failed") }
        XCTAssertEqual(after.channel?.name, "After")
    }

    func testRevokedAndExpiredGrantsCannotReplayCachedMutations() throws {
        let (authority, grant) = try open()
        let initial = try authority.open().document
        let envelope = CommandEnvelope(expectedRevision: initial.revision, command: .createChannel(name: "Protected", initialRecipe: [:]))
        _ = try authority.execute(envelope, grantID: grant.id)
        let (document, storedGrants) = try grants(for: authority, packageURL: root.appendingPathComponent("Channel.takeform"))
        try save(storedGrants.map { existing in
            var revoked = existing
            if revoked.id == grant.id { revoked.revokedAt = Date() }
            return revoked
        }, for: document.projectID, packageURL: root.appendingPathComponent("Channel.takeform"))
        XCTAssertEqual(try authority.execute(envelope, grantID: grant.id).outcome, .rejected(reason: "unauthorized"))

        let expired = Grant(label: "expired", scopes: [.editProject], expiresAt: Date(timeIntervalSinceNow: -1))
        try save(storedGrants + [expired], for: document.projectID, packageURL: root.appendingPathComponent("Channel.takeform"))
        XCTAssertEqual(try authority.execute(envelope, grantID: expired.id).outcome, .rejected(reason: "unauthorized"))
    }

    func testMovedPackageNeedsExplicitRebindAndInvalidatesOldGrant() throws {
        let (authority, grant) = try open()
        let initial = try authority.open().document
        let created = try authority.execute(CommandEnvelope(expectedRevision: initial.revision, command: .createChannel(name: "Portable", initialRecipe: [:])), grantID: grant.id)
        guard case .applied(let document) = created.outcome else { return XCTFail("create failed") }

        let original = root.appendingPathComponent("Channel.takeform")
        let moved = root.appendingPathComponent("Moved.takeform")
        try FileManager.default.copyItem(at: original, to: moved)
        let movedAuthority = try ProjectAuthority(packageURL: moved, runtimeURL: root.appendingPathComponent("runtime"))
        XCTAssertThrowsError(try movedAuthority.open()) { XCTAssertEqual($0 as? AuthorityFailure, .copyDecisionRequired) }
        XCTAssertEqual(try movedAuthority.open(rebindMovedPackage: true).document, document)
        let denied = try movedAuthority.execute(CommandEnvelope(expectedRevision: document.revision, command: .renameChannel(name: "Needs pairing")), grantID: grant.id)
        XCTAssertEqual(denied.outcome, .rejected(reason: "unauthorized"))
    }

    func testProjectionDriftAndNewerSchemaAreVisibleWithoutReset() throws {
        let (authority, _) = try open()
        let package = root.appendingPathComponent("Channel.takeform/.takeform")
        try Data("{}".utf8).write(to: package.appendingPathComponent("projection.json"))
        XCTAssertFalse(try authority.open().projectionMatches)

        let manifestURL = package.appendingPathComponent("manifest.json")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        var newer = manifest
        newer["schema"] = 2
        try JSONSerialization.data(withJSONObject: newer).write(to: manifestURL)
        XCTAssertThrowsError(try authority.open()) { XCTAssertEqual($0 as? AuthorityFailure, .newerSchema(2)) }
    }

    func testMissingOrCorruptAuthorityObjectsAreRefused() throws {
        let (authority, _) = try open()
        let state = root.appendingPathComponent("Channel.takeform/.takeform")
        try FileManager.default.removeItem(at: state.appendingPathComponent("projection.json"))
        XCTAssertFalse(try authority.open().projectionMatches)

        try FileManager.default.removeItem(at: state.appendingPathComponent("project.sqlite"))
        XCTAssertThrowsError(try ProjectAuthority(packageURL: root.appendingPathComponent("Channel.takeform"), runtimeURL: root.appendingPathComponent("runtime"))) {
            XCTAssertEqual($0 as? AuthorityFailure, .missingObject("project.sqlite"))
        }

        let missing = root.appendingPathComponent("Missing.takeform/.takeform")
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        let missingAuthority = try ProjectAuthority(packageURL: root.appendingPathComponent("Missing.takeform"), runtimeURL: root.appendingPathComponent("missing-runtime"))
        let missingManifestURL = missing.appendingPathComponent("manifest.json")
        var missingManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: missingManifestURL)) as! [String: Any]
        missingManifest["objects"] = ["objects/declared-but-missing.json"]
        try JSONSerialization.data(withJSONObject: missingManifest).write(to: missingManifestURL)
        XCTAssertThrowsError(try missingAuthority.open()) { XCTAssertEqual($0 as? AuthorityFailure, .missingObject("objects/declared-but-missing.json")) }

        let corrupt = root.appendingPathComponent("Corrupt.takeform/.takeform")
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("not sqlite".utf8).write(to: corrupt.appendingPathComponent("project.sqlite"))
        XCTAssertThrowsError(try ProjectAuthority(packageURL: root.appendingPathComponent("Corrupt.takeform"), runtimeURL: root.appendingPathComponent("runtime"))) {
            XCTAssertEqual($0 as? AuthorityFailure, .corruptDatabase)
        }
    }
}
