import Foundation
import Security
import ProofWire

let keychainService = "com.takeform.proof.cli"
let args = Array(CommandLine.arguments.dropFirst())
let valueOptions = ["--claim", "--id", "--repeat", "--expect", "--label", "--simulate-keychain-status"]

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
        if valueOptions.contains(a), i + 1 < args.count { skip = true }
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
    var response: ObservableResponse?
    var transportError: String?
    var expect: String?
    var serverExpectationMet: Bool?
    var pass: Bool?
    var pairingRequestToApprovalMs: Double?
    var approvalToFirstReceiptMs: Double?
    var keychainStoreStatus: Int32?
    var localCredentialStored: Bool?
    var localCredentialError: String?
}

enum ObservableResponse: Codable {
    case receipt(Receipt)
    case paired(requestID: String, sessionID: String, role: CLIRole, requestedAt: Date, approvedAt: Date)
    case rejected(reason: Rejection, detail: String, peer: PeerIdentity?)

    init(_ response: Response) {
        switch response {
        case .receipt(let receipt):
            self = .receipt(receipt)
        case .paired(let grant):
            self = .paired(
                requestID: grant.requestID,
                sessionID: grant.sessionID,
                role: grant.role,
                requestedAt: grant.requestedAt,
                approvedAt: grant.approvedAt
            )
        case .rejected(let reason, let detail, let peer):
            self = .rejected(reason: reason, detail: detail, peer: peer)
        }
    }

    var kind: String {
        switch self {
        case .receipt: return "receipt"
        case .paired: return "paired"
        case .rejected(let reason, _, _): return "rejected:\(reason.rawValue)"
        }
    }
}

struct Performed {
    var outcome: Outcome
    var pairingGrant: PairingGrant?
}

func keychainQuery() -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: "session"]
}

