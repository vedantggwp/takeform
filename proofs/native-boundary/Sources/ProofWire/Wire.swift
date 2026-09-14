import Foundation
import Security

public enum CLIRole: String, Codable, Sendable { case proposer, creatorDelegate }

public enum Command: Codable, Sendable {
    case requestPairing(label: String)
    case approvePairing(requestID: String, role: CLIRole)
    case revokeSession(sessionID: String)
    case grantFixture(bookmark: Data, name: String)
    case describeFixture
    case startAttempt(seconds: Int)
    case cancelAttempt(lease: String)
    case attemptWrite(lease: String, note: String)
    case status
    case shutdown

    public var name: String {
        switch self {
        case .requestPairing: return "requestPairing"
        case .approvePairing: return "approvePairing"
        case .revokeSession: return "revokeSession"
        case .grantFixture: return "grantFixture"
        case .describeFixture: return "describeFixture"
        case .startAttempt: return "startAttempt"
        case .cancelAttempt: return "cancelAttempt"
        case .attemptWrite: return "attemptWrite"
        case .status: return "status"
        case .shutdown: return "shutdown"
        }
    }

    public var policy: Policy {
        switch self {
        case .requestPairing: return .anyone
        case .approvePairing, .revokeSession, .grantFixture, .shutdown: return .creatorOnly
        case .describeFixture, .startAttempt, .cancelAttempt, .attemptWrite, .status: return .creatorOrPaired
        }
    }
}

public enum Policy: String, Codable, Sendable { case anyone, creatorOrPaired, creatorOnly }

public struct Request: Codable, Sendable {
    public var commandID: String
    public var token: String?
    public var claimedActor: String?
    public var command: Command

    public init(commandID: String = UUID().uuidString, token: String? = nil, claimedActor: String? = nil, command: Command) {
        self.commandID = commandID
        self.token = token
        self.claimedActor = claimedActor
        self.command = command
    }
}

public struct PeerIdentity: Codable, Sendable, Equatable {
    public var pid: Int32
    public var auditTokenObtained: Bool
    public var guestSource: String
    public var codeIdentifier: String?
    public var cdhash: String?
    public var appRequirement: String?
    public var matchesAppRequirement: Bool
    public var matchesDeveloperIDAnchor: Bool
    public var error: String?

    public init(pid: Int32) {
        self.pid = pid
        self.auditTokenObtained = false
        self.guestSource = "none"
        self.matchesAppRequirement = false
        self.matchesDeveloperIDAnchor = false
    }
}

public enum Principal: Codable, Sendable, Equatable {
    case creator(pid: Int32, codeIdentifier: String)
    case pairedCLI(session: String, role: CLIRole)
    case unauthenticated(pid: Int32, codeIdentifier: String?)

    public var label: String {
        switch self {
        case .creator(let pid, let id): return "creator(pid \(pid), \(id))"
        case .pairedCLI(let s, let role): return "pairedCLI(session \(s), \(role.rawValue))"
        case .unauthenticated(let pid, let id): return "unauthenticated(pid \(pid), \(id ?? "unsigned"))"
        }
    }
}

public enum Rejection: String, Codable, Sendable {
    case unauthenticated, unauthorized, unknownSession, revokedSession, staleLease, unknownLease
    case attemptRunning, noFixture, pairingTimeout, invalidRequest, helperFailed
}

public struct Receipt: Codable, Sendable, Equatable {
    public var commandID: String
    public var command: String
    public var principal: Principal
    public var peer: PeerIdentity
    public var claimedActor: String?
    public var result: String
    public var issuedAt: Date
    public var serviceStartedAt: Date
    public var servicePid: Int32

    public init(commandID: String, command: String, principal: Principal, peer: PeerIdentity, claimedActor: String?, result: String, issuedAt: Date, serviceStartedAt: Date, servicePid: Int32) {
        self.commandID = commandID
        self.command = command
        self.principal = principal
        self.peer = peer
        self.claimedActor = claimedActor
        self.result = result
        self.issuedAt = issuedAt
        self.serviceStartedAt = serviceStartedAt
        self.servicePid = servicePid
    }
}

public struct PairingGrant: Codable, Sendable {
    public var requestID: String
    public var sessionID: String
    public var token: String
    public var role: CLIRole
    public var requestedAt: Date
    public var approvedAt: Date

    public init(requestID: String, sessionID: String, token: String, role: CLIRole, requestedAt: Date, approvedAt: Date) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.token = token
        self.role = role
        self.requestedAt = requestedAt
        self.approvedAt = approvedAt
    }
}

