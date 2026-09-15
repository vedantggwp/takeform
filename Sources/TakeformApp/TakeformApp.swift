import AppKit
import AVFoundation
import AVKit
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

/// The inspector receives this only after a fresh authority open verified the
/// catalog object. Asset, package, and revision move together so an old open
/// cannot combine an asset with a newer project.
struct VerifiedAssetSelection: Equatable {
    let asset: ManagedAsset
    let packageURL: URL
    let revision: Revision
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
    @Published private(set) var verifiedAssetSelection: VerifiedAssetSelection?
    @Published var isDropTargeted = false

    private let client: any WorkspaceClient
    private var importTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var workspaceGeneration = 0
    private var selectionGeneration = 0
    private var requestedPackageURL: URL?

    init(client: any WorkspaceClient) { self.client = client }

    var document: ProjectDocument? { snapshot?.document }
    var packageURL: URL? { snapshot?.packageURL }
    var selectedEpisode: Episode? { document?.episodes.first { $0.id == selectedEpisodeID } }

    private func beginWorkspaceUpdate(for packageURL: URL?) -> Int {
        workspaceGeneration &+= 1
        requestedPackageURL = packageURL
        invalidateSelection()
        return workspaceGeneration
    }

    private func invalidateSelection() {
        selectionGeneration &+= 1
        selectionTask?.cancel()
        selectionTask = nil
        selectedAssetID = nil
        verifiedAssetSelection = nil
    }

    private static func samePackage(_ lhs: URL?, _ rhs: URL) -> Bool {
        lhs?.standardizedFileURL == rhs.standardizedFileURL
    }

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
        let generation = beginWorkspaceUpdate(for: url)
        Task {
            isWorking = true; error = nil
            defer { isWorking = false }
            do {
                let result = try await client.open(packageURL: url, rebindMovedPackage: rebind)
                guard workspaceGeneration == generation, Self.samePackage(requestedPackageURL, url) else { return }
                let grants = (try? await client.listCLIGrants(packageURL: url)) ?? []
                guard workspaceGeneration == generation, Self.samePackage(requestedPackageURL, url) else { return }
                snapshot = result
                cliGrants = grants
                selectedGrantID = cliGrants.contains(where: { $0.id == selectedGrantID }) ? selectedGrantID : nil
                pendingRebindURL = nil
                selectedEpisodeID = result.document.episodes.first?.id
                requestedPackageURL = nil
                status = rebind ? "Rebound project at revision \(result.document.revision.value). Previous CLI grants were invalidated; pair again." : "Opened revision \(result.document.revision.value)."
            } catch let failure as WorkspaceFailure {
                guard workspaceGeneration == generation, Self.samePackage(requestedPackageURL, url) else { return }
                pendingRebindURL = failure == .copyDecisionRequired ? url : nil
                error = failure; status = failure.errorDescription ?? "Unable to open project."
            } catch {
                guard workspaceGeneration == generation, Self.samePackage(requestedPackageURL, url) else { return }
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

    func selectAsset(_ asset: ManagedAsset) {
        guard let packageURL else {
            error = .rejected("Open a project before inspecting media")
            status = error?.errorDescription ?? "Unable to inspect media."
            return
        }
        // Remove any prior preview while the authority checks the current
        // catalog. A stale selection must not keep a player or image alive.
        invalidateSelection()
        let selection = selectionGeneration
        let workspace = workspaceGeneration
        selectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                // `open` is the authority's digest/length verification gate;
                // never hand a selected filesystem URL straight to a preview.
                let verified = try await self.client.open(packageURL: packageURL, rebindMovedPackage: false)
                guard !Task.isCancelled,
                      self.selectionGeneration == selection,
                      self.workspaceGeneration == workspace,
                      Self.samePackage(self.packageURL, packageURL) else { return }
                guard let verifiedAsset = WorkspacePresentation.assetForVerifiedPreview(document: verified.document, selectedAssetID: asset.id) else {
                    selectedAssetID = nil
                    verifiedAssetSelection = nil
                    error = .missingObject("selected managed asset")
                    status = error?.errorDescription ?? "Selected media is unavailable."
                    return
                }
                snapshot = verified
                selectedAssetID = verifiedAsset.id
                verifiedAssetSelection = VerifiedAssetSelection(asset: verifiedAsset, packageURL: verified.packageURL, revision: verified.document.revision)
            } catch let failure as WorkspaceFailure {
                guard !Task.isCancelled, self.selectionGeneration == selection, self.workspaceGeneration == workspace else { return }
                self.error = failure
                self.status = failure.errorDescription ?? "Selected media is unavailable."
                selectedAssetID = nil
                verifiedAssetSelection = nil
            } catch {
                guard !Task.isCancelled, self.selectionGeneration == selection, self.workspaceGeneration == workspace else { return }
                self.error = .corruptProject
                self.status = WorkspaceFailure.corruptProject.errorDescription ?? "Selected media is unavailable."
                selectedAssetID = nil
                verifiedAssetSelection = nil
            }
        }
    }

