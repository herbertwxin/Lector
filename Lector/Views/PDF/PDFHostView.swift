import SwiftUI
import PDFKit
import AppKit

// MARK: - PDFHostView

/// SwiftUI wrapper around PDFView + AnnotationLayer overlay.
struct PDFHostView: NSViewRepresentable {
    @Bindable var state: AppState

    func makeNSView(context: Context) -> PDFContainerView {
        let container = PDFContainerView(state: state)
        return container
    }

    func updateNSView(_ container: PDFContainerView, context: Context) {
        // Track any input mode that steals focus: command bar, search bar, quick-select sheet.
        let inInput: Bool
        switch state.mode {
        case .command, .search: inInput = true
        default:                inInput = false
        }
        if inInput || state.showQuickSelect {
            context.coordinator.wasInInputMode = true
        } else if context.coordinator.wasInInputMode {
            context.coordinator.wasInInputMode = false
            DispatchQueue.main.async {
                container.window?.makeFirstResponder(container.pdfView)
            }
        }
        container.update(state: state)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        let state: AppState
        var wasInInputMode = false
        init(state: AppState) { self.state = state }
    }
}

// MARK: - PDFContainerView

/// An NSView that hosts PDFView + the annotation overlay.
final class PDFContainerView: NSView {
    let pdfView: LectorPDFView
    private let annotationLayer: AnnotationLayer
    private weak var state: AppState?

