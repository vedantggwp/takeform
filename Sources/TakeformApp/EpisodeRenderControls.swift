import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import TakeformAppAuthorityWire
import TakeformAppServiceClient
import TakeformCore
import TakeformRenderedPreview
import TakeformWorkspace

/// App-only rendering operations. The portable workspace protocol intentionally
/// does not import the app wire module, so this boundary remains in the app.
protocol RenderWorkspaceClient: Sendable {
    func requestEpisodeRender(packageURL: URL, envelope: CommandEnvelope) async throws -> CommandResult
    func renderStatus(packageURL: URL, jobID: UUID) async throws -> EpisodeRenderRequestStatus
    func cancelEpisodeRender(packageURL: URL, jobID: UUID, operationID: CommandID) async throws -> EpisodeRenderRequestStatus
    func playbackSource(packageURL: URL, jobID: UUID, operationID: CommandID) async throws -> EpisodeRenderPlaybackSource
    func exportEpisodeRender(packageURL: URL, jobID: UUID, operationID: CommandID, destination: URL, decision: EpisodeRenderExportDecision) async throws -> EpisodeRenderExportResult
    func configureRenderRuntime(packageURL: URL, selectors: RenderRuntimeSelectors, operationID: CommandID) async throws -> RenderRuntimeReadiness
    func renderRuntimeReadiness(packageURL: URL) async throws -> RenderRuntimeReadiness
}

extension AppAuthorityServiceClient: RenderWorkspaceClient {}

struct UnavailableRenderWorkspaceClient: RenderWorkspaceClient {
    private func unavailable<T>() throws -> T { throw WorkspaceFailure.authorityUnavailable }
    func requestEpisodeRender(packageURL: URL, envelope: CommandEnvelope) async throws -> CommandResult { try unavailable() }
    func renderStatus(packageURL: URL, jobID: UUID) async throws -> EpisodeRenderRequestStatus { try unavailable() }
    func cancelEpisodeRender(packageURL: URL, jobID: UUID, operationID: CommandID) async throws -> EpisodeRenderRequestStatus { try unavailable() }
    func playbackSource(packageURL: URL, jobID: UUID, operationID: CommandID) async throws -> EpisodeRenderPlaybackSource { try unavailable() }
    func exportEpisodeRender(packageURL: URL, jobID: UUID, operationID: CommandID, destination: URL, decision: EpisodeRenderExportDecision) async throws -> EpisodeRenderExportResult { try unavailable() }
    func configureRenderRuntime(packageURL: URL, selectors: RenderRuntimeSelectors, operationID: CommandID) async throws -> RenderRuntimeReadiness { try unavailable() }
    func renderRuntimeReadiness(packageURL: URL) async throws -> RenderRuntimeReadiness { try unavailable() }
}

enum RenderRuntimeTool: CaseIterable, Hashable {
    case browser, ffmpeg, ffprobe

    var title: String {
        switch self {
        case .browser: "Browser"
        case .ffmpeg: "FFmpeg"
        case .ffprobe: "FFprobe"
        }
    }

    var panelMessage: String { "Choose the \(title) executable for Takeform's local renderer" }
}

struct RenderRuntimeSelectionNames: Equatable {
    let browser: String?
    let ffmpeg: String?
    let ffprobe: String?

    subscript(_ tool: RenderRuntimeTool) -> String? {
        switch tool {
        case .browser: browser
        case .ffmpeg: ffmpeg
        case .ffprobe: ffprobe
        }
    }
}

struct ActiveRender: Equatable {
    let packageURL: URL
    let episodeID: UUID
    let revision: Revision
    let compositionDigest: String
    let jobID: UUID
}