    private func importMedia(_ urls: [URL], into packageURL: URL) {
        guard !urls.isEmpty else { return }
        importTask?.cancel()
        let generation = beginWorkspaceUpdate(for: packageURL)
        importTask = Task { [weak self] in
            guard let self else { return }
            self.isWorking = true
            self.importOutcomes = []
            defer { self.isWorking = false; self.importTask = nil }
            do {
                let outcomes = try await self.client.importMedia(packageURL: packageURL, sources: urls)
                guard !Task.isCancelled, self.workspaceGeneration == generation, Self.samePackage(self.requestedPackageURL, packageURL) else { return }
                self.importOutcomes = outcomes
                if Task.isCancelled { self.status = "Media import cancelled."; return }
                self.status = outcomes.map(Self.importMessage).joined(separator: "\n")
                let opened = try await self.client.open(packageURL: packageURL, rebindMovedPackage: false)
                guard !Task.isCancelled, self.workspaceGeneration == generation, Self.samePackage(self.requestedPackageURL, packageURL) else { return }
                self.snapshot = opened
                self.requestedPackageURL = nil
            } catch let failure as WorkspaceFailure {
                guard !Task.isCancelled, self.workspaceGeneration == generation else { return }
                self.error = failure; self.status = failure.errorDescription ?? "Import failed."
            } catch {
                guard !Task.isCancelled, self.workspaceGeneration == generation else { return }
                self.status = "Import failed without committing incomplete media."
            }
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
            let generation = self.beginWorkspaceUpdate(for: url)
            Task {
                self.isWorking = true; self.error = nil
                defer { self.isWorking = false }
                do {
                    let created = try await self.client.createChannelPackage(packageURL: url, name: name, initialRecipe: initialRecipe)
                    guard self.workspaceGeneration == generation, Self.samePackage(self.requestedPackageURL, url) else { return }
                    let document = created.document
                    let grants = (try? await self.client.listCLIGrants(packageURL: url)) ?? []
                    guard self.workspaceGeneration == generation, Self.samePackage(self.requestedPackageURL, url) else { return }
                    self.snapshot = created
                    self.cliGrants = grants
                    self.requestedPackageURL = nil
                    self.status = "Created \(name) at revision \(document.revision.value)."
                } catch let failure as WorkspaceFailure {
                    guard self.workspaceGeneration == generation else { return }
                    self.error = failure; self.status = failure.errorDescription ?? "Channel creation failed."
                } catch {
                    guard self.workspaceGeneration == generation else { return }
                    self.status = "Channel creation failed. No project changes were committed."
                }
            }
        }
    }

    func rebindPendingProject() {
        guard let pendingRebindURL else { return }
        open(pendingRebindURL, rebind: true)
    }

