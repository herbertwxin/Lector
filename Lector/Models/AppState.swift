import Foundation
import SwiftUI
import AppKit
import PDFKit
import Observation

// MARK: - AppearanceMode

enum AppearanceMode: String, CaseIterable {
    case auto  = "Auto"
    case light = "Light"
    case dark  = "Dark"

    /// The SwiftUI ColorScheme override, or nil to follow the system.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .auto:  return nil
        case .light: return .light
        case .dark:  return .dark
        }
    }
}

// MARK: - ViewerMode

enum ViewerMode: Equatable {
    case normal
    case search
    case command(String)
    case awaitingMark
    case awaitingHighlightType
    case awaitingPortalDest
}

// MARK: - AppState

@Observable
final class AppState {

    // MARK: Document
    var documentURL: URL?
    var document: PDFDocument?
    var documentID: Int64 = 0
    var outlineCache: [(page: Int, label: String)] = []

    // MARK: Navigation
    var currentPage: Int = 0
    var scrollYOffset: Double = 0
    var zoomScale: CGFloat = 1.0
    var fitToWidth: Bool = true
    /// The actual scale factor reported by PDFView (kept in sync by LectorPDFView).
    var viewScaleFactor: CGFloat = 1.0

    // MARK: Mode & UI
    var mode: ViewerMode = .normal
    var appearanceMode: AppearanceMode = .auto
    var showTOC: Bool = false

    /// True when the effective appearance is dark (used by PDFView / AnnotationLayer).
    var isDarkMode: Bool {
        switch appearanceMode {
        case .dark:  return true
        case .light: return false
        case .auto:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }
    var numberPrefix: String = ""
    var statusMessage: String = ""

    // MARK: Search
    var searchText: String = ""
    var isSearching: Bool = false

    // MARK: Annotations (loaded for current doc)
    var bookmarks: [Bookmark] = []
    var highlights: [Highlight] = []
    var marks: [Mark] = []
    var portals: [Portal] = []

    // MARK: Quick-select
    var showQuickSelect: Bool = false
    var quickSelectItems: [QuickSelectItem] = []
    var quickSelectTitle: String = ""

    // MARK: Document structure (figures, tables, equations, etc.)
    /// Cache key: document URL path. Cleared when document closes.
    private var detectedStructureCache: [String: [DocumentStructureItem]] = [:]
    var isDetectingStructure: Bool = false

    // MARK: Citation index (inline citations → reference locations)
    /// Maps citation keys to reference definitions. Keys are either numeric
    /// strings ("1", "2", ...) or author–year keys like "Sargent 1991".
    /// Populated when document loads.
    private(set) var citationReferenceIndex: [String: IndexedReference] = [:]
    /// Pre-computed clickable regions per page. Used for reliable hit-testing.
    private(set) var citationRegions: [Int: [(rect: CGRect, key: String)]] = [:]
    /// True while citation catalog and regions are being built (async). Use to show loading or diagnose timing.
    private(set) var isIndexingCitations: Bool = false
    /// In-flight indexing task — cancelled when a new document is loaded.
    @ObservationIgnored private var citationTask: Task<Void, Never>?

    // MARK: Portal state
    var portalSourcePage: Int? = nil
    var portalSourceY: Double = 0

    // MARK: Services
    @ObservationIgnored let isReadOnly: Bool

    @ObservationIgnored let database: Database
    @ObservationIgnored private let navHistory = NavHistory()
    @ObservationIgnored private let keyTrie = KeyTrie()
    private(set) var recentDocuments: [RecentDocument] = []

    // MARK: Preferences
    var rememberLastPosition: Bool {
        didSet { UserDefaults.standard.set(rememberLastPosition, forKey: "rememberLastPosition") }
    }
    var citationDetectionEnabled: Bool = true {
        didSet { UserDefaults.standard.set(citationDetectionEnabled, forKey: "citationDetectionEnabled") }
    }
    var citationTestLogEnabled: Bool = false {
        didSet { UserDefaults.standard.set(citationTestLogEnabled, forKey: "citationTestLogEnabled") }
    }

    // MARK: Init

    init(readOnly: Bool = false) {
        self.isReadOnly = readOnly
        UserDefaults.standard.register(defaults: [
            "rememberLastPosition": true,
            "citationDetectionEnabled": true,
            "citationTestLogEnabled": false,
        ])
        rememberLastPosition = UserDefaults.standard.bool(forKey: "rememberLastPosition")
        citationDetectionEnabled = UserDefaults.standard.bool(forKey: "citationDetectionEnabled")
        citationTestLogEnabled = UserDefaults.standard.bool(forKey: "citationTestLogEnabled")
        do {
            database = try Database()
        } catch {
            fatalError("Cannot open Lector database: \(error)")
        }
        keyTrie.build(from: DefaultBindings.keybindings)
        loadRecentDocuments()

        // Save position before the app terminates.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.saveCurrentPosition() }
    }

    // MARK: - Document Opening

    func openDocumentDialog() {
        let panel = NSOpenPanel()
        // Do NOT set allowedContentTypes: it breaks the Tags sidebar in NSOpenPanel
        // (tags view renders blank when a content-type filter is active).
        // PDFDocument(url:) returning nil is sufficient validation downstream.
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select a PDF document"
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            if document == nil {
                openDocument(at: url)
            } else {
                AppWindowManager.shared.openURL(url)
            }
        }
    }