@MainActor
extension WorkspaceModel {
    func refreshRenderRuntimeReadiness() {
        guard let packageURL else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let readiness = try await renderClient.renderRuntimeReadiness(packageURL: packageURL)
                guard self.packageURL == packageURL else { return }
                renderRuntimeReadiness = readiness
            } catch let failure as WorkspaceFailure {
                guard self.packageURL == packageURL else { return }
                renderRuntimeReadiness = .unavailable(reason: failure.errorDescription ?? "Renderer setup is unavailable.")
            } catch {
                guard self.packageURL == packageURL else { return }
                renderRuntimeReadiness = .unavailable(reason: "Renderer setup is unavailable.")
            }
        }
    }

    func chooseRenderRuntime(_ tool: RenderRuntimeTool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = tool.panelMessage
        panel.prompt = "Choose \(tool.title)"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.selectedRenderRuntimeURLs[tool] = url
            self?.renderRuntimeSelectionNames = self?.runtimeSelectionNames()
            self?.renderMessage = nil
        }
    }

    func configureRenderRuntime() {
        guard let packageURL else { return }
        guard let browser = selectedRenderRuntimeURLs[.browser],
              let ffmpeg = selectedRenderRuntimeURLs[.ffmpeg],
              let ffprobe = selectedRenderRuntimeURLs[.ffprobe] else {
            renderMessage = "Choose a browser, FFmpeg, and FFprobe before checking the local renderer."
            return
        }
        let selectors = RenderRuntimeSelectors(browser: browser, ffmpeg: ffmpeg, ffprobe: ffprobe)
        let operationID = CommandID()
        isWorking = true
        renderMessage = "Checking the local renderer…"
        Task { [weak self] in
            guard let self else { return }
            defer {
                // URLs are only held while this app-authority request is in flight.
                selectedRenderRuntimeURLs.removeAll()
                renderRuntimeSelectionNames = nil
                isWorking = false
            }
            do {
                let readiness = try await renderClient.configureRenderRuntime(packageURL: packageURL, selectors: selectors, operationID: operationID)
                guard self.packageURL == packageURL else { return }
                renderRuntimeReadiness = readiness
                renderMessage = renderReadinessMessage(readiness)
            } catch let failure as WorkspaceFailure {
                guard self.packageURL == packageURL else { return }
                renderRuntimeReadiness = .unavailable(reason: failure.errorDescription ?? "Renderer setup was not saved.")
                renderMessage = failure.errorDescription ?? "Renderer setup was not saved."
            } catch {
                guard self.packageURL == packageURL else { return }
                renderRuntimeReadiness = .unavailable(reason: "Renderer setup was not saved.")
                renderMessage = "Renderer setup was not saved."
            }
        }
    }

    func requestRender(for episode: Episode) {
        guard let document, let packageURL,
              let composition = document.episodeCompositions.first(where: { $0.episodeID == episode.id }) else {
            renderMessage = "Save a composition before rendering this episode."
            return
        }
        guard case .ready? = renderRuntimeReadiness else {
            renderMessage = "Set up the local renderer before requesting a render."
            return
        }
        do {
            let digest = try compositionDigest(composition)
            let context = ActiveRender(packageURL: packageURL, episodeID: episode.id, revision: document.revision, compositionDigest: digest, jobID: UUID())
            let envelope = CommandEnvelope(
                expectedRevision: document.revision,
                command: .requestEpisodeRender(episodeID: episode.id, compositionDigest: digest, format: .mp4)
            )
            renderStatusGeneration &+= 1
            let statusGeneration = renderStatusGeneration
            renderPreviewLoadGeneration &+= 1
            activeRender = nil
            renderStatus = nil
            renderedPreviewPlayer.clear()
            isWorking = true
            renderMessage = "Requesting render…"
            Task { [weak self] in
                guard let self else { return }
                defer { isWorking = false }
                do {
                    let result = try await renderClient.requestEpisodeRender(packageURL: packageURL, envelope: envelope)
                    guard renderStatusGeneration == statusGeneration,
                          isCurrentRenderContext(context, packageURL: packageURL, episodeID: episode.id, revision: document.revision, digest: digest) else { return }
                    guard case let .renderRequested(status) = result.outcome else {
                        renderMessage = WorkspacePresentation.commandMessage(result)
                        return
                    }
                    activeRender = ActiveRender(packageURL: packageURL, episodeID: episode.id, revision: document.revision, compositionDigest: digest, jobID: status.jobID)
                    renderStatus = status
                    renderMessage = renderStatusMessage(status)
                } catch let failure as WorkspaceFailure {
                    guard renderStatusGeneration == statusGeneration,
                          isCurrentRenderContext(context, packageURL: packageURL, episodeID: episode.id, revision: document.revision, digest: digest) else { return }
                    renderMessage = failure.errorDescription ?? "Render request was not accepted."
                } catch {
                    guard renderStatusGeneration == statusGeneration,
                          isCurrentRenderContext(context, packageURL: packageURL, episodeID: episode.id, revision: document.revision, digest: digest) else { return }
                    renderMessage = "Render request was not accepted."
                }
            }
        } catch {
            renderMessage = "The saved composition could not be prepared for rendering."
        }
    }

    func refreshRenderStatus() {
        guard let activeRender else { return }
        renderStatusGeneration &+= 1
        let statusGeneration = renderStatusGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await renderClient.renderStatus(packageURL: activeRender.packageURL, jobID: activeRender.jobID)
                guard self.renderStatusGeneration == statusGeneration,
                      self.activeRender == activeRender,
                      isCurrentRenderContext(activeRender) else { return }
                renderStatus = status
                renderMessage = renderStatusMessage(status)
                if status.logicalState != .completed || status.availability != .available { renderedPreviewPlayer.clear() }
            } catch let failure as WorkspaceFailure {
                guard self.renderStatusGeneration == statusGeneration, self.activeRender == activeRender else { return }
                renderMessage = failure.errorDescription ?? "Render status is unavailable."
                renderedPreviewPlayer.clear()
            } catch {
                guard self.renderStatusGeneration == statusGeneration, self.activeRender == activeRender else { return }
                renderMessage = "Render status is unavailable."
                renderedPreviewPlayer.clear()
            }
        }
    }

    func cancelRender() {
        guard let activeRender else { return }
        let operationID = CommandID()
        renderStatusGeneration &+= 1
        let statusGeneration = renderStatusGeneration
        renderPreviewLoadGeneration &+= 1
        renderedPreviewPlayer.clear()
        isWorking = true
        Task { [weak self] in
            guard let self else { return }
            defer { isWorking = false }
            do {
                let status = try await renderClient.cancelEpisodeRender(packageURL: activeRender.packageURL, jobID: activeRender.jobID, operationID: operationID)
                guard self.renderStatusGeneration == statusGeneration, self.activeRender == activeRender else { return }
                renderStatus = status
                renderMessage = renderStatusMessage(status)
                renderedPreviewPlayer.clear()
            } catch let failure as WorkspaceFailure {
                guard self.renderStatusGeneration == statusGeneration, self.activeRender == activeRender else { return }
                renderMessage = failure.errorDescription ?? "Render cancellation was not accepted."
            } catch {
                guard self.renderStatusGeneration == statusGeneration, self.activeRender == activeRender else { return }
                renderMessage = "Render cancellation was not accepted."
            }
        }
    }

    func loadRenderedPreview() {
        guard let activeRender, isCurrentRenderContext(activeRender) else {
            invalidateRender()
            return
        }
        let operationID = CommandID()
        renderPreviewLoadGeneration &+= 1
        let previewLoadGeneration = renderPreviewLoadGeneration
        isWorking = true
        renderMessage = "Loading the verified render…"
        Task { [weak self] in
            guard let self else { return }
            defer { isWorking = false }
            do {
                let source = try await renderClient.playbackSource(packageURL: activeRender.packageURL, jobID: activeRender.jobID, operationID: operationID)
                guard self.renderPreviewLoadGeneration == previewLoadGeneration,
                      self.activeRender == activeRender,
                      source.jobID == activeRender.jobID,
                      source.requestedRevision == activeRender.revision,
                      source.compositionDigest == activeRender.compositionDigest,
                      isCurrentRenderContext(activeRender) else {
                    renderedPreviewPlayer.clear()
                    return
                }
                try await renderedPreviewPlayer.load(source)
                guard self.renderPreviewLoadGeneration == previewLoadGeneration,
                      self.activeRender == activeRender,
                      isCurrentRenderContext(activeRender) else {
                    renderedPreviewPlayer.clear()
                    return
                }
                renderMessage = "Ready to preview the verified render."
            } catch let failure as WorkspaceFailure {
                guard self.renderPreviewLoadGeneration == previewLoadGeneration, self.activeRender == activeRender else { return }
                renderedPreviewPlayer.clear()
                renderMessage = failure.errorDescription ?? "The verified render is unavailable."
            } catch {
                guard self.renderPreviewLoadGeneration == previewLoadGeneration, self.activeRender == activeRender else { return }
                renderedPreviewPlayer.clear()
                renderMessage = "The verified render is unavailable."
            }
        }
    }

    func exportRenderedEpisode() {
        guard let activeRender,
              let identity = renderedPreviewPlayer.sourceIdentity,
              identity.jobID == activeRender.jobID,
              identity.requestedRevision == activeRender.revision,
              identity.compositionDigest == activeRender.compositionDigest else {
            renderMessage = "Load the verified render before exporting it."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(selectedEpisode?.name ?? "Episode").mp4"
        panel.message = "Choose where to export this verified render"
        panel.prompt = "Export render"
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.export(activeRender, to: destination)
        }
    }

    func clearRenderIfStale(for episode: Episode?) {
        guard let activeRender else { return }
        guard episode?.id == activeRender.episodeID, isCurrentRenderContext(activeRender) else {
            invalidateRender()
            return
        }
    }

    func invalidateRender() {
        renderStatusGeneration &+= 1
        renderPreviewLoadGeneration &+= 1
        activeRender = nil
        renderStatus = nil
        renderMessage = nil
        renderedPreviewPlayer.clear()
    }

    private func export(_ activeRender: ActiveRender, to destination: URL) {
        let operationID = CommandID()
        isWorking = true
        renderMessage = "Exporting the verified render…"
        Task { [weak self] in
            guard let self else { return }
            defer { isWorking = false }
            do {
                let result = try await renderClient.exportEpisodeRender(
                    packageURL: activeRender.packageURL,
                    jobID: activeRender.jobID,
                    operationID: operationID,
                    destination: destination,
                    decision: .refuseExisting
                )
                guard self.activeRender == activeRender else { return }
                switch result {
                case .exported: renderMessage = "Exported the verified render."
                case .unavailable(let status):
                    renderStatus = status
                    renderMessage = renderStatusMessage(status)
                    renderedPreviewPlayer.clear()
                }
            } catch let failure as WorkspaceFailure {
                guard self.activeRender == activeRender else { return }
                renderMessage = failure.errorDescription ?? "The render was not exported."
            } catch {
                guard self.activeRender == activeRender else { return }
                renderMessage = "The render was not exported."
            }
        }
    }

    private func runtimeSelectionNames() -> RenderRuntimeSelectionNames {
        RenderRuntimeSelectionNames(
            browser: selectedRenderRuntimeURLs[.browser]?.lastPathComponent,
            ffmpeg: selectedRenderRuntimeURLs[.ffmpeg]?.lastPathComponent,
            ffprobe: selectedRenderRuntimeURLs[.ffprobe]?.lastPathComponent
        )
    }

    private func compositionDigest(_ composition: EpisodeComposition) throws -> String {
        SHA256.hash(data: try composition.canonicalData()).map { String(format: "%02x", $0) }.joined()
    }

    private func isCurrentRenderContext(_ activeRender: ActiveRender) -> Bool {
        isCurrentRenderContext(activeRender, packageURL: activeRender.packageURL, episodeID: activeRender.episodeID, revision: activeRender.revision, digest: activeRender.compositionDigest)
    }

    private func isCurrentRenderContext(_ proposed: ActiveRender, packageURL: URL, episodeID: UUID, revision: Revision, digest: String) -> Bool {
        guard self.packageURL == packageURL,
              document?.revision == revision,
              let composition = document?.episodeCompositions.first(where: { $0.episodeID == episodeID }),
              let currentDigest = try? compositionDigest(composition) else { return false }
        return currentDigest == digest && proposed.episodeID == episodeID
    }
}

