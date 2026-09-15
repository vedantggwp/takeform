import Foundation
import CryptoKit
import Darwin
import Security
import XCTest
@testable import TakeformAuthorityAppServiceCore
@_spi(Testing) @testable import TakeformAppAuthorityWire
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

    func testCreatorRebindAuthenticatesBeforeMutationAndNativeEditsDoNotMintCLIGrants() throws {
        let original = root.appendingPathComponent("Creator.takeform")
        let authority = try ProjectAuthority(packageURL: original)
        let creatorCredential = "creator-credential"
        let initial = try authority.openForAuthenticatedCreator(credential: creatorCredential, rebindMovedPackage: false).document
        let paired: Grant
        do { paired = try authority.issuePairedCLIGrant(credential: creatorCredential, label: "paired CLI", scopes: [.editProject], expiresAt: .distantFuture, rawToken: "paired-token") }
        catch { return XCTFail("initial pair failed: \(error)") }
        let stateURL = try machineURL(for: initial.projectID).appendingPathComponent("binding.json")
        let grantsBeforeNativeEdit = try JSONDecoder().decode(TestMachineState.self, from: Data(contentsOf: stateURL)).grants
        do { _ = try authority.openForAuthenticatedCreator(credential: creatorCredential, rebindMovedPackage: false) }
        catch { return XCTFail("creator credential changed before native edit: \(error)") }
        do { _ = try authority.executeForAuthenticatedCreator(CommandEnvelope(expectedRevision: initial.revision, command: .createChannel(name: "Native", initialRecipe: [:])), credential: creatorCredential) }
        catch { return XCTFail("native edit failed: \(error)") }
        XCTAssertEqual(try JSONDecoder().decode(TestMachineState.self, from: Data(contentsOf: stateURL)).grants, grantsBeforeNativeEdit)

        let moved = root.appendingPathComponent("CreatorMoved.takeform")
        try FileManager.default.copyItem(at: original, to: moved)
        let movedAuthority = try ProjectAuthority(packageURL: moved)
        let bindingBeforeWrongCredential = try Data(contentsOf: stateURL)
        XCTAssertThrowsError(try movedAuthority.openForAuthenticatedCreator(credential: "wrong-credential", rebindMovedPackage: true)) {
            XCTAssertEqual($0 as? AuthorityFailure, .unauthorized)
        }
        XCTAssertEqual(try Data(contentsOf: stateURL), bindingBeforeWrongCredential)

        do { _ = try movedAuthority.openForAuthenticatedCreator(credential: creatorCredential, rebindMovedPackage: true) }
        catch { return XCTFail("authenticated rebind failed: \(error)") }
        let denied = try movedAuthority.execute(CommandEnvelope(expectedRevision: Revision(1), command: .renameChannel(name: "Old grant")), grantID: paired.id, token: "paired-token")
        XCTAssertEqual(denied.outcome, .rejected(reason: "unauthorized"))

        let replacement: Grant
        do { replacement = try movedAuthority.issuePairedCLIGrant(credential: creatorCredential, label: "replacement", scopes: [.editProject], expiresAt: .distantFuture, rawToken: "replacement-token") }
        catch { return XCTFail("replacement pair failed: \(error)") }
        try movedAuthority.revokePairedCLIGrant(credential: creatorCredential, grantID: replacement.id)
        let revoked = try movedAuthority.execute(CommandEnvelope(expectedRevision: Revision(1), command: .renameChannel(name: "Revoked")), grantID: replacement.id, token: "replacement-token")
        XCTAssertEqual(revoked.outcome, .rejected(reason: "unauthorized"))
    }

    func testAtomicChannelPackageCreationCleansOwnedFailureAndPreservesExistingDestination() throws {
        let destination = root.appendingPathComponent("Atomic.takeform")
        let authorityRoot = try machineURL(for: UUID()).deletingLastPathComponent()
        let machineStateBefore = (try? FileManager.default.contentsOfDirectory(atPath: authorityRoot.path).sorted()) ?? []
        XCTAssertThrowsError(try ProjectAuthority.createChannelPackage(at: destination, name: "Atomic", initialRecipe: [:], credential: "creator", afterInitialBind: { throw NSError(domain: "test", code: 0) }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: authorityRoot.path).sorted()) ?? [], machineStateBefore)

        let collidingTemporary = root.appendingPathComponent(".Atomic.takeform.creating-collision")
        try FileManager.default.createDirectory(at: collidingTemporary, withIntermediateDirectories: false)
        let collisionMarker = collidingTemporary.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: collisionMarker)
        XCTAssertThrowsError(try ProjectAuthority.createChannelPackage(at: destination, name: "Atomic", initialRecipe: [:], credential: "creator", temporaryDirectoryName: "collision"))
        XCTAssertEqual(try Data(contentsOf: collisionMarker), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: authorityRoot.path).sorted()) ?? [], machineStateBefore)

        XCTAssertThrowsError(try ProjectAuthority.createChannelPackage(at: destination, name: "Atomic", initialRecipe: [:], credential: "creator") { throw NSError(domain: "test", code: 1) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: authorityRoot.path).sorted()) ?? [], machineStateBefore)

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        XCTAssertThrowsError(try ProjectAuthority.createChannelPackage(at: destination, name: "Atomic", initialRecipe: [:], credential: "creator"))
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
        try FileManager.default.removeItem(at: destination)

        let response = CreatorAuthorityService.respond(to: .create(destination, "Atomic", ["font": "Serif"], Data("creator".utf8)), from: .app)
        guard case let .snapshot(created) = response else { return XCTFail("app create route did not return a project snapshot") }
        projectIDs.insert(created.document.projectID)
        XCTAssertEqual(created.packageURL.standardizedFileURL.path, destination.standardizedFileURL.path)
        XCTAssertEqual(created.document.channel?.name, "Atomic")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".takeform/project.sqlite").path))
    }

    func testCLIRoleRouteCannotRunCreatorVerbsOrMutateAuthorityState() throws {
        let package = root.appendingPathComponent("RoleProtected.takeform")
        let authority = try ProjectAuthority(packageURL: package)
        let document = try authority.openForAuthenticatedCreator(credential: "creator", rebindMovedPackage: false).document
        projectIDs.insert(document.projectID)
        let stateURL = try machineURL(for: document.projectID).appendingPathComponent("binding.json")
        let bindingBefore = try Data(contentsOf: stateURL)
        let manifestURL = package.appendingPathComponent(".takeform/manifest.json")
        let manifestBefore = try Data(contentsOf: manifestURL)

        let open = AppAuthorityRequest.open(package, true, Data("forged".utf8))
        let pair = AppAuthorityRequest.pair(package, "forged", .distantFuture, Data("forged".utf8))
        guard case .failure(.creatorAuthorizationRequired) = CreatorAuthorityService.respond(to: open, from: .cli) else { return XCTFail("CLI role routed creator open") }
        guard case .failure(.creatorAuthorizationRequired) = CreatorAuthorityService.respond(to: pair, from: .cli) else { return XCTFail("CLI role routed creator pair") }
        XCTAssertEqual(try Data(contentsOf: stateURL), bindingBefore)
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
    }

    func testFakeServiceSocketReceivesNoCreatorSecretBeforePeerVerification() throws {
        final class ReadCapture: @unchecked Sendable {
            private let lock = NSLock()
            private var value = Data()
            let completed = DispatchSemaphore(value: 0)
            func set(_ value: Data) { lock.lock(); self.value = value; lock.unlock(); completed.signal() }
            func read() -> Data { lock.lock(); defer { lock.unlock() }; return value }
        }
        let socketURL = URL(fileURLWithPath: "/private/tmp/takeform-authority-test-\(UUID().uuidString).sock")
        AppAuthoritySocket.setTestingPath(socketURL.path)
        defer { AppAuthoritySocket.setTestingPath(nil) }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw XCTSkip("could not create test socket") }
        defer { close(listener); try? FileManager.default.removeItem(at: socketURL) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketURL.path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = UInt8(bitPattern: byte) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(listener, 1) == 0 else { throw XCTSkip("could not bind test socket") }
        let capture = ReadCapture()
        Thread {
            let peer = accept(listener, nil, nil)
            guard peer >= 0 else { capture.set(Data()); return }
            defer { close(peer) }
            var byte: UInt8 = 0
            let count = Darwin.read(peer, &byte, 1)
            capture.set(count > 0 ? Data([byte]) : Data())
        }.start()
        let rootURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let service = rootURL.appendingPathComponent(".build/debug/TakeformAuthorityAppService")
        guard FileManager.default.isExecutableFile(atPath: service.path), AppAuthorityPeer.requirement(for: service) != nil else { return XCTFail("service identity is unavailable") }
        XCTAssertThrowsError(try AppAuthoritySocket.verifiedRequest(.open(root.appendingPathComponent("Secret.takeform"), false, Data("creator-secret-marker".utf8)), expectedService: service))
        XCTAssertEqual(capture.completed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(capture.read(), Data())
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
