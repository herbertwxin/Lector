import SwiftUI
import AppKit

// MARK: - Logging

func lectorLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let logLine = "[\(timestamp)] \(message)\n"
    let logURL = URL(fileURLWithPath: "/Users/hxin/lector-debug.log")

    if let data = logLine.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: logURL)
        }
    }
    print(logLine, terminator: "")
}

// MARK: - App Entry Point

@main
struct LectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        lectorLog("LectorApp.init()")
    }

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
        lectorLog("WindowWrapper.init(state: \(state.documentURL?.lastPathComponent ?? "nil"))")
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
                // Do NOT call unregister here — SwiftUI fires onDisappear when it
                // abandons a companion scene's view even though the NSWindow is still
                // visible.  Entry cleanup is handled solely by the windowWillClose
                // observer registered in AppWindowManager.register().
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
// ║     applicationShouldHandleReopen fires.  A DispatchWorkItem is          ║
// ║     scheduled (deferredBlankWindow) that calls bringAnyWindowToFront()  ║
// ║     to deminiaturise an existing window, or posts lectorOpenNewWindow    ║
// ║     to open a blank welcome screen if there are none.                    ║
// ║     If application(_:open:) fires on the same run-loop cycle (Finder     ║
// ║     file-open while minimised or closed), it cancels deferredBlankWindow ║
// ║     before it executes and openURL() handles the PDF directly.           ║
// ║     If no file open follows (pure dock click), the deferred item runs    ║
// ║     → existing window deminiaturised, or welcome screen shown.           ║
// ║     NEVER call bringAnyWindowToFront() synchronously in                  ║
// ║     applicationShouldHandleReopen — that prevents application(_:open:)  ║
// ║     from being able to cancel the deminiaturise when a Finder file-open  ║
// ║     arrives on the same run-loop cycle.                                  ║
// ║     NEVER post lectorOpenNewWindow synchronously in                      ║
// ║     applicationShouldHandleReopen — that causes a homepage to appear     ║
// ║     alongside the PDF (regression).                                      ║
// ║     NEVER return true when !hasVisibleWindows — that tells SwiftUI's     ║
// ║     WindowGroup to spawn a companion blank scene, which is the homepage  ║
// ║     alongside PDF bug.  Return false instead (we manage the window).     ║
// ║                                                                          ║
// ║  INVARIANTS that must never be broken:                                   ║
// ║  • Entry holds STRONG refs — entry survives SwiftUI @State release.     ║
// ║  • windowWillClose removes the entry — only cleanup path for strong refs.║
// ║  • lectorOpenNewWindow observer is set up in AppDelegate.init() — before ║
// ║    any other lifecycle method fires — so cold-start notifications are    ║
// ║    never missed even if application(_:open:) races ahead of             ║
// ║    applicationDidFinishLaunching.                                        ║
// ║  • allRegisteredWindows tracks every window ever registered so           ║
// ║    sweepBlankWindows can close orphaned-but-visible blank windows whose  ║
// ║    entries were removed prematurely by willCloseNotification.            ║
// ║  • openDocument(at:) is always called BEFORE makeKeyAndOrderFront for   ║
// ║    programmatic (handleOpenNewWindow) windows, so register() always sees ║
// ║    state.document != nil.                                                ║
// ║  • bringAnyWindowToFront() always calls NSApp.activate so the app       ║
// ║    actually comes to the foreground.                                     ║
// ║  • pendingURLs is only used during cold start (hasEverRegistered==false).║
// ║  • applicationShouldHandleReopen returns false when !hasVisibleWindows  ║
// ║    (we handle it) and true only when hasVisibleWindows (harmless default).║
// ╚══════════════════════════════════════════════════════════════════════════╝

final class AppWindowManager {
    static let shared = AppWindowManager()

    private struct Entry {
        // Strong references so that SwiftUI releasing its @State storage does
        // NOT make the entry disappear from our table.  A blank SwiftUI window
        // can remain visible (NSApp retains it) even after SwiftUI abandons the
        // scene's @State.  Without a strong ref the entry becomes nil and we
        // lose track of the window, causing openURL to create a new programmatic
        // window alongside the still-visible blank one.  Entries are removed
        // explicitly via windowWillClose.
        let window: NSWindow
        let state: AppState
    }

    private var entries: [Entry] = []
    // Weak set of every window ever registered — used by sweepBlankWindows to
    // close windows whose entries were removed prematurely by willCloseNotification
    // (macOS/SwiftUI fires it before the window is actually off-screen).
    private var allRegisteredWindows = NSHashTable<NSWindow>.weakObjects()
    // Safety-net URLs to be consumed by the next blank window that registers.
    private var pendingURLs: [URL] = []
    // True once any window has registered.
    private(set) var hasEverRegistered = false
    private init() {}

    // MARK: Registration

