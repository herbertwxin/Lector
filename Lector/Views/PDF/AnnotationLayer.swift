import AppKit
import PDFKit

// MARK: - Highlight Color Map

extension Character {
    var highlightColor: NSColor {
        switch self {
        case "a": return NSColor.systemYellow.withAlphaComponent(0.4)
        case "b": return NSColor.systemGreen.withAlphaComponent(0.4)
        case "c": return NSColor.systemBlue.withAlphaComponent(0.4)
        case "d": return NSColor.systemRed.withAlphaComponent(0.4)
        default:  return NSColor.systemYellow.withAlphaComponent(0.4)
        }
    }
}

// MARK: - AnnotationLayer

/// Transparent overlay drawn on top of the PDFView.
/// Renders highlights, bookmarks ribbons, mark dots, and portal arrows.
final class AnnotationLayer: NSView {
    private weak var state: AppState?
    private weak var pdfView: PDFView?

    init(state: AppState, pdfView: PDFView) {
        self.state = state
        self.pdfView = pdfView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override var isOpaque: Bool { false }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let state = state,
              let pdfView = pdfView,
              let ctx = NSGraphicsContext.current?.cgContext
        else { return }

        drawHighlights(state: state, pdfView: pdfView, ctx: ctx)
        drawBookmarks(state: state, pdfView: pdfView, ctx: ctx)
        drawMarks(state: state, pdfView: pdfView, ctx: ctx)
        drawPortals(state: state, pdfView: pdfView, ctx: ctx)
    }

    // MARK: - Highlights

    private func drawHighlights(state: AppState, pdfView: PDFView, ctx: CGContext) {
        guard let doc = pdfView.document else { return }

        for highlight in state.highlights {
            let color = highlight.type.highlightColor
            ctx.setFillColor(color.cgColor)

            let rectsPerPage = highlight.decodedRects
            for (pageIdx, rects) in rectsPerPage {
                guard pageIdx < doc.pageCount,
                      let pdfPage = doc.page(at: pageIdx)
                else { continue }

                for pdfRect in rects {
                    let screenRect = pdfView.convert(pdfRect, from: pdfPage)
                    let localRect = convert(screenRect, from: pdfView)
                    ctx.fill(localRect)
                }
            }
        }
    }

    // MARK: - Bookmarks

    private func drawBookmarks(state: AppState, pdfView: PDFView, ctx: CGContext) {
        guard let doc = pdfView.document else { return }
        let ribbonWidth: CGFloat = 8
        let ribbonHeight: CGFloat = 20
        let ribbonColor = NSColor.systemRed

        for bm in state.bookmarks {
            guard bm.page < doc.pageCount,
                  let pdfPage = doc.page(at: bm.page)
            else { continue }

            // Convert the y_offset on the page to screen coords
            let pageSize = pdfPage.bounds(for: .mediaBox).size
            let pdfPoint = CGPoint(x: 0, y: pageSize.height - CGFloat(bm.yOffset))
            let screenPt = pdfView.convert(pdfPoint, from: pdfPage)
            let localPt  = convert(screenPt, from: pdfView)

            let ribbonRect = CGRect(
                x: 0,
                y: localPt.y - ribbonHeight / 2,
                width: ribbonWidth,
                height: ribbonHeight
            )

            ctx.setFillColor(ribbonColor.cgColor)
            ctx.fill(ribbonRect)

            // Triangle on the right edge of the ribbon
            ctx.beginPath()
            ctx.move(to: CGPoint(x: ribbonWidth, y: ribbonRect.minY))
            ctx.addLine(to: CGPoint(x: ribbonWidth, y: ribbonRect.maxY))
            ctx.addLine(to: CGPoint(x: ribbonWidth + 5, y: ribbonRect.midY))
            ctx.closePath()
            ctx.fillPath()
        }
    }

    // MARK: - Marks

    private func drawMarks(state: AppState, pdfView: PDFView, ctx: CGContext) {
        guard let doc = pdfView.document else { return }
        let dotRadius: CGFloat = 6
        let dotColor = NSColor.systemBlue

        for mark in state.marks {
            guard mark.page < doc.pageCount,
                  let pdfPage = doc.page(at: mark.page)
            else { continue }

            let pageSize = pdfPage.bounds(for: .mediaBox).size
            let pdfPoint = CGPoint(x: pageSize.width, y: pageSize.height - CGFloat(mark.yOffset))
            let screenPt = pdfView.convert(pdfPoint, from: pdfPage)
            var localPt  = convert(screenPt, from: pdfView)
            localPt.x = bounds.width - dotRadius * 3

            let dotRect = CGRect(
                x: localPt.x - dotRadius,
                y: localPt.y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )

            ctx.setFillColor(dotColor.withAlphaComponent(0.8).cgColor)
            ctx.fillEllipse(in: dotRect)

            // Draw the mark letter
            let letter = String(mark.symbol)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let attrStr = NSAttributedString(string: letter, attributes: attrs)
            let strSize = attrStr.size()
            let strRect = CGRect(
                x: dotRect.midX - strSize.width / 2,
                y: dotRect.midY - strSize.height / 2,
                width: strSize.width,
                height: strSize.height
            )
            attrStr.draw(in: strRect)
        }
    }

    // MARK: - Portals

    private func drawPortals(state: AppState, pdfView: PDFView, ctx: CGContext) {
        guard let doc = pdfView.document else { return }

        for portal in state.portals {
            guard portal.srcPage < doc.pageCount,
                  let pdfPage = doc.page(at: portal.srcPage)
            else { continue }

            let pageSize = pdfPage.bounds(for: .mediaBox).size
            let pdfPoint = CGPoint(x: pageSize.width / 2, y: pageSize.height - CGFloat(portal.srcY))
            let screenPt = pdfView.convert(pdfPoint, from: pdfPage)
            let localPt  = convert(screenPt, from: pdfView)

            // Dashed arrow indicator
            let arrowLen: CGFloat = 20
            ctx.setStrokeColor(NSColor.systemPurple.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(2)
            ctx.setLineDash(phase: 0, lengths: [4, 2])

            ctx.beginPath()
            ctx.move(to: CGPoint(x: localPt.x, y: localPt.y))
            ctx.addLine(to: CGPoint(x: localPt.x + arrowLen, y: localPt.y))
            ctx.strokePath()

            // Arrowhead
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.beginPath()
            ctx.move(to: CGPoint(x: localPt.x + arrowLen - 6, y: localPt.y - 4))
            ctx.addLine(to: CGPoint(x: localPt.x + arrowLen, y: localPt.y))
            ctx.addLine(to: CGPoint(x: localPt.x + arrowLen - 6, y: localPt.y + 4))
            ctx.strokePath()
        }

        // Draw portal source indicator if pending
        if let srcPage = state.portalSourcePage, srcPage < doc.pageCount,
           let pdfPage = doc.page(at: srcPage) {
            let pageSize = pdfPage.bounds(for: .mediaBox).size
            let pdfPoint = CGPoint(x: pageSize.width / 2, y: pageSize.height - CGFloat(state.portalSourceY))
            let screenPt = pdfView.convert(pdfPoint, from: pdfPage)
            let localPt  = convert(screenPt, from: pdfView)

            ctx.setFillColor(NSColor.systemOrange.withAlphaComponent(0.6).cgColor)
            ctx.fillEllipse(in: CGRect(x: localPt.x - 5, y: localPt.y - 5, width: 10, height: 10))
        }
    }

    // MARK: - Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Transparent to mouse events — let PDFView handle them
        return nil
    }
}
