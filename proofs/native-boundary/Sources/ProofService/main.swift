import Foundation
import CryptoKit
import Darwin
import ProofWire

let serviceStartedAt = Date()
let servicePid = getpid()
let serviceStamp = ProcessProbe.stamp(pid: servicePid)
let env = ProcessInfo.processInfo.environment
let idleSeconds = Double(env["PROOF_IDLE_SECONDS"] ?? "") ?? 90
let pairGrantDelayMs = Int(env["PROOF_PAIR_GRANT_DELAY_MS"] ?? "0") ?? 0

func log(_ s: String) { ProofLog.append("service.log", "[service \(servicePid)] \(s)") }

func sibling(_ name: String) -> String {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN * 4))
    let length = proc_pidpath(getpid(), &path, UInt32(path.count))
    let me = length > 0
        ? URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
        : URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return me.deletingLastPathComponent().appendingPathComponent(name).path
}

struct Session: Codable {
    var id: String
    var tokenDigest: String
    var role: CLIRole
    var label: String
    var createdAt: Date
    var revokedAt: Date?
}

func tokenDigest(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
}

final class PendingPairing {
    let id = UUID().uuidString
    let label: String
    let peer: PeerIdentity
    let requestedAt = Date()
    let sem = DispatchSemaphore(value: 0)
    var grant: PairingGrant?
    init(label: String, peer: PeerIdentity) { self.label = label; self.peer = peer }
}

struct Persisted: Codable {
    var sessions: [String: Session] = [:]
    var receipts: [String: Receipt] = [:]
    var bookmark: Data?
    var fixtureName: String?
}

final class Service {
    let lock = NSLock()
    var persisted = Persisted()
    var attempts = AttemptStore()
    var pending: [String: PendingPairing] = [:]
    var lastActivity = Date()
    var fixture: FixtureAccess?
    var helper: Process?
    let appRequirement: String?
    let appBinary: String
    let helperPath: String

    var stateFile: URL { ProofPaths.stateDir.appendingPathComponent("service-state.json") }
    var attemptsFile: URL { ProofPaths.stateDir.appendingPathComponent("attempts.json") }

    init() {
        appBinary = env["PROOF_APP_BINARY"] ?? sibling("ProofApp")
        helperPath = env["PROOF_HELPER_PATH"] ?? sibling("ProofHelper")
        let identity = CodeIdentity.staticIdentity(binaryPath: appBinary)
        if let id = identity.identifier, let cd = identity.cdhash {
            appRequirement = CodeIdentity.requirement(identifier: id, cdhash: cd)
        } else {
            appRequirement = nil
        }
        log("app binary \(appBinary) identity \(identity.identifier ?? "none") cdhash \(identity.cdhash ?? "none") error \(identity.error ?? "none")")
        log("app requirement \(appRequirement ?? "none")")
        log("helper path \(helperPath)")
        load()
        reconcile()
    }

    func load() {
        if let d = try? Data(contentsOf: stateFile), let p = try? Codec.decoder.decode(Persisted.self, from: d) { persisted = p }
        if let d = try? Data(contentsOf: attemptsFile), let a = try? Codec.decoder.decode(AttemptStore.self, from: d) { attempts = a }
        log("loaded \(persisted.sessions.count) sessions, \(persisted.receipts.count) receipts, attempt \(attempts.current?.lease ?? "none") state \(attempts.current?.state ?? "none")")
    }

    func persist() {
        try? Codec.prettyEncoder.encode(persisted).write(to: stateFile)
        try? Codec.prettyEncoder.encode(attempts).write(to: attemptsFile)
    }

    func touch() { lock.lock(); lastActivity = Date(); lock.unlock() }

