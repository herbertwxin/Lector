import SwiftUI

// MARK: - SearchPanel

struct SearchPanel: View {
    @Bindable var state: AppState
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField("Search…", text: $state.searchText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { state.execute(.nextResult) }
                .onKeyPress(.escape) {
                    state.execute(.closeSearch)
                    return .handled
                }
                .onKeyPress(phases: .down) { keyPress in
                    if keyPress.key == .downArrow || keyPress.characters == "n" {
                        state.execute(.nextResult)
                        return .handled
                    }
                    if keyPress.key == .upArrow || keyPress.characters == "N" {
                        state.execute(.prevResult)
                        return .handled
                    }
                    return .ignored
                }

            // Result counter / "Not found" indicator
            if !state.searchText.isEmpty {
                Group {
                    if state.searchResultCount > 0 {
                        Text("\(state.searchCurrentResult) / \(state.searchResultCount)")
                    } else if state.searchIsComplete {
                        Text("Not found")
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(
                    state.searchIsComplete && state.searchResultCount == 0
                        ? AnyShapeStyle(Color.red.opacity(0.85))
                        : AnyShapeStyle(.secondary)
                )
                .fixedSize()
                .animation(.easeInOut(duration: 0.15), value: state.searchResultCount)
            }

            Button(action: { state.execute(.prevResult) }) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(state.searchResultCount == 0)

            Button(action: { state.execute(.nextResult) }) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(state.searchResultCount == 0)

            Button(action: { state.execute(.closeSearch) }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .onAppear { focused = true }
    }
}
