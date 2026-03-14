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

    // MARK: Search state
    private var searchSelections: [PDFSelection] = []
    private var searchSelectionIndex: Int = -1
    /// Mirrors the search text we last handled, so we can detect text changes in update().
    private var lastSearchText: String = ""

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
        // When the search text changes (or search closes) clear stale results immediately
        // so the count/index don't linger until the next PDFDocumentDidBeginFind fires.
        let newText = state.isSearching ? state.searchText : ""
        if newText != lastSearchText {
            lastSearchText = newText
            searchSelections = []
            searchSelectionIndex = -1
            pdfView.highlightedSelections = nil
            state.searchIsComplete = false
        }
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

        // PDFDocument search notifications (object = the PDFDocument; filtered in handlers).
        NotificationCenter.default.addObserver(
            self, selector: #selector(searchDidFindMatch(_:)),
            name: .PDFDocumentDidFindMatch, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(searchDidEnd(_:)),
            name: .PDFDocumentDidEndFind, object: nil)

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
            (#selector(handleScrollBy(_:)),     .lectorScrollBy),
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

    @objc private func handleScrollBy(_ note: Notification) {
        guard let delta = note.userInfo?["delta"] as? CGFloat,
              let smooth = note.userInfo?["smooth"] as? Bool else { return }
        pdfView.performScroll(by: delta, smooth: smooth)
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
            DispatchQueue.global(qos: .userInitiated).async { NSWorkspace.shared.open(url) }
        }
    }

    @objc private func handleSearchNext() {
        guard !searchSelections.isEmpty else { return }
        searchSelectionIndex = (searchSelectionIndex + 1) % searchSelections.count
        let sel = searchSelections[searchSelectionIndex]
        pdfView.go(to: sel)
        pdfView.setCurrentSelection(sel, animate: true)
        state?.searchCurrentResult = searchSelectionIndex + 1
    }

    @objc private func handleSearchPrev() {
        guard !searchSelections.isEmpty else { return }
        searchSelectionIndex = (searchSelectionIndex - 1 + searchSelections.count) % searchSelections.count
        let sel = searchSelections[searchSelectionIndex]
        pdfView.go(to: sel)
        pdfView.setCurrentSelection(sel, animate: true)
        state?.searchCurrentResult = searchSelectionIndex + 1
    }

    /// Appends each match PDFKit finds, highlights it, and auto-jumps to the first result.
    @objc private func searchDidFindMatch(_ note: Notification) {
        guard note.object as? PDFDocument === pdfView.document else { return }
        guard let sel = note.userInfo?[PDFDocumentFoundSelectionKey] as? PDFSelection else { return }
        searchSelections.append(sel)
        pdfView.highlightedSelections = searchSelections
        // Auto-navigate to the very first match as soon as it arrives.
        if searchSelections.count == 1 {
            searchSelectionIndex = 0
            pdfView.go(to: sel)
            pdfView.setCurrentSelection(sel, animate: false)
            state?.searchCurrentResult = 1
        }
        state?.searchResultCount = searchSelections.count
    }

    /// Called when PDFKit has finished searching the whole document.
    @objc private func searchDidEnd(_ note: Notification) {
        guard note.object as? PDFDocument === pdfView.document else { return }
        state?.searchResultCount = searchSelections.count
        state?.searchIsComplete = true
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

        // Page — prefer a precise PDFDestination when a programmatic navigation has
        // set pendingNavigationOffset; fall back to the coarser go(to:PDFPage) for
        // user-driven page changes (where only the page index is known).
        if let pendingOffset = state.pendingNavigationOffset {
            state.pendingNavigationOffset = nil
            if let doc = document,
               state.currentPage >= 0,
               state.currentPage < doc.pageCount,
               let page = doc.page(at: state.currentPage) {
                let bounds = page.bounds(for: .mediaBox)
                var offset = pendingOffset
                if offset < 0 { offset = 0 }
                if offset > Double(bounds.height) { offset = Double(bounds.height) }
                let point = CGPoint(x: bounds.minX, y: bounds.maxY - CGFloat(offset))
                go(to: PDFDestination(page: page, at: point))
            }
        } else if let doc = document,
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

    // MARK: - Keyboard scroll

    /// Scroll the PDF document view by `delta` points (positive = down / further into doc).
    /// Uses the scroll view's native coordinate space, so PDFKit handles page boundaries
    /// seamlessly in continuous-scroll mode.
    fileprivate func performScroll(by delta: CGFloat, smooth: Bool) {
        guard let docView = documentView,
              let scrollView = docView.enclosingScrollView else { return }

        let currentOrigin = scrollView.contentView.bounds.origin
        let contentHeight = docView.frame.height
        let visibleHeight = scrollView.contentSize.height
        let maxY = max(0, contentHeight - visibleHeight)
        let targetY = min(max(0, currentOrigin.y + delta), maxY)
        let target = CGPoint(x: currentOrigin.x, y: targetY)

        if smooth {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                scrollView.contentView.animator().setBoundsOrigin(target)
            }, completionHandler: {
                scrollView.reflectScrolledClipView(scrollView.contentView)
            })
        } else {
            scrollView.contentView.scroll(to: target)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    // MARK: - Key events passed to AppState

    override func keyDown(with event: NSEvent) {
        if state?.handleKeyEvent(event) == true { return }
        super.keyDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Citation handling (hover → tooltip; 'c' key → open references panel)

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
                state.hoveredCitation = citation
                showCitationTooltip(citation: citation, near: windowPoint)
            }
        } else {
            hideCitationTooltip()
        }
    }

    private func showCitationTooltip(citation: CitationAtPoint, near windowPoint: NSPoint) {
        let bodyText = citation.fullText
        guard !bodyText.isEmpty else { return }
        let text = bodyText + "\n— Press 'c' to open in References"

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
        hoveredCitation = nil
        state?.hoveredCitation = nil
    }
}

