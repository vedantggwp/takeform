import SwiftUI
import AppKit
import ServiceManagement
import ProofWire

struct Metrics: Codable {
    var appPid = getpid()
    var appProcessStart: Date?
    var auto = false
    var bundlePath = ProofPaths.redactHome(Bundle.main.bundlePath)
    var bundleIdentifier = Bundle.main.bundleIdentifier ?? "none"
    var sandboxed = ProofPaths.isSandboxed
    var serviceSpawns: [ServiceSpawn] = []
    var coldStartMs: Double?
    var firstReceipt: Receipt?
    var bookmarkKind: String?
    var grantResult: String?
    var approvals: [Approval] = []
    var pairingSecondDecisions: [String] = []
    var revocations: [String] = []
    var relaunches: [ServiceSpawn] = []
    var agent: AgentResult?
    var windowNumber: Int?
    var errors: [String] = []
}

struct ServiceSpawn: Codable {
    var spawnedAt: Date
    var socketReadyAt: Date?
    var spawnToSocketMs: Double?
    var servicePid: Int32?
    var reason: String
}

struct Approval: Codable {
    var requestID: String
    var seenAt: Date
    var approvedAt: Date
    var role: CLIRole
    var result: String
}

struct AgentResult: Codable {
    var action: String
    var statusBefore: String
    var statusAfter: String
    var error: String?
    var at: Date
}

@MainActor
final class AppModel: ObservableObject {
    @Published var serviceState = "not started"
    @Published var fixtureName: String?
    @Published var receipts: [Receipt] = []
    @Published var status: StatusReport?
    @Published var agentStatus = "not registered"
    @Published var lastError: String?
    @Published var lastLease: String?

    var metrics = Metrics()
    let env = ProcessInfo.processInfo.environment
    var auto: Bool { env["PROOF_AUTO"] == "1" }
    var timer: Timer?
    var relaunchStartedAt: Date?
    var started = false

    var servicePath: String {
        env["PROOF_SERVICE_PATH"] ?? Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("ProofService").path
    }

    func record(_ mutate: (inout Metrics) -> Void) {
        mutate(&metrics)
        try? ProofPaths.ensureStateDir()
        try? Codec.prettyEncoder.encode(metrics).write(to: ProofPaths.stateDir.appendingPathComponent("app-metrics.json"))
    }

    func fail(_ s: String) {
        lastError = s
        record { $0.errors.append(s) }
    }

