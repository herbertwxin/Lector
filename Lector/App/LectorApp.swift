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
// Design: pendingURLs handles the cold-start handoff only (when the SwiftUI
// WindowGroup window is being created before application(_:open:) fires).
// For every subsequent Finder open the URL is passed directly in the
// lectorOpenNewWindow notification so handleOpenNewWindow pre-loads the
// document BEFORE the window is shown.  This guarantees register() always
// sees state.document != nil for programmatic document windows and never
// mistakes them for stray blank scenes that must be closed.

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

        // Document window (pre-loaded via split/portal or Finder open-with-manual-window)
        if state.document != nil {
            sweepBlankWindows(except: state)
            return
        }

        // Blank window.
        // If we have a pending cold-start URL, drain the first one into this window.
        if let url = pendingURLs.first {
            pendingURLs.removeFirst()
            state.openDocument(at: url)
            window.title = url.lastPathComponent
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            
            // Sweep any other blank windows that macOS may have spawned during launch.
            sweepBlankWindows(except: state)
            
            // If there are more URLs (e.g. 3 files selected in Finder), dispatch
            // them to openURL(). Since hasEverRegistered is now true, they will
            // be opened in new windows.
            if !pendingURLs.isEmpty {
                let remaining = pendingURLs
                pendingURLs = []
                DispatchQueue.main.async {
                    remaining.forEach { AppWindowManager.shared.openURL($0) }
                }
            }
        } else {
            // No pending URL. Close this window ONLY if a document window ALREADY
            // exists; it is a stray companion scene spawned by macOS.
            let hasDocumentWindow = entries.contains {
                $0.state?.document != nil && $0.window != nil && $0.state !== state
            }
            if hasDocumentWindow {
                window.close()
                entries.removeAll { $0.window == nil || $0.state === state }
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

        guard hasEverRegistered else {
            // Launch phase: the SwiftUI WindowGroup window is being created
            // and will drain pendingURLs when it first calls register().
            if !pendingURLs.contains(url) {
                pendingURLs.append(url)
            }
            return
        }

        // If a blank (welcome-screen) window is already registered, load the
        // URL directly into it — no new window needed.
        if let entry = entries.first(where: { $0.state?.document == nil }),
           let blankState = entry.state, let win = entry.window {
            blankState.openDocument(at: url)
            win.title = url.lastPathComponent
            win.deminiaturize(nil)
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            // Sweep any other blank windows macOS may have spawned alongside
            // this one.
            sweepBlankWindows(except: blankState)
            return
        }

        // No blank window available. Create a new window.
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
            // Load the document BEFORE building the view hierarchy.
            // WindowWrapper registers this window via WindowAccessor; if
            // state.document were nil at that point register() would treat this
            // window as a stray blank scene and close it.  Pre-loading ensures
            // register() sees a real document window and sweeps any companion
            // blank scenes macOS may have spawned alongside this one.
            newState.openDocument(at: url)
            if let page = startPage { newState.currentPage  = page }
            if let y    = startY    { newState.scrollYOffset = y   }
        }
        // url == nil only for the cold-start blank welcome window; register()
        // will load pendingURLs into it when the first URL arrives.

        let rootView   = WindowWrapper(state: newState)
        let controller = NSHostingController(rootView: rootView)
        let window     = NSWindow(contentViewController: controller)
        window.title   = url?.lastPathComponent ?? ""
        window.setContentSize(NSSize(width: 1024, height: 768))
        window.styleMask    = [.titled, .closable, .miniaturizable, .resizable]
        window.isRestorable = false
        window.center()

        // WindowWrapper handles AppWindowManager registration via WindowAccessor.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
