import Darwin
import CryptoKit
import Foundation
import TakeformAuthorityAppServiceCore
import TakeformCore

private struct HarnessBinding: Codable { let canonicalPath: String; let epoch: Int }
private struct HarnessMachineState: Codable { let binding: HarnessBinding; let grants: [Grant] }

func run(_ executable: String, arguments: [String], input: String? = nil, quiet: Bool = false) throws {
    let process = Process()
    let pipe = input.map { _ in Pipe() }
    let terminated = DispatchSemaphore(value: 0)
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = pipe
    if quiet {
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }
    process.terminationHandler = { _ in terminated.signal() }
    try process.run()
    if let input, let pipe {
        pipe.fileHandleForWriting.write(Data("\(input)\n".utf8))
        pipe.fileHandleForWriting.closeFile()
    }
    guard terminated.wait(timeout: .now() + 5) == .success else {
        process.terminate()
        _ = terminated.wait(timeout: .now() + 1)
        throw NSError(domain: "TakeformAuthorityEngineHarness", code: 7)
    }
    guard process.terminationStatus == 0 else { throw NSError(domain: "TakeformAuthorityEngineHarness", code: Int(process.terminationStatus)) }
}

func fails(_ executable: String, arguments: [String], input: String? = nil) throws -> Bool? {
    let process = Process()
    let pipe = input.map { _ in Pipe() }
    let terminated = DispatchSemaphore(value: 0)
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = pipe
    process.terminationHandler = { _ in terminated.signal() }
    try process.run()
    if let input, let pipe {
        pipe.fileHandleForWriting.write(Data("\(input)\n".utf8))
        pipe.fileHandleForWriting.closeFile()
    }
    guard terminated.wait(timeout: .now() + 5) == .success else {
        process.terminate()
        _ = terminated.wait(timeout: .now() + 1)
        return nil
    }
    return process.terminationStatus != 0
}

func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

func percentile(_ values: [Double], _ percentile: Double) -> Double {
    let sorted = values.sorted()
    return sorted[Int((Double(sorted.count - 1) * percentile).rounded())]
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard (arguments.count == 2 || arguments.count == 3), arguments.count == 2 || arguments[2] == "--service-only" else {
    fputs("usage: TakeformAuthorityEngineHarness <TakeformAuthorityEngineService> <takeform> [--service-only]\n", stderr)
    exit(2)
}
let serviceOnly = arguments.count == 3

let root = FileManager.default.temporaryDirectory.appendingPathComponent("takeform-authority-harness-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }

do {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let package = root.appendingPathComponent("Channel.takeform")
    let authority = try ProjectAuthority(packageURL: package)
    let initial = try authority.open().document
    let token = UUID().uuidString
    let digest = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    let grant = Grant(label: "unshipped-harness", scopes: [.editProject], expiresAt: .distantFuture, authorityEpoch: 1, tokenDigest: digest)
    guard let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw NSError(domain: "TakeformAuthorityEngineHarness", code: 3) }
    let authorityStore = applicationSupport.appendingPathComponent("Takeform/Authority/\(initial.projectID.uuidString)")
    defer { try? FileManager.default.removeItem(at: authorityStore) }
    let stateURL = authorityStore.appendingPathComponent("binding.json")
    let state = HarnessMachineState(binding: HarnessBinding(canonicalPath: package.standardizedFileURL.path, epoch: 1), grants: [grant])
    try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)

    let create = CommandEnvelope(expectedRevision: initial.revision, command: .createChannel(name: "Process", initialRecipe: [:]))
    try run(arguments[0], arguments: ["execute", package.path, grant.id.uuidString, try json(create)], input: token)
    let created = try authority.open().document
    guard created.channel?.name == "Process" else { throw NSError(domain: "TakeformAuthorityEngineHarness", code: 1) }

    let openMilliseconds = try (0..<20).map { _ -> Double in
        let start = Date()
        _ = try authority.open()
        return Date().timeIntervalSince(start) * 1000
    }
    let commandMilliseconds: [Double]
    if serviceOnly {
        commandMilliseconds = try (0..<20).map { index -> Double in
            let document = try authority.open().document
            let command = CommandEnvelope(expectedRevision: document.revision, command: .publishRecipe(values: ["measurement": "\(index)"]))
            let start = Date()
            try run(arguments[0], arguments: ["execute", package.path, grant.id.uuidString, try json(command)], input: token, quiet: true)
            return Date().timeIntervalSince(start) * 1000
        }
    } else {
        try run(arguments[1], arguments: ["import-paired-credential", grant.id.uuidString], input: token)
        defer { try? run(arguments[1], arguments: ["forget-paired-credential", grant.id.uuidString]) }
        guard let unavailableCredentialFailed = try fails(arguments[1], arguments: ["execute", package.path, UUID().uuidString, "{}"]), unavailableCredentialFailed else {
            throw NSError(domain: "TakeformAuthorityEngineHarness", code: 8)
        }
        let rename = CommandEnvelope(expectedRevision: created.revision, command: .renameChannel(name: "CLI"))
        try run(arguments[1], arguments: ["execute", package.path, grant.id.uuidString, try json(rename)])
        guard try authority.open().document.channel?.name == "CLI" else { throw NSError(domain: "TakeformAuthorityEngineHarness", code: 2) }
        commandMilliseconds = try (0..<20).map { index -> Double in
            let document = try authority.open().document
            let command = CommandEnvelope(expectedRevision: document.revision, command: .publishRecipe(values: ["measurement": "\(index)"]))
            let start = Date()
            try run(arguments[1], arguments: ["execute", package.path, grant.id.uuidString, try json(command)], quiet: true)
            return Date().timeIntervalSince(start) * 1000
        }
    }

    let copied = root.appendingPathComponent("Copy.takeform")
    try FileManager.default.copyItem(at: package, to: copied)
    let moved = CommandEnvelope(expectedRevision: Revision(2), command: .renameChannel(name: "Must decide"))
    guard try fails(arguments[0], arguments: ["execute", copied.path, grant.id.uuidString, try json(moved)], input: token) == true else { throw NSError(domain: "TakeformAuthorityEngineHarness", code: 5) }
    let forgedRuntime = root.appendingPathComponent("forged-runtime")
    try FileManager.default.createDirectory(at: forgedRuntime, withIntermediateDirectories: true)
    guard try fails(arguments[0], arguments: ["execute", package.path, forgedRuntime.path, grant.id.uuidString, try json(moved)], input: token) == true else { throw NSError(domain: "TakeformAuthorityEngineHarness", code: 6) }
    let lane = serviceOnly ? "service" : "service-and-cli"
    print("authority-harness: PASS \(lane); copied package and caller runtime were refused; opens=20 p50=\(String(format: "%.3f", percentile(openMilliseconds, 0.5)))ms p95=\(String(format: "%.3f", percentile(openMilliseconds, 0.95)))ms; commands=20 p50=\(String(format: "%.3f", percentile(commandMilliseconds, 0.5)))ms p95=\(String(format: "%.3f", percentile(commandMilliseconds, 0.95)))ms")
} catch {
    fputs("authority-harness: \(error.localizedDescription)\n", stderr)
    exit(1)
}