    func start() {
        guard !started else { return }
        started = true
        if let s = ProcessProbe.stamp(pid: getpid()) {
            metrics.appProcessStart = Date(timeIntervalSince1970: Double(s.startSec) + Double(s.startUsec) / 1e6)
        }
        record { $0.auto = auto }
        Task { await runStartup() }
        timer = Timer.scheduledTimer(withTimeInterval: auto ? 0.2 : 0.5, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
    }

    func runStartup() async {
        let ok = await ensureService(reason: "startup")
        guard ok else { return }
        if let f = env["PROOF_FIXTURE"], !f.isEmpty { await grant(url: URL(fileURLWithPath: f)) }
        if auto {
            await describe()
        }
        if env["PROOF_REGISTER_AGENT"] == "1" { registerAgent() }
        if env["PROOF_UNREGISTER_AGENT"] == "1" { unregisterAgent() }
    }

    func ensureService(reason: String) async -> Bool {
        if UnixSocket.canConnect() { serviceState = "connected"; return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: servicePath)
        var e = env
        e["PROOF_APP_BINARY"] = Bundle.main.executablePath
        e["PROOF_HELPER_PATH"] = env["PROOF_HELPER_PATH"] ?? Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("ProofHelper").path
        p.environment = e
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        var spawn = ServiceSpawn(spawnedAt: Date(), reason: reason)
        do { try p.run() } catch {
            fail("service launch failed: \(error.localizedDescription)")
            serviceState = "launch failed"
            return false
        }
        spawn.servicePid = p.processIdentifier
        serviceState = "launching pid \(p.processIdentifier)"
        let ready = await Task.detached { () -> Bool in
            let t0 = Date()
            while Date().timeIntervalSince(t0) < 10 {
                if UnixSocket.canConnect() { return true }
                usleep(2000)
            }
            return false
        }.value
        if ready {
            spawn.socketReadyAt = Date()
            spawn.spawnToSocketMs = spawn.socketReadyAt!.timeIntervalSince(spawn.spawnedAt) * 1000
            serviceState = "connected (pid \(p.processIdentifier))"
        } else {
            serviceState = "socket never came up"
            fail("service socket not ready within 10 s")
        }
        record { m in
            if reason == "startup" { m.serviceSpawns.append(spawn) } else { m.relaunches.append(spawn) }
        }
        return ready
    }

    func send(_ command: Command, commandID: String = UUID().uuidString) async -> Response? {
        let req = Request(commandID: commandID, command: command)
        do {
            let r = try await Task.detached { try UnixSocket.request(req) }.value
            if case .receipt(let receipt) = r {
                receipts.insert(receipt, at: 0)
                if metrics.firstReceipt == nil, let start = metrics.appProcessStart {
                    let cold = receipt.issuedAt.timeIntervalSince(start) * 1000
                    record { $0.firstReceipt = receipt; $0.coldStartMs = cold }
                }
            }
            if case .rejected(let reason, let detail, _) = r { lastError = "\(reason.rawValue): \(detail)" }
            return r
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    func poll() async {
        if !UnixSocket.canConnect() {
            if relaunchStartedAt == nil { relaunchStartedAt = Date() }
            serviceState = "service gone, relaunching"
            _ = await ensureService(reason: "relaunch after connection failure")
            relaunchStartedAt = nil
            return
        }
        guard let r = await send(.status) else { return }
        if case .receipt(let receipt) = r, let data = receipt.result.data(using: .utf8), let s = try? Codec.decoder.decode(StatusReport.self, from: data) {
            status = s
            receipts.removeAll { $0.command == "status" }
            if auto {
                for p in s.pending where !metrics.approvals.contains(where: { $0.requestID == p.id }) {
                    let role = CLIRole(rawValue: env["PROOF_AUTO_ROLE"] ?? "proposer") ?? .proposer
                    await approve(p, role: role)
                }
                await handleControlFiles(s)
            }
        }
    }

    func handleControlFiles(_ s: StatusReport) async {
        let fm = FileManager.default
        let dir = ProofPaths.controlDir
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names {
            let path = dir.appendingPathComponent(name)
            switch name {
            case "revoke-all":
                for session in s.sessions where session.revokedAt == nil { await revoke(session) }
                try? fm.removeItem(at: path)
            case "cancel-current":
                if let a = s.attempts.current, a.state == "running" { await cancel(lease: a.lease) }
                try? fm.removeItem(at: path)
            case "describe":
                await describe()
                try? fm.removeItem(at: path)
            case "start-attempt":
                await startAttempt(seconds: 8)
                try? fm.removeItem(at: path)
            case "quit":
                try? fm.removeItem(at: path)
                NSApp.terminate(nil)
            default:
                if name.hasPrefix("shot-") {
                    screenshot(name: String(name.dropFirst(5)))
                    try? fm.removeItem(at: path)
                }
            }
        }
    }

    func screenshot(name: String) {
        guard let w = NSApp.windows.first(where: { $0.isVisible }) else { fail("screenshot \(name): no visible window"); return }
        record { $0.windowNumber = w.windowNumber }
        let id = CGWindowID(w.windowNumber)
        guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) else {
            fail("screenshot \(name): CGWindowListCreateImage returned nil")
            return
        }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let png = rep.representation(using: .png, properties: [:]) else { fail("screenshot \(name): png encode failed"); return }
        let dir = ProofPaths.stateDir.appendingPathComponent("screens")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do { try png.write(to: dir.appendingPathComponent("\(name).png")) } catch { fail("screenshot \(name): \(error.localizedDescription)") }
    }

    func approve(_ p: PendingSummary, role: CLIRole) async {
        let seen = Date()
        let r = await send(.approvePairing(requestID: p.id, role: role))
        let text: String
        if case .receipt(let rc)? = r { text = rc.result } else { text = r?.kind ?? "no response" }
        record { $0.approvals.append(Approval(requestID: p.id, seenAt: seen, approvedAt: Date(), role: role, result: text)) }
        if env["PROOF_DOUBLE_APPROVE"] == "1" {
            let second = await send(.approvePairing(requestID: p.id, role: role))
            record { $0.pairingSecondDecisions.append("\(p.id): \(second?.kind ?? "no response")") }
        }
    }

    func revoke(_ s: SessionSummary) async {
        let r = await send(.revokeSession(sessionID: s.id))
        record { $0.revocations.append("\(s.id): \(r?.kind ?? "no response")") }
    }

    func openFixture() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose the fixture clip the service may read"
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            Task { await self?.grant(url: url) }
        }
    }

