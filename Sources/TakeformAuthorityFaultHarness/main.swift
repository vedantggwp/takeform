import Darwin
import CryptoKit
import Foundation
import TakeformAuthority
import TakeformCore

private struct Fixture: Codable {
    let projectID: UUID
    let grantID: UUID
    let envelope: CommandEnvelope
}

private struct HarnessBinding: Codable { let canonicalPath: String; let epoch: Int }
private struct HarnessMachineState: Codable { let binding: HarnessBinding; let grants: [Grant] }

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2, let root = arguments.last.map({ URL(fileURLWithPath: $0) }) else {
    fputs("usage: TakeformAuthorityFaultHarness <setup|before|verify-before|after|replay|cleanup> <root>\n", stderr)
    exit(2)
}

let package = root.appendingPathComponent("Channel.takeform")
let fixtureURL = root.appendingPathComponent("fixture.json")

private func fixture() throws -> Fixture {
    try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
}

private func authority() throws -> ProjectAuthority {
    try ProjectAuthority(packageURL: package)
}

private func token(for fixture: Fixture) -> String {
    "fault-harness-\(fixture.projectID.uuidString)-\(fixture.grantID.uuidString)"
}

do {
    switch arguments[0] {
    case "setup":
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let authority = try authority()
        let document = try authority.open().document
        let fixtureGrantID = UUID()
        let rawToken = "fault-harness-\(document.projectID.uuidString)-\(fixtureGrantID.uuidString)"
        let digest = SHA256.hash(data: Data(rawToken.utf8)).map { String(format: "%02x", $0) }.joined()
        let grant = Grant(id: fixtureGrantID, label: "fault-harness", scopes: [.editProject], expiresAt: .distantFuture, authorityEpoch: 1, tokenDigest: digest)
        guard let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw NSError(domain: "TakeformAuthorityFaultHarness", code: 4) }
        let stateURL = applicationSupport.appendingPathComponent("Takeform/Authority/\(document.projectID.uuidString)/binding.json")
        try JSONEncoder().encode(HarnessMachineState(binding: HarnessBinding(canonicalPath: package.standardizedFileURL.path, epoch: 1), grants: [grant])).write(to: stateURL, options: .atomic)
        let command = CommandEnvelope(expectedRevision: document.revision, command: .createChannel(name: "Recovered", initialRecipe: [:]))
        try JSONEncoder().encode(Fixture(projectID: document.projectID, grantID: grant.id, envelope: command)).write(to: fixtureURL, options: .atomic)
        print("fault-harness: setup")
    case "before":
        _ = try fixture()
        _ = try authority()
        print("fault-harness: barrier before transaction")
        fflush(stdout)
        _exit(75)
    case "verify-before":
        let document = try authority().open().document
        guard document.revision == Revision(0), document.channel == nil else { throw NSError(domain: "TakeformAuthorityFaultHarness", code: 1) }
        print("fault-harness: PASS pre-commit termination retained revision 0")
    case "after":
        let fixture = try fixture()
        let result = try authority().execute(fixture.envelope, grantID: fixture.grantID, token: token(for: fixture))
        guard case .applied(let document) = result.outcome, document.revision == Revision(1) else { throw NSError(domain: "TakeformAuthorityFaultHarness", code: 2) }
        print("fault-harness: barrier after durable commit before acknowledgement")
        fflush(stdout)
        _exit(75)
    case "replay":
        let fixture = try fixture()
        let result = try authority().execute(fixture.envelope, grantID: fixture.grantID, token: token(for: fixture))
        guard case .applied(let document) = result.outcome, document.revision == Revision(1), document.channel?.name == "Recovered" else { throw NSError(domain: "TakeformAuthorityFaultHarness", code: 3) }
        print("fault-harness: PASS post-commit replay returned revision 1 without another mutation")
    case "cleanup":
        if let stored = try? fixture() {
            if let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                try? FileManager.default.removeItem(at: applicationSupport.appendingPathComponent("Takeform/Authority/\(stored.projectID.uuidString)"))
            }
        }
        try? FileManager.default.removeItem(at: root)
        print("fault-harness: cleanup")
    default:
        fputs("fault-harness: unknown mode\n", stderr)
        exit(2)
    }
} catch {
    fputs("fault-harness: \(error.localizedDescription)\n", stderr)
    exit(1)
}