    init(state: AppState) {
        self.state = state
        pdfView = LectorPDFView(state: state)
        annotationLayer = AnnotationLayer(state: state, pdfView: pdfView)
        super.init(frame: .zero)

        addSubview(pdfView)
        addSubview(annotationLayer)

        observeNotifications()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        pdfView.frame = bounds
        annotationLayer.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // Give the PDF view first-responder status as soon as we join a window.
        // The async hop lets SwiftUI finish its layout pass first.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.window?.makeFirstResponder(self.pdfView)
        }
    }

    func update(state: AppState) {
        pdfView.update(state: state)
        annotationLayer.setNeedsDisplay(bounds)
    }

    private func observeNotifications() {
        // Global: refresh annotation layer whenever PDFView scrolls or zooms.
        // These are PDFKit system notifications posted without a state object.
        let globalNames: [Notification.Name] = [
            .PDFViewPageChanged,
            .PDFViewScaleChanged,
            .PDFViewVisiblePagesChanged,
            .lectorAnnotationsChanged
        ]
        for name in globalNames {
            NotificationCenter.default.addObserver(
                self, selector: #selector(refreshAnnotations), name: name, object: nil
            )
        }

        // Scoped: only handle notifications originating from this window's state.
        // Passing `state` as object ensures two windows with the same PDF
        // remain independent (no cross-window page sync, printing, rotation, etc.).
        guard let state else { return }
        let scoped: [(Selector, Notification.Name)] = [
            (#selector(handleAddHighlight(_:)), .lectorAddHighlight),
            (#selector(handleWebSearch(_:)),    .lectorWebSearch),
            (#selector(handleSearchNext),       .lectorSearchNext),
            (#selector(handleSearchPrev),       .lectorSearchPrev),
            (#selector(handleCopy),             .lectorCopySelection),
            (#selector(handleRotate(_:)),       .lectorRotate),
            (#selector(handlePrint),            .lectorPrint),
            (#selector(focusPDF),               .lectorFocusPDF),
        ]
        for (sel, name) in scoped {
            NotificationCenter.default.addObserver(self, selector: sel, name: name, object: state)
        }
    }

    @objc private func handlePrint() {
        pdfView.print(with: NSPrintInfo.shared, autoRotate: true)
    }

    @objc private func focusPDF() {
        window?.makeFirstResponder(pdfView)
    }

    @objc private func refreshAnnotations() {
        annotationLayer.setNeedsDisplay(annotationLayer.bounds)
    }

    @objc private func handleAddHighlight(_ note: Notification) {
        guard let typeStr = note.userInfo?["type"] as? String,
              let type = typeStr.first else { return }
        guard let selection = pdfView.currentSelection,
              let doc = pdfView.document else { return }

        var rectsPerPage: [Int: [CGRect]] = [:]
        var startPage = Int.max, endPage = 0

        for page in selection.pages {
            let pageIdx = doc.index(for: page)
            startPage = min(startPage, pageIdx)
            endPage   = max(endPage, pageIdx)
            let bounds = selection.bounds(for: page)
            rectsPerPage[pageIdx] = [bounds]
        }

        let text = selection.string ?? ""
        if startPage <= endPage {
            state?.addHighlight(type: type, rectsPerPage: rectsPerPage,
                                selectionText: text, startPage: startPage, endPage: endPage)
        }
    }

    @objc private func handleWebSearch(_ note: Notification) {
        guard let engine = note.userInfo?["engine"] as? WebEngine else { return }
        let text = pdfView.currentSelection?.string ?? ""
        let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlStr = String(format: engine.urlTemplate, query)
        if let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func handleSearchNext() {
        pdfView.goToNextPage(nil)
    }

    @objc private func handleSearchPrev() {
        pdfView.goToPreviousPage(nil)
    }

    @objc private func handleCopy() {
        guard let text = pdfView.currentSelection?.string, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func handleRotate(_ note: Notification) {
        let clockwise = note.userInfo?["clockwise"] as? Bool ?? true
        guard let doc = pdfView.document else { return }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            page.rotation += clockwise ? 90 : -90
        }
        pdfView.layoutDocumentView()
    }
}

// MARK: - LectorPDFView

final class LectorPDFView: PDFView {
    private weak var state: AppState?
    private var lastPage: Int = -1
    private var lastSearchText: String = ""
    private var isLoadingDocument = false

    init(state: AppState) {
        self.state = state
        super.init(frame: .zero)
        configure()
        observeNotifications()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        autoScales = true
        displayMode = .singlePageContinuous
        displayDirection = .vertical
        displaysPageBreaks = true
        backgroundColor = .clear
    }

    private func observeNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: self
        )
    }

    @objc private func pageChanged(_ note: Notification) {
        guard !isLoadingDocument else { return }
        guard let page = currentPage, let doc = document else { return }
        let idx = doc.index(for: page)
        if idx != lastPage {
            lastPage = idx
            DispatchQueue.main.async { [weak self] in
                self?.state?.currentPage = idx
            }
        }
    }

    func update(state: AppState) {
        // Document
        if document?.documentURL != state.documentURL {
            if let url = state.documentURL {
                let targetPage = state.currentPage
                isLoadingDocument = true
                lastPage = -1 // Reset lastPage for the new document
                
                document = PDFDocument(url: url)
                
                // Force initial page navigation after document is set.
                // We do it both immediately and async to catch PDFKit in various states.
                if let doc = document, let page = doc.page(at: targetPage) {
                    go(to: page)
                }
                
                DispatchQueue.main.async { [weak self] in
                    guard let self, let doc = self.document else {
                        self?.isLoadingDocument = false
                        return
                    }
                    if let page = doc.page(at: targetPage), self.currentPage != page {
                        self.go(to: page)
                    }
                    self.isLoadingDocument = false
                    // Sync lastPage so the first real user-scroll fires correctly
                    if let p = self.currentPage { self.lastPage = doc.index(for: p) }
                }
            } else {
                document = nil
                lastPage = -1
            }
        }

        // Page
        if let doc = document,
           state.currentPage >= 0,
           state.currentPage < doc.pageCount,
           let page = doc.page(at: state.currentPage),
           currentPage != page {
            go(to: page)
        }

        // Zoom
        if state.fitToWidth {
            autoScales = true
        } else {
            autoScales = false
            let targetScale = state.zoomScale
            if abs(scaleFactor - targetScale) > 0.01 {
                scaleFactor = targetScale
            }
        }

        // Search
        if state.isSearching && state.searchText != lastSearchText {
            lastSearchText = state.searchText
            document?.cancelFindString()
            if !state.searchText.isEmpty {
                document?.beginFindString(state.searchText, withOptions: .caseInsensitive)
            }
        } else if !state.isSearching && !lastSearchText.isEmpty {
            lastSearchText = ""
            document?.cancelFindString()
        }

        // Appearance — nil lets the view inherit from the window (respects auto/system)
        switch state.appearanceMode {
        case .dark:  appearance = NSAppearance(named: .darkAqua)
        case .light: appearance = NSAppearance(named: .aqua)
        case .auto:  appearance = nil
        }
    }

    // MARK: - Key events passed to AppState

    override func keyDown(with event: NSEvent) {
        if state?.handleKeyEvent(event) == true { return }
        super.keyDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }
}

