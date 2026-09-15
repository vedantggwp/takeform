import Foundation
import CryptoKit
import Security
import XCTest
@testable import TakeformAuthority
import TakeformCore

final class ProjectAuthorityTests: XCTestCase {
    private var root: URL!
    private var tokenAccounts: Set<String> = []
    private var tokens: [UUID: String] = [:]
    private var projectIDs: Set<UUID> = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("takeform-authority-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for account in tokenAccounts { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: "com.takeform.authority.cli", kSecAttrAccount: account] as CFDictionary) }
        for projectID in projectIDs { try? FileManager.default.removeItem(at: try machineURL(for: projectID)) }
        try FileManager.default.removeItem(at: root)
    }

    private func open() throws -> (ProjectAuthority, Grant) {
        let authority = try ProjectAuthority(packageURL: root.appendingPathComponent("Channel.takeform"))
        let document = try authority.open().document
        projectIDs.insert(document.projectID)
        let token = UUID().uuidString
        let grant = Grant(label: "test", scopes: [.editProject], expiresAt: .distantFuture, authorityEpoch: 1, tokenDigest: digest(token))
        tokens[grant.id] = token
        tokenAccounts.insert(grant.id.uuidString)
        let tokenQuery: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "com.takeform.authority.cli", kSecAttrAccount: grant.id.uuidString]
        SecItemDelete(tokenQuery as CFDictionary)
        var storedToken = tokenQuery
        storedToken[kSecValueData] = Data(token.utf8)
        guard SecItemAdd(storedToken as CFDictionary, nil) == errSecSuccess else { throw AuthorityFailure.unauthorized }
        try save([grant], for: document.projectID)
        return (authority, grant)
    }

    private func save(_ grants: [Grant], for projectID: UUID) throws {
        let url = try machineURL(for: projectID).appendingPathComponent("binding.json")
        var state = try JSONDecoder().decode(TestMachineState.self, from: Data(contentsOf: url))
        state.grants = grants
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    private func grants(for authority: ProjectAuthority) throws -> (ProjectDocument, [Grant]) {
        let document = try authority.open().document
        let data = try Data(contentsOf: try machineURL(for: document.projectID).appendingPathComponent("binding.json"))
        return (document, try JSONDecoder().decode(TestMachineState.self, from: data).grants)
    }

    private struct TestBinding: Codable { let canonicalPath: String; let epoch: Int }
    private struct TestMachineState: Codable { var binding: TestBinding?; var grants: [Grant] }
    private func machineURL(for projectID: UUID) throws -> URL {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw AuthorityFailure.unauthorized }
        return root.appendingPathComponent("Takeform/Authority/\(projectID.uuidString)")
    }
    private func digest(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func execute(_ authority: ProjectAuthority, _ envelope: CommandEnvelope, grant: Grant) throws -> CommandResult { try authority.execute(envelope, grantID: grant.id, token: tokens[grant.id]) }

    func testRecipeVersionsPinExistingEpisodesAndReportOverrideSource() throws {
        let (authority, grant) = try open()
        let initial = try authority.open().document
        let created = try execute(authority, CommandEnvelope(expectedRevision: initial.revision, command: .createChannel(name: "North", initialRecipe: ["font": "Serif"])), grant: grant)
        guard case .applied(let first) = created.outcome else { return XCTFail("create failed") }
        let episodeOne = try execute(authority, CommandEnvelope(expectedRevision: first.revision, command: .createEpisode(name: "One", recipeVersion: 1)), grant: grant)
        guard case .applied(let pinned) = episodeOne.outcome else { return XCTFail("episode failed") }
        let published = try execute(authority, CommandEnvelope(expectedRevision: pinned.revision, command: .publishRecipe(values: ["font": "Sans"])), grant: grant)
        guard case .applied(let secondRecipe) = published.outcome else { return XCTFail("publish failed") }
        let episodeTwo = try execute(authority, CommandEnvelope(expectedRevision: secondRecipe.revision, command: .createEpisode(name: "Two", recipeVersion: 2)), grant: grant)
        guard case .applied(let document) = episodeTwo.outcome else { return XCTFail("episode failed") }

        XCTAssertEqual(document.episodes.map(\.recipeVersion), [1, 2])
        XCTAssertEqual(document.effectiveValues(for: document.episodes[0].id)?.first?.value, "Serif")
        XCTAssertEqual(document.effectiveValues(for: document.episodes[1].id)?.first?.value, "Sans")
        let overridden = try execute(authority, CommandEnvelope(expectedRevision: document.revision, command: .setOverride(episodeID: document.episodes[0].id, key: "font", value: "Mono")), grant: grant)
        guard case .applied(let withOverride) = overridden.outcome else { return XCTFail("override failed") }
        XCTAssertEqual(withOverride.effectiveValues(for: withOverride.episodes[0].id)?.first?.source, .override)
    }

    func testUnauthorizedAndStaleCommandsPreserveCommittedDocument() throws {
        let (authority, grant) = try open()
        let initial = try authority.open().document
        let denied = try authority.execute(CommandEnvelope(expectedRevision: initial.revision, command: .createChannel(name: "Denied", initialRecipe: [:])), grantID: nil, token: nil)
        XCTAssertEqual(denied.outcome, .rejected(reason: "unauthorized"))
        let created = try execute(authority, CommandEnvelope(expectedRevision: initial.revision, command: .createChannel(name: "Kept", initialRecipe: [:])), grant: grant)
        guard case .applied(let document) = created.outcome else { return XCTFail("create failed") }
        let stale = try execute(authority, CommandEnvelope(expectedRevision: initial.revision, command: .renameChannel(name: "Lost")), grant: grant)
        XCTAssertEqual(stale.outcome, .conflict(currentRevision: document.revision))
        XCTAssertEqual(try authority.open().document.channel?.name, "Kept")
    }

    func testAuthorizedDuplicateReturnsOriginalResultAndRejectsChangedRequest() throws {
        let (authority, grant) = try open()
        let initial = try authority.open().document
        let id = CommandID()
        let first = try execute(authority, CommandEnvelope(id: id, expectedRevision: initial.revision, command: .createChannel(name: "Stable", initialRecipe: [:])), grant: grant)
        let replay = try execute(authority, CommandEnvelope(id: id, expectedRevision: initial.revision, command: .createChannel(name: "Stable", initialRecipe: [:])), grant: grant)
        let changed = try execute(authority, CommandEnvelope(id: id, expectedRevision: initial.revision, command: .createChannel(name: "Other", initialRecipe: [:])), grant: grant)
        let changedRevision = try execute(authority, CommandEnvelope(id: id, expectedRevision: Revision(initial.revision.value + 1), command: .createChannel(name: "Stable", initialRecipe: [:])), grant: grant)
        XCTAssertEqual(replay, first)
        XCTAssertEqual(changed.outcome, .rejected(reason: "command-id-reused-with-different-request"))
        XCTAssertEqual(changedRevision.outcome, .rejected(reason: "command-id-reused-with-different-request"))
    }

    func testEquivalentDictionaryRequestHasStableCommandFingerprint() throws {
        let (authority, grant) = try open()
        let initial = try authority.open().document
        let id = CommandID()
        let first = try execute(authority, CommandEnvelope(id: id, expectedRevision: initial.revision, command: .createChannel(name: "Stable", initialRecipe: ["a": "1", "b": "2"])), grant: grant)
        let replay = try execute(authority, CommandEnvelope(id: id, expectedRevision: initial.revision, command: .createChannel(name: "Stable", initialRecipe: ["b": "2", "a": "1"])), grant: grant)
        XCTAssertEqual(replay, first)
    }

    func testUndoAndRedoAreRevisionedChanges() throws {
        let (authority, grant) = try open()
        let initial = try authority.open().document
        let create = try execute(authority, CommandEnvelope(expectedRevision: initial.revision, command: .createChannel(name: "Before", initialRecipe: [:])), grant: grant)
        guard case .applied(let document) = create.outcome else { return XCTFail("create failed") }
        let renamed = try execute(authority, CommandEnvelope(expectedRevision: document.revision, command: .renameChannel(name: "After")), grant: grant)
        guard case .applied(let changed) = renamed.outcome else { return XCTFail("rename failed") }
        let undone = try execute(authority, CommandEnvelope(expectedRevision: changed.revision, command: .undo), grant: grant)
        guard case .applied(let before) = undone.outcome else { return XCTFail("undo failed") }
        XCTAssertEqual(before.channel?.name, "Before")
        let redone = try execute(authority, CommandEnvelope(expectedRevision: before.revision, command: .redo), grant: grant)
        guard case .applied(let after) = redone.outcome else { return XCTFail("redo failed") }
        XCTAssertEqual(after.channel?.name, "After")
    }

    func testRevokedAndExpiredGrantsCannotReplayCachedMutations() throws {
        let (authority, grant) = try open()
        let initial = try authority.open().document
        let envelope = CommandEnvelope(expectedRevision: initial.revision, command: .createChannel(name: "Protected", initialRecipe: [:]))
        _ = try execute(authority, envelope, grant: grant)
        let (document, storedGrants) = try grants(for: authority)
        try save(storedGrants.map { existing in
            var revoked = existing
            if revoked.id == grant.id { revoked.revokedAt = Date() }
            return revoked
        }, for: document.projectID)
        XCTAssertEqual(try execute(authority, envelope, grant: grant).outcome, .rejected(reason: "unauthorized"))

        let expired = Grant(label: "expired", scopes: [.editProject], expiresAt: Date(timeIntervalSinceNow: -1), authorityEpoch: 1, tokenDigest: digest("expired"))
        try save(storedGrants + [expired], for: document.projectID)
        XCTAssertEqual(try authority.execute(envelope, grantID: expired.id, token: nil).outcome, .rejected(reason: "unauthorized"))
    }

    func testMovedPackageNeedsExplicitRebindAndInvalidatesOldGrant() throws {
        let (authority, grant) = try open()
        let initial = try authority.open().document
        let created = try execute(authority, CommandEnvelope(expectedRevision: initial.revision, command: .createChannel(name: "Portable", initialRecipe: [:])), grant: grant)
        guard case .applied(let document) = created.outcome else { return XCTFail("create failed") }

        let original = root.appendingPathComponent("Channel.takeform")
        let moved = root.appendingPathComponent("Moved.takeform")
        try FileManager.default.copyItem(at: original, to: moved)
        let copiedDatabase = try Data(contentsOf: moved.appendingPathComponent(".takeform/project.sqlite"))
        let movedAuthority = try ProjectAuthority(packageURL: moved)
        XCTAssertThrowsError(try movedAuthority.open()) { XCTAssertEqual($0 as? AuthorityFailure, .copyDecisionRequired) }
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent(".takeform/project.sqlite")), copiedDatabase)
        XCTAssertThrowsError(try execute(movedAuthority, CommandEnvelope(expectedRevision: document.revision, command: .renameChannel(name: "Must decide")), grant: grant)) {
            XCTAssertEqual($0 as? AuthorityFailure, .copyDecisionRequired)
        }
        XCTAssertEqual(try movedAuthority.open(rebindMovedPackage: true).document, document)
        let denied = try execute(movedAuthority, CommandEnvelope(expectedRevision: document.revision, command: .renameChannel(name: "Needs pairing")), grant: grant)
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
        let missingDatabase = try ProjectAuthority(packageURL: root.appendingPathComponent("Channel.takeform"))
        XCTAssertThrowsError(try missingDatabase.open()) {
            XCTAssertEqual($0 as? AuthorityFailure, .missingObject("project.sqlite"))
        }

        let missing = root.appendingPathComponent("Missing.takeform/.takeform")
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        let missingAuthority = try ProjectAuthority(packageURL: root.appendingPathComponent("Missing.takeform"))
        _ = try missingAuthority.open()
        let missingManifestURL = missing.appendingPathComponent("manifest.json")
        var missingManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: missingManifestURL)) as! [String: Any]
        missingManifest["objects"] = ["objects/declared-but-missing.json"]
        try JSONSerialization.data(withJSONObject: missingManifest).write(to: missingManifestURL)
        XCTAssertThrowsError(try missingAuthority.open()) { XCTAssertEqual($0 as? AuthorityFailure, .missingObject("objects/declared-but-missing.json")) }

        let corrupt = root.appendingPathComponent("Corrupt.takeform/.takeform")
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("not sqlite".utf8).write(to: corrupt.appendingPathComponent("project.sqlite"))
        let corruptAuthority = try ProjectAuthority(packageURL: root.appendingPathComponent("Corrupt.takeform"))
        XCTAssertThrowsError(try corruptAuthority.open()) {
            XCTAssertEqual($0 as? AuthorityFailure, .corruptDatabase)
        }
    }
}
