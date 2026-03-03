import SwiftUI
import AppKit

// MARK: - App Entry Point

@main
struct LectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .frame(minWidth: 800, minHeight: 600)
        }
        .commands {
            // File menu
            CommandGroup(replacing: .newItem) {
                Button("Open…") { state.openDocumentDialog() }
                    .keyboardShortcut("o", modifiers: .command)

                Menu("Open Recent") {
                    ForEach(state.recentDocuments.prefix(10)) { doc in
                        Button(doc.url.lastPathComponent) {
                            state.openDocument(at: doc.url)
                        }
                    }
                }
            }

            // View menu extras
            CommandGroup(after: .toolbar) {
                Button("Toggle Table of Contents") { state.showTOC.toggle() }
                    .keyboardShortcut("t", modifiers: .command)

                Toggle("Dark Mode", isOn: Binding(
                    get: { state.isDarkMode },
                    set: { state.isDarkMode = $0 }
                ))
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        // Settings window
        Settings {
            PreferencesView(state: state)
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        // Handle file open via Finder or command-line
        // The main window's AppState will pick this up via notification
        NotificationCenter.default.post(name: .lectorOpenURL, object: urls.first)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Activate the app window
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

extension Notification.Name {
    static let lectorOpenURL = Notification.Name("lectorOpenURL")
}
