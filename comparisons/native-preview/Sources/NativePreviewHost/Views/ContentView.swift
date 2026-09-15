import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: PreviewStore

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            PreviewWebView(store: store)
                .accessibilityLabel("Native preview page")
            Divider()
            status
        }
        .onDisappear { store.stopHelper() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            store.stopHelperForApplicationTermination()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Backend", selection: $store.selectedPage) {
                    Text("Diagnostic").tag("diagnostic")
                    Text("Renderer bundle").tag("bundle")
                }
                .accessibilityLabel("Preview backend")
                Spacer()
                Button("Load page") { store.startDiagnostic() }
                    .keyboardShortcut("l", modifiers: [.command])
                    .accessibilityHint("Starts the local loopback helper and loads the selected page")
                Button("Stop helper") { store.stopHelper() }
                    .accessibilityHint("Stops the app-owned loopback helper")
            }
            HStack {
                Button("Choose Node") { store.nodeURL = chooseFile(title: "Choose Node executable", directories: false) ?? store.nodeURL }
                Button("Choose bundle root") { store.bundleRoot = chooseFile(title: "Choose comparison bundle root", directories: true) ?? store.bundleRoot }
                Button("Choose fixture root") { store.fixtureRoot = chooseFile(title: "Choose fixture root", directories: true) ?? store.fixtureRoot }
                Text(configurationSummary).foregroundStyle(.secondary).lineLimit(1)
            }
            .accessibilityElement(children: .contain)
            HStack {
                Text("Frame \(store.session.requestedFrame + 1) / \(store.session.totalFrames)")
                    .monospacedDigit()
                    .frame(width: 140, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(store.session.requestedFrame) },
                    set: { store.setRequestedFrame(Int($0)) }
                ), in: 0...Double(store.session.totalFrames - 1), step: 1) { Text("Requested frame") }
                    .accessibilityLabel("Requested frame")
                Button("Seek") { store.markSent(store.commandForRequestedFrame()) }
                    .accessibilityHint("Sends a seek request. The displayed frame changes only after the page acknowledges it.")
                Button(store.session.playback == .playing ? "Pause" : "Play") {
                    store.session.playback == .playing ? store.pause() : store.play()
                }
            }
            HStack {
                Text("Timecode \(timecode(frame: store.session.requestedFrame))")
                Text("Snapshot \(store.session.snapshotID)").textSelection(.enabled)
                if let acknowledged = store.session.acknowledgedFrame {
                    Text("Displayed \(acknowledged + 1)")
                } else {
                    Text("Awaiting page acknowledgement").foregroundStyle(.secondary)
                }
                if let latency = store.state.lastLatency {
                    Text(String(format: "%@ #%llu %.2f ms %@", latency.kind.rawValue, latency.requestID, latency.milliseconds, store.state.acknowledgementStatus?.rawValue ?? "unknown"))
                        .monospacedDigit()
                }
                if !store.acknowledgementLog.isEmpty {
                    Text(store.acknowledgementLog.joined(separator: " · "))
                        .accessibilityLabel("Acknowledgement log")
                        .accessibilityValue(store.acknowledgementLog.joined(separator: ", "))
                        .monospacedDigit()
                }
            }
            .font(.caption)
        }
        .padding()
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(store.helperStatus)
            if let stale = store.session.staleNotice { Text(stale).foregroundStyle(.orange) }
            if let error = store.session.error { Text(error).foregroundStyle(.red) }
            Text("Page acknowledgements mean a web paint callback. They do not prove decoded source media or renderer output.")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview status")
    }

    private func timecode(frame: Int) -> String {
        let totalMilliseconds = Int(Double(frame) * store.session.frameRate.secondsPerFrame * 1_000)
        return String(format: "%02d:%02d.%03d", totalMilliseconds / 60_000, (totalMilliseconds / 1_000) % 60, totalMilliseconds % 1_000)
    }

    private var configurationSummary: String {
        let node = store.nodeURL == nil ? "Node missing" : "Node selected"
        let bundle = store.bundleRoot == nil ? "bundle root missing" : "bundle root selected"
        let fixtures = store.fixtureRoot == nil ? "fixture root missing" : "fixture root selected"
        return "\(node), \(bundle), \(fixtures)"
    }

    private func chooseFile(title: String, directories: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