    func submit(_ command: ProjectCommand) {
        guard let document, let packageURL else { return }
        let generation = beginWorkspaceUpdate(for: packageURL)
        Task {
            isWorking = true; error = nil
            defer { isWorking = false }
            do {
                let result = try await client.execute(packageURL: packageURL, envelope: CommandEnvelope(expectedRevision: document.revision, command: command))
                guard workspaceGeneration == generation, Self.samePackage(requestedPackageURL, packageURL) else { return }
                status = WorkspacePresentation.commandMessage(result)
                if case .applied(let next) = result.outcome {
                    snapshot = WorkspaceSnapshot(document: next, projectionMatches: true, packageURL: packageURL)
                    selectedEpisodeID = selectedEpisodeID ?? next.episodes.first?.id
                }
                requestedPackageURL = nil
            } catch let failure as WorkspaceFailure {
                guard workspaceGeneration == generation else { return }
                error = failure; status = failure.errorDescription ?? "No change was committed."
            } catch {
                guard workspaceGeneration == generation else { return }
                status = "No change was committed."
            }
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
                            Button { model.selectAsset(asset) } label: { HStack(alignment: .top, spacing: 12) {
                                Image(systemName: asset.mediaType == "image" ? "photo" : asset.mediaType == "audio" ? "waveform" : "film")
                                    .frame(width: 108, height: 72)
                                VStack(alignment: .leading) {
                                    Text(asset.filename)
                                    Text("Source asset · \(asset.mediaType) · \(asset.byteLength) bytes · \(asset.digest.prefix(12))").font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }.padding(4).background(model.selectedAssetID == asset.id ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6)) }
                            .buttonStyle(.plain).accessibilityIdentifier("managed-asset-\(asset.digest.prefix(12))")
                        }
                        if let selected = model.verifiedAssetSelection {
                            GroupBox("Selected source asset") {
                                HStack(alignment: .top, spacing: 12) {
                                    ManagedAssetPreview(asset: selected.asset, packageURL: selected.packageURL)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(selected.asset.filename)
                                        Text("Revision \(selected.revision.value) · \(selected.asset.mediaType) · \(selected.asset.byteLength) bytes · \(selected.asset.digest)").font(.caption.monospaced())
                                        ManagedAssetProbeDetails(probe: selected.asset.probe)
                                        Text("This is a source asset, not a timeline moment.").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }.accessibilityIdentifier("managed-asset-inspector")
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
    @State private var player: AVPlayer?
    @State private var failure: String?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let player {
                VideoPlayer(player: player)
                    .accessibilityLabel(asset.mediaType == "audio" ? "Managed audio playback" : "Managed video playback")
            } else if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
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
        .onDisappear { releasePlayer() }
    }

    @MainActor private func loadPreview() async {
        image = nil
        releasePlayer()
        failure = nil
        guard let packageURL else { failure = "Preview unavailable"; return }
        let object = packageURL.appendingPathComponent(".takeform/objects/\(asset.digest)")
        switch asset.mediaType {
        case "image":
            guard let loaded = NSImage(contentsOf: object) else { failure = "Image preview unavailable"; return }
            image = loaded
        case "video", "audio":
            // The current `open` call selected this asset only after the
            // authority checked this derived object. Never use a source URL.
            player = AVPlayer(url: object)
        default:
            failure = "Preview unsupported for \(asset.mediaType)"
        }
    }

    @MainActor private func releasePlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}

private struct ManagedAssetProbeDetails: View {
    let probe: ManagedAssetProbe?

    var body: some View {
        if let probe {
            VStack(alignment: .leading, spacing: 3) {
                if let container = probe.containerIdentifier { Text("Container: \(container)") }
                if let duration = rational(value: probe.durationValue, timescale: probe.durationTimescale) { Text("Measured duration: \(duration)") }
                if let width = probe.imageDisplayedWidth, let height = probe.imageDisplayedHeight {
                    Text("Image: \(width) × \(height)\(probe.imageOrientation.map { ", orientation \($0)" } ?? "")")
                }
                if let video = probe.video {
                    Text("Video: \(video.displayedWidth) × \(video.displayedHeight)\(video.codec.map { ", \($0)" } ?? "")")
                    if let range = video.timeRange, range.count == 2 { Text("Video range: \(range[0].value)/\(range[0].timescale) + \(range[1].value)/\(range[1].timescale)") }
                    Text("Observed presentation deltas: \(video.observedPresentationDeltaCount)\(video.isVariableFrameRate == true ? " · variable frame rate" : "")")
                }
                ForEach(Array(probe.audio.enumerated()), id: \.offset) { _, audio in
                    Text("Audio: \(audio.channels.map(String.init) ?? "?") channels · \(audio.sampleRate.map { String(format: "%.0f Hz", $0) } ?? "unknown rate")\(audio.codec.map { " · \($0)" } ?? "")")
                }
                if let liveID = probe.livePhotoComparisonIdentifier ?? probe.livePhotoIdentifier {
                    Text("Live Photo identifier evidence: \(liveID)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Text("No measured range is available for this legacy asset.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func rational(value: Int64?, timescale: Int32?) -> String? {
        guard let value, let timescale, timescale > 0 else { return nil }
        return "\(value)/\(timescale)"
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
