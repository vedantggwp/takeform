import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import TakeformCore
import TakeformSupport
import TakeformWorkspace
import TakeformAppAuthorityWire
import TakeformAppServiceClient

private let authorityClient = AppAuthorityServiceClient()

private final class DroppedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL] = []
    func append(_ url: URL) { lock.lock(); values.append(url); lock.unlock() }
    func snapshot() -> [URL] { lock.lock(); defer { lock.unlock() }; return values }
}

@MainActor
final class TakeformAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppAppearance.applyStoredPreference()
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await authorityClient.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private enum AppAppearance: String, CaseIterable, Identifiable {
    static let defaultsKey = "takeform.appAppearance"
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    @MainActor static func applyStoredPreference() { apply(rawValue: UserDefaults.standard.string(forKey: defaultsKey)) }
    @MainActor static func apply(rawValue: String?) {
        switch rawValue.flatMap(Self.init(rawValue:)) ?? .system {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

@main
struct TakeformApp: App {
    @NSApplicationDelegateAdaptor(TakeformAppDelegate.self) private var appDelegate
    @StateObject private var workspace = WorkspaceModel(client: authorityClient)

    var body: some Scene {
        WindowGroup("Takeform", id: "main") {
            WorkspaceView(model: workspace)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Channel…") { workspace.beginNewChannel() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open Project…") { workspace.openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Channel") {
                Button("Rename Channel…") { workspace.showRename = true }
                    .disabled(workspace.document?.channel == nil)
                Divider()
                Button("Undo") { workspace.submit(.undo) }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(workspace.document == nil)
                Button("Redo") { workspace.submit(.redo) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(workspace.document == nil)
            }
            CommandMenu("CLI Access") {
                Button("Pair CLI…") { workspace.showPairing = true }
                    .disabled(workspace.document == nil)
            }
        }
        Settings { SettingsView() }
    }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var snapshot: WorkspaceSnapshot?
    @Published var selectedEpisodeID: UUID?
    @Published var status = "Open a project to begin."
    @Published var error: WorkspaceFailure?
    @Published var isWorking = false
    @Published var showRename = false
    @Published var showPairing = false
    @Published var showNewChannel = false
    @Published var pendingRebindURL: URL?
    @Published private(set) var cliGrants: [CLIPairingSummary] = []
    @Published var selectedGrantID: UUID?
    @Published private(set) var importOutcomes: [ManagedImportOutcome] = []
    @Published var selectedAssetID: UUID?
    @Published var isDropTargeted = false

    private let client: any WorkspaceClient
    private var importTask: Task<Void, Never>?

    init(client: any WorkspaceClient) { self.client = client }

    var document: ProjectDocument? { snapshot?.document }
    var packageURL: URL? { snapshot?.packageURL }
    var selectedEpisode: Episode? { document?.episodes.first { $0.id == selectedEpisodeID } }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Takeform project folder"
        panel.prompt = "Open Project"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.open(url, rebind: false)
        }
    }

    func open(_ url: URL, rebind: Bool) {
        Task {
            isWorking = true; error = nil
            defer { isWorking = false }
            do {
                let result = try await client.open(packageURL: url, rebindMovedPackage: rebind)
                snapshot = result
                cliGrants = (try? await client.listCLIGrants(packageURL: url)) ?? []
                selectedGrantID = cliGrants.contains(where: { $0.id == selectedGrantID }) ? selectedGrantID : nil
                pendingRebindURL = nil
                selectedEpisodeID = result.document.episodes.first?.id
                status = rebind ? "Rebound project at revision \(result.document.revision.value). Previous CLI grants were invalidated; pair again." : "Opened revision \(result.document.revision.value)."
            } catch let failure as WorkspaceFailure {
                pendingRebindURL = failure == .copyDecisionRequired ? url : nil
                error = failure; status = failure.errorDescription ?? "Unable to open project."
            } catch {
                status = "Unable to open project. No changes were made."
            }
        }
    }

    func beginNewChannel() { showNewChannel = true }

    func chooseMedia() {
        guard let packageURL else { error = .rejected("Open a project before importing media"); return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.message = "Choose footage to copy into this Takeform project"; panel.prompt = "Import footage"
        panel.begin { [weak self] response in
            guard response == .OK else { self?.status = "Media import cancelled."; return }
            self?.importMedia(panel.urls, into: packageURL)
        }
    }

    func importDroppedMedia(_ urls: [URL]) {
        guard let packageURL else { error = .rejected("Open a project before importing media"); return }
        importMedia(urls, into: packageURL)
    }

    func cancelMediaImport() {
        importTask?.cancel()
        status = "Cancelling media import after the current file boundary…"
    }

    private func importMedia(_ urls: [URL], into packageURL: URL) {
        guard !urls.isEmpty else { return }
        importTask?.cancel()
        importTask = Task { [weak self] in
            guard let self else { return }
            self.isWorking = true
            self.importOutcomes = []
            defer { self.isWorking = false; self.importTask = nil }
            do {
                let outcomes = try await self.client.importMedia(packageURL: packageURL, sources: urls)
                self.importOutcomes = outcomes
                if Task.isCancelled { self.status = "Media import cancelled."; return }
                self.status = outcomes.map(Self.importMessage).joined(separator: "\n")
                self.snapshot = try await self.client.open(packageURL: packageURL, rebindMovedPackage: false)
            } catch let failure as WorkspaceFailure { self.error = failure; self.status = failure.errorDescription ?? "Import failed." }
            catch { self.status = "Import failed without committing incomplete media." }
        }
    }

    static func importMessage(_ outcome: ManagedImportOutcome) -> String {
        switch outcome {
        case .imported(let asset): "Imported \(asset.filename) · \(asset.byteLength) bytes"
        case .duplicate(_, let filename): "Already managed: \(filename)"
        case .cancelled(let filename): "Cancelled \(filename)"
        case .failed(let filename, let reason): "Failed \(filename): \(reason)"
        }
    }

    func createChannel(name: String, initialRecipe: [String: String]) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(name).takeform"
        panel.message = "Choose where to create this Takeform project"
        panel.prompt = "Create Project"
        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { self.status = "Channel creation cancelled."; return }
            guard !FileManager.default.fileExists(atPath: url.path) else { self.error = .rejected("Choose a new project folder; that destination already exists"); self.status = self.error?.errorDescription ?? "Channel creation failed."; return }
            Task {
                self.isWorking = true; self.error = nil
                defer { self.isWorking = false }
                do {
                    let created = try await self.client.createChannelPackage(packageURL: url, name: name, initialRecipe: initialRecipe)
                    let document = created.document
                    self.snapshot = created
                    self.cliGrants = (try? await self.client.listCLIGrants(packageURL: url)) ?? []
                    self.status = "Created \(name) at revision \(document.revision.value)."
                } catch let failure as WorkspaceFailure { self.error = failure; self.status = failure.errorDescription ?? "Channel creation failed." }
                catch { self.status = "Channel creation failed. No project changes were committed." }
            }
        }
    }

    func rebindPendingProject() {
        guard let pendingRebindURL else { return }
        open(pendingRebindURL, rebind: true)
    }

    func submit(_ command: ProjectCommand) {
        guard let document, let packageURL else { return }
        Task {
            isWorking = true; error = nil
            defer { isWorking = false }
            do {
                let result = try await client.execute(packageURL: packageURL, envelope: CommandEnvelope(expectedRevision: document.revision, command: command))
                status = WorkspacePresentation.commandMessage(result)
                if case .applied(let next) = result.outcome {
                    snapshot = WorkspaceSnapshot(document: next, projectionMatches: true, packageURL: packageURL)
                    selectedEpisodeID = selectedEpisodeID ?? next.episodes.first?.id
                }
            } catch let failure as WorkspaceFailure {
                error = failure; status = failure.errorDescription ?? "No change was committed."
            } catch { status = "No change was committed." }
        }
    }

    func pairCLI() {
        guard let packageURL else { return }
        Task {
            isWorking = true; defer { isWorking = false }
            do {
                try await client.pairCLI(packageURL: packageURL, label: "Takeform CLI", expiresAt: Date().addingTimeInterval(60 * 60 * 24 * 30))
                cliGrants = try await client.listCLIGrants(packageURL: packageURL)
                status = "CLI access paired for this project."
            } catch let failure as WorkspaceFailure { error = failure; status = failure.errorDescription ?? "CLI pairing failed." }
            catch { status = "CLI pairing failed." }
        }
    }

    func revokeCLI() {
        guard let packageURL, let selectedGrantID else { error = .rejected("Select a CLI grant to revoke"); return }
        Task {
            isWorking = true; defer { isWorking = false }
            do { try await client.revokeCLI(packageURL: packageURL, grantID: selectedGrantID); cliGrants = try await client.listCLIGrants(packageURL: packageURL); self.selectedGrantID = nil; status = "CLI access revoked." }
            catch let failure as WorkspaceFailure { error = failure; status = failure.errorDescription ?? "CLI revocation failed." }
            catch { status = "CLI revocation failed." }
        }
    }
}

private struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var channelName = ""
    @State private var recipeKey = ""
    @State private var recipeValue = ""
    @State private var episodeName = ""
    @State private var overrideKey = ""
    @State private var overrideValue = ""

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Label(ProductIdentity.declared.displayName, systemImage: "rectangle.3.group")
                    .font(.headline)
                    .accessibilityIdentifier("takeform-title")
                if let document = model.document {
                    Label(document.channel?.name ?? "Untitled channel", systemImage: "rectangle.stack")
                    Text("Revision \(document.revision.value)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Divider()
                    Text("Episodes").font(.subheadline.weight(.semibold))
                    List(document.episodes, selection: $model.selectedEpisodeID) { episode in
                        VStack(alignment: .leading) {
                            Text(episode.name)
                            Text("Recipe \(episode.recipeVersion)").font(.caption).foregroundStyle(.secondary)
                        }.tag(episode.id)
                    }
                } else {
                    ContentUnavailableView("No project open", systemImage: "folder", description: Text("Open a project to view its committed channel and episodes."))
                }
                Spacer()
                Button("Open Project…") { model.openPanel() }
                Button("New Channel…") { model.beginNewChannel() }
            }
            .padding()
            .frame(minWidth: 230)
        } content: {
            editor
        } detail: {
            inspector
        }
        .overlay(alignment: .bottomLeading) { statusBar }
        .sheet(isPresented: $model.showNewChannel) { newChannelSheet }
        .sheet(isPresented: $model.showRename) { renameSheet }
        .sheet(isPresented: $model.showPairing) { pairingSheet }
        .alert("Project needs attention", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            if model.pendingRebindURL != nil { Button("Rebind moved project") { model.rebindPendingProject() } }
            Button("Dismiss", role: .cancel) { model.error = nil; model.pendingRebindURL = nil }
        } message: { Text(model.error?.errorDescription ?? "No project changes were made.") }
    }

    @ViewBuilder private var editor: some View {
        if let document = model.document {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(document.channel?.name ?? "Channel setup").font(.largeTitle.weight(.semibold))
                            Text("Committed revision \(document.revision.value)").font(.callout.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu("Channel actions") {
                            Button("Rename…") { model.showRename = true }
                            Button("Undo") { model.submit(.undo) }
                            Button("Redo") { model.submit(.redo) }
                        }
                        Button("Import footage…") { model.chooseMedia() }
                    }
                    GroupBox("Recipes") {
                        VStack(alignment: .leading, spacing: 10) {
                            if document.recipes.isEmpty { Text("Create a channel to publish its first recipe.").foregroundStyle(.secondary) }
                            ForEach(document.recipes, id: \.id) { recipe in
                                LabeledContent("Version \(recipe.id)") { Text(recipe.values.map { "\($0.key): \($0.value)" }.sorted().joined(separator: " · ")) }
                            }
                            HStack {
                                TextField("Value name", text: $recipeKey)
                                TextField("Value", text: $recipeValue)
                                Button("Publish recipe") {
                                    guard !recipeKey.isEmpty else { return }
                                    model.submit(.publishRecipe(values: [recipeKey: recipeValue])); recipeKey = ""; recipeValue = ""
                                }.disabled(document.channel == nil)
                            }
                        }
                    }
                    GroupBox("Episodes") {
                        HStack {
                            TextField("Episode name", text: $episodeName)
                            Button("Create episode") {
                                guard let recipe = document.recipes.last else { return }
                                model.submit(.createEpisode(name: episodeName, recipeVersion: recipe.id)); episodeName = ""
                            }.disabled(document.recipes.isEmpty || episodeName.isEmpty)
                        }
                    }
                    GroupBox("Managed media") {
                        if document.assets.isEmpty { Text("No managed media yet. Imported originals are copied into this project unchanged.").foregroundStyle(.secondary) }
                        ForEach(document.assets) { asset in
                            Button { model.selectedAssetID = asset.id } label: { HStack(alignment: .top, spacing: 12) {
                                ManagedAssetPreview(asset: asset, packageURL: model.packageURL)
                                VStack(alignment: .leading) {
                                    Text(asset.filename)
                                    Text("Source asset · \(asset.mediaType) · \(asset.byteLength) bytes · \(asset.digest.prefix(12))").font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }.padding(4).background(model.selectedAssetID == asset.id ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6)) }
                            .buttonStyle(.plain).accessibilityIdentifier("managed-asset-\(asset.digest.prefix(12))")
                        }
                        HStack {
                            Button("Import footage…") { model.chooseMedia() }
                            if model.isWorking { Button("Cancel import", role: .cancel) { model.cancelMediaImport() } }
                        }
                        if model.isWorking { ProgressView("Copying and measuring imported media…").accessibilityIdentifier("managed-import-progress") }
                        if !model.importOutcomes.isEmpty {
                            VStack(alignment: .leading) { Text("Latest import").font(.headline); ForEach(model.importOutcomes) { Text(WorkspaceModel.importMessage($0)) } }
                                .accessibilityIdentifier("managed-import-outcomes")
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(model.isDropTargeted ? Color.accentColor.opacity(0.08) : .clear)
                .accessibilityIdentifier("managed-media-drop-target")
                .onDrop(of: [UTType.fileURL], isTargeted: $model.isDropTargeted) { providers in
                    let group = DispatchGroup()
                    let urls = DroppedURLs()
                    for provider in providers {
                        group.enter()
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                            defer { group.leave() }
                            guard let data = item as? Data,
                                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                            urls.append(url)
                        }
                    }
                    group.notify(queue: .main) { model.importDroppedMedia(urls.snapshot()) }
                    return true
                }
            }
        } else {
            ContentUnavailableView("Choose a project", systemImage: "folder.badge.plus", description: Text("Takeform opens projects through its authority. It does not infer an empty project from an error."))
        }
    }

    @ViewBuilder private var inspector: some View {
        if let document = model.document, let episode = model.selectedEpisode {
            Form {
                Section("Episode") {
                    Text(episode.name)
                    Text("Pinned to recipe \(episode.recipeVersion)").foregroundStyle(.secondary)
                }
                Section("Effective values") {
                    ForEach(WorkspacePresentation.resolvedValues(document: document, episodeID: episode.id), id: \.key) { value in
                        LabeledContent(value.key) { Text("\(value.value) · \(value.source.rawValue)") }
                    }
                }
                Section("Override") {
                    TextField("Value name", text: $overrideKey)
                    TextField("Value", text: $overrideValue)
                    Button("Apply override") { model.submit(.setOverride(episodeID: episode.id, key: overrideKey, value: overrideValue)) }
                        .disabled(overrideKey.isEmpty)
                    Button("Reset override") { model.submit(.resetOverride(episodeID: episode.id, key: overrideKey)) }
                        .disabled(overrideKey.isEmpty)
                }
                cliAccess
            }.padding()
        } else {
            Form { cliAccess }
        }
    }

    private var cliAccess: some View {
        Section("CLI access") {
            Button("Pair CLI…") { model.showPairing = true }
            if model.cliGrants.isEmpty { Text("No paired CLI grants.").foregroundStyle(.secondary) }
            ForEach(model.cliGrants) { grant in
                HStack {
                    Button { model.selectedGrantID = grant.id } label: { Image(systemName: model.selectedGrantID == grant.id ? "checkmark.circle.fill" : "circle") }
                    VStack(alignment: .leading) { Text(grant.label); Text(grant.revokedAt == nil ? "Expires \(grant.expiresAt.formatted())" : "Revoked").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Button("Revoke selected grant") { model.revokeCLI() }.disabled(model.selectedGrantID == nil)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.isWorking { ProgressView().controlSize(.small) }
            Text(model.status).font(.caption).foregroundStyle(model.error == nil ? Color.secondary : Color.red)
        }.padding(10).background(.bar).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var newChannelSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Channel").font(.title2.weight(.semibold))
            TextField("Channel name", text: $channelName)
            TextField("First recipe value name", text: $recipeKey)
            TextField("First recipe value", text: $recipeValue)
            HStack { Spacer(); Button("Cancel") { model.showNewChannel = false }; Button("Create") {
                model.createChannel(name: channelName, initialRecipe: recipeKey.isEmpty ? [:] : [recipeKey: recipeValue]); model.showNewChannel = false
            }.keyboardShortcut(.defaultAction).disabled(channelName.isEmpty) }
        }.padding().frame(width: 400)
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Channel").font(.title2.weight(.semibold))
            TextField("Channel name", text: $channelName)
            HStack { Spacer(); Button("Cancel") { model.showRename = false }; Button("Rename") { model.submit(.renameChannel(name: channelName)); model.showRename = false }.keyboardShortcut(.defaultAction).disabled(channelName.isEmpty) }
        }.padding().frame(width: 360)
    }

    private var pairingSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair Takeform CLI").font(.title2.weight(.semibold))
            Text("Pairing grants the bundled CLI a time-limited project session. Takeform never stores the raw CLI token in this project.").fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Cancel") { model.showPairing = false }; Button("Pair CLI") { model.pairCLI(); model.showPairing = false }.keyboardShortcut(.defaultAction) }
        }.padding().frame(width: 420)
    }
}