struct EpisodeRenderControls: View {
    @ObservedObject var model: WorkspaceModel
    let episode: Episode

    var body: some View {
        Group {
            Section("Local renderer") {
                runtimeSetup
            }
            Section("Render") {
                renderControls
            }
            .accessibilityIdentifier("episode-render-controls")
        }
        .onAppear {
            model.refreshRenderRuntimeReadiness()
            model.clearRenderIfStale(for: episode)
        }
        .onChange(of: episode.id) { _, _ in model.clearRenderIfStale(for: episode) }
        .onChange(of: model.document?.revision) { _, _ in model.clearRenderIfStale(for: episode) }
    }

    @ViewBuilder private var renderControls: some View {
            if let status = model.renderStatus {
                renderState(status)
            } else {
                Text(model.document?.episodeCompositions.contains(where: { $0.episodeID == episode.id }) == true
                     ? "Request a render from the saved composition."
                     : "Save a composition before requesting a render.")
                    .foregroundStyle(.secondary)
            }
            if let message = model.renderMessage {
                Text(message)
                    .foregroundStyle(model.renderStatus?.logicalState == .failed ? .red : .secondary)
                    .accessibilityIdentifier("episode-render-message")
            }
            Button("Render episode") { model.requestRender(for: episode) }
                .disabled(!readinessIsAvailable || model.isWorking || model.document?.episodeCompositions.contains(where: { $0.episodeID == episode.id }) != true)
                .accessibilityIdentifier("episode-render-request")
        }

