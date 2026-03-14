import Foundation
import PDFKit

// MARK: - IndexedReference

/// A bibliography/reference entry detected at the bottom of a document.
/// `key` is either a numeric string (e.g. "1") or an author-year key
/// like "Sargent 1991".
struct IndexedReference: Sendable {
    let key: String
    let pageIndex: Int
    let yOffset: Double
    let fullText: String
}

// MARK: - CitationAtPoint

/// Result of detecting an inline citation at a point.
/// `key` matches the `IndexedReference.key` (numeric or author-year).
struct CitationAtPoint: Sendable {
    let key: String
    let fullText: String
}

// MARK: - CitationDetector

/// Auto-detects inline citations and indexes bibliography references.
/// Based on sioyek-old's index_references and get_reference_text_at_position.
enum CitationDetector {

    /// Inline citation pattern: [1], [2], [1,2,3], [1, 2, 3]
    /// Currently used via manual parsing, but kept for future refinements.
    private static let inlineCitationRegex = try! NSRegularExpression(
        pattern: "\\[([0-9]+(?:\\s*,\\s*[0-9]+)*)\\]",
        options: []
    )

    /// Reference definition at start of line: [1] or [1, 2, 3] followed by citation text.
    /// Allows up to 3 chars before [ (e.g. line numbers, spaces) per sioyek heuristic.
    private static let referenceLineRegex = try! NSRegularExpression(
        pattern: "^.{0,3}\\[([0-9\\s,]+)\\]\\s*(.*)$",
        options: [.anchorsMatchLines]
    )

    /// Matches section headings like "References", "Bibliography", "Works Cited".
    private static let referenceHeadingRegex = try! NSRegularExpression(
        pattern: #"^\s*(References?|Bibliography|Works Cited|Literature Cited|Citations?|Sources)\s*$"#,
        options: [.caseInsensitive, .anchorsMatchLines]
    )

    // MARK: - Author name helpers

    /// Words that cannot be the first token of an author surname.
    private static let notSurnames: Set<String> = [
        // Articles, prepositions, conjunctions, pronouns
        "of", "and", "in", "on", "for", "with", "without", "at", "to", "from", "by", "the", "an", "a",
        "we", "our", "their", "they", "this", "that", "these", "those", "there", "here", "it", "its",
        "also", "thus", "note", "first", "second", "third", "when", "where", "while", "since", "as",
        // Academic / document terms
        "application", "applications", "working", "constraints", "agents", "paper", "report", "reports",
        "see", "forthcoming", "chapter", "section", "above", "below", "following",
        "table", "tables", "figure", "figures", "equation", "equations", "appendix", "appendices",
        // Journal / publication terms
        "journal", "review", "annual", "quarterly", "proceedings", "advances", "studies", "research",
        "econometrics", "economics", "economic", "finance", "financial", "mathematical", "statistics",
        "statistical", "american", "international", "national", "european", "conference", "symposium",
        "transactions", "letters", "bulletin", "gazette", "magazine", "series", "volume", "issue",
        // Publishers / institutions
        "press", "university", "institute", "bureau", "board", "center", "centre", "department",
        "princeton", "cambridge", "harvard", "yale", "mit", "oxford", "nber", "elsevier", "springer",
        "wiley", "routledge", "macmillan", "palgrave",
        // Common content nouns that start lines
        "model", "models", "learning", "reinforcement", "deep", "heterogeneous", "aggregate", "policy",
        "market", "markets", "price", "prices", "income", "wealth", "risk", "reward", "prediction",
        "monetary", "service", "rate", "rates", "games", "effects", "book", "academic", "brain",
        "distribution", "inequality", "challenge", "challenges", "control", "constraint", "constraints",
        "dynamics", "dynamic", "equilibrium", "equilibria", "algorithm", "algorithms", "neural",
        "network", "networks", "data", "analysis", "methods", "method", "approach", "framework",
        "theory", "theories", "evidence", "result", "results", "asset", "assets", "capital",
        "consumption", "production", "investment", "employment", "macro", "micro", "general",
        "partial", "stochastic", "recursive", "markov", "bayesian", "linear", "nonlinear", "optimal",
        "adaptive", "expectation", "expectations", "rational", "affect", "following", "given",
        "introduction", "conclusion", "references", "bibliography", "acknowledgments", "abstract",
        "multi-agent", "multi", "single", "joint", "common", "recent", "new", "novel", "standard",
        "homogeneous", "representative", "idiosyncratic", "total",
    ]

    /// Known lowercase surname prefixes (e.g. "de", "van", "von").
    private static let knownLowerPrefixes: Set<String> = [
        "de", "van", "von", "del", "le", "la", "al", "bin", "ibn",
    ]

    /// Returns true if a trimmed line can start a new bibliography entry.
    static func isNewEntryStart(_ line: String) -> Bool {
        guard let firstChar = line.first else { return false }
        if firstChar == "," || firstChar == "–" || firstChar == "-" { return false }
        if firstChar.isUppercase { return true }
        if firstChar.isLowercase {
            let words = line.split(separator: " ", maxSplits: 2)
            guard words.count >= 2 else { return false }
            let firstWord = String(words[0]).lowercased()
            if knownLowerPrefixes.contains(firstWord) {
                return String(words[1]).first?.isUppercase == true
            }
        }
        return false
    }