private struct SettingsView: View {
    @AppStorage(AppAppearance.defaultsKey) private var appearance = AppAppearance.system.rawValue
    var body: some View {
        TabView { Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { preference in Text(preference.title).tag(preference.rawValue) }
            }
            .accessibilityIdentifier("appearance-preference")
            .onChange(of: appearance) { _, value in AppAppearance.apply(rawValue: value) }
            Text("Project authority and CLI access are managed per project.").foregroundStyle(.secondary)
        }.padding().tabItem { Label("General", systemImage: "gearshape") } }
            .frame(width: 460, height: 240)
    }
}

/// Preview only reads the immutable object derived from the catalog digest. It
/// never follows an original source URL, which remains outside the package.
private struct ManagedAssetPreview: View {
    let asset: ManagedAsset
    let packageURL: URL?
    @State private var image: NSImage?
    @State private var unsupported = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if unsupported {
                Label("Preview unsupported", systemImage: "film")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 108, height: 72)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: asset.digest) { await loadPreview() }
    }

    @MainActor private func loadPreview() async {
        guard let packageURL else { unsupported = true; return }
        let object = packageURL.appendingPathComponent(".takeform/objects/\(asset.digest)")
        if let image = NSImage(contentsOf: object) { self.image = image; return }
        let media = AVURLAsset(url: object)
        let generator = AVAssetImageGenerator(asset: media)
        generator.appliesPreferredTrackTransform = true
        do {
            let frame = try await generator.image(at: .zero).image
            image = NSImage(cgImage: frame, size: .zero)
        } catch {
            unsupported = true
        }
    }
}


