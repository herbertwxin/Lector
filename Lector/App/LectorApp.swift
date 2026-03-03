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
                .onAppear {
                    // Give AppDelegate a direct path to the primary AppState so
                    // application(_:open:) can route Finder opens without going
                    // through a Combine/notification subscription that may not
                    // be live at the moment the event arrives.
                    appDelegate.openDocumentHandler = { url in
                        state.openDocument(at: url)
                    }
                }
                .onDisappear {
                    // Window was closed (red button). Save position and reset to
                    // home screen so re-opening the window starts fresh.
                    state.closeDocument()
                }
        }
        .commands {
            LectorCommands()
        }

        // Settings window
        Settings {
            PreferencesView(state: state)
        }
    }
}

// MARK: - Commands
// Uses @FocusedValue so menu actions always target the currently focused window,
// whether that is the primary window or a tab/new window opened later.

struct LectorCommands: Commands {
    @FocusedValue(\.appState) private var state: AppState?

    var body: some Commands {
        // File menu
        CommandGroup(replacing: .newItem) {
            Button("Open…") { state?.openDocumentDialog() }
                .keyboardShortcut("o", modifiers: .command)

            Menu("Open Recent") {
                if let docs = state?.recentDocuments {
                    ForEach(Array(docs.prefix(10))) { doc in
                        Button(doc.url.lastPathComponent) {
                            state?.openDocument(at: doc.url)
                        }
                    }
                }
            }
        }

        // View menu extras
        CommandGroup(after: .toolbar) {
            Button("Toggle Table of Contents") { state?.showTOC.toggle() }
                .keyboardShortcut("t", modifiers: .command)

            Button("Toggle Appearance (Auto/Dark/Light)") { state?.execute(.toggleDarkMode) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the primary WindowGroup view on appear. Called directly by
    /// application(_:open:) so no Combine/notification subscription is needed.
    var openDocumentHandler: ((URL) -> Void)?

    // Keep the app alive when the window is closed (red button).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // Clicking the Dock icon re-shows the window when none are visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Enable macOS's built-in tab bar so addTabbedWindow(_:ordered:) works.
        NSWindow.allowsAutomaticWindowTabbing = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenNewWindow(_:)),
            name: .lectorOpenNewWindow,
            object: nil
        )
    }

    // Called by macOS both at launch (double-clicked before app started) and
    // while already running (Finder double-click, "Open With…", drag-onto-Dock).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            openDocumentHandler?(url)
        }
    }

    // MARK: - Multi-window / tab support

    @objc private func handleOpenNewWindow(_ notification: Notification) {
        guard let url   = notification.userInfo?["url"]   as? URL,
              let asTab = notification.userInfo?["asTab"] as? Bool else { return }
        openDocumentWindow(url: url, asTab: asTab)
    }

    private func openDocumentWindow(url: URL, asTab: Bool) {
        let newState = AppState()
        let rootView = ContentView(state: newState)
            .frame(minWidth: 800, minHeight: 600)
            .onDisappear { newState.closeDocument() }

        let controller = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: controller)
        window.title = url.lastPathComponent
        window.setContentSize(NSSize(width: 1024, height: 768))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()

        if asTab, let keyWindow = NSApp.keyWindow {
            keyWindow.addTabbedWindow(window, ordered: .above)
        }
        window.makeKeyAndOrderFront(nil)
        // Open the document after the window is on screen so the PDF view
        // is ready to receive the initial page/zoom restore.
        newState.openDocument(at: url)
    }
}
