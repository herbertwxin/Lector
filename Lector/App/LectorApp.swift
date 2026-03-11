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
//
// Design: pendingURLs is the *universal* handoff between openURL() and the
// window system — at launch, during reopen, and for every subsequent Finder
// open.  openURL() queues a URL and ensures a blank window exists (creating
// one if needed).  The blank window drains pendingURLs the moment it
// registers, regardless of whether that registration happens synchronously
// inside makeKeyAndOrderFront or asynchronously on the next display frame.
// This means we never need to race against updateNSView timing.

final class AppWindowManager {
    static let shared = AppWindowManager()

    private struct Entry {
        weak var window: NSWindow?
        weak var state: AppState?
    }
    private var entries: [Entry] = []
    // URLs waiting to be loaded into the next available blank window.
    private var pendingURLs: [URL] = []
    // True once any window has registered — marks the end of the SwiftUI
    // launch phase where WindowGroup creates the first scene.
    private var hasEverRegistered = false
    private init() {}

    // MARK: Registration

    func register(window: NSWindow, state: AppState) {
        hasEverRegistered = true
        entries.removeAll { $0.window == nil || $0.state == nil || $0.state === state }
        entries.append(Entry(window: window, state: state))

        if state.document != nil {
            // Document window (e.g. opened via split/portal with a pre-loaded URL).
            // Sweep out any stray blank scenes macOS created alongside it.
            sweepBlankWindows(except: state)
        } else {
            // Blank (home-screen) window.
            if let url = pendingURLs.first {
                // A URL is waiting — load it and bring this window to front.
                pendingURLs.removeFirst()
                state.openDocument(at: url)
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                // Dispatch any remaining pending URLs on the next run-loop turn
                // to avoid deep re-entrant call stacks.
                let remaining = pendingURLs
                pendingURLs = []
                if !remaining.isEmpty {
                    DispatchQueue.main.async {
                        remaining.forEach { AppWindowManager.shared.openURL($0) }
                    }
                }
            } else {
                // No pending URL. Close this window if document windows already
                // exist; it is a stray companion scene spawned by macOS.
                let hasDocumentWindow = entries.contains {
                    $0.state?.document != nil && $0.window != nil && $0.state !== state
                }
                if hasDocumentWindow {
                    window.close()
                    entries.removeAll { $0.window == nil || $0.state === state }
                }
                // Otherwise keep it as the welcome screen.
            }
        }
    }

    private func sweepBlankWindows(except current: AppState) {
        let blanks = entries.filter {
            $0.state?.document == nil && $0.window != nil && $0.state !== current
        }
        blanks.forEach { $0.window?.close() }
        entries.removeAll { $0.state?.document == nil && $0.state !== current }
    }

    func unregister(state: AppState) {
        entries.removeAll { $0.state === state || $0.window == nil || $0.state == nil }
    }

    // MARK: URL Opening

    func openURL(_ url: URL) {
        entries.removeAll { $0.window == nil || $0.state == nil }

        // Bring to front if this URL is already open.
        if let entry = entries.first(where: { $0.state?.documentURL == url }),
           let win = entry.window {
            win.deminiaturize(nil)
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Queue the URL.  The blank window that drains it may already be
        // registered below, or will arrive shortly via register().
        pendingURLs.append(url)

        guard hasEverRegistered else {
            // Launch phase: the SwiftUI WindowGroup window is being created
            // and will drain pendingURLs when it first calls register().
            return
        }

        // If a blank window is already registered, drain into it immediately.
        if let entry = entries.first(where: { $0.state?.document == nil }),
           let blankState = entry.state, let win = entry.window,
           let first = pendingURLs.first {
            pendingURLs.removeFirst()
            blankState.openDocument(at: first)
            win.deminiaturize(nil)
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let remaining = pendingURLs
            pendingURLs = []
            if !remaining.isEmpty {
                DispatchQueue.main.async {
                    remaining.forEach { AppWindowManager.shared.openURL($0) }
                }
            }
            return
        }

        // No blank window is available yet.  Create a new (initially blank)
        // window; when it registers via WindowAccessor it will drain pendingURLs.
        NotificationCenter.default.post(
            name: .lectorOpenNewWindow,
            object: nil,
            userInfo: nil   // nil = blank window; register() will load pendingURLs
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
    /// The coordinator ensures the callback fires exactly once per window lifetime.
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
        let url       = notification.userInfo?["url"]      as? URL
        let readOnly  = notification.userInfo?["readOnly"] as? Bool   ?? false
        let startPage = notification.userInfo?["page"]     as? Int
        let startY    = notification.userInfo?["yOffset"]  as? Double

        let newState = AppState(readOnly: readOnly)

        if let url {
            // Internal navigation (split, portal, "open in new window"):
            // pre-load state so register() sees a non-nil document and never
            // treats this window as a stray blank scene.
            newState.openDocument(at: url)
            if let page = startPage { newState.currentPage  = page }
            if let y    = startY    { newState.scrollYOffset = y   }
        }
        // nil url → intentionally blank window; register() will drain pendingURLs.

        let rootView   = WindowWrapper(state: newState)
        let controller = NSHostingController(rootView: rootView)
        let window     = NSWindow(contentViewController: controller)
        window.title   = url?.lastPathComponent ?? ""
        window.setContentSize(NSSize(width: 1024, height: 768))
        window.styleMask    = [.titled, .closable, .miniaturizable, .resizable]
        window.isRestorable = false
        window.center()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