public enum Response: Codable, Sendable {
    case receipt(Receipt)
    case paired(PairingGrant)
    case rejected(reason: Rejection, detail: String, peer: PeerIdentity?)

    public var kind: String {
        switch self {
        case .receipt: return "receipt"
        case .paired: return "paired"
        case .rejected(let r, _, _): return "rejected:\(r.rawValue)"
        }
    }
}

public struct SessionSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var role: CLIRole
    public var tokenPrefix: String
    public var createdAt: Date
    public var revokedAt: Date?
    public init(id: String, label: String, role: CLIRole, tokenPrefix: String, createdAt: Date, revokedAt: Date?) {
        self.id = id; self.label = label; self.role = role; self.tokenPrefix = tokenPrefix; self.createdAt = createdAt; self.revokedAt = revokedAt
    }
}

public struct PendingSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var peerPid: Int32
    public var peerIdentifier: String?
    public var requestedAt: Date
    public init(id: String, label: String, peerPid: Int32, peerIdentifier: String?, requestedAt: Date) {
        self.id = id; self.label = label; self.peerPid = peerPid; self.peerIdentifier = peerIdentifier; self.requestedAt = requestedAt
    }
}

public struct ProcessStamp: Codable, Sendable, Equatable {
    public var pid: Int32
    public var startSec: Int64
    public var startUsec: Int32
    public init(pid: Int32, startSec: Int64, startUsec: Int32) { self.pid = pid; self.startSec = startSec; self.startUsec = startUsec }
}

public struct AttemptRecord: Codable, Sendable, Equatable {
    public var lease: String
    public var stamp: ProcessStamp
    public var state: String
    public var seconds: Int
    public var startedAt: Date
    public var cancelRequestedAt: Date?
    public var exitedAt: Date?
    public var exitCode: Int32?
    public var cancelToExitMs: Double?
    public var notes: [String]
    public var helperEvents: [String]
    public init(lease: String, stamp: ProcessStamp, state: String, seconds: Int, startedAt: Date) {
        self.lease = lease; self.stamp = stamp; self.state = state; self.seconds = seconds; self.startedAt = startedAt
        self.notes = []; self.helperEvents = []
    }
}

public struct ReconcileRecord: Codable, Sendable, Equatable {
    public var at: Date
    public var lease: String
    public var recordedStamp: ProcessStamp
    public var liveStamp: ProcessStamp?
    public var classification: String
    public var signalled: Bool
    public var method: String
    public var msSinceServiceProcessStart: Double
    public init(at: Date, lease: String, recordedStamp: ProcessStamp, liveStamp: ProcessStamp?, classification: String, signalled: Bool, method: String, msSinceServiceProcessStart: Double) {
        self.at = at; self.lease = lease; self.recordedStamp = recordedStamp; self.liveStamp = liveStamp
        self.classification = classification; self.signalled = signalled; self.method = method; self.msSinceServiceProcessStart = msSinceServiceProcessStart
    }
}

public struct AttemptStore: Codable, Sendable, Equatable {
    public var current: AttemptRecord?
    public var history: [AttemptRecord]
    public var reconciles: [ReconcileRecord]
    public init() { history = []; reconciles = [] }
}

public struct FixtureAccess: Codable, Sendable, Equatable {
    public var name: String
    public var resolvedWith: String
    public var stale: Bool
    public var startAccessing: Bool
    public var readOK: Bool
    public var size: Int64?
    public var headHex: String?
    public var error: String?
    public var sandboxed: Bool
    public init(name: String, resolvedWith: String, stale: Bool, startAccessing: Bool, readOK: Bool, size: Int64?, headHex: String?, error: String?, sandboxed: Bool) {
        self.name = name; self.resolvedWith = resolvedWith; self.stale = stale; self.startAccessing = startAccessing
        self.readOK = readOK; self.size = size; self.headHex = headHex; self.error = error; self.sandboxed = sandboxed
    }
}

