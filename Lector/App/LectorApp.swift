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
                .background(WindowAccessor { window in
                    guard let window else { return }
                    AppWindowManager.shared.register(window: window, state: state)
                })
                .onDisappear {
                    AppWindowManager.shared.unregister(state: state)
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

// MARK: - Window Manager

final class AppWindowManager {
    static let shared = AppWindowManager()

    private struct Entry {
        weak var window: NSWindow?
        weak var state: AppState?
    }
    private var entries: [Entry] = []
    private var pendingURLs: [URL] = []
    private init() {}

    func register(window: NSWindow, state: AppState) {
        entries.removeAll { $0.window == nil || $0.state == nil || $0.state === state }
        entries.append(Entry(window: window, state: state))
        if !pendingURLs.isEmpty {
            let pending = pendingURLs; pendingURLs = []
            pending.forEach { openURL($0) }
        }
    }

    func unregister(state: AppState) {
        entries.removeAll { $0.state === state || $0.window == nil || $0.state == nil }
    }

    func openURL(_ url: URL) {
        entries.removeAll { $0.window == nil || $0.state == nil }
        guard !entries.isEmpty else { pendingURLs.append(url); return }

        // Already open → bring to front
        if let entry = entries.first(where: { $0.state?.documentURL == url }),
           let win = entry.window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Empty window available → reuse it
        if let entry = entries.first(where: { $0.state?.document == nil }),
           let win = entry.window, let st = entry.state {
            st.openDocument(at: url)
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // All windows occupied → open a new one
        NotificationCenter.default.post(name: .lectorOpenNewWindow, object: nil,
                                        userInfo: ["url": url])
    }

    func bringAnyWindowToFront() {
        entries.removeAll { $0.window == nil || $0.state == nil }
        entries.first?.window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Window Accessor

struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.callback(view.window) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
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

    // Keep the app alive when the window is closed (red button).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // Clicking the Dock icon re-shows a window when none are visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            AppWindowManager.shared.bringAnyWindowToFront()
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

    // Called by macOS at launch and while running (Finder double-click, "Open With…").
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { AppWindowManager.shared.openURL($0) }
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
            .onDisappear {
                AppWindowManager.shared.unregister(state: newState)
                newState.closeDocument()
            }

        let controller = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: controller)
        window.title = url.lastPathComponent
        window.setContentSize(NSSize(width: 1024, height: 768))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isRestorable = false
        window.center()
        AppWindowManager.shared.register(window: window, state: newState)
        window.makeKeyAndOrderFront(nil)
        newState.openDocument(at: url)
        if let page = startPage { newState.currentPage = page }
        if let y    = startY    { newState.scrollYOffset = y }
    }
}