    func reconcile() {
        guard var a = attempts.current, a.state == "running" else { return }
        let live = ProcessProbe.stamp(pid: a.stamp.pid)
        let classification: String
        var signalled = false
        let verified = a.handshake?.lease == a.lease && a.handshake?.stamp == a.stamp
        if !verified {
            classification = "interrupted-unverified-helper-handshake"
        } else if let live, live == a.stamp {
            classification = "interrupted-helper-alive-same-start-time"
            kill(a.stamp.pid, SIGTERM)
            signalled = true
        } else if live == nil {
            classification = "interrupted-helper-gone"
        } else {
            classification = "interrupted-pid-reused-start-time-mismatch"
        }
        let elapsed = serviceStamp.map { Date().timeIntervalSince(Date(timeIntervalSince1970: Double($0.startSec) + Double($0.startUsec) / 1e6)) * 1000 } ?? -1
        let record = ReconcileRecord(at: Date(), lease: a.lease, recordedStamp: a.stamp, liveStamp: live, classification: classification, signalled: signalled, method: "lease+pid+start-time", msSinceServiceProcessStart: elapsed)
        a.state = "interrupted"
        a.notes.append("reconcile: \(classification), signalled \(signalled)")
        attempts.history.append(a)
        attempts.current = nil
        attempts.reconciles.append(record)
        persist()
        log("reconcile \(classification) lease \(a.lease) pid \(a.stamp.pid) signalled \(signalled) live \(live.map { "\($0.startSec).\($0.startUsec)" } ?? "none") recorded \(a.stamp.startSec).\(a.stamp.startUsec)")
    }

