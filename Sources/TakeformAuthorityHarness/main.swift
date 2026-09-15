import Darwin
import Foundation
import TakeformAuthority
import TakeformCore

private struct HarnessBinding: Codable {
    let canonicalPath: String
    let epoch: Int
}

private struct HarnessMachineState: Codable {
    let grants: [UUID: [Grant]]
    let bindings: [UUID: HarnessBinding]
}

func run(_ executable: String, arguments: [String], environment: [String: String] = [:]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "TakeformAuthorityHarness", code: Int(process.terminationStatus)) }
}

func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 else {
    fputs("usage: TakeformAuthorityHarness <TakeformAuthorityService> <takeform>\n", stderr)
    exit(2)
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("takeform-authority-harness-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }

do {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let package = root.appendingPathComponent("Channel.takeform")
    let runtime = root.appendingPathComponent("runtime")
    let authority = try ProjectAuthority(packageURL: package, runtimeURL: runtime)
    let initial = try authority.open().document
    let grant = Grant(label: "unshipped-harness", scopes: [.editProject], expiresAt: .distantFuture)
    let state = HarnessMachineState(grants: [initial.projectID: [grant]], bindings: [initial.projectID: HarnessBinding(canonicalPath: package.path, epoch: 1)])
    try JSONEncoder().encode(state).write(to: runtime.appendingPathComponent("grants.json"), options: .atomic)

    let create = CommandEnvelope(expectedRevision: initial.revision, command: .createChannel(name: "Process", initialRecipe: [:]))
    try run(arguments[0], arguments: ["execute", package.path, runtime.path, grant.id.uuidString, try json(create)])
    let created = try authority.open().document
    guard created.channel?.name == "Process" else { throw NSError(domain: "TakeformAuthorityHarness", code: 1) }

    let rename = CommandEnvelope(expectedRevision: created.revision, command: .renameChannel(name: "CLI"))
    try run(arguments[1], arguments: ["execute", package.path, runtime.path, grant.id.uuidString, try json(rename)], environment: ["TAKEFORM_AUTHORITY_SERVICE": arguments[0]])
    guard try authority.open().document.channel?.name == "CLI" else { throw NSError(domain: "TakeformAuthorityHarness", code: 2) }
    print("authority-harness: PASS service and CLI persisted one authorized command each")
} catch {
    fputs("authority-harness: \(error.localizedDescription)\n", stderr)
    exit(1)
}