public struct StatusReport: Codable, Sendable, Equatable {
    public var servicePid: Int32
    public var serviceStartedAt: Date
    public var serviceStamp: ProcessStamp?
    public var appRequirement: String?
    public var sandboxed: Bool
    public var socketPath: String
    public var idleSeconds: Double
    public var sessions: [SessionSummary]
    public var pending: [PendingSummary]
    public var fixture: FixtureAccess?
    public var attempts: AttemptStore
    public var receiptCount: Int
    public init(servicePid: Int32, serviceStartedAt: Date, serviceStamp: ProcessStamp?, appRequirement: String?, sandboxed: Bool, socketPath: String, idleSeconds: Double, sessions: [SessionSummary], pending: [PendingSummary], fixture: FixtureAccess?, attempts: AttemptStore, receiptCount: Int) {
        self.servicePid = servicePid; self.serviceStartedAt = serviceStartedAt; self.serviceStamp = serviceStamp; self.appRequirement = appRequirement
        self.sandboxed = sandboxed; self.socketPath = socketPath; self.idleSeconds = idleSeconds; self.sessions = sessions; self.pending = pending
        self.fixture = fixture; self.attempts = attempts; self.receiptCount = receiptCount
    }
}

public enum Codec {
    public static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func configure(_ e: JSONEncoder) -> JSONEncoder {
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(iso.string(from: date))
        }
        return e
    }

    public static let encoder: JSONEncoder = {
        let e = configure(JSONEncoder())
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static let prettyEncoder: JSONEncoder = {
        let e = configure(JSONEncoder())
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = iso.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
            }
            return date
        }
        return d
    }()

    public static func prettyString<T: Encodable>(_ v: T) -> String {
        guard let data = try? prettyEncoder.encode(v) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum ProofPaths {
    public static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    public static var stateDir: URL {
        let env = ProcessInfo.processInfo.environment
        if let p = env["PROOF_STATE_DIR"], !p.isEmpty { return URL(fileURLWithPath: p) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let group = env["PROOF_APP_GROUP"], !group.isEmpty {
            return home.appendingPathComponent("Library/Group Containers/\(group)/TakeformProof")
        }
        return home.appendingPathComponent("Library/Application Support/TakeformProof")
    }

    public static var socketPath: String { stateDir.appendingPathComponent("proof.sock").path }
    public static var controlDir: URL { stateDir.appendingPathComponent("control") }

    public static func ensureStateDir() throws {
        try FileManager.default.createDirectory(at: controlDir, withIntermediateDirectories: true)
    }

    public static func redactHome(_ s: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var out = s.replacingOccurrences(of: home, with: "$HOME")
        if let real = ProcessInfo.processInfo.environment["HOME"], !real.isEmpty {
            out = out.replacingOccurrences(of: real, with: "$HOME")
        }
        return out
    }
}

public enum WireError: Error, CustomStringConvertible {
    case io(String, Int32)
    case closed
    case tooLarge
    case connect(String, Int32)
    case socketPathTooLong(String)

    public var description: String {
        switch self {
        case .io(let op, let e): return "\(op) failed errno \(e) \(String(cString: strerror(e)))"
        case .closed: return "peer closed"
        case .tooLarge: return "message too large"
        case .connect(let p, let e): return "connect \(ProofPaths.redactHome(p)) errno \(e) \(String(cString: strerror(e)))"
        case .socketPathTooLong(let p): return "socket path too long \(ProofPaths.redactHome(p))"
        }
    }
}

public enum Wire {
    public static func writeLine(_ data: Data, to fd: Int32) throws {
        var buf = data
        buf.append(0x0A)
        var offset = 0
        try buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw WireError.io("write", errno)
                }
                offset += Int(n)
            }
        }
    }

    public static func readLine(from fd: Int32, max: Int = 16_000_000) throws -> Data {
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while out.count < max {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n == 0 { throw WireError.closed }
            if n < 0 {
                if errno == EINTR { continue }
                throw WireError.io("read", errno)
            }
            if let nl = chunk[0..<Int(n)].firstIndex(of: 0x0A) {
                out.append(contentsOf: chunk[0..<nl])
                return out
            }
            out.append(contentsOf: chunk[0..<Int(n)])
        }
        throw WireError.tooLarge
    }

    public static func send<T: Encodable>(_ v: T, to fd: Int32) throws {
        try writeLine(try Codec.encoder.encode(v), to: fd)
    }

    public static func receive<T: Decodable>(_ t: T.Type, from fd: Int32) throws -> T {
        try Codec.decoder.decode(t, from: try readLine(from: fd))
    }
}

