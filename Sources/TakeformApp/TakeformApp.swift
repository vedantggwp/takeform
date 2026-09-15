import AppKit
import SwiftUI
import TakeformSupport

@MainActor
final class TakeformAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppAppearance.applyStoredPreference()
        NSApp.activate(ignoringOtherApps: true)
    }
}

private enum AppAppearance: String, CaseIterable, Identifiable {
    static let defaultsKey = "takeform.appAppearance"

    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }

    @MainActor
    static func applyStoredPreference() {
        apply(rawValue: UserDefaults.standard.string(forKey: defaultsKey))
    }

    @MainActor
    static func apply(rawValue: String?) {
        let preference = rawValue.flatMap(Self.init(rawValue:)) ?? .system
        switch preference {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
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
                    .accessibilityLabel(identity.displayName)
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
    @AppStorage(AppAppearance.defaultsKey) private var appearance = AppAppearance.system.rawValue

    var body: some View {
        TabView {
            Form {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { preference in
                        Text(preference.title).tag(preference.rawValue)
                    }
                }
                .accessibilityIdentifier("appearance-preference")
                .onChange(of: appearance) { _, value in
                    AppAppearance.apply(rawValue: value)
                }

                Text("Appearance is the only application preference available in this development foundation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 460, height: 240)
    }
}
