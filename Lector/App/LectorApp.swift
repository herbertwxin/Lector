import SwiftUI
import AppKit

// MARK: - App Entry Point

@main
struct LectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            WindowWrapper()
                .frame(minWidth: 800, minHeight: 600)
        }
        .commands {
            LectorCommands()
        }

        // Settings window
        Settings {
            PreferencesWrapper()
        }
    }
}

// MARK: - Window Wrapper

struct WindowWrapper: View {
    @State private var state: AppState

    init(state: AppState = AppState()) {
        _state = State(wrappedValue: state)
    }

    var body: some View {
        ContentView(state: state)
            .frame(minWidth: 800, minHeight: 600)
            .navigationTitle(state.documentURL?.deletingPathExtension().lastPathComponent ?? "")
            .background(WindowAccessor { window in
                AppWindowManager.shared.register(window: window, state: state)
            })
            .onDisappear {
                AppWindowManager.shared.unregister(state: state)
                state.closeDocument()
            }
    }
}

struct PreferencesWrapper: View {
    @State private var state = AppState()
    var body: some View {
        PreferencesView(state: state)
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
    // Set to true once the first window has registered. Before that we are
    // still in the SwiftUI launch phase where the WindowGroup window is being
    // created; queuing pending URLs is safer than posting a notification that
    // would spawn a second window before the first one registers.
    private var hasEverRegistered = false
    private init() {}

    func register(window: NSWindow, state: AppState) {
        hasEverRegistered = true
        entries.removeAll { $0.window == nil || $0.state == nil || $0.state === state }
        entries.append(Entry(window: window, state: state))

        if state.document != nil {
            // A document window just registered. Close any lingering blank (home)
            // windows — handles the race where a blank window registered first
            // (e.g. macOS created a WindowGroup scene before openURL ran).
            let blanks = entries.filter {
                $0.state?.document == nil && $0.window != nil && $0.state !== state
            }
            blanks.forEach { $0.window?.close() }
            entries.removeAll { $0.state?.document == nil && $0.state !== state }
        } else {
            // A blank window registered. Close it if a document window already
            // exists and we have nothing queued to load into it.
            let hasDocumentWindow = entries.contains {
                $0.state?.document != nil && $0.window != nil && $0.state !== state
            }
            if hasDocumentWindow && pendingURLs.isEmpty {
                window.close()
                entries.removeAll { $0.window == nil || $0.state === state }
                return
            }
        }

        // If the app was launched (or a URL was opened) before any window
        // existed, pending URLs are queued here. Prefer to load the first
        // pending URL into this brand-new, empty SwiftUI window instead of
        // spawning an extra “home” window plus a separate document window.
        if !pendingURLs.isEmpty {
            var remaining = pendingURLs
            pendingURLs = []

            if state.document == nil, let first = remaining.first {
                state.openDocument(at: first)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                remaining.removeFirst()
            }

            // Any additional URLs still get their own windows via openURL.
            remaining.forEach { openURL($0) }
        }
    }

    func unregister(state: AppState) {
        entries.removeAll { $0.state === state || $0.window == nil || $0.state == nil }
    }

    func openURL(_ url: URL) {
        entries.removeAll { $0.window == nil || $0.state == nil }
        if entries.isEmpty {
            if hasEverRegistered {
                // App is running but all windows were closed. Spin up a new
                // window immediately — no SwiftUI WindowGroup window is coming.
                NotificationCenter.default.post(
                    name: .lectorOpenNewWindow,
                    object: nil,
                    userInfo: ["url": url]
                )
            } else {
                // Still in the launch phase: the SwiftUI WindowGroup window is
                // being created and will pick up this URL via register().
                pendingURLs.append(url)
            }
            return
        }

        // If a window with this URL is already open, bring it to front.
        if let entry = entries.first(where: { $0.state?.documentURL == url }),
           let win = entry.window {
            win.deminiaturize(nil)
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // If a blank (home screen) window is available, reuse it instead of
        // spawning a new one. This handles the case where macOS creates a
        // WindowGroup scene before application(_:open:urls:) fires.
        if let entry = entries.first(where: { $0.state?.document == nil }),
           let state = entry.state,
           let win = entry.window {
            state.openDocument(at: url)
            win.deminiaturize(nil)
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // All existing windows have documents; create a new window.
        NotificationCenter.default.post(
            name: .lectorOpenNewWindow,
            object: nil,
            userInfo: ["url": url]
        )
    }

    func bringAnyWindowToFront() {
        entries.removeAll { $0.window == nil || $0.state == nil }
        if let win = entries.first?.window {
            win.deminiaturize(nil)
            win.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Window Accessor

struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    /// updateNSView fires after layout, guaranteeing nsView.window is non-nil.
    /// The coordinator ensures we call back exactly once per view lifetime.
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window, !context.coordinator.didFire else { return }
        context.coordinator.didFire = true
        callback(window)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var didFire = false
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
            Button("Open…") {
                if let state = state, state.document == nil {
                    state.openDocumentDialog()
                } else {
                    // Current window occupied or no focused state -> use open panel then AppWindowManager
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    panel.canChooseFiles = true
                    if panel.runModal() == .OK, let url = panel.url {
                        AppWindowManager.shared.openURL(url)
                    }
                }
            }
            .keyboardShortcut("o", modifiers: .command)

            Menu("Open Recent") {
                if let docs = state?.recentDocuments {
                    ForEach(Array(docs.prefix(10))) { doc in
                        Button(doc.url.lastPathComponent) {
                            AppWindowManager.shared.openURL(doc.url)
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
        let rootView = WindowWrapper(state: newState)

        let controller = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: controller)
        window.title = url.lastPathComponent
        window.setContentSize(NSSize(width: 1024, height: 768))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isRestorable = false
        window.center()
        
        // WindowWrapper handles AppWindowManager registration via WindowAccessor.

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        newState.openDocument(at: url)
        if let page = startPage { newState.currentPage = page }
        if let y    = startY    { newState.scrollYOffset = y }
    }
}
