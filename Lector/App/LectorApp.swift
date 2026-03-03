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
                .onOpenURL { url in
                    state.openDocument(at: url)
                }
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
// Note: application(_:open:) is intentionally NOT implemented here.
// When a custom delegate overrides that method, it intercepts the event and
// SwiftUI's .onOpenURL modifier never fires. Removing it lets SwiftUI route
// file-open events directly to .onOpenURL on the WindowGroup.

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
