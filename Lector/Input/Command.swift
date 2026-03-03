import Foundation

// MARK: - Web Engine

enum WebEngine {
    case scholar
    case google

    var urlTemplate: String {
        switch self {
        case .scholar: return "https://scholar.google.com/scholar?q=%@"
        case .google:  return "https://www.google.com/search?q=%@"
        }
    }
}

// MARK: - Command

enum Command: Equatable {
    // Navigation
    case gotoBeginning
    case gotoEnd
    case gotoPage(Int)
    case scrollDown(CGFloat)
    case scrollUp(CGFloat)
    case nextPage
    case prevPage
    case back
    case forward

    // Zoom
    case zoomIn
    case zoomOut
    case fitToWidth
    case actualSize

    // Search
    case beginSearch
    case nextResult
    case prevResult
    case closeSearch

    // Bookmarks
    case addBookmark
    case deleteBookmark
    case listBookmarks
    case listAllBookmarks

    // Highlights (type char required)
    case addHighlight(Character)
    case deleteHighlight
    case listHighlights
    case nextHighlight
    case prevHighlight

    // Marks
    case setMark(Character)
    case gotoMark(Character)
    case listMarks

    // Portals
    case setPortalSource
    case gotoPortal
    case editPortal
    case deletePortal

    // Web search
    case webSearch(engine: WebEngine)

    // UI
    case toggleTOC
    case commandMode
    case openDocument
    case toggleDarkMode
    case quit

    // MARK: - Needs-char flag

    /// True if the command requires a follow-up character from the user.
    var needsChar: Bool {
        switch self {
        case .setMark, .gotoMark, .addHighlight: return true
        default: return false
        }
    }
}
