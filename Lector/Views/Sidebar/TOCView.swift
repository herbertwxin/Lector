import SwiftUI
import PDFKit

// MARK: - TOCView

struct TOCView: View {
    @Bindable var state: AppState
    @State private var filter: String = ""
    @State private var outline: [TOCEntry] = []
    /// Index of the keyboard-highlighted row (-1 = none).
    @State private var selectedIndex: Int = 0
    @FocusState private var filterFocused: Bool

    private var filteredEntries: [TOCEntry] {
        filter.isEmpty ? outline : outline.filter {
            $0.title.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "list.bullet.indent")
                Text("Contents")
                    .font(.headline)
                Spacer()
                Button(action: { closeTOC() }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Filter field — also owns keyboard navigation for the list below.
            TextField("Filter…", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .focused($filterFocused)
                .onSubmit { commitSelection() }
                .onKeyPress(.escape) {
                    closeTOC()
                    return .handled
                }
                .onKeyPress(phases: [.down, .repeat]) { keyPress in
                    switch keyPress.key {
                    case .downArrow: moveSelection(by: +1); return .handled
                    case .upArrow:   moveSelection(by: -1); return .handled
                    default:         return .ignored
                    }
                }
                .onChange(of: filter) { _, _ in
                    // Clamp selection when the filtered list shrinks.
                    let count = filteredEntries.count
                    selectedIndex = count > 0 ? min(selectedIndex, count - 1) : 0
                }

            Divider()

            let entries = filteredEntries
            ScrollViewReader { proxy in
                List(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                    Button(action: { jumpTo(entry: entry) }) {
                        HStack(spacing: 0) {
                            // Indent
                            Rectangle()
                                .frame(width: CGFloat(entry.depth) * 12)
                                .opacity(0)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title)
                                    .lineLimit(2)
                                    .font(entry.depth == 0 ? .body.bold() : .body)
                                if let page = entry.pageLabel {
                                    Text(page)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        idx == selectedIndex
                            ? Color.accentColor.opacity(0.15)
                            : Color.clear
                    )
                    .id(idx)
                }
                .listStyle(.plain)
                // Keep the highlighted row visible as the user arrows through the list.
                .onChange(of: selectedIndex) { _, newIdx in
                    guard newIdx >= 0, newIdx < entries.count else { return }
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(newIdx, anchor: .center)
                    }
                }
            }
        }
        .frame(minWidth: 220)
        .onChange(of: state.documentURL) { _, _ in loadOutline() }
        .onAppear {
            loadOutline()
            // Auto-focus the filter field so the user can start typing or
            // arrow-key through entries immediately after pressing "t".
            filterFocused = true
        }
    }

    // MARK: - Helpers

    private func moveSelection(by delta: Int) {
        let count = filteredEntries.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    /// Keyboard Enter: jump to the highlighted entry and return focus to the PDF.
    private func commitSelection() {
        let entries = filteredEntries
        guard selectedIndex >= 0, selectedIndex < entries.count else { return }
        jumpTo(entry: entries[selectedIndex])
        closeTOC()
    }

    private func closeTOC() {
        state.showTOC = false
        // Return keyboard focus to the PDF view.
        NotificationCenter.default.post(name: .lectorFocusPDF, object: state)
    }

    private func loadOutline() {
        guard let doc = state.document else { outline = []; return }
        outline = []
        if let root = doc.outlineRoot {
            flatten(node: root, depth: 0)
        }
        selectedIndex = 0
    }

    private func flatten(node: PDFOutline, depth: Int) {
        for i in 0..<node.numberOfChildren {
            guard let child = node.child(at: i) else { continue }
            let pageLabel = child.destination?.page.map { page in
                guard let doc = state.document else { return "" }
                return "Page \(doc.index(for: page) + 1)"
            } ?? nil
            outline.append(TOCEntry(
                id: UUID(),
                title: child.label ?? "",
                depth: depth,
                pageLabel: pageLabel,
                destination: child.destination
            ))
            if child.numberOfChildren > 0 {
                flatten(node: child, depth: depth + 1)
            }
        }
    }

    private func jumpTo(entry: TOCEntry) {
        guard let dest = entry.destination,
              let page = dest.page,
              let doc = state.document
        else { return }
        state.pushNavState()
        state.currentPage = doc.index(for: page)
    }
}

// MARK: - TOCEntry

struct TOCEntry: Identifiable {
    let id: UUID
    let title: String
    let depth: Int
    let pageLabel: String?
    let destination: PDFDestination?
}
