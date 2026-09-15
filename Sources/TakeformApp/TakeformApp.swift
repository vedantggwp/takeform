import AppKit
import SwiftUI
import TakeformSupport

final class TakeformAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct TakeformApp: App {
    @NSApplicationDelegateAdaptor(TakeformAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Takeform", id: "main") {
            ContentView()
        }
        .defaultSize(width: 1024, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .saveItem) {}
        }

        Settings {
            SettingsView()
        }
    }
}

private struct ContentView: View {
    private let identity = ProductIdentity.declared

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                Label(identity.displayName, systemImage: "rectangle.3.group")
                    .font(.system(size: 32, weight: .semibold))
                    .accessibilityIdentifier("takeform-title")
                Spacer()
                Text(identity.developmentVersion)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Development version \(identity.developmentVersion)")
            }

            Text("Native development foundation")
                .font(.title3)
                .foregroundStyle(.secondary)

            GroupBox("Available in this build") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Native app menus and About information", systemImage: "menubar.rectangle")
                    Label("A dedicated Settings window", systemImage: "gearshape")
                    Label("Build and tool diagnostics from the checkout", systemImage: "stethoscope")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Development status") {
                Text("Project editing, preview, and export are not available in this development slice.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Project editing, preview, and export are not available")
            }

            SettingsLink {
                Label("Open Settings", systemImage: "gearshape")
            }
            .accessibilityIdentifier("open-settings")

            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(minWidth: 720, minHeight: 500, alignment: .topLeading)
    }
}

private struct SettingsView: View {
    @AppStorage("showDevelopmentDetails") private var showDevelopmentDetails = true

    var body: some View {
        TabView {
            Form {
                Toggle("Show development details", isOn: $showDevelopmentDetails)
                    .accessibilityIdentifier("show-development-details")
                Text("This setting only changes the amount of status detail shown by future development features.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 460, height: 240)
    }
}