    @ViewBuilder private var runtimeSetup: some View {
            Text(model.renderRuntimeReadiness.map(renderReadinessMessage) ?? "Checking local renderer setup…")
                .foregroundStyle(readinessIsAvailable ? Color.secondary : Color.orange)
                .accessibilityIdentifier("render-runtime-readiness")
            ForEach(RenderRuntimeTool.allCases, id: \.self) { tool in
                HStack {
                    Text(tool.title)
                    Spacer()
                    Text(model.renderRuntimeSelectionNames?[tool] ?? "Not selected")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Choose…") { model.chooseRenderRuntime(tool) }
                        .accessibilityIdentifier("render-runtime-\(tool.title.lowercased())")
                }
            }
            Button("Check local renderer") { model.configureRenderRuntime() }
                .disabled(!runtimeSelectionIsComplete || model.isWorking)
                .accessibilityIdentifier("render-runtime-configure")
    }

    @ViewBuilder private func renderState(_ status: EpisodeRenderRequestStatus) -> some View {
        Text(renderStatusMessage(status))
            .accessibilityIdentifier("episode-render-status")
        HStack {
            Button("Refresh status") { model.refreshRenderStatus() }
                .accessibilityIdentifier("episode-render-refresh")
            if status.logicalState == .requested || status.availability == .queued || status.availability == .running {
                Button("Cancel render", role: .cancel) { model.cancelRender() }
                    .accessibilityIdentifier("episode-render-cancel")
            }
            if status.logicalState == .completed && status.availability == .available {
                Button("Load preview") { model.loadRenderedPreview() }
                    .accessibilityIdentifier("episode-render-load-preview")
            }
        }
        if let identity = model.renderedPreviewPlayer.sourceIdentity,
           identity.jobID == status.jobID,
           identity.requestedRevision == status.requestedRevision,
           identity.compositionDigest == status.compositionDigest {
            RenderedPreviewView(player: model.renderedPreviewPlayer.player)
                .frame(minHeight: 180)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("episode-render-preview")
            HStack {
                Button("Play") { model.renderedPreviewPlayer.play() }
                    .accessibilityIdentifier("episode-render-play")
                Button("Pause") { model.renderedPreviewPlayer.pause() }
                    .accessibilityIdentifier("episode-render-pause")
                Button("Export render…") { model.exportRenderedEpisode() }
                    .accessibilityIdentifier("episode-render-export")
            }
        }
    }

