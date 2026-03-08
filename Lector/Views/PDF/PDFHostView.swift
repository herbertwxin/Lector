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
    private var lastScrollUpdateTime: TimeInterval = 0

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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(visiblePagesChanged(_:)),
            name: .PDFViewVisiblePagesChanged,
            object: self
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scaleChanged(_:)),
            name: .PDFViewScaleChanged,
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

    @objc private func visiblePagesChanged(_ note: Notification) {
        guard !isLoadingDocument else { return }
        guard let doc = document, let page = currentPage else { return }

        // Throttle updates to avoid excessive state churn while scrolling.
        let now = Date().timeIntervalSince1970
        if now - lastScrollUpdateTime < 0.05 { return } // ~20 Hz max
        lastScrollUpdateTime = now

        let pageIndex = doc.index(for: page)
        guard pageIndex >= 0, pageIndex < doc.pageCount else { return }

        let pageBounds = page.bounds(for: .mediaBox)

        // Use the vertical center of the visible rect as our anchor.
        let visibleRect = documentView?.visibleRect ?? bounds
        let anchorY = visibleRect.midY
        let viewPoint = CGPoint(x: bounds.midX, y: anchorY)
        let pagePoint = convert(viewPoint, to: page)

        // Distance from the top of the page (consistent with AnnotationLayer's yOffset semantics).
        var offset = Double(pageBounds.maxY - pagePoint.y)
        let maxOffset = Double(pageBounds.height)
        if offset < 0 { offset = 0 }
        if offset > maxOffset { offset = maxOffset }

        DispatchQueue.main.async { [weak self] in
            self?.state?.scrollYOffset = offset
        }
    }

    @objc private func scaleChanged(_ note: Notification) {
        guard !isLoadingDocument else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state?.viewScaleFactor = self.scaleFactor
        }
    }

    func update(state: AppState) {
        // Document: AppState is the single source of truth for PDFDocument.
        if document !== state.document {
            isLoadingDocument = true
            lastPage = -1
            lastScrollUpdateTime = 0
            document = state.document

            func goToTargetPosition() {
                guard let doc = self.document,
                      doc.pageCount > 0 else { return }
                let targetPage = state.currentPage
                let targetOffset = state.scrollYOffset

                let clampedPage = max(0, min(targetPage, doc.pageCount - 1))
                guard let page = doc.page(at: clampedPage) else { return }
                let bounds = page.bounds(for: .mediaBox)
                let maxOffset = Double(bounds.height)
                var offset = targetOffset
                if offset < 0 { offset = 0 }
                if offset > maxOffset { offset = maxOffset }
                let point = CGPoint(x: bounds.minX, y: bounds.maxY - CGFloat(offset))
                let dest = PDFDestination(page: page, at: point)
                self.go(to: dest)
            }

            // If a document is present, navigate to the desired page/offset.
            if state.document != nil {
                goToTargetPosition()

                DispatchQueue.main.async { [weak self] in
                    guard let self, let doc = self.document else {
                        self?.isLoadingDocument = false
                        return
                    }
                    goToTargetPosition()
                    self.isLoadingDocument = false
                    // Sync lastPage so the first real user-scroll fires correctly
                    if let p = self.currentPage { self.lastPage = doc.index(for: p) }
                }
            } else {
                isLoadingDocument = false
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

    // MARK: - Citation handling (left click → jump, right click → Google Scholar, hover → tooltip)

    private var citationTooltipWindow: NSWindow?
    private var hoveredCitation: CitationAtPoint?
    private var citationTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = citationTrackingArea {
            removeTrackingArea(existing)
        }
        let options: NSTrackingArea.Options = [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow]
        citationTrackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(citationTrackingArea!)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateCitationHover(at: event.locationInWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateCitationHover(at: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hideCitationTooltip()
    }

    private func updateCitationHover(at windowPoint: NSPoint) {
        guard let state, let doc = document, state.citationDetectionEnabled else { hideCitationTooltip(); return }
        guard self.window != nil else { hideCitationTooltip(); return }
        let viewPoint = convert(windowPoint, from: nil)
        guard let page = page(for: viewPoint, nearest: false) else { hideCitationTooltip(); return }
        let pageIndex = doc.index(for: page)
        let pagePoint = convert(viewPoint, to: page)

        let citation: CitationAtPoint?
        if !state.citationRegions.isEmpty {
            citation = CitationDetector.citationAt(
                pageIndex: pageIndex,
                pointInPage: pagePoint,
                regions: state.citationRegions,
                catalog: state.citationReferenceIndex
            )
        } else {
            citation = CitationDetector.citationAt(
                document: doc,
                page: page,
                pointInPage: pagePoint,
                referenceIndex: state.citationReferenceIndex
            )
        }
        if let citation = citation {
            if hoveredCitation?.key != citation.key || hoveredCitation?.fullText != citation.fullText {
                hoveredCitation = citation
                showCitationTooltip(citation: citation, near: windowPoint)
            }
        } else {
            hideCitationTooltip()
            hoveredCitation = nil
        }
    }

    private func showCitationTooltip(citation: CitationAtPoint, near windowPoint: NSPoint) {
        let text = citation.fullText
        guard !text.isEmpty else { return }

        let font = NSFont.systemFont(ofSize: 11)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let maxWidth: CGFloat = 400
        let size = attrStr.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).size
        let padding: CGFloat = 8
        let contentSize = CGSize(width: min(size.width + padding * 2, maxWidth + padding * 2), height: size.height + padding * 2)

        if citationTooltipWindow == nil {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: contentSize),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = true
            panel.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.95)
            panel.hasShadow = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces]
            citationTooltipWindow = panel
        }

        guard let panel = citationTooltipWindow else { return }
        let label: NSTextField = {
            if let existing = panel.contentView?.subviews.compactMap({ $0 as? NSTextField }).first {
                return existing
            }
            let tf = NSTextField(labelWithAttributedString: NSAttributedString(string: ""))
            tf.isEditable = false
            tf.isSelectable = true
            tf.drawsBackground = false
            tf.isBordered = false
            tf.lineBreakMode = .byWordWrapping
            tf.maximumNumberOfLines = 0
            tf.cell?.truncatesLastVisibleLine = false
            panel.contentView = NSView(frame: NSRect(origin: .zero, size: contentSize))
            panel.contentView?.addSubview(tf)
            return tf
        }()
        label.attributedStringValue = attrStr
        label.frame = NSRect(x: padding, y: padding, width: contentSize.width - padding * 2, height: contentSize.height - padding * 2)

        panel.setContentSize(contentSize)
        if let window = self.window {
            let screenPoint = window.convertPoint(toScreen: windowPoint)
            let x = screenPoint.x
            let y = screenPoint.y + 12
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFront(nil)
    }

    private func hideCitationTooltip() {
        citationTooltipWindow?.orderOut(nil)
    }

    override func mouseDown(with event: NSEvent) {
        if handleCitationClick(at: event.locationInWindow, rightClick: false) { return }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if handleCitationClick(at: event.locationInWindow, rightClick: true) { return }
        super.rightMouseDown(with: event)
    }

    private func handleCitationClick(at windowPoint: NSPoint, rightClick: Bool) -> Bool {
        guard let state, let doc = document, state.citationDetectionEnabled else { return false }
        let viewPoint = convert(windowPoint, from: nil)
        guard let page = page(for: viewPoint, nearest: false) else { return false }
        let pageIndex = doc.index(for: page)
        let pagePoint = convert(viewPoint, to: page)

        let citation: CitationAtPoint?
        if !state.citationRegions.isEmpty {
            citation = CitationDetector.citationAt(
                pageIndex: pageIndex,
                pointInPage: pagePoint,
                regions: state.citationRegions,
                catalog: state.citationReferenceIndex
            )
        } else {
            citation = CitationDetector.citationAt(
                document: doc,
                page: page,
                pointInPage: pagePoint,
                referenceIndex: state.citationReferenceIndex
            )
        }
        guard let citation = citation else { return false }

        if rightClick {
            let query = citation.fullText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let urlStr = String(format: WebEngine.scholar.urlTemplate, query)
            if let url = URL(string: urlStr) {
                NSWorkspace.shared.open(url)
            }
            return true
        }

        guard let ref = state.citationReferenceIndex[citation.key] else { return false }
        state.pushNavState()
        state.currentPage = ref.pageIndex
        state.scrollYOffset = ref.yOffset
        return true
    }
}