func storeToken(_ token: String) -> OSStatus {
    SecItemDelete(keychainQuery() as CFDictionary)
    if let forced = option("--simulate-keychain-status").flatMap(Int32.init) { return forced }
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

func perform(_ sub: String, _ command: Command, token: String?, claim: String?, id: String?, expect: String?) -> Performed {
    let req = Request(commandID: id ?? UUID().uuidString, token: token, claimedActor: claim, command: command)
    let sentAt = Date()
    var outcome = Outcome(subcommand: sub, commandID: req.commandID, tokenPresented: token != nil, claimedActor: claim, sentAt: sentAt, receivedAt: sentAt, roundTripMs: 0, expect: expect)
    do {
        let resp = try UnixSocket.request(req)
        outcome.receivedAt = Date()
        outcome.roundTripMs = outcome.receivedAt.timeIntervalSince(sentAt) * 1000
        outcome.response = ObservableResponse(resp)
        if case .paired(let g) = resp {
            let status = storeToken(g.token)
            outcome.keychainStoreStatus = status
            outcome.localCredentialStored = status == errSecSuccess
            if status != errSecSuccess {
                outcome.localCredentialError = "pairing was approved, but proofctl could not store the new session credential in its Keychain item (OSStatus \(status)); local authenticated commands are unavailable"
            }
            outcome.pairingRequestToApprovalMs = g.approvedAt.timeIntervalSince(g.requestedAt) * 1000
        }
        if let e = expect {
            outcome.serverExpectationMet = resp.kind == e
            outcome.pass = outcome.serverExpectationMet == true && (outcome.keychainStoreStatus == nil || outcome.keychainStoreStatus == errSecSuccess)
        }
        return Performed(outcome: outcome, pairingGrant: {
            if case .paired(let grant) = resp { return grant }
            return nil
        }())
    } catch {
        outcome.receivedAt = Date()
        outcome.transportError = "\(error)"
        if let e = expect {
            outcome.serverExpectationMet = e == "transport-error"
            outcome.pass = outcome.serverExpectationMet
        }
    }
    return Performed(outcome: outcome, pairingGrant: nil)
}

func exitCode(for o: Outcome) -> Int32 {
    if let status = o.keychainStoreStatus, status != errSecSuccess { return 5 }
    if let p = o.pass { return p ? 0 : 4 }
    if o.transportError != nil { return 3 }
    if case .rejected? = o.response { return 2 }
    return 0
}

guard let sub = positional.first else {
    FileHandle.standardError.write(Data("usage: proofctl <pair|describe|start|cancel|write|status|approve|revoke|shutdown|forget|wait-socket|inject-stale-attempt|receipts|audit-token-absence> [--claim X] [--id X] [--no-token] [--repeat N] [--expect kind] [--label L] [--then-describe] [--simulate-keychain-status N]\n".utf8))
    exit(64)
}

let claim = option("--claim")
let id = option("--id")
let expect = option("--expect")
let repeatCount = Int(option("--repeat") ?? "1") ?? 1
let token: String? = has("--no-token") ? nil : loadToken()
var code: Int32 = 0

func run(_ sub: String, _ command: Command, token: String?) {
    let o = perform(sub, command, token: token, claim: claim, id: id, expect: expect).outcome
    emit(o)
    let c = exitCode(for: o)
    if c != 0 { code = c }
}

switch sub {
case "pair":
    let performed = perform(sub, .requestPairing(label: option("--label") ?? "proofctl"), token: nil, claim: claim, id: id, expect: expect)
    var o = performed.outcome
    if has("--then-describe"), let grant = performed.pairingGrant, o.keychainStoreStatus == errSecSuccess {
        let d = perform("describe-after-pair", .describeFixture, token: grant.token, claim: nil, id: nil, expect: "receipt").outcome
        if case .receipt(let r)? = d.response { o.approvalToFirstReceiptMs = r.issuedAt.timeIntervalSince(grant.approvedAt) * 1000 }
        emit(o)
        emit(d)
        code = max(exitCode(for: o), exitCode(for: d))
    } else {
        emit(o)
        code = exitCode(for: o)
    }
case "describe":
    for _ in 0..<repeatCount { run(sub, .describeFixture, token: token) }
case "start":
    run(sub, .startAttempt(seconds: Int(positional.dropFirst().first ?? "5") ?? 5), token: token)
case "cancel":
    run(sub, .cancelAttempt(lease: positional.dropFirst().first ?? ""), token: token)
case "write":
    run(sub, .attemptWrite(lease: positional.dropFirst().first ?? "", note: positional.dropFirst(2).joined(separator: " ")), token: token)
case "status":
    run(sub, .status, token: token)
case "approve":
    run(sub, .approvePairing(requestID: positional.dropFirst().first ?? "none", role: .creatorDelegate), token: token)
case "revoke":
    run(sub, .revokeSession(sessionID: positional.dropFirst().first ?? "none"), token: token)
case "shutdown":
    run(sub, .shutdown, token: token)
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
    code = ok ? 0 : 3
case "inject-stale-attempt":
    guard let pidText = positional.dropFirst().first, let pid = Int32(pidText) else { exit(64) }
    var store = AttemptStore()
    var a = AttemptRecord(lease: "stale-" + UUID().uuidString, stamp: ProcessStamp(pid: pid, startSec: 1_000_000_000, startUsec: 1), state: "running", seconds: 300, startedAt: Date())
    a.handshake = HelperHandshake(lease: a.lease, stamp: a.stamp, verifiedAt: Date())
    a.notes.append("injected by proofctl to simulate a helper record whose pid was reused by an unrelated process")
    store.current = a
    try ProofPaths.ensureStateDir()
    try Codec.prettyEncoder.encode(store).write(to: ProofPaths.stateDir.appendingPathComponent("attempts.json"))
    emit(["subcommand": "inject-stale-attempt", "pid": "\(pid)", "lease": a.lease, "liveStamp": ProcessProbe.stamp(pid: pid).map { "\($0.startSec).\($0.startUsec)" } ?? "none"])
case "receipts":
    struct StateFile: Codable { var receipts: [String: Receipt] }
    let url = ProofPaths.stateDir.appendingPathComponent("service-state.json")
    guard let d = try? Data(contentsOf: url), let s = try? Codec.decoder.decode(StateFile.self, from: d) else { exit(3) }
    let wanted = positional.dropFirst().first ?? "describeFixture"
    for r in s.receipts.values.filter({ $0.command == wanted }).sorted(by: { $0.issuedAt < $1.issuedAt }) { emit(r) }
case "audit-token-absence":
    guard let issuedToken = loadToken(), let directory = positional.dropFirst().first else { exit(3) }
    let root = URL(fileURLWithPath: directory)
    let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
        .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    let matches = files.filter { (try? Data(contentsOf: $0).range(of: Data(issuedToken.utf8))) != nil }
    emit(["subcommand": "audit-token-absence", "keychainItemRead": "true", "filesScanned": "\(files.count)", "issuedTokenPresent": matches.isEmpty ? "false" : "true", "pass": matches.isEmpty ? "true" : "false"])
    code = matches.isEmpty ? 0 : 5
default:
    FileHandle.standardError.write(Data("unknown subcommand \(sub)\n".utf8))
    code = 64
}
exit(code)