private actor NativeAuthorityClient: WorkspaceClient {
    private var ownedService: Process?

    deinit {
        if ownedService?.isRunning == true { ownedService?.terminate() }
    }
    private func credential() throws -> Data { try CreatorCredentialStore.loadOrCreate() }
    func importMedia(packageURL: URL, sources: [URL]) async throws -> [ManagedImportOutcome] { let r = try await request(.importMedia(packageURL, sources, UUID(), try credential())); if case let .importOutcomes(outcomes) = r { return outcomes }; throw WorkspaceFailure.authorityUnavailable }
    private func verifiedRequest(_ request: AppAuthorityRequest) throws -> AppAuthorityResponse {
        guard let service = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("TakeformAuthorityAppService") else { throw WorkspaceFailure.authorityUnavailable }
        return try AppAuthoritySocket.verifiedRequest(request, expectedService: service)
    }
    private func request(_ r: AppAuthorityRequest) async throws -> AppAuthorityResponse {
        do { return try verifiedRequest(r) }
        catch is AppAuthoritySocketFailure {
            throw WorkspaceFailure.creatorAuthorizationRequired
        } catch {
            guard let here = Bundle.main.executableURL else { throw WorkspaceFailure.authorityUnavailable }
            let service = here.deletingLastPathComponent().appendingPathComponent("TakeformAuthorityAppService")
            guard FileManager.default.isExecutableFile(atPath: service.path) else { throw WorkspaceFailure.authorityUnavailable }
            if ownedService?.isRunning != true {
                let launched = Process(); launched.executableURL = service; launched.standardOutput = FileHandle.nullDevice; launched.standardError = FileHandle.nullDevice
                launched.terminationHandler = { [weak self, weak launched] _ in
                    guard let self else { return }
                    Task { await self.clearOwnedService(launched) }
                }
                try launched.run(); ownedService = launched
            }
            for _ in 0..<100 { if let response = try? verifiedRequest(r) { return response }; try await Task.sleep(for: .milliseconds(20)) }
            throw WorkspaceFailure.authorityUnavailable
        }
    }
    func createChannelPackage(packageURL: URL, name: String, initialRecipe: [String: String]) async throws -> WorkspaceSnapshot { let r = try await request(.create(packageURL, name, initialRecipe, try credential())); if case .snapshot(let snapshot) = r { return snapshot }; if case .failure(let failure) = r { throw failure }; throw WorkspaceFailure.authorityUnavailable }
    private func clearOwnedService(_ service: Process?) { if ownedService === service { ownedService = nil } }
    func open(packageURL: URL, rebindMovedPackage: Bool) async throws -> WorkspaceSnapshot { let r=try await request(.open(packageURL,rebindMovedPackage,try credential())); if case .snapshot(let x)=r{return x}; if case .failure(let e)=r{throw e};throw WorkspaceFailure.authorityUnavailable }
    func execute(packageURL: URL, envelope: CommandEnvelope) async throws -> CommandResult { let r=try await request(.execute(packageURL,envelope,try credential()));if case .result(let x)=r{return x};if case .failure(let e)=r{throw e};throw WorkspaceFailure.authorityUnavailable }
    func pairCLI(packageURL: URL, label: String, expiresAt: Date) async throws { let r=try await request(.pair(packageURL,label,expiresAt,try credential()));guard case .pairing(let id,let raw)=r else {if case .failure(let e)=r{throw e};throw WorkspaceFailure.authorityUnavailable};try importCredential(id,raw) }
    func listCLIGrants(packageURL: URL) async throws -> [CLIPairingSummary] { let r=try await request(.listGrants(packageURL,try credential())); if case .grants(let x)=r{return x}; if case .failure(let e)=r{throw e};throw WorkspaceFailure.authorityUnavailable }
    func revokeCLI(packageURL: URL, grantID: UUID) async throws { let r=try await request(.revoke(packageURL,grantID,try credential())); if case .success=r{return}; if case .failure(let e)=r{throw e};throw WorkspaceFailure.authorityUnavailable }
    private func importCredential(_ id: UUID,_ raw:String)throws{guard let here=Bundle.main.executableURL else{throw WorkspaceFailure.authorityUnavailable};let cli=here.deletingLastPathComponent().appendingPathComponent("takeform");let p=Process();let input=Pipe();p.executableURL=cli;p.arguments=["import-paired-credential",id.uuidString];p.standardInput=input;try p.run();input.fileHandleForWriting.write(Data(raw.utf8));input.fileHandleForWriting.write(Data("\n".utf8));input.fileHandleForWriting.closeFile();p.waitUntilExit();guard p.terminationStatus==0 else{throw WorkspaceFailure.rejected("CLI credential import failed")}}
}
