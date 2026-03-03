import SwiftUI
import PDFKit

// MARK: - TOCView

struct TOCView: View {
    @Bindable var state: AppState
    @State private var filter: String = ""
    @State private var outline: [TOCEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "list.bullet.indent")
                Text("Contents")
                    .font(.headline)
                Spacer()
                Button(action: { state.showTOC = false }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            TextField("Filter…", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

            Divider()

            let entries = filter.isEmpty ? outline : outline.filter {
                $0.title.localizedCaseInsensitiveContains(filter)
            }

            List(entries) { entry in
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
            }
            .listStyle(.plain)
        }
        .frame(minWidth: 220)
        .onChange(of: state.documentURL) { _, _ in loadOutline() }
        .onAppear { loadOutline() }
    }

    private func loadOutline() {
        guard let doc = state.document else { outline = []; return }
        outline = []
        if let root = doc.outlineRoot {
            flatten(node: root, depth: 0)
        }
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
