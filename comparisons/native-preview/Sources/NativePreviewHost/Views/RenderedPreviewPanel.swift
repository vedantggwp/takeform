import SwiftUI

struct RenderedPreviewPanel: View {
    @Bindable var store: RenderedPreviewStore
    @Bindable var playback: RenderedPreviewPlaybackStore
    let player: RenderedPreviewPlayer

    var body: some View {
        Group {
            switch store.status {
        case let .unavailable(message): unavailable(message)
        case .queued: waiting("Rendered preview is queued. The current plan remains unavailable until the renderer reports an artifact.")
        case let .running(progress): waiting(progressText(progress))
        case let .succeeded(artifact):
            VStack(spacing: 8) {
                RenderedPreviewView(player: player.player)
                    .accessibilityLabel("Rendered preview video")
                if let error = playback.errorMessage {
                    Text(error).foregroundStyle(.red).font(.caption)
                } else if let session = playback.session {
                    HStack {
                        Text("Frame \(session.requestedFrame + 1) / \(session.totalFrames)")
                            .monospacedDigit()
                        Button("Seek first") {
                            Task { await playback.seek(frame: 0, artifact: artifact, player: player) }
                        }
                        Button(session.playback == .playing ? "Pause" : "Play") {
                            Task {
                                if session.playback == .playing {
                                    await playback.pause(artifact: artifact, player: player)
                                } else {
                                    await playback.play(artifact: artifact, player: player)
                                }
                            }
                        }
                        if playback.status == .decoded { Text("Decoded pixel buffer").foregroundStyle(.secondary) }
                    }
                    .font(.caption)
                } else {
                    Text("Loading verified artifact.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Rendered artifact \(artifact.key.outputSHA256.prefix(12)) · revision \(artifact.key.revision)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            .task(id: artifact.key.outputSHA256 + artifact.key.revision) {
                await playback.load(artifact: artifact, player: player)
            }
        case .cancelled: waiting("Rendered preview was cancelled. No partial artifact is available.")
        case .superseded: waiting("Rendered preview belongs to an older plan revision and cannot be displayed as current.")
        case let .failed(message): waiting(message)
            }
        }
        .onChange(of: store.status) { _, status in
            if case .succeeded = status { return }
            player.stop()
        }
        .onDisappear { player.stop() }
    }

    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView("Rendered preview unavailable", systemImage: "film.stack", description: Text(message + " Original-asset inspection remains separate."))
            .accessibilityLabel("Rendered preview unavailable")
    }

    private func waiting(_ message: String) -> some View {
        ContentUnavailableView("Waiting for rendered artifact", systemImage: "clock", description: Text(message))
            .accessibilityLabel("Rendered preview wait state")
    }

    private func progressText(_ progress: RendererProgress) -> String {
        switch progress {
        case .indeterminate: "Renderer is working. It did not report a numeric progress value."
        case let .units(completed, total): "Renderer progress: \(completed) of \(total) reported units."
        }
    }
}