    func resolveFixture(bookmark: Data, name: String) -> FixtureAccess {
        var stale = false
        var resolvedWith = "withSecurityScope"
        var url: URL?
        var err: String?
        do {
            url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            err = "withSecurityScope: \(error.localizedDescription)"
            resolvedWith = "plain"
            do {
                url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch {
                err = (err ?? "") + "; plain: \(error.localizedDescription)"
                url = nil
            }
        }
        guard let u = url else {
            return FixtureAccess(name: name, resolvedWith: "failed", stale: stale, startAccessing: false, readOK: false, size: nil, headHex: nil, error: err, sandboxed: ProofPaths.isSandboxed)
        }
        let access = u.startAccessingSecurityScopedResource()
        defer { if access { u.stopAccessingSecurityScopedResource() } }
        var readOK = false
        var size: Int64?
        var head: String?
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: u.path)
            size = (attrs[.size] as? NSNumber)?.int64Value
            let h = try FileHandle(forReadingFrom: u)
            let bytes = h.readData(ofLength: 16)
            h.closeFile()
            head = bytes.map { String(format: "%02x", $0) }.joined()
            readOK = bytes.count == 16
        } catch {
            err = (err.map { $0 + "; " } ?? "") + "read: \(error.localizedDescription)"
        }
        return FixtureAccess(name: name, resolvedWith: resolvedWith, stale: stale, startAccessing: access, readOK: readOK, size: size, headHex: head, error: err, sandboxed: ProofPaths.isSandboxed)
    }

    func fixtureURL() -> URL? {
        guard let b = persisted.bookmark else { return nil }
        var stale = false
        return (try? URL(resolvingBookmarkData: b, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: b, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
    }

    func status() -> StatusReport {
        let sessions = persisted.sessions.values.sorted { $0.createdAt < $1.createdAt }.map {
            SessionSummary(id: $0.id, label: $0.label, role: $0.role, createdAt: $0.createdAt, revokedAt: $0.revokedAt)
        }
        let pendingList = pending.values.sorted { $0.requestedAt < $1.requestedAt }.map {
            PendingSummary(id: $0.id, label: $0.label, peerPid: $0.peer.pid, peerIdentifier: $0.peer.codeIdentifier, requestedAt: $0.requestedAt)
        }
        return StatusReport(servicePid: servicePid, serviceStartedAt: serviceStartedAt, serviceStamp: serviceStamp, appRequirement: appRequirement, sandboxed: ProofPaths.isSandboxed, socketPath: ProofPaths.redactHome(ProofPaths.socketPath), idleSeconds: idleSeconds, sessions: sessions, pending: pendingList, fixture: fixture, attempts: attempts, receiptCount: persisted.receipts.count)
    }

    func dispatch(_ req: Request, fd: Int32) -> Response {
        touch()
        let peer = CodeIdentity.peer(of: fd, appRequirement: appRequirement)
        lock.lock()
        defer { lock.unlock() }
        let principal: Principal
        if peer.matchesAppRequirement {
            principal = .creator(pid: peer.pid, codeIdentifier: peer.codeIdentifier ?? "unknown")
        } else if let t = req.token {
            let digest = tokenDigest(t)
            guard let s = persisted.sessions.values.first(where: { $0.tokenDigest == digest }) else {
                return .rejected(reason: .unknownSession, detail: "token does not match any session", peer: peer)
            }
            if let r = s.revokedAt {
                return .rejected(reason: .revokedSession, detail: "session \(s.id) revoked at \(Codec.iso.string(from: r))", peer: peer)
            }
            principal = .pairedCLI(session: s.id, role: s.role)
        } else {
            principal = .unauthenticated(pid: peer.pid, codeIdentifier: peer.codeIdentifier)
        }
        log("\(req.command.name) from \(principal.label) claimed \(req.claimedActor ?? "-") id \(req.commandID.prefix(8))")
        switch req.command.policy {
        case .anyone:
            break
        case .creatorOrPaired:
            if case .unauthenticated = principal {
                return .rejected(reason: .unauthenticated, detail: "\(req.command.name) needs creator or pairedCLI; connection classified \(principal.label); payload claimed actor \(req.claimedActor ?? "none") ignored", peer: peer)
            }
        case .creatorOnly:
            guard case .creator = principal else {
                return .rejected(reason: .unauthorized, detail: "\(req.command.name) is creator only; connection classified \(principal.label); payload claimed actor \(req.claimedActor ?? "none") ignored", peer: peer)
            }
        }
        if case .requestPairing(let label) = req.command {
            let p = PendingPairing(label: label, peer: peer)
            pending[p.id] = p
            log("pairing request \(p.id) from pid \(peer.pid) \(peer.codeIdentifier ?? "unsigned")")
            lock.unlock()
            let waited = p.sem.wait(timeout: .now() + 120)
            lock.lock()
            pending.removeValue(forKey: p.id)
            if waited == .success, let g = p.grant { return .paired(g) }
            return .rejected(reason: .pairingTimeout, detail: "no approval within 120 s", peer: peer)
        }
        if let first = persisted.receipts[req.commandID] {
            log("replay of \(req.commandID.prefix(8)) returns first receipt")
            return .receipt(first)
        }
        let result: String
        switch execute(req.command, principal: principal) {
        case .success(let r): result = r
        case .failure(let e): return .rejected(reason: e.reason, detail: e.detail, peer: peer)
        }
        let receipt = Receipt(commandID: req.commandID, command: req.command.name, principal: principal, peer: peer, claimedActor: req.claimedActor, result: result, issuedAt: Date(), serviceStartedAt: serviceStartedAt, servicePid: servicePid)
        persisted.receipts[req.commandID] = receipt
        persist()
        return .receipt(receipt)
    }

    struct Failure: Error { let reason: Rejection; let detail: String }

    func execute(_ command: Command, principal: Principal) -> Result<String, Failure> {
        switch command {
        case .requestPairing:
            return .failure(Failure(reason: .invalidRequest, detail: "unreachable"))
        case .approvePairing(let requestID, let role):
            guard let p = pending[requestID] else { return .failure(Failure(reason: .invalidRequest, detail: "no pending request \(requestID)")) }
            guard p.grant == nil else {
                return .failure(Failure(reason: .pairingAlreadyDecided, detail: "pairing request \(requestID) already has a decision"))
            }
            var tokenBytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, tokenBytes.count, &tokenBytes)
            let token = tokenBytes.map { String(format: "%02x", $0) }.joined()
            let s = Session(id: UUID().uuidString, tokenDigest: tokenDigest(token), role: role, label: p.label, createdAt: Date())
            persisted.sessions[s.id] = s
            p.grant = PairingGrant(requestID: p.id, sessionID: s.id, token: token, role: role, requestedAt: p.requestedAt, approvedAt: s.createdAt)
            if pairGrantDelayMs > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(pairGrantDelayMs)) { p.sem.signal() }
            } else {
                p.sem.signal()
            }
            return .success("approved request \(requestID) as session \(s.id) role \(role.rawValue) for peer pid \(p.peer.pid) \(p.peer.codeIdentifier ?? "unsigned"); request to approval \(Int(s.createdAt.timeIntervalSince(p.requestedAt) * 1000)) ms")
        case .revokeSession(let id):
            guard var s = persisted.sessions[id] else { return .failure(Failure(reason: .unknownSession, detail: "no session \(id)")) }
            s.revokedAt = Date()
            persisted.sessions[id] = s
            return .success("revoked session \(id)")
        case .grantFixture(let bookmark, let name):
            persisted.bookmark = bookmark
            persisted.fixtureName = name
            fixture = resolveFixture(bookmark: bookmark, name: name)
            return .success("granted fixture \(name); " + Codec.prettyString(fixture))
        case .describeFixture:
            guard let bookmark = persisted.bookmark, let name = persisted.fixtureName else {
                return .failure(Failure(reason: .noFixture, detail: "no fixture granted by the creator"))
            }
            let fresh = resolveFixture(bookmark: bookmark, name: name)
            fixture = fresh
            return .success("fixture \(fresh.name) size \(fresh.size.map(String.init) ?? "unknown") bytes head \(fresh.headHex ?? "none") readOK \(fresh.readOK) via \(fresh.resolvedWith) startAccessing \(fresh.startAccessing) sandboxed \(fresh.sandboxed)")
        case .startAttempt(let seconds):
            if let a = attempts.current, a.state == "running" { return .failure(Failure(reason: .attemptRunning, detail: "attempt \(a.lease) still running")) }
            return startAttempt(seconds: seconds)
        case .cancelAttempt(let lease):
            return cancel(lease: lease, by: principal)
        case .attemptWrite(let lease, let note):
            guard var a = attempts.current else { return .failure(Failure(reason: .unknownLease, detail: "no attempt")) }
            guard a.lease == lease, a.state == "running" else {
                return .failure(Failure(reason: .staleLease, detail: "lease \(lease) is not the running attempt (current \(a.lease) state \(a.state)); write rejected"))
            }
            a.notes.append(note)
            attempts.current = a
            return .success("write accepted for lease \(lease): \(note)")
        case .status:
            return .success(Codec.prettyString(status()))
        case .shutdown:
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { log("shutdown by creator"); exit(0) }
            return .success("shutting down")
        }
    }

    func startAttempt(seconds: Int) -> Result<String, Failure> {
        let lease = UUID().uuidString
        let p = Process()
        p.executableURL = URL(fileURLWithPath: helperPath)
        var args = ["--lease", lease, "--seconds", "\(seconds)"]
        if let u = fixtureURL() { args += ["--fixture", u.path] }
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        let startedAt = Date()
        do { try p.run() } catch {
            return .failure(Failure(reason: .helperFailed, detail: "launch \(ProofPaths.redactHome(helperPath)): \(error.localizedDescription)"))
        }
        let pid = p.processIdentifier
        guard let stamp = ProcessProbe.stamp(pid: pid) else {
            return .failure(Failure(reason: .helperFailed, detail: "no kinfo_proc for pid \(pid)"))
        }
        let handshakeData: Data
        do {
            handshakeData = try readHelperLine(from: pipe.fileHandleForReading.fileDescriptor)
        } catch {
            kill(pid, SIGTERM)
            return .failure(Failure(reason: .helperFailed, detail: "helper handshake read failed: \(error)"))
        }
        guard let event = try? Codec.decoder.decode([String: String].self, from: handshakeData),
              event["event"] == "started",
              event["lease"] == lease,
              event["pid"] == "\(pid)",
              event["startSec"] == "\(stamp.startSec)",
              event["startUsec"] == "\(stamp.startUsec)" else {
            kill(pid, SIGTERM)
            return .failure(Failure(reason: .helperFailed, detail: "helper handshake did not match lease, pid and process start time"))
        }
        var a = AttemptRecord(lease: lease, stamp: stamp, state: "running", seconds: seconds, startedAt: startedAt)
        a.handshake = HelperHandshake(lease: lease, stamp: stamp, verifiedAt: Date())
        a.helperEvents.append(ProofPaths.redactHome(String(decoding: handshakeData, as: UTF8.self)))
        a.notes.append("helper launched pid \(pid) start \(stamp.startSec).\(stamp.startUsec)")
        attempts.current = a
        helper = p
        persist()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            guard let self else { return }
            let text = String(decoding: d, as: UTF8.self)
            self.lock.lock()
            if var cur = self.attempts.current, cur.lease == lease {
                for line in text.split(separator: "\n") where !line.isEmpty { cur.helperEvents.append(ProofPaths.redactHome(String(line))) }
                self.attempts.current = cur
            }
            self.lock.unlock()
        }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.lock.lock()
            if var cur = self.attempts.current, cur.lease == lease {
                cur.exitedAt = Date()
                cur.exitCode = proc.terminationStatus
                if let c = cur.cancelRequestedAt {
                    cur.cancelToExitMs = cur.exitedAt!.timeIntervalSince(c) * 1000
                    cur.state = "cancelled"
                } else {
                    cur.state = "completed"
                }
                self.attempts.current = cur
                self.persist()
                log("helper pid \(proc.processIdentifier) exited \(proc.terminationStatus) state \(cur.state) cancelToExitMs \(cur.cancelToExitMs.map { String(format: "%.1f", $0) } ?? "-")")
            }
            self.lock.unlock()
        }
        log("attempt \(lease) helper pid \(pid) start \(stamp.startSec).\(stamp.startUsec) seconds \(seconds)")
        return .success("attempt \(lease) helper pid \(pid) startSec \(stamp.startSec) startUsec \(stamp.startUsec)")
    }

    func cancel(lease: String, by principal: Principal) -> Result<String, Failure> {
        guard var a = attempts.current else { return .failure(Failure(reason: .unknownLease, detail: "no attempt")) }
        guard a.lease == lease else { return .failure(Failure(reason: .staleLease, detail: "lease \(lease) is not current (\(a.lease))")) }
        guard a.state == "running" else { return .failure(Failure(reason: .staleLease, detail: "attempt \(lease) already \(a.state)")) }
        guard a.handshake?.lease == a.lease, a.handshake?.stamp == a.stamp else {
            return .failure(Failure(reason: .helperFailed, detail: "attempt \(lease) has no verified helper lease and start-time handshake; no signal sent"))
        }
        let live = ProcessProbe.stamp(pid: a.stamp.pid)
        guard live == a.stamp else {
            a.state = "interrupted"
            a.notes.append("cancel refused to signal pid \(a.stamp.pid): live stamp \(live.map { "\($0.startSec).\($0.startUsec)" } ?? "none") differs from recorded \(a.stamp.startSec).\(a.stamp.startUsec)")
            attempts.current = a
            persist()
            return .success("not signalled: pid \(a.stamp.pid) start time mismatch, attempt classified interrupted")
        }
        a.cancelRequestedAt = Date()
        attempts.current = a
        kill(a.stamp.pid, SIGTERM)
        let deadline = Date().addingTimeInterval(5)
        lock.unlock()
        while Date() < deadline {
            usleep(2000)
            lock.lock()
            let done = attempts.current?.exitedAt != nil
            lock.unlock()
            if done { break }
        }
        lock.lock()
        let cur = attempts.current ?? a
        persist()
        return .success("cancelled by \(principal.label): pid \(cur.stamp.pid) SIGTERM to exit \(cur.cancelToExitMs.map { String(format: "%.1f", $0) } ?? "timeout") ms exit \(cur.exitCode.map(String.init) ?? "-")")
    }

    func idleWatch() {
        Thread {
            while true {
                sleep(2)
                self.lock.lock()
                let idle = Date().timeIntervalSince(self.lastActivity)
                let busy = (self.attempts.current?.state == "running") || !self.pending.isEmpty
                self.lock.unlock()
                if idle > idleSeconds && !busy {
                    log("idle \(Int(idle)) s, exiting")
                    exit(0)
                }
            }
        }.start()
    }
}

