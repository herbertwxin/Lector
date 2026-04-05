import SwiftUI

// MARK: - CommandPanel

struct CommandPanel: View {
    @Bindable var state: AppState
    @FocusState private var focused: Bool
    @State private var selectedIndex: Int = 0

    // MARK: - Command catalogue

    private static let catalogue: [(cmd: String, desc: String)] = [
        // Highlights
        ("highlight a",     "Add yellow highlight"),
        ("highlight b",     "Add green highlight"),
        ("highlight c",     "Add blue highlight"),
        ("highlight d",     "Add red highlight"),
        ("deletehighlight", "Remove highlight on current page  (dh)"),
        ("highlights",      "List all highlights  (gh)"),
        ("nexthighlight",   "Jump to next highlight  (gnh)"),
        ("prevhighlight",   "Jump to previous highlight  (gNh)"),
        // Bookmarks
        ("bookmark",        "Add bookmark  (b)"),
        ("deletebookmark",  "Remove bookmark on current page  (db)"),
        ("bookmarks",       "List bookmarks  (gb)"),
        ("allbookmarks",    "List bookmarks across all documents"),
        // Navigation
        ("page",            "Go to page number  (e.g. page 5)"),
        ("beginning",       "Go to first page  (gg)"),
        ("end",             "Go to last page  (G)"),
        ("back",            "Navigate back"),
        ("forward",         "Navigate forward"),
        ("nextpage",        "Next page"),
        ("prevpage",        "Previous page"),
        ("nextchapter",     "Jump to next chapter  (gc)"),
        ("prevchapter",     "Jump to previous chapter  (gC)"),
        // Zoom
        ("zoom",            "Set zoom level  (e.g. zoom 150)"),
        ("zoomin",          "Zoom in  (+)"),
        ("zoomout",         "Zoom out  (-)"),
        ("fit",             "Fit to width  (=)"),
        ("actualsize",      "Reset zoom to 100%  (0)"),
        // Search
        ("search",          "Search text  (e.g. search word)"),
        // Marks
        ("mark",            "Set mark  (e.g. mark a)"),
        ("goto",            "Go to mark  (e.g. goto a)"),
        ("marks",           "List marks  (gm)"),
        // Portals
        ("portal",          "Set portal source  (p)"),
        ("deleteportal",    "Delete portal  (dp)"),
        ("gotoportal",      "Go to nearest portal"),
        // Appearance
        ("dark",            "Dark mode"),
        ("light",           "Light mode"),
        ("auto",            "System appearance"),
        // Document structure
        ("figure",          "Browse figures"),
        ("equation",        "Browse equations"),
        ("table",           "Browse tables"),
        ("proposition",     "Browse propositions"),
        ("theorem",         "Browse theorems"),
        ("lemma",           "Browse lemmas"),
        // Web / misc
        ("scholar",         "Google Scholar search  (e.g. scholar query)"),
        ("google",          "Google search  (e.g. google query)"),
        ("toc",             "Toggle table of contents  (t)"),
        ("split",           "Open document in split window"),
        ("open",            "Open document  (o)"),
        ("recent",          "Open recent document"),
        ("copy",            "Copy current selection"),
        ("rotate",          "Rotate pages  (rotate ccw for counter-clockwise)"),
        ("print",           "Print document"),
        ("fullscreen",      "Toggle fullscreen"),
        ("citation",        "Open citations panel  (c)"),
        ("help",            "Show help"),
        ("quit",            "Quit"),
    ]

    // MARK: - Filtered suggestions

    private var suggestions: [(cmd: String, desc: String)] {
        let input = commandText.wrappedValue.lowercased().trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return [] }
        let word = input.components(separatedBy: " ").first ?? input
        return Array(Self.catalogue.filter { $0.cmd.lowercased().hasPrefix(word) }.prefix(6))
    }

    // MARK: - Binding

    private var commandText: Binding<String> {
        Binding(
            get: {
                if case .command(let t) = state.mode { return t }
                return ""
            },
            set: { state.mode = .command($0) }
        )
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !suggestions.isEmpty {
                suggestionsView
            }
            commandInputView
        }
        .onAppear { focused = true }
        .onChange(of: commandText.wrappedValue) { _, _ in
            selectedIndex = 0
        }
    }

    // MARK: - Suggestions list

    private var suggestionsView: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { i, item in
                HStack(spacing: 6) {
                    Text(item.cmd)
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.medium)
                        .foregroundColor(i == selectedIndex ? .primary : .primary.opacity(0.75))
                    Text(item.desc)
                        .font(.system(.caption))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(i == selectedIndex ? Color.accentColor.opacity(0.18) : Color.clear)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12)
    }

    // MARK: - Command input

    private var commandInputView: some View {
        HStack(spacing: 4) {
            Text(":")
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)

            TextField("", text: commandText)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .focused($focused)
                .onSubmit {
                    if case .command(let text) = state.mode {
                        state.executeCommandString(text)
                    }
                }
                .onKeyPress(.escape) {
                    state.mode = .normal
                    return .handled
                }
                .onKeyPress(.tab) {
                    completeSuggestion()
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    if !suggestions.isEmpty {
                        selectedIndex = max(0, selectedIndex - 1)
                    }
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    if !suggestions.isEmpty {
                        selectedIndex = min(suggestions.count - 1, selectedIndex + 1)
                    }
                    return .handled
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Tab completion

    private func completeSuggestion() {
        guard selectedIndex < suggestions.count else { return }
        commandText.wrappedValue = suggestions[selectedIndex].cmd + " "
    }
}
