import SwiftUI

@main
struct NativePreviewHostApp: App {
    @State private var store = PreviewStore.diagnostic()

    var body: some Scene {
        WindowGroup("Takeform Native Preview") {
            ContentView(store: store)
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
