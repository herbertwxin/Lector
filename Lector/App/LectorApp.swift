import SwiftUI
import AppKit

// MARK: - Logging

func lectorLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let logLine = "[\(timestamp)] \(message)\n"
    let homePath = "/Users/hxin/lector-debug.log"
    let logURL = URL(fileURLWithPath: homePath)
    
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
    print(logLine)
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
        let window: NSWindow
        let state: AppState
    }
    
    private var entries: [Entry] = []
    private var pendingURLs: [URL] = []
    private var hasEverRegistered = false
    private init() {}

    // MARK: Registration

    func register(window: NSWindow, state: AppState) {
        lectorLog("AppWindowManager.register: title='\(window.title)' hasDoc=\(state.document != nil) hasEverRegistered=\(hasEverRegistered)")
        
        // Remove stale entries and avoid duplicates
        entries.removeAll { $0.window == window || $0.state === state }
        entries.append(Entry(window: window, state: state))
        hasEverRegistered = true
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )

        // 1. If this is a document window, sweep any blank companions.
        if state.document != nil {
            lectorLog("AppWindowManager.register: doc window, sweeping blanks")
            sweepBlankWindows(except: state)
            return
        }

        // 2. If it's a blank window, consume pending URLs from Finder.
        if !pendingURLs.isEmpty {
            let url = pendingURLs.removeFirst()
            lectorLog("AppWindowManager.register: consuming '\(url.lastPathComponent)'")
            state.openDocument(at: url)
            window.title = url.lastPathComponent
            
            // If more URLs were queued (e.g. user selected 5 files), 
            // open them in new windows now that we are registered.
            if !pendingURLs.isEmpty {
                let remaining = pendingURLs
                pendingURLs = []
                DispatchQueue.main.async {
                    remaining.forEach { self.openURL($0) }
                }
            }
            sweepBlankWindows(except: state)
        } else {
            // 3. No pending URL. If any other window already exists (blank or doc),
            // this new blank window is a redundant scene spawned by macOS.
            let isRedundant = entries.contains { $0.window !== window }
            if isRedundant {
                lectorLog("AppWindowManager.register: closing redundant homepage")
                window.close()
            }
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            lectorLog("AppWindowManager: window '\(window.title)' closing")
            entries.removeAll { $0.window == window }
        }
    }

    func unregister(state: AppState) {
        entries.removeAll { $0.state === state }
    }

    private func sweepBlankWindows(except current: AppState) {
        let blanks = entries.filter { $0.state.document == nil && $0.state !== current }
        lectorLog("AppWindowManager.sweepBlankWindows: closing \(blanks.count) windows")
        blanks.forEach { $0.window.close() }
    }

    // MARK: URL Opening

    func openURL(_ url: URL) {
        lectorLog("AppWindowManager.openURL: '\(url.lastPathComponent)' hasEverRegistered=\(hasEverRegistered) count=\(entries.count)")
        
        // Focus if already open
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

        // If a blank window is available, reuse it.
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

        // No blank window, open new.
        lectorLog("AppWindowManager.openURL: post lectorOpenNewWindow")
        NotificationCenter.default.post(
            name: .lectorOpenNewWindow,
            object: nil,
            userInfo: ["url": url]
        )
    }

    func bringAnyWindowToFront() {
        if let entry = entries.first {
            entry.window.deminiaturize(nil)
            entry.window.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Window Accessor

struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowCallbackView()
        view.callback = callback
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    class WindowCallbackView: NSView {
        var callback: ((NSWindow) -> Void)?
        var didFire = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window = window, !didFire {
                didFire = true
                callback?(window)
            }
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
        lectorLog("AppDelegate.application(_:open:): urls=\(urls.count)")
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
