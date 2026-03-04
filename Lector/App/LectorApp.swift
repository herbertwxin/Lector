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
                .navigationTitle(state.documentURL?.deletingPathExtension().lastPathComponent ?? "")
                .onAppear {
                    // Register exactly once so only the primary window handles
                    // Finder file opens — prevents duplicate windows when macOS
                    // restores multiple WindowGroup instances from a prior session.
                    appDelegate.registerOpenHandler { url in
                        if state.document != nil {
                            // A PDF is already open — always use a new window so
                            // the existing document is not replaced.
                            NotificationCenter.default.post(
                                name: .lectorOpenNewWindow,
                                object: nil,
                                userInfo: ["url": url]
                            )
                        } else {
                            state.openDocument(at: url)
                        }
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

        CommandGroup(replacing: .printItem) {
            Button("Print…") { state?.printDocument() }
                .keyboardShortcut("p", modifiers: .command)
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
    // Receives Finder file-open events and routes them to the primary window's
    // AppState.  Registered once by the primary ContentView on first appear.
    // Using a direct closure instead of a broadcast notification prevents
    // duplicate handling when macOS restores multiple WindowGroup windows.
    private var openHandler: ((URL) -> Void)?
    private var pendingURLs: [URL] = []

    /// Called once by the primary ContentView. Flushes any URLs that arrived
    /// before the view was ready (app-launch double-click scenario).
    func registerOpenHandler(_ handler: @escaping (URL) -> Void) {
        guard openHandler == nil else { return }   // only the first window registers
        openHandler = handler
        let pending = pendingURLs
        pendingURLs = []
        pending.forEach { handler($0) }
    }

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
        NSWindow.allowsAutomaticWindowTabbing = false

        // Close any Settings window that macOS restored from the previous session.
        DispatchQueue.main.async {
            NSApp.windows
                .filter { $0.title == "Settings" || $0.title == "Preferences" }
                .forEach { $0.close() }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenNewWindow(_:)),
            name: .lectorOpenNewWindow,
            object: nil
        )
    }

    // Called by macOS at launch (files on command line / double-clicked before
    // the app started) and while already running (Finder double-click, "Open With…").
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let handler = openHandler {
                handler(url)
            } else {
                // View not yet ready — queue for when registerOpenHandler is called.
                pendingURLs.append(url)
            }
        }
    }

    // MARK: - Multi-window support

    @objc private func handleOpenNewWindow(_ notification: Notification) {
        guard let url = notification.userInfo?["url"] as? URL else { return }
        let readOnly  = notification.userInfo?["readOnly"]  as? Bool   ?? false
        let startPage = notification.userInfo?["page"]      as? Int
        let startY    = notification.userInfo?["yOffset"]   as? Double

        let newState = AppState(readOnly: readOnly)
        let rootView = ContentView(state: newState)
            .frame(minWidth: 800, minHeight: 600)
            .onDisappear { newState.closeDocument() }

        let controller = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: controller)
        window.title = url.lastPathComponent
        window.setContentSize(NSSize(width: 1024, height: 768))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()
        window.makeKeyAndOrderFront(nil)
        newState.openDocument(at: url)
        if let page = startPage { newState.currentPage = page }
        if let y    = startY    { newState.scrollYOffset = y }
    }
}
