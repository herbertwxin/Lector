import SwiftUI

// MARK: - StatusBar

struct StatusBar: View {
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            // Mode indicator
            modeLabel

            Spacer()

            // Document name
            if let url = state.documentURL {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .foregroundColor(.secondary)
                    .font(.caption)
            }

            Spacer()

            // Counts
            countsView

            Divider().frame(height: 12)

            // Page indicator
            pageLabel
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    @ViewBuilder
    private var modeLabel: some View {
        switch state.mode {
        case .normal:
            if !state.numberPrefix.isEmpty {
                Text(state.numberPrefix)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.accentColor)
            } else if !state.statusMessage.isEmpty {
                Text(state.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        case .search:
            Label("SEARCH", systemImage: "magnifyingglass")
                .font(.caption.bold())
                .foregroundColor(.accentColor)
        case .command(let text):
            Text(":\(text)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
        case .awaitingMark, .awaitingHighlightType, .awaitingPortalDest:
            Text("Awaiting char…")
                .font(.caption)
                .foregroundColor(.orange)
        }
    }

    private var countsView: some View {
        HStack(spacing: 6) {
            if !state.bookmarks.isEmpty {
                Label("\(state.bookmarks.count)", systemImage: "bookmark.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            if !state.highlights.isEmpty {
                Label("\(state.highlights.count)", systemImage: "highlighter")
                    .font(.caption)
                    .foregroundColor(.yellow)
            }
            if !state.marks.isEmpty {
                Label("\(state.marks.count)", systemImage: "mappin")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
        }
    }

    private var pageLabel: some View {
        Group {
            if let doc = state.document {
                Text("\(state.currentPage + 1) / \(doc.pageCount)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }
}
