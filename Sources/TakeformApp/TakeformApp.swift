import AppKit
import SwiftUI
import TakeformCore
import TakeformSupport
import TakeformWorkspace
import TakeformAppAuthorityWire

final class TakeformAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct TakeformApp: App {
    @NSApplicationDelegateAdaptor(TakeformAppDelegate.self) private var appDelegate
    @StateObject private var workspace = WorkspaceModel(client: NativeAuthorityClient())

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
                Button("Revoke CLI Access") { workspace.revokeCLI() }
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

    private let client: any WorkspaceClient

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
                selectedEpisodeID = result.document.episodes.first?.id
                status = "Opened revision \(result.document.revision.value)."
            } catch let failure as WorkspaceFailure {
                error = failure; status = failure.errorDescription ?? "Unable to open project."
            } catch {
                status = "Unable to open project. No changes were made."
            }
        }
    }

    func beginNewChannel() { showNewChannel = true }

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
                status = "CLI access paired for this project."
            } catch let failure as WorkspaceFailure { error = failure; status = failure.errorDescription ?? "CLI pairing failed." }
            catch { status = "CLI pairing failed." }
        }
    }

    func revokeCLI() {
        guard let packageURL else { return }
        Task {
            isWorking = true; defer { isWorking = false }
            do { try await client.revokeCLI(packageURL: packageURL); status = "CLI access revoked." }
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
                Text("Workspace").font(.headline)
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
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                Section("CLI access") {
                    Button("Pair CLI…") { model.showPairing = true }
                    Button("Revoke CLI access", role: .destructive) { model.revokeCLI() }
                }
            }.padding()
        } else {
            ContentUnavailableView("Select an episode", systemImage: "slider.horizontal.3", description: Text("Its pinned recipe and override provenance will appear here."))
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
                model.submit(.createChannel(name: channelName, initialRecipe: recipeKey.isEmpty ? [:] : [recipeKey: recipeValue])); model.showNewChannel = false
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
    var body: some View {
        TabView { Form { Text("Project authority and CLI access are managed per project.").foregroundStyle(.secondary) }.padding().tabItem { Label("General", systemImage: "gearshape") } }
            .frame(width: 460, height: 240)
    }
}


private struct NativeAuthorityClient: WorkspaceClient {
    private func credential() throws -> Data { try CreatorCredentialStore.loadOrCreate() }
    private func request(_ r: AppAuthorityRequest) async throws -> AppAuthorityResponse {
        do { return try await Task.detached { try AppAuthoritySocket.request(r) }.value }
        catch {
            guard let here = Bundle.main.executableURL else { throw WorkspaceFailure.authorityUnavailable }
            let service = here.deletingLastPathComponent().appendingPathComponent("TakeformAuthorityAppService")
            guard FileManager.default.isExecutableFile(atPath: service.path) else { throw WorkspaceFailure.authorityUnavailable }
            let process = Process(); process.executableURL = service; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; try process.run()
            for _ in 0..<100 { if let response = try? AppAuthoritySocket.request(r) { return response }; try await Task.sleep(for: .milliseconds(20)) }
            throw WorkspaceFailure.authorityUnavailable
        }
    }
    func open(packageURL: URL, rebindMovedPackage: Bool) async throws -> WorkspaceSnapshot { let r=try await request(.open(packageURL,rebindMovedPackage,try credential())); if case .snapshot(let x)=r{return x}; if case .failure(let e)=r{throw e};throw WorkspaceFailure.authorityUnavailable }
    func execute(packageURL: URL, envelope: CommandEnvelope) async throws -> CommandResult { let r=try await request(.execute(packageURL,envelope,try credential()));if case .result(let x)=r{return x};if case .failure(let e)=r{throw e};throw WorkspaceFailure.authorityUnavailable }
    func pairCLI(packageURL: URL, label: String, expiresAt: Date) async throws { let r=try await request(.pair(packageURL,label,expiresAt,try credential()));guard case .pairing(let id,let raw)=r else {if case .failure(let e)=r{throw e};throw WorkspaceFailure.authorityUnavailable};try importCredential(id,raw) }
    func revokeCLI(packageURL: URL) async throws { throw WorkspaceFailure.rejected("Choose the specific CLI grant to revoke.") }
    private func importCredential(_ id: UUID,_ raw:String)throws{guard let here=Bundle.main.executableURL else{throw WorkspaceFailure.authorityUnavailable};let cli=here.deletingLastPathComponent().appendingPathComponent("takeform");let p=Process();let input=Pipe();p.executableURL=cli;p.arguments=["import-paired-credential",id.uuidString];p.standardInput=input;try p.run();input.fileHandleForWriting.write(Data(raw.utf8));input.fileHandleForWriting.write(Data("\n".utf8));input.fileHandleForWriting.closeFile();p.waitUntilExit();guard p.terminationStatus==0 else{throw WorkspaceFailure.rejected("CLI credential import failed")}}
}