public enum UnixSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw WireError.socketPathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    public static func connect(_ path: String = ProofPaths.socketPath) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WireError.io("socket", errno) }
        var addr = try address(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            close(fd)
            throw WireError.connect(path, e)
        }
        return fd
    }

    public static func listen(_ path: String = ProofPaths.socketPath) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WireError.io("socket", errno) }
        var addr = try address(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            close(fd)
            throw WireError.io("bind", e)
        }
        guard Darwin.listen(fd, 32) == 0 else {
            let e = errno
            close(fd)
            throw WireError.io("listen", e)
        }
        return fd
    }

    public static func request(_ req: Request, path: String = ProofPaths.socketPath) throws -> Response {
        let fd = try connect(path)
        defer { close(fd) }
        try Wire.send(req, to: fd)
        return try Wire.receive(Response.self, from: fd)
    }

    public static func canConnect(_ path: String = ProofPaths.socketPath) -> Bool {
        guard let fd = try? connect(path) else { return false }
        close(fd)
        return true
    }
}

public enum CodeIdentity {
    public static func requirement(identifier: String, cdhash: String) -> String {
        "identifier \"\(identifier)\" and cdhash H\"\(cdhash)\""
    }

    public static let developerIDAnchor = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    public static func staticIdentity(binaryPath: String) -> (identifier: String?, cdhash: String?, error: String?) {
        var sc: SecStaticCode?
        let st = SecStaticCodeCreateWithPath(URL(fileURLWithPath: binaryPath) as CFURL, [], &sc)
        guard st == errSecSuccess, let code = sc else { return (nil, nil, "SecStaticCodeCreateWithPath status \(st)") }
        return signingInfo(code)
    }

    static func signingInfo(_ code: SecStaticCode) -> (identifier: String?, cdhash: String?, error: String?) {
        var info: CFDictionary?
        let st = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info)
        guard st == errSecSuccess, let dict = info as? [String: Any] else { return (nil, nil, "SecCodeCopySigningInformation status \(st)") }
        let id = dict[kSecCodeInfoIdentifier as String] as? String
        let cd = (dict[kSecCodeInfoUnique as String] as? Data).map { $0.map { String(format: "%02x", $0) }.joined() }
        return (id, cd, nil)
    }

    public static func peer(of fd: Int32, appRequirement: String?) -> PeerIdentity {
        var pid: pid_t = 0
        var plen = socklen_t(MemoryLayout<pid_t>.size)
        _ = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &plen)
        var identity = PeerIdentity(pid: pid)
        var token = audit_token_t()
        var tlen = socklen_t(MemoryLayout<audit_token_t>.size)
        let tokenOK = getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tlen) == 0
        identity.auditTokenObtained = tokenOK
        var attrs: [CFString: Any]
        if tokenOK {
            attrs = [kSecGuestAttributeAudit: withUnsafeBytes(of: &token) { Data($0) }]
            identity.guestSource = "audit"
        } else {
            attrs = [kSecGuestAttributePid: Int(pid)]
            identity.guestSource = "pid"
        }
        var guest: SecCode?
        let st = SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [], &guest)
        guard st == errSecSuccess, let code = guest else {
            identity.error = "SecCodeCopyGuestWithAttributes status \(st)"
            return identity
        }
        var sc: SecStaticCode?
        if SecCodeCopyStaticCode(code, [], &sc) == errSecSuccess, let s = sc {
            let info = signingInfo(s)
            identity.codeIdentifier = info.identifier
            identity.cdhash = info.cdhash
            if let e = info.error { identity.error = e }
        }
        if let reqString = appRequirement {
            identity.appRequirement = reqString
            identity.matchesAppRequirement = check(code, reqString)
        }
        identity.matchesDeveloperIDAnchor = check(code, developerIDAnchor)
        return identity
    }

    static func check(_ code: SecCode, _ reqString: String) -> Bool {
        var req: SecRequirement?
        guard SecRequirementCreateWithString(reqString as CFString, [], &req) == errSecSuccess, let r = req else { return false }
        return SecCodeCheckValidity(code, [], r) == errSecSuccess
    }
}

public enum ProcessProbe {
    public static func stamp(pid: Int32) -> ProcessStamp? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard rc == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return ProcessStamp(pid: pid, startSec: Int64(info.kp_proc.p_starttime.tv_sec), startUsec: Int32(info.kp_proc.p_starttime.tv_usec))
    }

    public static func alive(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

public enum ProofLog {
    static let lock = NSLock()
    public static func append(_ file: String, _ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let url = ProofPaths.stateDir.appendingPathComponent(file)
        let text = "\(Codec.iso.string(from: Date())) \(ProofPaths.redactHome(line))\n"
        if let h = FileHandle(forWritingAtPath: url.path) {
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            h.closeFile()
        } else {
            try? Data(text.utf8).write(to: url)
        }
        FileHandle.standardError.write(Data(text.utf8))
    }
}