func readHelperLine(from fd: Int32) throws -> Data {
    var data = Data()
    var byte: UInt8 = 0
    while data.count < 4096 {
        let count = Darwin.read(fd, &byte, 1)
        if count == 0 { throw WireError.closed }
        if count < 0 {
            if errno == EINTR { continue }
            throw WireError.io("helper handshake read", errno)
        }
        if byte == 0x0A { return data }
        data.append(byte)
    }
    throw WireError.tooLarge
}

signal(SIGPIPE, SIG_IGN)
try ProofPaths.ensureStateDir()
let service = Service()
signal(SIGTERM) { _ in
    log("SIGTERM, exiting")
    exit(0)
}
let listenFD = try UnixSocket.listen()
log("listening on \(ProofPaths.socketPath) sandboxed \(ProofPaths.isSandboxed) idle \(idleSeconds) s stamp \(serviceStamp.map { "\($0.startSec).\($0.startUsec)" } ?? "none")")
service.idleWatch()
while true {
    let cfd = accept(listenFD, nil, nil)
    if cfd < 0 { continue }
    Thread {
        defer { close(cfd) }
        let req: Request
        do { req = try Wire.receive(Request.self, from: cfd) } catch {
            try? Wire.send(Response.rejected(reason: .invalidRequest, detail: "\(error)", peer: nil), to: cfd)
            return
        }
        let response = service.dispatch(req, fd: cfd)
        try? Wire.send(response, to: cfd)
    }.start()
}
