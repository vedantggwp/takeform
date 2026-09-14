import Foundation
import Security
import ProofWire

let keychainService = "com.takeform.proof.cli"
let args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func has(_ name: String) -> Bool { args.contains(name) }
var positional: [String] = []
var skip = false
for (i, a) in args.enumerated() {
    if skip { skip = false; continue }
    if a.hasPrefix("--") {
        if ["--claim", "--id", "--repeat", "--expect", "--label"].contains(a), i + 1 < args.count { skip = true }
        continue
    }
    positional.append(a)
}

struct Outcome: Codable {
    var tool = "proofctl"
    var pid = getpid()
    var subcommand: String
    var commandID: String
    var tokenPresented: Bool
    var claimedActor: String?
    var sentAt: Date
    var receivedAt: Date
    var roundTripMs: Double
    var response: Response?
    var transportError: String?
    var expect: String?
    var pass: Bool?
}

func keychainQuery() -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: "session"]
}

func storeToken(_ token: String) -> OSStatus {
    SecItemDelete(keychainQuery() as CFDictionary)
    var add = keychainQuery()
    add[kSecValueData as String] = Data(token.utf8)
    add[kSecAttrLabel as String] = "Takeform Proof CLI session"
    return SecItemAdd(add as CFDictionary, nil)
}

func loadToken() -> String? {
    var q = keychainQuery()
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let d = item as? Data else { return nil }
    return String(decoding: d, as: UTF8.self)
}

func emit<T: Encodable>(_ v: T) {
    let data = (try? Codec.encoder.encode(v)) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func send(_ sub: String, _ command: Command, token: String?, claim: String?, id: String?, expect: String?) -> Int32 {
    let req = Request(commandID: id ?? UUID().uuidString, token: token, claimedActor: claim, command: command)
    let sentAt = Date()
    var outcome = Outcome(subcommand: sub, commandID: req.commandID, tokenPresented: token != nil, claimedActor: claim, sentAt: sentAt, receivedAt: sentAt, roundTripMs: 0, expect: expect)
    var code: Int32 = 0
    do {
        let resp = try UnixSocket.request(req)
        outcome.receivedAt = Date()
        outcome.roundTripMs = outcome.receivedAt.timeIntervalSince(sentAt) * 1000
        outcome.response = resp
        if case .paired(let g) = resp {
            let st = storeToken(g.token)
            FileHandle.standardError.write(Data("keychain store status \(st)\n".utf8))
        }
        if case .rejected = resp { code = 2 }
        if let e = expect { outcome.pass = (resp.kind == e); if outcome.pass == false { code = 4 } }
    } catch {
        outcome.receivedAt = Date()
        outcome.transportError = "\(error)"
        code = 3
        if let e = expect { outcome.pass = (e == "transport-error"); if outcome.pass == true { code = 0 } }
    }
    emit(outcome)
    return code
}

guard let sub = positional.first else {
    FileHandle.standardError.write(Data("usage: proofctl <pair|describe|start|cancel|write|status|approve|revoke|shutdown|forget|wait-socket|inject-stale-attempt> [--claim X] [--id X] [--no-token] [--repeat N] [--expect kind] [--label L]\n".utf8))
    exit(64)
}

let claim = option("--claim")
let id = option("--id")
let expect = option("--expect")
let repeatCount = Int(option("--repeat") ?? "1") ?? 1
let token: String? = has("--no-token") ? nil : loadToken()
var exitCode: Int32 = 0

switch sub {
case "pair":
    exitCode = send(sub, .requestPairing(label: option("--label") ?? "proofctl"), token: nil, claim: claim, id: id, expect: expect)
case "describe":
    for _ in 0..<repeatCount {
        let c = send(sub, .describeFixture, token: token, claim: claim, id: id, expect: expect)
        if c != 0 { exitCode = c }
    }
case "start":
    exitCode = send(sub, .startAttempt(seconds: Int(positional.dropFirst().first ?? "5") ?? 5), token: token, claim: claim, id: id, expect: expect)
case "cancel":
    exitCode = send(sub, .cancelAttempt(lease: positional.dropFirst().first ?? ""), token: token, claim: claim, id: id, expect: expect)
case "write":
    exitCode = send(sub, .attemptWrite(lease: positional.dropFirst().first ?? "", note: positional.dropFirst(2).joined(separator: " ")), token: token, claim: claim, id: id, expect: expect)
case "status":
    exitCode = send(sub, .status, token: token, claim: claim, id: id, expect: expect)
case "approve":
    exitCode = send(sub, .approvePairing(requestID: positional.dropFirst().first ?? "none", role: .creatorDelegate), token: token, claim: claim, id: id, expect: expect)
case "revoke":
    exitCode = send(sub, .revokeSession(sessionID: positional.dropFirst().first ?? "none"), token: token, claim: claim, id: id, expect: expect)
case "shutdown":
    exitCode = send(sub, .shutdown, token: token, claim: claim, id: id, expect: expect)
case "forget":
    let st = SecItemDelete(keychainQuery() as CFDictionary)
    emit(["subcommand": "forget", "status": "\(st)"])
case "wait-socket":
    let seconds = Double(positional.dropFirst().first ?? "10") ?? 10
    let t0 = Date()
    var ok = false
    while Date().timeIntervalSince(t0) < seconds {
        if UnixSocket.canConnect() { ok = true; break }
        usleep(5000)
    }
    emit(["subcommand": "wait-socket", "connected": "\(ok)", "waitedMs": String(format: "%.1f", Date().timeIntervalSince(t0) * 1000)])
    exitCode = ok ? 0 : 3
case "inject-stale-attempt":
    guard let pidText = positional.dropFirst().first, let pid = Int32(pidText) else { exit(64) }
    var store = AttemptStore()
    var a = AttemptRecord(lease: "stale-" + UUID().uuidString, stamp: ProcessStamp(pid: pid, startSec: 1_000_000_000, startUsec: 1), state: "running", seconds: 300, startedAt: Date())
    a.notes.append("injected by proofctl to simulate a helper record whose pid was reused by an unrelated process")
    store.current = a
    try ProofPaths.ensureStateDir()
    try Codec.prettyEncoder.encode(store).write(to: ProofPaths.stateDir.appendingPathComponent("attempts.json"))
    emit(["subcommand": "inject-stale-attempt", "pid": "\(pid)", "lease": a.lease, "liveStamp": ProcessProbe.stamp(pid: pid).map { "\($0.startSec).\($0.startUsec)" } ?? "none"])
default:
    FileHandle.standardError.write(Data("unknown subcommand \(sub)\n".utf8))
    exitCode = 64
}
exit(exitCode)
