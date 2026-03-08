import Foundation
import PDFKit

// MARK: - DocumentStructureType

enum DocumentStructureType: String, CaseIterable {
    case figure
    case table
    case equation
    case proposition
    case theorem
    case lemma

    var displayName: String { rawValue.capitalized }

    /// For each N, try these strings in order; first match wins (e.g. "Figure 1", "Fig. 1", "Fig 1").
    var searchPatterns: (Int) -> [String] {
        switch self {
        case .figure:
            return { n in ["Figure \(n)", "Fig. \(n)", "Fig \(n)"] }
        case .table:
            return { n in ["Table \(n)", "Tbl. \(n)", "Tbl \(n)"] }
        case .equation:
            return { n in ["Equation (\(n))", "Equation \(n)", "Eq. (\(n))", "Eq (\(n))", "Eq. \(n)", "Eq \(n)"] }
        case .proposition:
            return { n in ["Proposition \(n)", "Prop. \(n)", "Prop \(n)"] }
        case .theorem:
            return { n in ["Theorem \(n)", "Thm. \(n)", "Thm \(n)"] }
        case .lemma:
            return { n in ["Lemma \(n)", "Lem. \(n)", "Lem \(n)"] }
        }
    }

    /// How many numbered items to search for (e.g. Figure 1 … Figure 150).
    var searchLimit: Int {
        switch self {
        case .figure:     return 200
        case .table:     return 80
        case .equation:  return 100
        case .proposition: return 60
        case .theorem:   return 60
        case .lemma:     return 60
        }
    }

    /// Stop after this many consecutive misses (speeds up detection).
    var stopAfterMisses: Int { 5 }
}

// MARK: - DocumentStructureItem

struct DocumentStructureItem: Sendable {
    let type: DocumentStructureType
    let label: String
    let pageIndex: Int
    let yOffset: Double
}

// MARK: - DocumentStructureDetector

enum DocumentStructureDetector {

    /// Detects figures, tables, equations, etc. by searching for caption text.
    /// Runs on caller's thread; call from a background queue for large PDFs.
    static func detect(document: PDFDocument) -> [DocumentStructureItem] {
        var results: [DocumentStructureItem] = []
        let options: NSString.CompareOptions = [.caseInsensitive]

        for type in DocumentStructureType.allCases {
            var misses = 0
            for n in 1...type.searchLimit {
                let patterns = type.searchPatterns(n)
                var selection: PDFSelection?
                var matchedString: String?
                for candidate in patterns {
                    let matches = document.findString(candidate, withOptions: options)
                    if let first = matches.first {
                        selection = first
                        matchedString = candidate
                        break
                    }
                }
                guard let sel = selection, let label = matchedString else {
                    misses += 1
                    if misses >= type.stopAfterMisses { break }
                    continue
                }
                misses = 0

                guard let page = sel.pages.first else { continue }
                let pageIndex = document.index(for: page)
                let pageBounds = page.bounds(for: .mediaBox)
                let selBounds = sel.bounds(for: page)
                // yOffset = distance from top of page (same semantics as AnnotationLayer).
                // Anchor to the top edge of the caption text, then add an upward margin
                // so that PDFKit scrolls to a point *above* the caption, making the
                // figure/table visible rather than landing below it.  80 pt is generous
                // enough to show a typical caption header while keeping the figure in view.
                let margin: CGFloat = 80
                let yOffset = Double(pageBounds.maxY - selBounds.maxY - margin)
                let clamped = min(max(yOffset, 0), Double(pageBounds.height))

                results.append(DocumentStructureItem(
                    type: type,
                    label: label,
                    pageIndex: pageIndex,
                    yOffset: clamped
                ))
            }
        }

        return results.sorted { a, b in
            if a.pageIndex != b.pageIndex { return a.pageIndex < b.pageIndex }
            return a.yOffset < b.yOffset
        }
    }
}
