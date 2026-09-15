import SwiftUI

@main
struct NativePreviewHostApp: App {
    @State private var store = PreviewStore.diagnostic()
    @State private var renderedStore = RenderedPreviewStore(currentRevision: "renderer-unconnected")
    @State private var renderedPlayback = RenderedPreviewPlaybackStore()
    @State private var renderedPlayer = RenderedPreviewPlayer()

    var body: some Scene {
        WindowGroup("Takeform Native Preview") {
            ContentView(store: store, renderedStore: renderedStore, renderedPlayback: renderedPlayback, renderedPlayer: renderedPlayer)
                .frame(minWidth: 980, minHeight: 680)
        }
        .commands {
            CommandMenu("Preview") {
                Button("Play") { store.play() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Pause") { store.pause() }
                    .keyboardShortcut(".", modifiers: [])
            }
        }
    }
}