    func register(window: NSWindow, state: AppState) {
        lectorLog("AppWindowManager.register: win=\(window.windowNumber) title='\(window.title)' hasDoc=\(state.document != nil) hasEverRegistered=\(hasEverRegistered)")
        hasEverRegistered = true
        entries.removeAll { $0.state === state }
        entries.append(Entry(window: window, state: state))
        allRegisteredWindows.add(window)
        lectorLog("AppWindowManager.register: after append, count=\(entries.count)")

        // Remove entry when this window closes (strong-ref cleanup).
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            lectorLog("AppWindowManager.willCloseNotification: win=\(window.windowNumber), count-before=\(self?.entries.count ?? -1)")
            self?.entries.removeAll { $0.window === window }
        }

        // 1. If this is a document window, sweep any blank companions.
        if state.document != nil {
            // Doc window — sweep blank companions immediately and again after a short
            // delay to catch SwiftUI companion scenes that register late.
            lectorLog("AppWindowManager.register: doc window, sweeping blanks")
            sweepBlankWindows(except: state)
            let stateRef = state
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                AppWindowManager.shared.sweepBlankWindows(except: stateRef)
            }
            return
        }

        // 2. Blank window — drain a pending URL if one is waiting.
        if let url = pendingURLs.first {
            pendingURLs.removeFirst()
            lectorLog("AppWindowManager.register: blank window consuming '\(url.lastPathComponent)'")
            state.openDocument(at: url)
            window.title = url.lastPathComponent
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            sweepBlankWindows(except: state)
            if !pendingURLs.isEmpty {
                let remaining = pendingURLs
                pendingURLs = []
                DispatchQueue.main.async {
                    remaining.forEach { AppWindowManager.shared.openURL($0) }
                }
            }
            return
        }

        // 3. Blank window with no pending URL.
        let hasDocWindow = entries.contains {
            $0.state.document != nil && $0.state !== state
        }
        if hasDocWindow {
            // A document window already exists — this is a stray companion scene.
            lectorLog("AppWindowManager.register: closing stray blank window (doc window exists)")
            window.close()
            return
        }

        // No doc window yet — keep as welcome screen for now, but schedule a delayed
        // check in case a doc window registers shortly (companion scene timing race).
        lectorLog("AppWindowManager.register: keeping blank window as welcome screen")
        let windowRef = window
        let stateRef = state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            guard stateRef.document == nil else { return } // loaded in the meantime
            let hasDoc = self.entries.contains {
                $0.state.document != nil && $0.state !== stateRef
            }
            if hasDoc {
                lectorLog("AppWindowManager.register (delayed): closing stray blank window")
                windowRef.close()
            }
        }
    }

    private func sweepBlankWindows(except current: AppState) {
        // Sweep tracked entries.
        let blanks = entries.filter { $0.state.document == nil && $0.state !== current }
        lectorLog("AppWindowManager.sweepBlankWindows: closing \(blanks.count) tracked blanks, total=\(entries.count)")
        blanks.forEach { $0.window.close() }
        entries.removeAll { $0.state.document == nil && $0.state !== current }
        lectorLog("AppWindowManager.sweepBlankWindows: remaining=\(entries.count)")

        // Also sweep any registered window whose entry was removed prematurely
        // (macOS/SwiftUI fires willCloseNotification before the window is off-screen,
        //  removing it from entries — but it still appears on screen afterward).
        let docWinNums = Set(entries.filter { $0.state.document != nil }.map { $0.window.windowNumber })
        let currentWin = entries.first(where: { $0.state === current })?.window
        for win in allRegisteredWindows.allObjects {
            guard win.isVisible else { continue }
            guard win !== currentWin else { continue }
            guard !docWinNums.contains(win.windowNumber) else { continue }
            lectorLog("AppWindowManager.sweepBlankWindows: closing stray registered window win=\(win.windowNumber)")
            win.close()
        }
    }

    func unregister(state: AppState) {
        lectorLog("AppWindowManager.unregister: doc=\(state.documentURL?.lastPathComponent ?? "nil")")
        entries.removeAll { $0.state === state }
    }

    // MARK: URL Opening

    func openURL(_ url: URL) {
        lectorLog("AppWindowManager.openURL: '\(url.lastPathComponent)' hasEverRegistered=\(hasEverRegistered) count=\(entries.count)")

        // Bring to front if this URL is already open.
        if let entry = entries.first(where: { $0.state.documentURL == url }) {
            lectorLog("AppWindowManager.openURL: focus existing")
            entry.window.deminiaturize(nil)
            entry.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // During launch, queue the URL. The first window to register will consume it.
        if !hasEverRegistered {
            lectorLog("AppWindowManager.openURL: queuing for launch")
            if !pendingURLs.contains(url) {
                pendingURLs.append(url)
            }
            return
        }

        // If a blank (welcome-screen) window is already registered, load directly.
        if let entry = entries.first(where: { $0.state.document == nil }) {
            lectorLog("AppWindowManager.openURL: reuse blank window")
            entry.state.openDocument(at: url)
            entry.window.title = url.lastPathComponent
            entry.window.deminiaturize(nil)
            entry.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            sweepBlankWindows(except: entry.state)
            return
        }

        // No blank window available — create a new programmatic window with the URL
        // pre-loaded.  The observer is in AppDelegate.init() so it is always ready,
        // even before applicationDidFinishLaunching completes.
        lectorLog("AppWindowManager.openURL: post lectorOpenNewWindow")
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
        if let entry = entries.first {
            entry.window.deminiaturize(nil)
            entry.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }
        return false
    }
}