    func openDocument(at url: URL) {
        if documentURL == url && document != nil { return }

        guard let doc = PDFDocument(url: url) else {
            statusMessage = "Failed to open: \(url.lastPathComponent)"
            return
        }

        // Save position of whatever was open before switching.
        saveCurrentPosition()

        // Push current state before navigating away
        if documentURL != nil {
            pushNavState()
        }
        documentURL = url
        document = doc

        // Build outline cache synchronously (it is relatively fast compared to checksum)
        buildOutlineCache(for: doc)

        // Cancel any in-progress indexing from a previous document.
        citationTask?.cancel()
        citationTask = nil
        citationReferenceIndex = [:]
        citationRegions = [:]

        if citationDetectionEnabled {
            let capturedDoc = doc
            let capturedURL = url
            let capturedOutline = outlineCache
            let logEnabled = citationTestLogEnabled

            isIndexingCitations = true
            statusMessage = "Indexing citations…"

            // Run the heavy PDFKit text extraction and analysis on a background thread so the
            // UI remains responsive even for large documents (textbooks, long papers).
            // PDFPage.string and PDFSelection.bounds are read-only and safe to call off-main.
            citationTask = Task.detached(priority: .utility) { [weak self] in
                let refPages = CitationDetector.findReferenceListPages(
                    document: capturedDoc, outlineCache: capturedOutline)

                guard !Task.isCancelled else { return }

                let index = CitationDetector.indexReferences(document: capturedDoc, fromPages: refPages)

                guard !Task.isCancelled else { return }

                let regions = CitationDetector.buildCitationRegions(
                    document: capturedDoc, catalog: index, excludePages: refPages)

                guard !Task.isCancelled else { return }

                await MainActor.run { [weak self] in
                    guard let self, self.documentURL == capturedURL else { return }
                    self.citationReferenceIndex = index
                    self.citationRegions = regions
                    self.isIndexingCitations = false
                    self.statusMessage = capturedURL.lastPathComponent
                    if logEnabled { self.writeCitationTestLog(index: index, refPages: refPages) }
                }
            }
        }

        // Initialize view position defaults
        currentPage   = 0
        scrollYOffset = 0

        if !citationDetectionEnabled {
            statusMessage = url.lastPathComponent
        }

        // Upsert document in DB and compute checksum on a background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let checksum = Checksum.sha256(of: url) ?? ""

            DispatchQueue.main.async {
                guard let self = self, self.documentURL == url else { return }

                self.documentID = (try? self.database.upsertDocument(url: url, checksum: checksum)) ?? 0

                // Restore or reset view position now that we have the document ID.
                if self.rememberLastPosition,
                   let pos = try? self.database.fetchLastPosition(docID: self.documentID) {
                    self.currentPage   = pos.page
                    self.scrollYOffset = pos.yOffset
                    self.zoomScale     = CGFloat(pos.zoom)
                    self.fitToWidth    = pos.fitToWidth
                }

                self.loadAnnotations()
                self.loadRecentDocuments()
            }
        }
    }

    /// When citation test logging is enabled, write the current reference catalog to a file
    /// under Application Support so it can be inspected to improve the detection algorithm.
    private func writeCitationTestLog(index: [String: IndexedReference], refPages: Set<Int>) {
        guard citationTestLogEnabled else { return }
        do {
            let fm = FileManager.default
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("Lector", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let logURL = dir.appendingPathComponent("citation-test-log.txt")

            var lines: [String] = []
            let docPath = documentURL?.path ?? ""
            lines.append("Document: \(docPath)")
            let pagesDescription = refPages.sorted().map { String($0) }.joined(separator: ",")
            lines.append("ReferencePages: \(pagesDescription)")
            lines.append("Entries: \(index.count)")

            let sorted = index.values.sorted {
                if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
                return $0.yOffset < $1.yOffset
            }
            for ref in sorted {
                let yString = String(format: "%.1f", ref.yOffset)
                lines.append("[\(ref.key)] p\(ref.pageIndex + 1) y=\(yString)")
                lines.append("  \(ref.fullText)")
            }
            let content = lines.joined(separator: "\n") + "\n"
            let data = content.data(using: .utf8) ?? Data()
            if fm.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try data.write(to: logURL, options: .atomic)
            }
        } catch {
            // Silent failure for test logging.
        }
    }

    func saveCurrentPosition() {
        guard documentID > 0 else { return }
        try? database.saveLastPosition(
            docID: documentID,
            page: currentPage,
            yOffset: scrollYOffset,
            zoom: Double(zoomScale),
            fitToWidth: fitToWidth
        )
    }

    /// Called when the main window is closed. Saves position then shows the
    /// home screen so the next window open starts fresh.
    func closeDocument() {
        saveCurrentPosition()
        document    = nil
        documentURL = nil
        documentID  = 0
        outlineCache = []
        detectedStructureCache.removeAll()
        citationReferenceIndex = [:]
        citationRegions = [:]
        bookmarks   = []
        highlights  = []
        marks       = []
        portals     = []
        mode        = .normal
        isSearching = false
        showTOC     = false
        statusMessage = ""
    }

    func loadAnnotations() {
        guard documentID > 0 else { return }
        bookmarks  = (try? database.fetchBookmarks(docID: documentID)) ?? []
        highlights = (try? database.fetchHighlights(docID: documentID)) ?? []
        marks      = (try? database.fetchMarks(docID: documentID)) ?? []
        portals    = (try? database.fetchPortals(srcDocID: documentID)) ?? []
    }

    func loadRecentDocuments() {
        recentDocuments = (try? database.fetchRecentDocuments()) ?? []
    }

    // MARK: - Navigation History

    func pushNavState() {   // internal for TOCView access
        guard let url = documentURL else { return }
        navHistory.push(NavState(url: url, page: currentPage, yOffset: scrollYOffset))
    }

    func goBack() {
        pushNavState()
        guard let state = navHistory.back() else { return }
        navigate(to: state)
    }

    func goForward() {
        guard let state = navHistory.forward() else { return }
        navigate(to: state)
    }

    private func navigate(to state: NavState) {
        if state.url != documentURL {
            openDocument(at: state.url)
        }
        currentPage = state.page
        scrollYOffset = state.yOffset
    }

    // MARK: - Key Handling

    @discardableResult
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Block key events in non-normal modes (let views handle them)
        switch mode {
        case .search, .command:
            if event.keyCode == 53 { // Escape
                mode = .normal
                isSearching = false
                NotificationCenter.default.post(name: .lectorFocusPDF, object: self)
                return true
            }
            return false
        default:
            break
        }

        guard let commands = keyTrie.handleKey(event: event) else { return false }
        for command in commands { execute(command) }
        return true
    }

    // MARK: - Command Execution

    func execute(_ command: Command) {
        switch command {

        // Navigation
        case .gotoBeginning:
            pushNavState()
            currentPage = 0
        case .gotoEnd:
            pushNavState()
            currentPage = max(0, (document?.pageCount ?? 1) - 1)
        case .gotoPage(let p):
            pushNavState()
            let pageCount = document?.pageCount ?? 0
            currentPage = max(0, min(p, pageCount - 1))
        case .scrollDown(let d):
            scrollYOffset += d
        case .scrollUp(let d):
            scrollYOffset -= d
        case .nextPage:
            pushNavState()
            currentPage = min(currentPage + 1, (document?.pageCount ?? 1) - 1)
        case .prevPage:
            pushNavState()
            currentPage = max(currentPage - 1, 0)
        case .back:
            goBack()
        case .forward:
            goForward()

        // Zoom
        case .zoomIn:
            let base = fitToWidth ? viewScaleFactor : zoomScale
            fitToWidth = false
            zoomScale = min(base * 1.25, 32.0)
        case .zoomOut:
            let base = fitToWidth ? viewScaleFactor : zoomScale
            fitToWidth = false
            zoomScale = max(base / 1.25, 0.1)
        case .fitToWidth:
            fitToWidth = true
        case .smartZoom:
            smartZoomToggle()
        case .actualSize:
            fitToWidth = false
            zoomScale = 1.0

        // Search
        case .beginSearch:
            mode = .search
            isSearching = true
        case .nextResult:
            searchNext()
        case .prevResult:
            searchPrev()
        case .closeSearch:
            isSearching = false
            mode = .normal
            searchText = ""

        // Bookmarks
        case .addBookmark:
            if isReadOnly { statusMessage = "Read-only window" } else { addBookmarkAtCurrentPosition() }
        case .deleteBookmark:
            if isReadOnly { statusMessage = "Read-only window" } else { deleteBookmarkAtCurrentPosition() }
        case .listBookmarks:
            showBookmarksPanel(allDocs: false)
        case .listAllBookmarks:
            showBookmarksPanel(allDocs: true)

        // Highlights
        case .addHighlight(let ch):
            if isReadOnly { statusMessage = "Read-only window" } else { addHighlightWithType(ch) }
        case .deleteHighlight:
            if isReadOnly { statusMessage = "Read-only window" } else { deleteHighlightAtCurrentPosition() }
        case .listHighlights:
            showHighlightsPanel()
        case .nextHighlight:
            jumpToNextHighlight(forward: true)
        case .prevHighlight:
            jumpToNextHighlight(forward: false)

        // Marks
        case .setMark(let ch):
            if isReadOnly { statusMessage = "Read-only window" } else { setMark(symbol: ch) }
        case .gotoMark(let ch):
            gotoMark(symbol: ch)
        case .listMarks:
            showMarksPanel()

        // Portals
        case .setPortalSource:
            if isReadOnly { statusMessage = "Read-only window" } else { handlePortalCommand() }
        case .gotoPortal:
            gotoNearestPortal()
        case .editPortal:
            break   // future
        case .deletePortal:
            if isReadOnly { statusMessage = "Read-only window" } else { deletePortalAtCurrentPosition() }

        // Web search
        case .webSearch(let engine):
            performWebSearch(engine: engine)

        // UI
        case .toggleTOC:
            showTOC.toggle()
        case .commandMode:
            mode = .command("")
        case .openDocument:
            openDocumentDialog()
        case .toggleDarkMode:
            switch appearanceMode {
            case .auto:  appearanceMode = .dark
            case .dark:  appearanceMode = .light
            case .light: appearanceMode = .auto
            }
        case .quit:
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Execute Command String (from `:` mode)

    func executeCommandString(_ input: String) {
        let raw   = input.trimmingCharacters(in: .whitespaces)
        let parts = raw.components(separatedBy: " ")
        guard let name = parts.first?.lowercased(), !name.isEmpty else { mode = .normal; return }
        let arg  = parts.dropFirst().first ?? ""
        let rest = parts.dropFirst().joined(separator: " ")

        switch name {

        // ── Appearance ──────────────────────────────────────────────────
        case "dark", "darkmode":
            appearanceMode = .dark
        case "light", "lightmode":
            appearanceMode = .light
        case "auto", "automode", "system":
            appearanceMode = .auto
        case "toggledark", "toggledarkmode":
            execute(.toggleDarkMode)

        // ── Navigation ──────────────────────────────────────────────────
        case "page", "p":
            if let p = Int(arg) { execute(.gotoPage(p - 1)) }
            else { statusMessage = "Usage: page <number>" }
        case "beginning", "gg":
            execute(.gotoBeginning)
        case "end", "G":
            execute(.gotoEnd)
        case "next", "n":
            execute(.nextResult)
        case "prev", "previous", "N":
            execute(.prevResult)
        case "nextpage":
            execute(.nextPage)
        case "prevpage", "previouspage":
            execute(.prevPage)
        case "back":
            execute(.back)
        case "forward":
            execute(.forward)
        case "nextchapter", "gc":
            jumpToChapter(forward: true)
        case "prevchapter", "gC":
            jumpToChapter(forward: false)

        // ── Zoom ─────────────────────────────────────────────────────────
        case "zoom", "z":
            if let pct = Double(arg) {
                fitToWidth = false
                zoomScale  = CGFloat(pct / 100.0)
            } else { statusMessage = "Usage: zoom <percent>" }
        case "zoomin":
            execute(.zoomIn)
        case "zoomout":
            execute(.zoomOut)
        case "fit", "fitwidth", "fw":
            execute(.fitToWidth)
        case "smartzoom", "sz":
            execute(.smartZoom)
        case "actualsize", "reset":
            execute(.actualSize)

        // ── Search ───────────────────────────────────────────────────────
        case "search", "/":
            if rest.isEmpty {
                execute(.beginSearch)
            } else {
                searchText  = rest
                isSearching = true
                mode        = .search
            }

        // ── Bookmarks ────────────────────────────────────────────────────
        case "bookmark", "bm", "b":
            addBookmarkAtCurrentPosition(label: rest.isEmpty ? nil : rest)
        case "deletebookmark", "delbookmark", "db":
            execute(.deleteBookmark)
        case "bookmarks", "gb":
            execute(.listBookmarks)
        case "allbookmarks", "gB":
            execute(.listAllBookmarks)

        // ── Highlights ───────────────────────────────────────────────────
        case "highlight", "hl":
            let type: Character = arg.first ?? "a"
            execute(.addHighlight(type))
        case "deletehighlight", "delhighlight", "dh":
            execute(.deleteHighlight)
        case "highlights", "gh":
            execute(.listHighlights)
        case "nexthighlight", "gnh":
            execute(.nextHighlight)
        case "prevhighlight", "gNh":
            execute(.prevHighlight)

        // ── Marks ─────────────────────────────────────────────────────────
        case "mark", "m":
            if let ch = arg.first { execute(.setMark(ch)) }
            else { statusMessage = "Usage: mark <letter>" }
        case "goto", "gotomark":
            if let ch = arg.first { execute(.gotoMark(ch)) }
            else { statusMessage = "Usage: goto <letter>" }
        case "marks", "gm":
            execute(.listMarks)

        // ── Portals ──────────────────────────────────────────────────────
        case "portal", "po":
            execute(.setPortalSource)
        case "deleteportal", "delportal", "dp":
            execute(.deletePortal)
        case "gotoportal", "gp":
            execute(.gotoPortal)

        // ── Web search ───────────────────────────────────────────────────
        case "scholar", "s":
            if !rest.isEmpty {
                let q = rest.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                if let url = URL(string: String(format: WebEngine.scholar.urlTemplate, q)) {
                    NSWorkspace.shared.open(url)
                }
            } else {
                execute(.webSearch(engine: .scholar))
            }
        case "google", "g":
            if !rest.isEmpty {
                let q = rest.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                if let url = URL(string: String(format: WebEngine.google.urlTemplate, q)) {
                    NSWorkspace.shared.open(url)
                }
            } else {
                execute(.webSearch(engine: .google))
            }

        // ── Document structure (figure, equation, table, proposition, etc.) ─
        case "figure", "fig":
            showStructurePanel(type: .figure)
        case "equation", "eq":
            showStructurePanel(type: .equation)
        case "table":
            showStructurePanel(type: .table)
        case "proposition", "prop":
            showStructurePanel(type: .proposition)
        case "theorem":
            showStructurePanel(type: .theorem)
        case "lemma":
            showStructurePanel(type: .lemma)

        // ── UI / Misc ─────────────────────────────────────────────────────
        case "toc":
            showTOC.toggle()
        case "split", "sp":
            if let url = documentURL {
                NotificationCenter.default.post(
                    name: .lectorOpenNewWindow,
                    object: nil,
                    userInfo: ["url": url, "readOnly": true, "page": currentPage, "yOffset": scrollYOffset]
                )
            } else {
                statusMessage = "No document open"
            }
        case "open", "o":
            openDocumentDialog()
        case "recent", "O":
            showRecentDocsPanel()
        case "copy":
            NotificationCenter.default.post(name: .lectorCopySelection, object: self)
        case "rotate", "r":
            NotificationCenter.default.post(name: .lectorRotate, object: self,
                                            userInfo: ["clockwise": arg != "ccw"])
        case "print":
            printDocument()
        case "fullscreen", "f11":
            NSApplication.shared.mainWindow?.toggleFullScreen(nil)
        case "quit", "q":
            NSApplication.shared.terminate(nil)

        case "help", "?":
            showHelpPanel()
        case "citation", "citations", "cite":
            showCitationPanel()

        default:
            statusMessage = "Unknown command: \(name)"
        }

        mode = .normal
        NotificationCenter.default.post(name: .lectorFocusPDF, object: self)
    }

    // ── Chapter name for current page ─────────────────────────────────────

    private func buildOutlineCache(for doc: PDFDocument) {
        outlineCache = []
        guard let outline = doc.outlineRoot else { return }

        func walk(_ node: PDFOutline) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                if let destPage = child.destination?.page {
                    let idx = doc.index(for: destPage)
                    if idx >= 0 {
                        outlineCache.append((page: idx, label: child.label ?? ""))
                    }
                }
                walk(child)
            }
        }
        walk(outline)
        // Sort by page number so we can easily search
        outlineCache.sort { $0.page < $1.page }
    }

    var currentChapterName: String {
        guard !outlineCache.isEmpty else { return "" }

        var low = 0
        var high = outlineCache.count - 1
        var bestIndex = -1

        while low <= high {
            let mid = low + (high - low) / 2
            let entry = outlineCache[mid]

            if entry.page <= currentPage {
                bestIndex = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        guard bestIndex != -1 else { return "" }

        // Find the first entry with the same page number
        // to match the previous logic: `entry.page > bestPage`
        let bestPage = outlineCache[bestIndex].page
        var firstMatchIndex = bestIndex
        while firstMatchIndex > 0 && outlineCache[firstMatchIndex - 1].page == bestPage {
            firstMatchIndex -= 1
        }

        return outlineCache[firstMatchIndex].label
    }

    // ── Chapter navigation ────────────────────────────────────────────────

    func jumpToChapter(forward: Bool) {
        if outlineCache.isEmpty { return }

        if forward {
            if let next = outlineCache.first(where: { $0.page > currentPage }) {
                pushNavState()
                currentPage = next.page
            }
        } else {
            if let prev = outlineCache.last(where: { $0.page < currentPage }) {
                pushNavState()
                currentPage = prev.page
            }
        }
    }

    // ── Smart Zoom ───────────────────────────────────────────────────────

    /// Minimum difference (in points) between media and crop box widths
    /// to consider the crop box meaningfully tighter.
    private static let cropBoxThreshold: CGFloat = 1.0
    /// Minimum zoom ratio (2%) required before applying the margin crop.
    private static let minZoomImprovementRatio: CGFloat = 1.02

    /// Samples character bounding boxes on `page` to estimate the actual
    /// text-content width (ignoring blank margins).  Returns `nil` when
    /// the page has no extractable characters, is image-only, or when
    /// the text already spans the full media width.
    private func contentWidthFromCharacters(page: PDFPage, media: CGRect) -> CGFloat? {
        let n = page.numberOfCharacters
        guard n > 0 else { return nil }

        // Sample at most ~300 character positions evenly across the page.
        let step = max(1, n / 300)
        var union = CGRect.null
        for i in stride(from: 0, to: n, by: step) {
            let b = page.characterBounds(at: i)
            // Skip zero-size glyphs (spaces, invisible chars, image-only pages).
            guard b.width > 0, b.height > 0 else { continue }
            union = union.isNull ? b : union.union(b)
        }

        guard !union.isNull, union.width > 10 else { return nil }
        // Only useful when text is meaningfully narrower than the full page.
        guard union.width < media.width - Self.cropBoxThreshold else { return nil }
        return union.width
    }

    /// Toggles between fit-to-width and a tighter zoom that crops
    /// whitespace margins for maximum screen utilisation.
    ///
    /// Detection order:
    ///   1. PDF cropBox (zero-cost metadata, works when author set it)
    ///   2. Character bounding-box sampling (covers academic papers / textbooks
    ///      whose cropBox == mediaBox but have visible white margins)
    private func smartZoomToggle() {
        if fitToWidth {
            // Already fitting width → zoom in to crop margins.
            guard let doc = document else { return }
            let pageIndex = max(0, min(currentPage, doc.pageCount - 1))
            guard let page = doc.page(at: pageIndex) else { return }

            let media = page.bounds(for: .mediaBox)
            let crop  = page.bounds(for: .cropBox)

            // 1. Try the PDF's own crop box first (fast, exact).
            let contentWidth: CGFloat
            if crop.width < media.width - Self.cropBoxThreshold {
                contentWidth = crop.width
            } else if let charWidth = contentWidthFromCharacters(page: page, media: media) {
                // 2. Fall back to character-bounding-box sampling for PDFs
                //    whose cropBox == mediaBox but have real text margins.
                contentWidth = charWidth
            } else {
                return   // no usable margin information found
            }

            guard contentWidth > 0 else { return }
            let ratio = media.width / contentWidth   // e.g. 1.15 for 7.5% margins
            // Only apply if the ratio gives a noticeable improvement.
            if ratio > Self.minZoomImprovementRatio {
                fitToWidth = false
                zoomScale = viewScaleFactor * ratio
            }
        } else {
            // Any manual zoom → return to fit-to-width.
            fitToWidth = true
        }
    }

    // ── Help quick-select ─────────────────────────────────────────────────

    private func showHelpPanel() {
        let entries: [(keys: String, desc: String)] = [
            // Navigation
            ("j / ↓",         "Scroll down"),
            ("k / ↑",         "Scroll up"),
            ("⌃d",            "Scroll down (large step)"),
            ("⌃u",            "Scroll up (large step)"),
            ("Space",         "Next page"),
            ("Shift+Space",   "Previous page"),
            ("gg",            "Go to beginning"),
            ("G",             "Go to end"),
            ("{n}gg",         "Go to page n  (e.g. 42gg)"),
            ("⌫",             "Navigate back"),
            ("Shift+⌫",       "Navigate forward"),
            // Zoom
            ("+",             "Zoom in"),
            ("-",             "Zoom out"),
            ("=",             "Fit to width"),
            ("w",             "Smart zoom (toggle margin crop)"),
            ("0",             "Actual size (100%)"),
            // Search
            ("/",             "Open search bar"),
            ("n",             "Next search result"),
            ("N",             "Previous search result"),
            ("Esc",           "Close search"),
            // Bookmarks
            ("b",             "Add bookmark"),
            ("db",            "Delete bookmark"),
            ("gb",            "List bookmarks (this doc)"),
            ("gB",            "List bookmarks (all docs)"),
            // Highlights
            ("h + a/b/c/d",   "Highlight: yellow/green/blue/red"),
            ("dh",            "Delete highlight at current position"),
            ("gh",            "List highlights"),
            ("gnh",           "Jump to next highlight"),
            ("gNh",           "Jump to previous highlight"),
            // Marks
            ("m + char",      "Set mark (lowercase = per-doc)"),
            ("` + char",      "Jump to mark"),
            ("gm",            "List marks"),
            // Portals
            ("p",             "Set portal source / create portal"),
            ("dp",            "Delete nearest portal"),
            // Web search
            ("⌃f",            "Search selection on Google Scholar"),
            ("⌥f",            "Search selection on Google"),
            // UI
            ("t",             "Toggle table of contents"),
            (":figure",       "Jump to figure (dropdown)"),
            (":equation",     "Jump to equation (dropdown)"),
            (":table",        "Jump to table (dropdown)"),
            (":proposition",  "Jump to proposition (dropdown)"),
            (":citation",     "Show citation detection stats"),
            (":",             "Open command mode"),
            ("o",             "Open document picker"),
            ("F8",            "Cycle appearance: Auto → Dark → Light"),
            ("q",             "Quit"),
        ]
        let items: [QuickSelectItem] = entries.map { entry in
            QuickSelectItemImpl(title: entry.keys, subtitle: entry.desc, page: 0,
                                action: { [weak self] in self?.showQuickSelect = false })
        }
        quickSelectItems = items
        quickSelectTitle = "Keyboard Shortcuts — type to filter"
        showQuickSelect = true
    }

    // ── Citation panel: list all refs, Enter → Google Scholar ───────────────

    private func showCitationPanel() {
        let refs = citationReferenceIndex.values.sorted { a, b in
            if a.pageIndex != b.pageIndex { return a.pageIndex < b.pageIndex }
            return a.yOffset < b.yOffset
        }
        let maxTitleLen = 320
        let items: [QuickSelectItem] = refs.map { ref in
            let title = ref.fullText.count <= maxTitleLen
                ? ref.fullText
                : String(ref.fullText.prefix(maxTitleLen - 3)) + "..."
            let subtitle = "\(ref.key) · p.\(ref.pageIndex + 1)"
            let fullText = ref.fullText
            return QuickSelectItemImpl(
                title: title,
                subtitle: subtitle,
                page: ref.pageIndex,
                action: { [weak self] in
                    let query = fullText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    let urlStr = String(format: WebEngine.scholar.urlTemplate, query)
                    if let url = URL(string: urlStr) {
                        NSWorkspace.shared.open(url)
                    }
                    self?.showQuickSelect = false
                }
            )
        }
        quickSelectItems = items
        quickSelectTitle = "References — \(refs.count) found · Enter: Google Scholar"
        showQuickSelect = true
    }

    // ── Document structure (figure, equation, table, etc.) ─────────────────

    private func showStructurePanel(type: DocumentStructureType) {
        guard let doc = document, let url = documentURL else {
            statusMessage = "No document open"
            return
        }
        let cacheKey = url.path

        func showItems(_ items: [DocumentStructureItem]) {
            let list = items.filter { $0.type == type }
            if list.isEmpty {
                quickSelectItems = []
                quickSelectTitle = "\(type.displayName)s — none found"
            } else {
                quickSelectItems = list.map { item in
                    QuickSelectItemImpl(
                        title: item.label,
                        subtitle: "Page \(item.pageIndex + 1)",
                        page: item.pageIndex,
                        action: { [weak self] in
                            guard let self else { return }
                            self.currentPage = item.pageIndex
                            self.scrollYOffset = item.yOffset
                            self.showQuickSelect = false
                        }
                    )
                }
                quickSelectTitle = "\(type.displayName)s — type to filter"
            }
            showQuickSelect = true
        }

        if let cached = detectedStructureCache[cacheKey] {
            showItems(cached)
            return
        }

        quickSelectItems = []
        quickSelectTitle = "\(type.displayName)s — detecting…"
        showQuickSelect = true
        isDetectingStructure = true

        let docCopy = doc
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = DocumentStructureDetector.detect(document: docCopy)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isDetectingStructure = false
                self.detectedStructureCache[cacheKey] = items
                showItems(items)
            }
        }
    }

    // ── Recent docs quick-select ──────────────────────────────────────────

    private func showRecentDocsPanel() {
        let items: [QuickSelectItem] = recentDocuments.map { doc in
            QuickSelectItemImpl(
                title: doc.url.lastPathComponent,
                subtitle: doc.url.deletingLastPathComponent().path,
                page: 0,
                action: { AppWindowManager.shared.openURL(doc.url) }
            )
        }
        quickSelectItems = items
        quickSelectTitle = "Recent Documents"
        showQuickSelect = true
    }

    // MARK: - Bookmarks

    private func addBookmarkAtCurrentPosition(label: String? = nil) {
        guard documentID > 0 else { return }
        let text = label ?? document?.page(at: currentPage)?.label ?? "Page \(currentPage + 1)"
        _ = try? database.addBookmark(docID: documentID, page: currentPage,
                                      yOffset: scrollYOffset, text: text)
        loadAnnotations()
        statusMessage = "Bookmark added: \(text)"
    }

    private func deleteBookmarkAtCurrentPosition() {
        guard documentID > 0 else { return }
        try? database.deleteBookmark(docID: documentID, page: currentPage, yOffset: scrollYOffset)
        loadAnnotations()
        statusMessage = "Bookmark removed"
    }

    private func showBookmarksPanel(allDocs: Bool) {
        let items: [QuickSelectItem]
        if allDocs {
            let all = (try? database.fetchAllBookmarks()) ?? []
            items = all.map { bm in
                QuickSelectItemImpl(
                    title: bm.text.isEmpty ? "Page \(bm.page + 1)" : bm.text,
                    subtitle: "Page \(bm.page + 1)",
                    page: bm.page,
                    action: { [weak self] in
                        self?.currentPage = bm.page
                        self?.scrollYOffset = bm.yOffset
                    }
                )
            }
            quickSelectTitle = "All Bookmarks"
        } else {
            items = bookmarks.map { bm in
                QuickSelectItemImpl(
                    title: bm.text.isEmpty ? "Page \(bm.page + 1)" : bm.text,
                    subtitle: "Page \(bm.page + 1)",
                    page: bm.page,
                    action: { [weak self] in
                        self?.currentPage = bm.page
                        self?.scrollYOffset = bm.yOffset
                    }
                )
            }
            quickSelectTitle = "Bookmarks"
        }
        quickSelectItems = items
        showQuickSelect = true
    }

    // MARK: - Highlights

    private func addHighlightWithType(_ type: Character) {
        NotificationCenter.default.post(name: .lectorAddHighlight, object: self,
                                        userInfo: ["type": String(type)])
    }

    func addHighlight(type: Character, rectsPerPage: [Int: [CGRect]], selectionText: String,
                      startPage: Int, endPage: Int) {
        guard documentID > 0 else { return }
        let rectsJSON = Highlight.encodeRects(rectsPerPage)
        _ = try? database.addHighlight(docID: documentID, startPage: startPage, endPage: endPage,
                                       rectsJSON: rectsJSON, type: type, selectionText: selectionText)
        loadAnnotations()
        statusMessage = "Highlight added"
    }

    private func deleteHighlightAtCurrentPosition() {
        guard documentID > 0 else { return }
        let nearby = highlights.filter { $0.startPage == currentPage }
        if let first = nearby.first {
            try? database.deleteHighlight(id: first.id)
            loadAnnotations()
            statusMessage = "Highlight removed"
        }
    }

    private func showHighlightsPanel() {
        let items: [QuickSelectItem] = highlights.map { hl in
            QuickSelectItemImpl(
                title: hl.selectionText.isEmpty ? "Highlight (p.\(hl.startPage + 1))" : hl.selectionText,
                subtitle: "Page \(hl.startPage + 1) — type: \(hl.type)",
                page: hl.startPage,
                action: { [weak self] in
                    self?.currentPage = hl.startPage
                }
            )
        }
        quickSelectItems = items
        quickSelectTitle = "Highlights"
        showQuickSelect = true
    }

    private func jumpToNextHighlight(forward: Bool) {
        let sorted = highlights.sorted { $0.startPage < $1.startPage }
        if forward {
            if let next = sorted.first(where: { $0.startPage > currentPage }) {
                currentPage = next.startPage
            }
        } else {
            if let prev = sorted.last(where: { $0.startPage < currentPage }) {
                currentPage = prev.startPage
            }
        }
    }

    // MARK: - Marks

    private func setMark(symbol: Character) {
        guard documentID > 0 else { return }
        let upper = symbol.isUppercase
        if upper {
            // Global mark (uppercase letters)
            let urlStr = documentURL?.path ?? ""
            try? database.setGlobalMark(symbol: symbol, docURL: urlStr,
                                         page: currentPage, yOffset: scrollYOffset)
        } else {
            try? database.setMark(docID: documentID, symbol: symbol,
                                   page: currentPage, yOffset: scrollYOffset)
            loadAnnotations()
        }
        statusMessage = "Mark '\(symbol)' set"
    }

    private func gotoMark(symbol: Character) {
        let upper = symbol.isUppercase
        if upper {
            if let gm = try? database.fetchGlobalMark(symbol: symbol) {
                pushNavState()
                let url = URL(fileURLWithPath: gm.docURL)
                if url != documentURL {
                    openDocument(at: url)
                }
                currentPage = gm.page
                scrollYOffset = gm.yOffset
            }
        } else {
            if let mark = marks.first(where: { $0.symbol == symbol }) {
                pushNavState()
                currentPage = mark.page
                scrollYOffset = mark.yOffset
            }
        }
    }

    private func showMarksPanel() {
        let items: [QuickSelectItem] = marks.map { mark in
            QuickSelectItemImpl(
                title: "Mark '\(mark.symbol)'",
                subtitle: "Page \(mark.page + 1)",
                page: mark.page,
                action: { [weak self] in
                    self?.currentPage = mark.page
                    self?.scrollYOffset = mark.yOffset
                }
            )
        }
        quickSelectItems = items
        quickSelectTitle = "Marks"
        showQuickSelect = true
    }

    // MARK: - Portals

    private func handlePortalCommand() {
        if let srcPage = portalSourcePage {
            // Second `p` press — create portal to current location
            guard documentID > 0 else { return }
            let dstURL = documentURL?.path ?? ""
            _ = try? database.addPortal(
                srcDocID: documentID,
                srcPage: srcPage,
                srcY: portalSourceY,
                dstURL: dstURL,
                dstPage: currentPage,
                dstY: scrollYOffset,
                dstZoom: Double(zoomScale)
            )
            loadAnnotations()
            portalSourcePage = nil
            statusMessage = "Portal created"
        } else {
            // First `p` press — record source
            portalSourcePage = currentPage
            portalSourceY = scrollYOffset
            statusMessage = "Portal source set — navigate then press 'p' again"
        }
    }

    private func gotoNearestPortal() {
        guard documentID > 0 else { return }
        if let portal = try? database.nearestPortal(srcDocID: documentID,
                                                     page: currentPage,
                                                     yOffset: scrollYOffset) {
            pushNavState()
            let dstURL = URL(fileURLWithPath: portal.dstURL)
            if dstURL != documentURL {
                openDocument(at: dstURL)
            }
            currentPage = portal.dstPage
            scrollYOffset = portal.dstY
            zoomScale = CGFloat(portal.dstZoom)
        }
    }

    private func deletePortalAtCurrentPosition() {
        guard documentID > 0 else { return }
        try? database.deletePortal(srcDocID: documentID, srcPage: currentPage, srcY: scrollYOffset)
        loadAnnotations()
        statusMessage = "Portal deleted"
    }

    // MARK: - Search

    private var searchDelegate: AnyObject?

    private func searchNext() {
        NotificationCenter.default.post(name: .lectorSearchNext, object: self)
    }

    private func searchPrev() {
        NotificationCenter.default.post(name: .lectorSearchPrev, object: self)
    }

    // MARK: - Print

    func printDocument() {
        guard document != nil else { return }
        NotificationCenter.default.post(name: .lectorPrint, object: self)
    }

    // MARK: - Web Search

    private func performWebSearch(engine: WebEngine) {
        NotificationCenter.default.post(name: .lectorWebSearch, object: self,
                                        userInfo: ["engine": engine])
    }
}

// MARK: - QuickSelectItem

protocol QuickSelectItem: AnyObject {
    var title: String { get }
    var subtitle: String { get }
    var page: Int { get }
    func activate()
}

private final class QuickSelectItemImpl: QuickSelectItem {
    let title: String
    let subtitle: String
    let page: Int
    private let actionBlock: () -> Void

    init(title: String, subtitle: String, page: Int, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.page = page
        self.actionBlock = action
    }

    func activate() { actionBlock() }
}
