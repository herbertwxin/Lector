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
        container.update(state: state)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        let state: AppState
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

    func update(state: AppState) {
        pdfView.update(state: state)
        annotationLayer.setNeedsDisplay(bounds)
    }

    private func observeNotifications() {
        // Refresh annotation layer whenever PDFView scrolls or zooms
        let names: [Notification.Name] = [
            .PDFViewPageChanged,
            .PDFViewScaleChanged,
            .PDFViewVisiblePagesChanged,
            .lectorAnnotationsChanged
        ]
        for name in names {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(refreshAnnotations),
                name: name,
                object: nil
            )
        }

        // Add-highlight request
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAddHighlight(_:)),
            name: .lectorAddHighlight,
            object: nil
        )

        // Web search
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWebSearch(_:)),
            name: .lectorWebSearch,
            object: nil
        )

        // Search nav
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSearchNext),
            name: .lectorSearchNext,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSearchPrev),
            name: .lectorSearchPrev,
            object: nil
        )
    }

    @objc private func refreshAnnotations() {
        annotationLayer.setNeedsDisplay(annotationLayer.bounds)
    }

    @objc private func handleAddHighlight(_ note: Notification) {
        guard let type = note.object as? Character else { return }
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
        guard let engine = note.object as? WebEngine else { return }
        let text = pdfView.currentSelection?.string ?? ""
        let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlStr = String(format: engine.urlTemplate, query)
        if let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func handleSearchNext() {
        pdfView.goToNextPage(nil)   // approximate: jump between pages
        // Proper implementation: track search results via PDFDocumentDidFindMatch notifications
    }

    @objc private func handleSearchPrev() {
        pdfView.goToPreviousPage(nil)
    }
}

// MARK: - LectorPDFView

final class LectorPDFView: PDFView {
    private weak var state: AppState?
    private var lastPage: Int = -1
    private var lastSearchText: String = ""

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
                document = PDFDocument(url: url)
            } else {
                document = nil
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

        // Dark mode appearance
        appearance = state.isDarkMode
            ? NSAppearance(named: .darkAqua)
            : NSAppearance(named: .aqua)
    }

    // MARK: - Key events passed to AppState

    override func keyDown(with event: NSEvent) {
        if state?.handleKeyEvent(event) == true { return }
        super.keyDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }
}