    private var readinessIsAvailable: Bool {
        if case .ready? = model.renderRuntimeReadiness { return true }
        return false
    }

    private var runtimeSelectionIsComplete: Bool {
        RenderRuntimeTool.allCases.allSatisfy { model.renderRuntimeSelectionNames?[$0] != nil }
    }
}

func renderReadinessMessage(_ readiness: RenderRuntimeReadiness) -> String {
    switch readiness {
    case let .ready(nodeVersion, browserVersion, ffmpegVersion, ffprobeVersion):
        "Local renderer ready: Node \(nodeVersion), browser \(browserVersion), FFmpeg \(ffmpegVersion), FFprobe \(ffprobeVersion)."
    case let .unavailable(reason): reason
    }
}

func renderStatusMessage(_ status: EpisodeRenderRequestStatus) -> String {
    switch (status.logicalState, status.availability) {
    case (.requested, .queued): "Render is queued."
    case (.requested, .running): "Render is running."
    case (.completed, .available): "Render completed and is available on this Mac."
    case (.completed, .unavailable): "Render completed, but its verified artifact is unavailable on this Mac."
    case (.cancelled, _): "Render was cancelled."
    case (.interrupted, _): "Render was interrupted before a verified artifact was available."
    case (.failed, _): "Render failed before a verified artifact was available."
    default: "Render status is \(status.availability.rawValue)."
    }
}