    func grant(url: URL) async {
        var kind = "withSecurityScope"
        var data: Data
        do {
            data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            kind = "plain (withSecurityScope failed: \(error.localizedDescription))"
            do { data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) } catch {
                fail("bookmark failed: \(error.localizedDescription)")
                return
            }
        }
        let r = await send(.grantFixture(bookmark: data, name: url.lastPathComponent))
        fixtureName = url.lastPathComponent
        let text: String
        if case .receipt(let rc)? = r { text = rc.result } else { text = r?.kind ?? "no response" }
        record { $0.bookmarkKind = kind; $0.grantResult = text }
    }

    func describe() async { _ = await send(.describeFixture) }

    func startAttempt(seconds: Int) async {
        if case .receipt(let rc)? = await send(.startAttempt(seconds: seconds)) {
            lastLease = rc.result.split(separator: " ").dropFirst().first.map(String.init)
        }
    }

    func cancel(lease: String) async { _ = await send(.cancelAttempt(lease: lease)) }

    func agentService() -> SMAppService { SMAppService.agent(plistName: "com.takeform.proof.agent.plist") }

    func statusName(_ s: SMAppService.Status) -> String {
        switch s {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }

    func registerAgent() {
        let svc = agentService()
        let before = statusName(svc.status)
        var err: String?
        do { try svc.register() } catch { err = "\(error)" }
        let after = statusName(svc.status)
        agentStatus = "register: \(before) -> \(after)\(err.map { " error \($0)" } ?? "")"
        record { $0.agent = AgentResult(action: "register", statusBefore: before, statusAfter: after, error: err, at: Date()) }
    }

    func unregisterAgent() {
        let svc = agentService()
        let before = statusName(svc.status)
        var err: String?
        do { try svc.unregister() } catch { err = "\(error)" }
        let after = statusName(svc.status)
        agentStatus = "unregister: \(before) -> \(after)\(err.map { " error \($0)" } ?? "")"
        record { $0.agent = AgentResult(action: "unregister", statusBefore: before, statusAfter: after, error: err, at: Date()) }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Takeform Proof").font(.title2).bold()
                Spacer()
                Text("service: \(model.serviceState)").font(.caption).monospaced()
            }
            HStack {
                Button("Open fixture…") { model.openFixture() }
                Text(model.fixtureName ?? "no fixture granted").font(.caption)
                Spacer()
                Text(model.metrics.coldStartMs.map { String(format: "cold start %.0f ms", $0) } ?? "cold start pending").font(.caption).monospaced()
            }
            HStack {
                Button("Describe fixture") { Task { await model.describe() } }
                Button("Start helper (8 s)") { Task { await model.startAttempt(seconds: 8) } }
                Button("Cancel attempt") {
                    if let l = model.status?.attempts.current?.lease { Task { await model.cancel(lease: l) } }
                }
                Button("Register launch agent") { model.registerAgent() }
                Button("Unregister") { model.unregisterAgent() }
            }
            Text(model.agentStatus).font(.caption).monospaced()
            if let a = model.status?.attempts.current {
                Text("attempt \(a.lease.prefix(8)) pid \(a.stamp.pid) start \(a.stamp.startSec).\(a.stamp.startUsec) state \(a.state) cancelToExit \(a.cancelToExitMs.map { String(format: "%.1f ms", $0) } ?? "-")")
                    .font(.caption).monospaced()
            }
            GroupBox("Pairing requests (creator approves)") {
                if let pending = model.status?.pending, !pending.isEmpty {
                    ForEach(pending) { p in
                        HStack {
                            Text("\(p.label) pid \(p.peerPid) \(p.peerIdentifier ?? "unsigned")").font(.caption).monospaced()
                            Spacer()
                            Button("Approve as proposer") { Task { await model.approve(p, role: .proposer) } }
                            Button("Approve as creatorDelegate") { Task { await model.approve(p, role: .creatorDelegate) } }
                        }
                    }
                } else {
                    Text("none").font(.caption)
                }
            }
            GroupBox("Sessions") {
                if let sessions = model.status?.sessions, !sessions.isEmpty {
                    ForEach(sessions) { s in
                        HStack {
                            Text("\(s.id.prefix(8)) \(s.role.rawValue) \(s.revokedAt == nil ? "active" : "revoked")").font(.caption).monospaced()
                            Spacer()
                            if s.revokedAt == nil { Button("Revoke") { Task { await model.revoke(s) } } }
                        }
                    }
                } else {
                    Text("none").font(.caption)
                }
            }
            GroupBox("Receipts (newest first)") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.receipts, id: \.commandID) { r in
                            Text("\(Codec.iso.string(from: r.issuedAt)) \(r.command) by \(r.principal.label) id \(r.commandID.prefix(8))\n  \(r.result.prefix(220))")
                                .font(.caption2).monospaced()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let e = model.lastError { Text(e).font(.caption).foregroundStyle(.red) }
        }
        .padding()
        .onAppear { model.start() }
    }
}

@main
struct ProofAppMain: App {
    @StateObject var model = AppModel()

    var body: some Scene {
        WindowGroup("Takeform Proof") {
            ContentView().environmentObject(model).frame(minWidth: 820, minHeight: 620)
        }
    }
}