    /// Extracts the first author's surname from a bibliography entry line.
    /// Requires a comma (AEA format: "Surname, FirstName, ...") and validates the
    /// after-comma content to avoid matching body-text sentences.
    static func extractSurname(from line: String) -> String? {
        guard let commaRange = line.range(of: ",") else { return nil }

        let beforeComma = String(line[..<commaRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !beforeComma.isEmpty else { return nil }

        let tokens = beforeComma.split(separator: " ").map(String.init)
        guard !tokens.isEmpty, tokens.count <= 4 else { return nil }

        // No digits in surname
        if tokens.contains(where: { $0.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) }) {
            return nil
        }

        // First token must not be a common non-surname word
        if notSurnames.contains(tokens[0].lowercased()) { return nil }

        // Reject "First Last" co-author continuation pattern:
        // 2 tokens, both starting uppercase, no known lowercase prefix → likely a wrapped co-author.
        if tokens.count == 2 {
            let allUpperStart = tokens.allSatisfy { $0.first?.isUppercase == true }
            let hasKnownPrefix = knownLowerPrefixes.contains(tokens[0].lowercased())
            if allUpperStart && !hasKnownPrefix { return nil }
        }

        // After-comma: must start with uppercase or opening quote (filters body-text lines).
        let afterCommaStr = String(line[line.index(after: commaRange.lowerBound)...]).trimmingCharacters(in: .whitespaces)
        if let firstAfterComma = afterCommaStr.first {
            let isUpper = firstAfterComma.isUppercase
            let isQuote = "\"\u{201C}'\u{2018}\u{2019}".contains(firstAfterComma)
            guard isUpper || isQuote else { return nil }
        } else {
            return nil
        }

        // Reject "FirstName LastName, NextFirst NextLast, ..." co-author continuation lines
        // (lines that are mid-list in a long co-author sequence, with no title on the same line).
        // Real entry lines with multi-part given names (e.g. "Kahou, Mahdi Ebrahimi, ...") typically
        // include the quoted title on the same line.
        let hasTitle = line.contains("\"") || line.contains("\u{201C}") ||
                       line.contains("'") || line.contains("\u{2018}")
        if !hasTitle, let nextCommaIdx = afterCommaStr.firstIndex(of: ",") {
            let firstChunk = String(afterCommaStr[..<nextCommaIdx]).trimmingCharacters(in: .whitespaces)
            let chunkToks = firstChunk.split(separator: " ").map(String.init)
            if chunkToks.count >= 2 {
                let isFullName: (String) -> Bool = { t in
                    t.count > 2 && !t.contains(".") && (t.first?.isLetter ?? false) && t.lowercased() != "and"
                }
                let t0 = chunkToks[0], t1 = chunkToks[1]
                if isFullName(t0) && (t0.first?.isUppercase ?? false) &&
                   isFullName(t1) && (t1.first?.isUppercase ?? false) {
                    return nil
                }
            }
        }

        return beforeComma
    }

    /// Extracts a 4-digit year (19xx / 20xx) from accumulated bibliography entry text.
    /// Tries multiple patterns in order of specificity to handle AEA format, author-year
    /// format, working papers, and journal articles.
    static func extractYear(from text: String) -> String? {
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        // 1. Year in parens: (YYYY) — author-year format
        if let regex = try? NSRegularExpression(pattern: #"\(((19|20)\d{2})\)"#),
           let match = regex.firstMatch(in: text, range: fullRange),
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range])
        }
        // 2. " YYYY." — space before year, period after (working papers, end-of-entry)
        if let regex = try? NSRegularExpression(pattern: #"\s((19|20)\d{2})\."#),
           let match = regex.firstMatch(in: text, range: fullRange),
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range])
        }
        // 3. ". YYYY." — period before and after (AEA format mid-entry)
        if let regex = try? NSRegularExpression(pattern: #"\.\s*((19|20)\d{2})\."#),
           let match = regex.firstMatch(in: text, range: fullRange),
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range])
        }
        // 4. ", YYYY, N" — journal article: year followed by comma + volume number
        if let regex = try? NSRegularExpression(pattern: #",\s*((19|20)\d{2}),\s*\d"#),
           let match = regex.firstMatch(in: text, range: fullRange),
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range])
        }
        // 5. Any 4-digit year — last resort
        if let regex = try? NSRegularExpression(pattern: #"\b((?:19|20)\d{2})\b"#),
           let match = regex.firstMatch(in: text, range: fullRange),
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range])
        }
        return nil
    }

    // MARK: - Find Reference List Pages

    /// Keywords to match in TOC or page text for the reference section.
    private static let referenceSectionKeywords = ["reference", "bibliography", "works cited", "literature cited", "citations", "sources"]

    /// Finds reference list pages. Prefers TOC/outline when available (more reliable);
    /// falls back to scanning page text for headings.
    /// - Parameter outlineCache: Optional [(page, label)] from document outline. When present,
    ///   searches for an entry whose label contains "References", "Bibliography", etc.
    /// - Returns: Set of page indices containing the reference list (from section start to doc end).
    static func findReferenceListPages(
        document: PDFDocument,
        outlineCache: [(page: Int, label: String)] = []
    ) -> Set<Int> {
        let pageCount = document.pageCount
        guard pageCount > 0 else { return [] }

        // 1) Prefer TOC: if outline has "References", "Bibliography", etc., use that page.
        if !outlineCache.isEmpty {
            for entry in outlineCache.sorted(by: { $0.page < $1.page }) {
                let label = entry.label.trimmingCharacters(in: .whitespaces).lowercased()
                guard !label.isEmpty else { continue }
                for kw in referenceSectionKeywords {
                    if label.contains(kw) {
                        return Set(entry.page..<pageCount)
                    }
                }
            }
        }

        // 2) Scan page text for a "References" / "Bibliography" heading. More reliable than hyperlinks
        //    for author-year style papers (which don't embed numeric hyperlinks). Advances past the
        //    heading page if the heading appears at the bottom of a body-text page.
        if let headingPage = findReferenceStartPageByHeading(document: document) {
            let bibStart = findFirstBibliographyPage(document: document, from: headingPage)
            var endPage = pageCount
            for pIdx in bibStart..<pageCount {
                guard let pg = document.page(at: pIdx) else { continue }
                let text = pg.string ?? ""
                if pIdx > bibStart && isLikelyAppendixPage(text) {
                    endPage = pIdx
                    break
                }
            }
            return Set(bibStart..<endPage)
        }

        // 3) If the PDF has hyperlinks on inline citations (e.g. [1] links to ref list), use them.
        if let byLinks = findReferenceListPagesByHyperlinks(document: document), !byLinks.isEmpty {
            return byLinks
        }

        // 4) Fallback: pattern-based search. Reference list has many lines like "Author. YYYY. Title"
        //    or "Author, Name (YYYY)". Appendix after refs has few. Scan backwards to find the block.
        return findReferenceListPagesByPattern(document: document)
    }

    /// Scans the last 50% of the document for a "References" / "Bibliography" heading on its own line.
    private static func findReferenceStartPageByHeading(document: PDFDocument) -> Int? {
        let pageCount = document.pageCount
        let searchStart = max(0, pageCount - Int(Double(pageCount) * 0.5))
        for pageIdx in searchStart..<pageCount {
            guard let page = document.page(at: pageIdx) else { continue }
            let text = page.string ?? ""
            if referenceHeadingRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                return pageIdx
            }
        }
        return nil
    }

    /// Advances past the heading page when the "References" heading appears at the bottom of a
    /// body-text page (the bibliography itself starts on the following page).
    private static func findFirstBibliographyPage(document: PDFDocument, from startPage: Int) -> Int {
        let pageCount = document.pageCount
        for pIdx in startPage..<min(startPage + 3, pageCount) {
            guard let page = document.page(at: pIdx) else { continue }
            let lines = (page.string ?? "").components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                if isNewEntryStart(trimmed), extractSurname(from: trimmed) != nil { return pIdx }
                break  // Only check first non-empty line per page
            }
        }
        return startPage
    }

    /// Returns true if a page looks like an appendix (not a bibliography page).
    /// Appendix pages typically open with a label like "A " or text containing "appendix".
    private static func isLikelyAppendixPage(_ pageText: String) -> Bool {
        let lines = pageText.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let lower = trimmed.lowercased()
            if lower.prefix(80).contains("appendix") { return true }
            // Single uppercase letter followed by space: common appendix section label ("A Model...")
            if trimmed.count >= 2, let first = trimmed.first, first.isUppercase,
               trimmed.dropFirst().first == " " { return true }
            break
        }
        return false
    }

    /// Finds reference list pages by collecting internal link destinations. Many PDFs have
    /// clickable citations (e.g. [1]) that link to the bibliography; the pages that receive
    /// the most such links are the reference section.
    private static func findReferenceListPagesByHyperlinks(document: PDFDocument) -> Set<Int>? {
        let pageCount = document.pageCount
        guard pageCount > 0 else { return nil }
        var incomingLinkCount: [Int: Int] = [:]
        for pageIdx in 0..<pageCount {
            guard let page = document.page(at: pageIdx) else { continue }
            for annotation in page.annotations {
                // Link annotations that point to another page in this document.
                guard (annotation.type ?? "").lowercased() == "link" else { continue }
                if let dest = annotation.destination, let targetPage = dest.page {
                    let targetIdx = document.index(for: targetPage)
                    if targetIdx >= 0, targetIdx < pageCount {
                        incomingLinkCount[targetIdx, default: 0] += 1
                    }
                }
            }
        }
        guard !incomingLinkCount.isEmpty else { return nil }
        // Find the contiguous block [start, end] that maximizes total incoming links.
        var bestStart = 0
        var bestEnd = -1
        var bestTotal = 0
        var runStart = 0
        var runTotal = 0
        for pageIdx in 0..<pageCount {
            let c = incomingLinkCount[pageIdx] ?? 0
            runTotal += c
            if runTotal > bestTotal {
                bestTotal = runTotal
                bestStart = runStart
                bestEnd = pageIdx
            }
            if c == 0 {
                runStart = pageIdx + 1
                runTotal = 0
            }
        }
        guard bestEnd >= bestStart, bestTotal >= 2 else { return nil }
        return Set(bestStart...bestEnd)
    }

    /// Minimum number of reference-like lines on a page to consider it part of the reference section.
    private static let referenceLineCountThreshold = 2

    /// Finds reference list by scanning backwards: skip appendix (low density), then take
    /// the contiguous block of pages with high density of reference-style lines.
    private static func findReferenceListPagesByPattern(document: PDFDocument) -> Set<Int> {
        let pageCount = document.pageCount
        guard pageCount > 0 else { return [] }

        // Scan backwards from last page. Appendix is at the end (low density); reference list is before it.
        var refStart = pageCount
        var refEnd = -1

        for pageIdx in (0..<pageCount).reversed() {
            guard let page = document.page(at: pageIdx) else { continue }
            let count = countReferenceLikeLines(on: page)

            if count >= referenceLineCountThreshold {
                refEnd = max(refEnd, pageIdx)
                refStart = min(refStart, pageIdx)
            } else if refEnd >= 0 {
                // We had reference pages and now hit low density: we've left the reference section.
                break
            }
        }

        if refEnd >= 0, refStart <= refEnd {
            return Set(refStart...refEnd)
        }

        // Fallback: find the contiguous block (anywhere in doc) with highest total reference-line count.
        // Handles PDFs where refs are not at the end (e.g. refs then long appendix).
        var bestStart = 0
        var bestEnd = -1
        var bestTotal = 0
        var runStart = 0
        var runTotal = 0
        for pageIdx in 0..<pageCount {
            guard let page = document.page(at: pageIdx) else { continue }
            let c = countReferenceLikeLines(on: page)
            if c >= referenceLineCountThreshold {
                runTotal += c
                if runTotal > bestTotal {
                    bestTotal = runTotal
                    bestStart = runStart
                    bestEnd = pageIdx
                }
            } else {
                runStart = pageIdx + 1
                runTotal = 0
            }
        }
        if bestEnd >= bestStart, bestTotal > 0 {
            return Set(bestStart...bestEnd)
        }

        // Ultimate fallback: last 10% of pages
        let fallbackStart = max(0, pageCount - max(3, pageCount / 10))
        return Set(fallbackStart..<pageCount)
    }

    /// Counts lines on the page that look like bibliography entries (author-year or journal citation style).
    private static func countReferenceLikeLines(on page: PDFPage) -> Int {
        let pageString = page.string ?? ""
        let lines = pageString.components(separatedBy: .newlines)
        var count = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count > 10 else { continue }
            // Strip optional leading "1. " / "1) "
            var lineForMatch = trimmed
            if let numPrefix = trimmed.range(of: #"^\s*\d+[.)]\s*"#, options: .regularExpression) {
                lineForMatch = String(trimmed[numPrefix.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            if firstAuthorYearReference(in: lineForMatch) != nil { count += 1; continue }
            if authorYearReferenceWithPeriod(in: lineForMatch) != nil { count += 1; continue }
            // Heuristic: ", 1995," or ", 2019." or ". 2019." (common in refs)
            if lineForMatch.range(of: #",\s*(19|20)\d{2}\s*[.,)]"#, options: .regularExpression) != nil { count += 1; continue }
            if lineForMatch.range(of: #"\.\s*(19|20)\d{2}\s*\."#, options: .regularExpression) != nil { count += 1 }
        }
        return count
    }

    /// Trims reference text to a clean length, ending at a sentence boundary to avoid
    /// trailing junk (e.g. from merged lines or next reference). Keeps "Author. Year. Title." clean.
    private static func trimReferenceTextToCleanSentenceBoundary(_ raw: String, maxLength: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > maxLength else { return trimmed }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: maxLength, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
        let segment = String(trimmed[..<endIndex])
        // Prefer cut at last sentence end (period, question mark, exclamation) so we don't leave trailing words.
        if let lastPeriod = segment.lastIndex(where: { $0 == "." || $0 == "?" || $0 == "!" }) {
            return String(segment[..<segment.index(after: lastPeriod)]).trimmingCharacters(in: .whitespaces)
        }
        // Otherwise cut at last space to avoid mid-word.
        if let lastSpace = segment.lastIndex(where: { $0 == " " }) {
            return String(segment[..<lastSpace]).trimmingCharacters(in: .whitespaces)
        }
        return segment.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Index References

    /// Index bibliography references from the given pages only.
    /// Call findReferenceListPages first to get reference list pages.
    static func indexReferences(
        document: PDFDocument,
        fromPages pageIndices: Set<Int>
    ) -> [String: IndexedReference] {
        var result: [String: IndexedReference] = [:]
        for pageIdx in pageIndices.sorted() {
            guard let page = document.page(at: pageIdx) else { continue }
            indexReferences(on: page, pageIdx: pageIdx, into: &result)
        }
        return result
    }

    /// Index references from a single page (used by indexReferences variants).
    /// Uses an accumulation approach: detects entry starts via isNewEntryStart/extractSurname,
    /// accumulates continuation lines, then extracts year from the full accumulated text.
    /// This handles AEA format (year not in parens), multi-line entries, and long co-author lists.
    private static func indexReferences(
        on page: PDFPage,
        pageIdx: Int,
        into result: inout [String: IndexedReference]
    ) {
        let pageString = page.string ?? ""
        let pageBounds = page.bounds(for: .mediaBox)
        let lines = pageString.components(separatedBy: .newlines)
        var currentY: Double = pageBounds.maxY
        let lineHeight = pageBounds.height / max(1, Double(lines.count))

        var currentEntry: (surname: String, yOffset: Double, lines: [String])?

        func flushCurrentEntry() {
            guard let cur = currentEntry else { return }
            currentEntry = nil
            let raw = cur.lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return }
            guard let year = extractYear(from: raw) else { return }
            let key = "\(cur.surname) \(year)"
            guard result[key] == nil else { return }
            let fullText = trimReferenceTextToCleanSentenceBoundary(raw, maxLength: 520)
            let clampedY = min(max(cur.yOffset, 0), Double(pageBounds.height))
            result[key] = IndexedReference(key: key, pageIndex: pageIdx, yOffset: clampedY, fullText: fullText)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { currentY -= lineHeight; continue }

            // 1) Numeric-style: [1], [1, 2], ...
            let checkStart = String(trimmed.prefix(120))
            if let match = referenceLineRegex.firstMatch(in: checkStart, range: NSRange(checkStart.startIndex..., in: checkStart)) {
                flushCurrentEntry()
                var numbers: [Int] = []
                if let numRange = Range(match.range(at: 1), in: checkStart) {
                    numbers = String(checkStart[numRange])
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .compactMap { Int($0) }
                }
                let citationText: String
                if let bracketEnd = trimmed.firstIndex(of: "]") {
                    citationText = String(trimmed[trimmed.index(after: bracketEnd)...]).trimmingCharacters(in: .whitespaces)
                } else { citationText = "" }
                let yOffset = Double(pageBounds.maxY - currentY)
                let clampedY = min(max(yOffset, 0), Double(pageBounds.height))
                for num in numbers {
                    let key = String(num)
                    if result[key] == nil {
                        result[key] = IndexedReference(key: key, pageIndex: pageIdx, yOffset: clampedY,
                                                       fullText: citationText.isEmpty ? "[\(num)]" : citationText)
                    }
                }
                currentY -= lineHeight
                continue
            }

            // Strip optional "1. " / "1) " prefix
            var lineForAuthor = trimmed
            if let numPrefix = trimmed.range(of: #"^\s*\d+[.)]\s*"#, options: .regularExpression) {
                lineForAuthor = String(trimmed[numPrefix.upperBound...]).trimmingCharacters(in: .whitespaces)
            }

            // 2) New author-year entry: starts with uppercase (or known lower prefix), has a comma
            if isNewEntryStart(lineForAuthor), let surname = extractSurname(from: lineForAuthor) {
                flushCurrentEntry()
                let yOffset = Double(pageBounds.maxY - currentY)
                currentEntry = (surname, yOffset, [trimmed])
            }
            // 3) Continuation of current entry
            else if currentEntry != nil {
                currentEntry!.lines.append(trimmed)
            }

            currentY -= lineHeight
        }
        flushCurrentEntry()
    }

    /// Index all bibliography references in the document (legacy: scans all pages).
    /// Prefer indexReferences(document:fromPages:) with findReferenceListPages.
    /// Supports both numeric references like:
    ///   [1] Sargent, T. (1991) ...
    /// and author–year references like:
    ///   Sargent, T. (1991) ...
    ///
    /// Keys:
    ///   - "1", "2", ...               for numeric-style references
    ///   - "Sargent 1991"              for author-year references
    /// Runs on caller's thread; call from a background queue for large PDFs.
    static func indexReferences(document: PDFDocument) -> [String: IndexedReference] {
        var result: [String: IndexedReference] = [:]
        let pageCount = document.pageCount

        for pageIdx in 0..<pageCount {
            guard let page = document.page(at: pageIdx) else { continue }
            let pageString = page.string ?? ""
            let pageBounds = page.bounds(for: .mediaBox)

            let lines = pageString.components(separatedBy: .newlines)
            var currentY: Double = pageBounds.maxY
            let lineHeight = pageBounds.height / max(1, Double(lines.count))

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else {
                    currentY -= lineHeight
                    continue
                }

                // Allow up to 3 chars before [ (sioyek heuristic)
                let checkStart = trimmed.prefix(120)
                let checkStartString = String(checkStart)

                // 1) Numeric-style references: [1], [1, 2], ...
                if let match = referenceLineRegex.firstMatch(
                    in: checkStartString,
                    range: NSRange(checkStartString.startIndex..., in: checkStartString)
                ) {

                    var numbers: [Int] = []
                    if let numRange = Range(match.range(at: 1), in: checkStartString) {
                        let inside = String(checkStartString[numRange])
                        numbers = inside
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .compactMap { Int($0) }
                    }

                    // Full citation text is everything after the closing ]
                    let citationText: String
                    if let bracketEnd = trimmed.firstIndex(of: "]") {
                        let after = trimmed.index(after: bracketEnd)
                        citationText = String(trimmed[after...]).trimmingCharacters(in: .whitespaces)
                    } else {
                        citationText = ""
                    }

                    let yOffset = Double(pageBounds.maxY - currentY)
                    let clampedY = min(max(yOffset, 0), Double(pageBounds.height))

                    for num in numbers {
                        let key = String(num)
                        // Do not overwrite an existing entry with same key.
                        if result[key] == nil {
                            result[key] = IndexedReference(
                                key: key,
                                pageIndex: pageIdx,
                                yOffset: clampedY,
                                fullText: citationText.isEmpty ? "[\(num)]" : citationText
                            )
                        }
                    }
                }

                // 2) Author–year references, e.g. "Sargent, T. (1991) ..." or "1. Sargent, T. (1991) ..."
                var lineForAuthorYear = trimmed
                if let numPrefix = trimmed.range(of: #"^\s*\d+[.)]\s*"#, options: .regularExpression) {
                    lineForAuthorYear = String(trimmed[numPrefix.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
                if let (authorKey, authorText) = firstAuthorYearReference(in: lineForAuthorYear) {
                    let yOffset = Double(pageBounds.maxY - currentY)
                    let clampedY = min(max(yOffset, 0), Double(pageBounds.height))
                    if result[authorKey] == nil {
                        let fullText = lineForAuthorYear == trimmed ? authorText : trimmed
                        result[authorKey] = IndexedReference(
                            key: authorKey,
                            pageIndex: pageIdx,
                            yOffset: clampedY,
                            fullText: fullText
                        )
                    }
                } else if let (authorKey, authorText) = authorYearReferenceWithPeriod(in: lineForAuthorYear) {
                    let yOffset = Double(pageBounds.maxY - currentY)
                    let clampedY = min(max(yOffset, 0), Double(pageBounds.height))
                    if result[authorKey] == nil {
                        let fullText = lineForAuthorYear == trimmed ? authorText : trimmed
                        result[authorKey] = IndexedReference(
                            key: authorKey,
                            pageIndex: pageIdx,
                            yOffset: clampedY,
                            fullText: fullText
                        )
                    }
                }
                currentY -= lineHeight
            }
        }
        return result
    }

    // MARK: - Build Citation Regions (pre-computed clickable areas)

    /// Pre-computes hover regions for each citation in the document.
    /// Uses the catalog from indexReferences to search for inline citations
    /// and get their bounding rects via PDFSelection. More reliable than
    /// characterIndex(at:) at interaction time.
    /// - Parameter excludePages: pages to skip (e.g. reference list). Search only in the paper body.
    /// Returns: pageIndex -> [(rect in page coords, key)]
    static func buildCitationRegions(
        document: PDFDocument,
        catalog: [String: IndexedReference],
        excludePages: Set<Int> = []
    ) -> [Int: [(rect: CGRect, key: String)]] {
        var result: [Int: [(rect: CGRect, key: String)]] = [:]
        let pageCount = document.pageCount

        for pageIdx in 0..<pageCount {
            guard !excludePages.contains(pageIdx) else { continue }
            guard let page = document.page(at: pageIdx) else { continue }
            let pageString = page.string ?? ""
            let length = (pageString as NSString).length
            guard length > 0 else { continue }

            var pageRegions: [(rect: CGRect, key: String)] = []
            let fullRange = NSRange(location: 0, length: length)

            // 1) Numeric citations: scan the full page for all [n], [n,n,n] bracket groups at once.
            //    Searching for literal "[1]" would miss "[1,2,3]" — using inlineCitationRegex
            //    captures all forms and lets us add a region per number within each bracket.
            let bracketMatches = inlineCitationRegex.matches(in: pageString, options: [], range: fullRange)
            for match in bracketMatches {
                guard let sel = page.selection(for: match.range),
                      let pageForSel = sel.pages.first,
                      document.index(for: pageForSel) == pageIdx else { continue }
                let rect = sel.bounds(for: pageForSel)
                guard let numRange = Range(match.range(at: 1), in: pageString) else { continue }
                let inside = String(pageString[numRange])
                let numbers = inside.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .compactMap { Int($0) }
                for num in numbers {
                    let key = String(num)
                    guard catalog[key] != nil else { continue }
                    pageRegions.append((rect, key))
                }
            }

            // 2) Author-year keys: "Sargent 1991" or "Del Negro 2015" -> search for author near year.
            for (key, _) in catalog {
                guard Int(key) == nil else { continue }  // numeric keys handled above
                let parts = key.split(separator: " ")
                guard parts.count >= 2, let year = parts.last else { continue }
                let author = parts.dropLast().joined(separator: " ")
                let escapedAuthor = NSRegularExpression.escapedPattern(for: author)
                // Match author + up to 25 chars (et al., and, etc.) + year. Avoids spanning sentences.
                let pattern = "\(escapedAuthor).{0,25}\(year)"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
                let matches = regex.matches(in: pageString, options: [], range: fullRange)
                for match in matches {
                    if let sel = page.selection(for: match.range),
                       let pageForSel = sel.pages.first,
                       document.index(for: pageForSel) == pageIdx {
                        let rect = sel.bounds(for: pageForSel)
                        pageRegions.append((rect, key))
                    }
                }
            }

            if !pageRegions.isEmpty {
                result[pageIdx] = pageRegions
            }
        }
        return result
    }

    /// Hit-test: find which citation (if any) contains the given point in page coordinates.
    static func citationAt(
        pageIndex: Int,
        pointInPage: NSPoint,
        regions: [Int: [(rect: CGRect, key: String)]],
        catalog: [String: IndexedReference]
    ) -> CitationAtPoint? {
        guard let pageRegions = regions[pageIndex] else { return nil }
        let cgPoint = CGPoint(x: pointInPage.x, y: pointInPage.y)
        for (rect, key) in pageRegions {
            if rect.contains(cgPoint), let ref = catalog[key] {
                return CitationAtPoint(key: key, fullText: ref.fullText)
            }
        }
        return nil
    }

    // MARK: - Citation at Point (legacy: uses characterIndex, less reliable)

    /// Detect if the given point (in page coordinates) is on an inline citation.
    /// Returns the citation number and full reference text if found.
    static func citationAt(
        document: PDFDocument,
        page: PDFPage,
        pointInPage: NSPoint,
        referenceIndex: [String: IndexedReference]
    ) -> CitationAtPoint? {
        let pageString = page.string ?? ""
        guard !pageString.isEmpty else { return nil }

        let charIndex = page.characterIndex(at: pointInPage)
        guard charIndex != NSNotFound, charIndex >= 0, charIndex < pageString.utf16.count else { return nil }

        let nsString = pageString as NSString

        // First, try numeric-style [1], [1,2,3] citations.
        if let numeric = citationAtNumeric(
            nsString: nsString,
            charIndex: charIndex,
            referenceIndex: referenceIndex
        ) {
            return numeric
        }

        // If that fails, try author–year style citations inside parentheses,
        // e.g. "(Sargent, 1991; Branch, 2006)" or "Del Negro ... (2015)".
        if let authorYear = citationAtAuthorYear(
            nsString: nsString,
            charIndex: charIndex,
            referenceIndex: referenceIndex
        ) {
            return authorYear
        }

        return nil
    }

    // MARK: - Numeric citation: [1], [1,2,3]

    private static func citationAtNumeric(
        nsString: NSString,
        charIndex: Int,
        referenceIndex: [String: IndexedReference]
    ) -> CitationAtPoint? {
        var searchStart = charIndex
        var searchEnd = charIndex

        // Expand backward to find the encompassing [ ... ]
        while searchStart > 0 {
            let c = nsString.character(at: searchStart - 1)
            if c == UInt16(Character("[").asciiValue!) {
                searchStart -= 1
                break
            }
            if c == UInt16(Character("]").asciiValue!) {
                return nil
            }
            searchStart -= 1
        }
        while searchEnd < nsString.length {
            let c = nsString.character(at: searchEnd)
            if c == UInt16(Character("]").asciiValue!) {
                searchEnd += 1
                break
            }
            if c == UInt16(Character("[").asciiValue!) && searchEnd > charIndex {
                return nil
            }
            searchEnd += 1
        }

        let range = NSRange(location: searchStart, length: searchEnd - searchStart)
        let snippet = nsString.substring(with: range)
        guard snippet.hasPrefix("["), snippet.hasSuffix("]") else { return nil }

        let inside = String(snippet.dropFirst().dropLast())
        let numbers = inside
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { Int($0) }

        guard !numbers.isEmpty else { return nil }

        // Determine which number the user clicked on (character offset within the bracket)
        let clickedOffset = charIndex - searchStart
        var accumulated = 0
        var selectedNum = numbers[0]
        for (i, num) in numbers.enumerated() {
            let numLen = String(num).count
            if clickedOffset >= accumulated && clickedOffset < accumulated + numLen {
                selectedNum = numbers[i]
                break
            }
            accumulated += numLen
            // Roughly account for comma/space between numbers.
            if i < numbers.count - 1 {
                accumulated += 1
            }
        }

        let key = String(selectedNum)
        guard let ref = referenceIndex[key] else { return nil }
        return CitationAtPoint(key: key, fullText: ref.fullText)
    }

    // MARK: - Author–year citation: (Sargent, 1991; Branch, 2006) etc.

    /// Extract the first author–year pair from a bibliography line and
    /// return (key, fullText). Key is "Surname 1991" or "Del Negro 2015".
    /// Supports: "Sargent, T. (1991)" and "Sargent (1991)".
    private static func firstAuthorYearReference(in line: String) -> (String, String)? {
        // First author is everything before the first comma or paren (handles "Del Negro", "Sargent").
        // Restrict years to 19xx / 20xx and apply heuristics to avoid picking up titles or fragments.
        // Group 1: author; group 2: full 4-digit year (group 3 is the century prefix, not used).
        let pattern = #"^\s*([^,\(]+?)\s*[,\(].*?\(((19|20)\d{2})\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        guard match.numberOfRanges >= 3 else { return nil }
        let authorRange = match.range(at: 1)
        let yearRange = match.range(at: 2)  // group 2 = full YYYY (not just "19"/"20")
        guard authorRange.location != NSNotFound,
              yearRange.location != NSNotFound else { return nil }

        let rawAuthor = ns.substring(with: authorRange)
        let author = rawAuthor.trimmingCharacters(in: .whitespaces)
        guard !author.isEmpty else { return nil }
        let tokens = author.split(whereSeparator: { $0 == " " })
        if tokens.isEmpty { return nil }
        if tokens.count > 4 { return nil }
        if tokens.contains(where: { $0.rangeOfCharacter(from: .decimalDigits) != nil }) { return nil }
        let firstTokenLower = String(tokens.first!).lowercased()
        if notSurnames.contains(firstTokenLower) { return nil }

        let year = ns.substring(with: yearRange)
        let key = "\(author) \(year)"
        let text = line.trimmingCharacters(in: .whitespaces)
        return (key, text)
    }

    /// Author–year format with period or space before year: "Author. 2019. Title" or "Author 2015. Title"
    /// (e.g. "Del Negro, Marco, ... Patterson. 2015. \"Title\"" or "Patterson 2015. ").
    /// Key is "Surname YYYY" (first author's last name).
    private static func authorYearReferenceWithPeriod(in line: String) -> (String, String)? {
        let ns = line as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        // Prefer ". YYYY. " then fall back to " YYYY. " (name without period before year, e.g. "Patterson 2015.").
        // Restrict years to 19xx / 20xx to avoid treating issue numbers like 7540 or 7676 as years.
        for (pattern, requireLetterBefore) in [(#"\.\s*((?:19|20)\d{2})\s*\."#, false), (#"\s+((?:19|20)\d{2})\s*\."#, true)] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: line, options: [], range: fullRange),
                  match.numberOfRanges >= 2,
                  match.range(at: 1).location != NSNotFound,
                  let yearRange = Range(match.range(at: 1), in: line),
                  let matchRange = Range(match.range(at: 0), in: line) else {
                continue
            }
            if requireLetterBefore, matchRange.lowerBound > line.startIndex {
                let idx = line.index(before: matchRange.lowerBound)
                if !line[idx].isLetter { continue }
            }
            let year = String(line[yearRange])
            let authorPart = String(line[..<matchRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard !authorPart.isEmpty else { continue }
            // First author's surname = text before the first comma (e.g. "Del Negro, Marco, ..." -> "Del Negro").
            let rawSurname = authorPart.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? authorPart
            let firstSurname = rawSurname.trimmingCharacters(in: .whitespaces)
            guard !firstSurname.isEmpty else { continue }
            let tokens = firstSurname.split(whereSeparator: { $0 == " " })
            if tokens.isEmpty { continue }
            if tokens.count > 4 { continue }
            if tokens.contains(where: { $0.rangeOfCharacter(from: .decimalDigits) != nil }) { continue }
            let firstTokenLower = String(tokens.first!).lowercased()
            if notSurnames.contains(firstTokenLower) { continue }

            let key = "\(firstSurname) \(year)"
            let text = line.trimmingCharacters(in: .whitespaces)
            return (key, text)
        }
        return nil
    }

    /// Detect an author–year citation around `charIndex`, e.g. inside
    /// "(Sargent, 1991; Branch, 2006)" or in "Del Negro ... (2015)".
    private static func citationAtAuthorYear(
        nsString: NSString,
        charIndex: Int,
        referenceIndex: [String: IndexedReference]
    ) -> CitationAtPoint? {
        let length = nsString.length
        if length == 0 { return nil }

        // Try to find surrounding parentheses if we are inside "( ... )".
        var start = charIndex
        var end = charIndex

        while start > 0 {
            let c = nsString.character(at: start - 1)
            if c == UInt16(Character("(").asciiValue!) || c == UInt16(10) { // '(' or newline
                break
            }
            start -= 1
        }
        while end < length {
            let c = nsString.character(at: end)
            if c == UInt16(Character(")").asciiValue!) || c == UInt16(10) { // ')' or newline
                end += 1
                break
            }
            end += 1
        }

        if end <= start { return nil }
        let range = NSRange(location: start, length: end - start)
        let snippet = nsString.substring(with: range)

        // Look for author–year pairs; author can be multi-word (e.g. "Del Negro", "von Mises").
        let pattern = #"([A-Z][A-Za-z\-]+(?:\s+[A-Z][A-Za-z\-]+)*)[^0-9]{0,25}(\d{4})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let snippetNS = snippet as NSString
        let fullRange = NSRange(location: 0, length: snippetNS.length)
        let matches = regex.matches(in: snippet, options: [], range: fullRange)
        if matches.isEmpty { return nil }

        // Map charIndex into snippet coordinates.
        let offsetInSnippet = charIndex - start

        // Find the match whose range contains the click position.
        var chosen: NSTextCheckingResult?
        for m in matches {
            if NSLocationInRange(offsetInSnippet, m.range) {
                chosen = m
                break
            }
        }
        if chosen == nil {
            // Fallback: use the first match.
            chosen = matches.first
        }
        guard let match = chosen, match.numberOfRanges >= 3 else { return nil }

        let authorRange = match.range(at: 1)
        let yearRange = match.range(at: 2)
        guard authorRange.location != NSNotFound,
              yearRange.location != NSNotFound else { return nil }

        let author = snippetNS.substring(with: authorRange)
        let year = snippetNS.substring(with: yearRange)
        let key = "\(author) \(year)"

        guard let ref = referenceIndex[key] else { return nil }
        return CitationAtPoint(key: key, fullText: ref.fullText)
    }
}
