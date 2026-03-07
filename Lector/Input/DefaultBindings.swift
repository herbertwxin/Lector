import Foundation

enum DefaultBindings {
    static let scrollStep: CGFloat = 60
    static let largeScrollStep: CGFloat = 300

    static let keybindings: [(keys: [String], command: Command)] = [
        // Navigation
        (["g", "g"],          .gotoBeginning),
        (["G"],               .gotoEnd),
        (["j"],               .scrollDown(scrollStep)),
        (["k"],               .scrollUp(scrollStep)),
        (["<space>"],         .nextPage),
        (["<S-space>"],       .prevPage),
        (["<C-d>"],           .scrollDown(largeScrollStep)),
        (["<C-u>"],           .scrollUp(largeScrollStep)),
        (["<down>"],          .scrollDown(scrollStep)),
        (["<up>"],            .scrollUp(scrollStep)),

        // Zoom
        (["+"],               .zoomIn),
        (["-"],               .zoomOut),
        (["="],               .fitToWidth),
        (["w"],               .smartZoom),
        (["0"],               .actualSize),

        // Search
        (["/"],               .beginSearch),
        (["n"],               .nextResult),
        (["N"],               .prevResult),
        (["<esc>"],           .closeSearch),

        // Bookmarks
        (["b"],               .addBookmark),
        (["d", "b"],          .deleteBookmark),
        (["g", "b"],          .listBookmarks),
        (["g", "B"],          .listAllBookmarks),

        // Highlights
        (["h"],               .addHighlight("a")),   // 'h' alone → awaiting char
        (["d", "h"],          .deleteHighlight),
        (["g", "h"],          .listHighlights),
        (["g", "n", "h"],     .nextHighlight),
        (["g", "N", "h"],     .prevHighlight),

        // Marks
        (["m"],               .setMark("a")),         // 'm' alone → awaiting char
        (["`"],               .gotoMark("a")),         // '`' alone → awaiting char
        (["g", "m"],          .listMarks),

        // Portals
        (["p"],               .setPortalSource),
        (["d", "p"],          .deletePortal),

        // History
        (["<backspace>"],     .back),
        (["<S-backspace>"],   .forward),

        // UI
        (["t"],               .toggleTOC),
        ([":"],               .commandMode),
        (["o"],               .openDocument),
        (["<f8>"],            .toggleDarkMode),
        (["q"],               .quit),

        // Web search
        (["<C-f>"],           .webSearch(engine: .scholar)),
        (["<A-f>"],           .webSearch(engine: .google)),
    ]
}
