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
// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  ARCHITECTURE NOTE — read before touching file-opening logic            ║
// ║                                                                          ║
// ║  There are four distinct entry points for opening files, each with       ║
// ║  its own invariants.  Breaking any one of them tends to resurrect the    ║
// ║  blank-welcome-screen or silent-no-window bugs.                          ║
// ║                                                                          ║
// ║  1. COLD START (hasEverRegistered == false)                              ║
// ║     application(_:open:) fires before the SwiftUI WindowGroup window     ║
// ║     exists.  URL is queued in pendingURLs.  The first window that calls  ║
// ║     register() drains pendingURLs and loads the document.               ║
// ║                                                                          ║
// ║  2. FINDER OPEN / WARM START — blank window available                   ║
// ║     application(_:open:) fires, openURL() finds a blank (welcome-screen) ║
// ║     window in entries and calls openDocument(at:) on it directly.        ║
// ║                                                                          ║
// ║  3. FINDER OPEN / WARM START — no blank window                          ║
// ║     application(_:open:) fires, openURL() posts lectorOpenNewWindow with  ║
// ║     the URL in userInfo.  handleOpenNewWindow() creates an NSWindow,     ║
// ║     calls openDocument(at:) BEFORE makeKeyAndOrderFront so that          ║
// ║     register() sees state.document != nil and treats it as a real        ║
// ║     document window (not a stray blank).                                 ║
// ║                                                                          ║
// ║  4. DOCK CLICK / REOPEN — no visible windows                            ║
// ║     applicationShouldHandleReopen fires.  bringAnyWindowToFront()       ║
// ║     deminiaturises an existing window (if any) and activates the app.   ║
// ║     If there are NO windows at all, a blank window is opened explicitly  ║
// ║     so the user gets a welcome screen.  If application(_:open:) also    ║
// ║     fires (Finder file-open while app had no windows), openURL() finds   ║
// ║     that blank window and loads the document into it.                    ║
// ║                                                                          ║
// ║  INVARIANTS that must never be broken:                                   ║
// ║  • openDocument(at:) is always called BEFORE makeKeyAndOrderFront for   ║
// ║    programmatic (handleOpenNewWindow) windows, so register() always sees ║
// ║    state.document != nil.                                                ║
// ║  • bringAnyWindowToFront() always calls NSApp.activate so the app       ║
// ║    actually comes to the foreground.                                     ║
// ║  • pendingURLs is only used during cold start (hasEverRegistered==false).║
// ╚══════════════════════════════════════════════════════════════════════════╝

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
                // Cold-start path: a URL was queued before any window existed.
                // Load it into this blank window.
                pendingURLs.removeFirst()
                state.openDocument(at: url)
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                // Sweep any other blank companion windows macOS may have created
                // during launch — they are now redundant.
                sweepBlankWindows(except: state)
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

        guard hasEverRegistered else {
            // Launch phase: the SwiftUI WindowGroup window is being created
            // and will drain pendingURLs when it first calls register().
            pendingURLs.append(url)
            return
        }

        // If a blank (welcome-screen) window is already registered, load the
        // URL directly into it — no new window needed.
        if let entry = entries.first(where: { $0.state?.document == nil }),
           let blankState = entry.state, let win = entry.window {
            blankState.openDocument(at: url)
            win.deminiaturize(nil)
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            // Sweep any other blank windows macOS may have spawned alongside
            // this one.  Without this call a second companion WindowGroup scene
            // that registered before openURL() ran would linger as a homepage.
            sweepBlankWindows(except: blankState)
            return
        }

        // No blank window available.  Create a new window with the URL embedded
        // in the notification so handleOpenNewWindow pre-loads the document
        // BEFORE the window is displayed.  register() will then see
        // state.document != nil, treat the window as a real document window,
        // and sweep any stray companion blank scenes macOS may have spawned.
        NotificationCenter.default.post(
            name: .lectorOpenNewWindow,
            object: nil,
            userInfo: ["url": url]
        )
    }

    /// Deminiaturise and activate the first registered window, if any.
    /// Returns true when a window was found and brought to front.
    @discardableResult
    func bringAnyWindowToFront() -> Bool {
        entries.removeAll { $0.window == nil || $0.state == nil }
        if let win = entries.first?.window {
            win.deminiaturize(nil)
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)   // ← was missing; app stayed in background
            return true
        }
        return false
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

    // Clicking the Dock icon (or any activation while the app has no visible
    // windows) ends up here.  This is also called before application(_:open:)
    // when the user double-clicks a file in Finder while every window is
    // closed or minimised.
    //
    // Strategy:
    //   • Minimised windows → deminiaturise + activate (bringAnyWindowToFront).
    //   • No windows at all → open a blank window explicitly.
    //       - Dock-click: the blank window shows the welcome screen.
    //       - Finder file-open: application(_:open:) fires next and
    //         openURL() finds this blank window and loads the PDF into it,
    //         so the user never sees the welcome screen flash.
    //
    // DO NOT rely on returning true to make SwiftUI create a window —
    // that behaviour is unreliable when isRestorable=false and varies
    // across macOS versions.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            if !AppWindowManager.shared.bringAnyWindowToFront() {
                // No existing window to deminiaturise — open a blank one.
                NotificationCenter.default.post(name: .lectorOpenNewWindow, object: nil)
            }
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
        // url == nil for two cases:
        //   a. Cold start: register() will drain pendingURLs into this window.
        //   b. applicationShouldHandleReopen with no windows: openURL() will
        //      find this blank window and load the Finder-opened PDF into it.

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
