import Foundation
import AppKit
import PDFKit
import Observation

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

    // MARK: Navigation
    var currentPage: Int = 0
    var scrollYOffset: Double = 0
    var zoomScale: CGFloat = 1.0
    var fitToWidth: Bool = true

    // MARK: Mode & UI
    var mode: ViewerMode = .normal
    var isDarkMode: Bool = false
    var showTOC: Bool = false
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

    // MARK: Portal state
    var portalSourcePage: Int? = nil
    var portalSourceY: Double = 0

    // MARK: Services
    @ObservationIgnored let database: Database
    @ObservationIgnored private let navHistory = NavHistory()
    @ObservationIgnored private let keyTrie = KeyTrie()
    private(set) var recentDocuments: [RecentDocument] = []

    // MARK: Init

    init() {
        do {
            database = try Database()
        } catch {
            fatalError("Cannot open Lector database: \(error)")
        }
        keyTrie.build(from: DefaultBindings.keybindings)
        loadRecentDocuments()
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
            openDocument(at: url)
        }
    }

    func openDocument(at url: URL) {
        guard let doc = PDFDocument(url: url) else {
            statusMessage = "Failed to open: \(url.lastPathComponent)"
            return
        }
        // Push current state before navigating away
        if documentURL != nil {
            pushNavState()
        }
        documentURL = url
        document = doc

        // Upsert document in DB
        let checksum = Checksum.sha256(of: url) ?? ""
        documentID = (try? database.upsertDocument(url: url, checksum: checksum)) ?? 0

        currentPage = 0
        scrollYOffset = 0
        loadAnnotations()
        loadRecentDocuments()
        statusMessage = url.lastPathComponent
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
                return true
            }
            return false
        default:
            break
        }

        let commands = keyTrie.handleKey(event: event)
        guard !commands.isEmpty else { return false }

        for command in commands {
            execute(command)
        }
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
            fitToWidth = false
            zoomScale = min(zoomScale * 1.25, 10.0)
        case .zoomOut:
            fitToWidth = false
            zoomScale = max(zoomScale / 1.25, 0.1)
        case .fitToWidth:
            fitToWidth = true
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
            addBookmarkAtCurrentPosition()
        case .deleteBookmark:
            deleteBookmarkAtCurrentPosition()
        case .listBookmarks:
            showBookmarksPanel(allDocs: false)
        case .listAllBookmarks:
            showBookmarksPanel(allDocs: true)

        // Highlights
        case .addHighlight(let ch):
            addHighlightWithType(ch)
        case .deleteHighlight:
            deleteHighlightAtCurrentPosition()
        case .listHighlights:
            showHighlightsPanel()
        case .nextHighlight:
            jumpToNextHighlight(forward: true)
        case .prevHighlight:
            jumpToNextHighlight(forward: false)

        // Marks
        case .setMark(let ch):
            setMark(symbol: ch)
        case .gotoMark(let ch):
            gotoMark(symbol: ch)
        case .listMarks:
            showMarksPanel()

        // Portals
        case .setPortalSource:
            handlePortalCommand()
        case .gotoPortal:
            gotoNearestPortal()
        case .editPortal:
            break   // future
        case .deletePortal:
            deletePortalAtCurrentPosition()

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
            isDarkMode.toggle()
        case .quit:
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Execute Command String (from `:` mode)

    func executeCommandString(_ input: String) {
        let parts = input.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
        guard let name = parts.first else { return }
        switch name {
        case "dark", "darkmode":   isDarkMode = true
        case "light", "lightmode": isDarkMode = false
        case "toc":                showTOC.toggle()
        case "quit", "q":          NSApplication.shared.terminate(nil)
        case "open", "o":          openDocumentDialog()
        case "page":
            if let p = parts.dropFirst().first.flatMap(Int.init) {
                execute(.gotoPage(p - 1))
            }
        default:
            statusMessage = "Unknown command: \(name)"
        }
        mode = .normal
    }

    // MARK: - Bookmarks

    private func addBookmarkAtCurrentPosition() {
        guard documentID > 0 else { return }
        let text = document?.page(at: currentPage)?.label ?? "Page \(currentPage + 1)"
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
        // Grab current PDFView selection — signalled via notification
        NotificationCenter.default.post(name: .lectorAddHighlight, object: type)
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
        NotificationCenter.default.post(name: .lectorSearchNext, object: nil)
    }

    private func searchPrev() {
        NotificationCenter.default.post(name: .lectorSearchPrev, object: nil)
    }

    // MARK: - Web Search

    private func performWebSearch(engine: WebEngine) {
        NotificationCenter.default.post(name: .lectorWebSearch, object: engine)
    }
}

// MARK: - QuickSelectItem protocol

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

// MARK: - Notifications

extension Notification.Name {
    static let lectorAddHighlight = Notification.Name("lectorAddHighlight")
    static let lectorSearchNext   = Notification.Name("lectorSearchNext")
    static let lectorSearchPrev   = Notification.Name("lectorSearchPrev")
    static let lectorWebSearch    = Notification.Name("lectorWebSearch")
    static let lectorAnnotationsChanged = Notification.Name("lectorAnnotationsChanged")
}