// MARK: - Window Accessor

struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CallbackView()
        view.onWindow = callback
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// NSView subclass that fires the callback via viewDidMoveToWindow.
    /// This is more reliable than updateNSView for our purposes: it fires as
    /// soon as the view is inserted into a window's view hierarchy, which
    /// happens even when the window closes before SwiftUI's first render pass.
    final class CallbackView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        private var fired = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !fired else { return }
            fired = true
            onWindow?(window)
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

    // Deferred blank-window work item posted by applicationShouldHandleReopen.
    // Cancelled by application(_:open:) when a real URL arrives on the same
    // run-loop cycle, preventing a spurious homepage from appearing alongside
    // the PDF that Finder is opening.
    private var deferredBlankWindow: DispatchWorkItem?

    // Set up the lectorOpenNewWindow observer immediately — before any lifecycle
    // method fires — so notifications posted by openURL() are never missed even
    // if application(_:open:) races ahead of applicationDidFinishLaunching.
    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenNewWindow(_:)),
            name: .lectorOpenNewWindow,
            object: nil
        )
    }

    // Keep the app alive when the window is closed (red button).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // Called when the Dock icon is clicked (or whenever the app is activated
    // while it has no visible windows).  macOS also calls this BEFORE
    // application(_:open:) when the user double-clicks a file in Finder
    // while every window is closed or minimised.
    //
    // Strategy:
    //   • Minimised windows  → deferred deminiaturise + activate so that
    //     application(_:open:) — fired on the same run-loop cycle for
    //     Finder file-opens — can CANCEL it before it executes.
    //       - Dock-click only:   deferred fires → bringAnyWindowToFront() ✓
    //       - Finder file-open:  application(_:open:) cancels the deferred
    //                            item; openURL() opens the PDF instead.    ✓
    //   • No windows at all  → same deferred mechanism; if nothing cancels
    //     it a blank welcome window is shown.
    //     Return false (handled).
    //
    // RETURN false when !hasVisibleWindows — we manage the window ourselves.
    // RETURN true  when  hasVisibleWindows — visible windows exist; let macOS
    //   handle focus normally (no window will be spawned).
    //
    // Returning true when !hasVisibleWindows tells SwiftUI to do its default
    // WindowGroup reopen handling, which spawns a blank companion scene —
    // that is exactly the homepage-alongside-PDF regression.
    //
    // IMPORTANT: bringAnyWindowToFront() must be deferred (not synchronous)
    // so that application(_:open:) can cancel it when a Finder file-open
    // arrives on the same run-loop cycle.  If it ran synchronously the window
    // would deminiaturise before application(_:open:) could fire, preventing
    // the new PDF from opening.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }

        lectorLog("AppDelegate.applicationShouldHandleReopen: no visible windows")
        // Always defer — application(_:open:) may arrive on the same run-loop
        // cycle (Finder file-open while minimised) and must be able to cancel
        // this before it executes.
        let item = DispatchWorkItem { [weak self] in
            lectorLog("AppDelegate.deferredBlankWindow: firing")
            self?.deferredBlankWindow = nil
            if !AppWindowManager.shared.bringAnyWindowToFront() {
                NotificationCenter.default.post(name: .lectorOpenNewWindow, object: nil)
            }
        }
        deferredBlankWindow = item
        DispatchQueue.main.async(execute: item)
        return false  // we handled it; prevent SwiftUI spawning a companion blank scene
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        lectorLog("AppDelegate.applicationDidFinishLaunching")
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false

        // Close any Settings window that macOS restored from the previous session.
        DispatchQueue.main.async {
            NSApp.windows
                .filter { $0.title == "Settings" || $0.title == "Preferences" }
                .forEach { $0.close() }
        }
    }

    // Called by macOS at launch and while running (Finder double-click, "Open With…").
    func application(_ application: NSApplication, open urls: [URL]) {
        lectorLog("AppDelegate.application(_:open:): urls=\(urls.count)")
        // Cancel any deferred blank window — real URLs take priority.
        deferredBlankWindow?.cancel()
        deferredBlankWindow = nil
        urls.forEach { AppWindowManager.shared.openURL($0) }
    }

    // MARK: - Multi-window support

    @objc private func handleOpenNewWindow(_ notification: Notification) {
        let url       = notification.userInfo?["url"]      as? URL
        lectorLog("AppDelegate.handleOpenNewWindow: url=\(url?.lastPathComponent ?? "nil")")
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
