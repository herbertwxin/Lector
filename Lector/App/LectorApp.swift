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
// Design:
//   Entry uses STRONG references (let window, let state) — keeps AppState alive
//   even after SwiftUI releases its @State storage (scene abandoned).  Entries
//   are removed only when the NSWindow posts willCloseNotification.
//
//   pendingURLs — cold-start queue: application(_:open:) may fire before any
//                 window registers (hasEverRegistered == false).  The first blank
//                 window drains this queue in register().
//   lectorOpenNewWindow — used to create programmatic windows (running-app path).
//
// Cold-start sequence:
//   1. application(_:open:) fires — hasEverRegistered may be false → URL queued
//   2. First WindowGroup blank registers → drains pendingURLs → shows PDF
//
// Running-app sequence:
//   3. application(_:open:) fires — blank window reused (strong ref kept), or
//      new window created via lectorOpenNewWindow notification with URL
//
// KEY INVARIANTS:
//   • Entry holds STRONG refs — entry survives SwiftUI @State release.
//   • windowWillClose removes the entry — only cleanup path for strong refs.
//   • lectorOpenNewWindow observer is set up in AppDelegate.init() — before any
//     other lifecycle method can fire — ensuring it's never missed.
//   • applicationShouldHandleReopen returns false — prevents SwiftUI from
//     spawning blank companion scenes when the app opens a PDF.
//   • application(_:open:) cancels deferredBlankWindow before calling openURL()
//     so the deferred welcome screen never appears when a PDF is incoming.
//   • register() runs a delayed sweep 0.5 s after a doc window appears so that
//     late-arriving companion blank scenes are closed even if they register after
//     the doc window's immediate sweep.

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
    // (macOS/SwiftUI fires it before the window is actually visible).
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

        // Blank window — drain a pending URL if one is waiting.
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

        // Blank window with no pending URL.
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
        // (macOS/SwiftUI fires willCloseNotification before the window is visible,
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

        // No blank window available (cold start or all windows closed) —
        // create a new programmatic window with the URL pre-loaded.
        // The observer is in AppDelegate.init() so it is always ready,
        // even before applicationDidFinishLaunching completes.
        lectorLog("AppWindowManager.openURL: post lectorOpenNewWindow")
        NotificationCenter.default.post(
            name: .lectorOpenNewWindow,
            object: nil,
            userInfo: ["url": url]
        )
    }

    /// Brings the first registered window to the front. Returns true if a window was found.
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

    // Deferred work item for showing a blank welcome window on Dock click.
    // Cancelled by application(_:open:) if URLs arrive first.
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

    // Clicking the Dock icon re-shows a window when none are visible.
    // MUST return false — returning true lets SwiftUI spawn a blank companion
    // scene alongside any PDF being simultaneously opened from Finder.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            lectorLog("AppDelegate.applicationShouldHandleReopen: no visible windows")
            if !AppWindowManager.shared.bringAnyWindowToFront() {
                // No window found — defer a blank welcome window by 100 ms.
                // application(_:open:) will cancel this if URLs arrive first.
                let item = DispatchWorkItem {
                    lectorLog("AppDelegate.deferredBlankWindow: firing")
                    NotificationCenter.default.post(
                        name: .lectorOpenNewWindow, object: nil, userInfo: nil
                    )
                }
                deferredBlankWindow = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
            }
        }
        return false
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
        // Cancel deferred blank window before opening files — prevents a welcome
        // screen flash when the user double-clicked a PDF from Finder.
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
            // Load the document BEFORE building the view hierarchy so that
            // register() sees state.document != nil and treats this as a real
            // document window rather than a stray blank scene.
            newState.openDocument(at: url)
            if let page = startPage { newState.currentPage  = page }
            if let y    = startY    { newState.scrollYOffset = y   }
        }
        // url == nil → blank welcome window; register() will drain pendingURLs.

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
