import SwiftUI

// MARK: - QuickSelectPanel

struct QuickSelectPanel: View {
    @Bindable var state: AppState
    @State private var filter: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var filterFocused: Bool

    private var filtered: [QuickSelectItem] {
        if filter.isEmpty {
            return state.quickSelectItems
        }
        let q = filter.lowercased()
        return state.quickSelectItems.filter {
            $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(state.quickSelectTitle)
                    .font(.headline)
                Spacer()
                Button("Close") { state.showQuickSelect = false }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()

            // Filter field
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Filter…", text: $filter)
                    .textFieldStyle(.plain)
                    .focused($filterFocused)
                    .onKeyPress(.downArrow) {
                        selectedIndex = min(selectedIndex + 1, max(filtered.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        selectedIndex = max(selectedIndex - 1, 0)
                        return .handled
                    }
                    .onSubmit { activate() }
                    .onChange(of: filter) { _, _ in selectedIndex = 0 }
            }
            .padding(10)
            .background(Color(.textBackgroundColor))

            Divider()

            // List
            ScrollViewReader { proxy in
                List(selection: .constant(selectedIndex)) {
                    ForEach(filtered.indices, id: \.self) { i in
                        QuickSelectRow(item: filtered[i], isSelected: i == selectedIndex)
                            .id(i)
                            .onTapGesture {
                                selectedIndex = i
                                activate()
                            }
                    }
                }
                .listStyle(.plain)
                .onChange(of: selectedIndex) { _, new in
                    withAnimation(.none) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
        .onAppear { filterFocused = true }
        .onKeyPress(.escape) {
            state.showQuickSelect = false
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "jkJK"), phases: .down) { keyPress in
            if keyPress.characters == "j" || keyPress.characters == "J" {
                selectedIndex = min(selectedIndex + 1, max(filtered.count - 1, 0))
                return .handled
            }
            if keyPress.characters == "k" || keyPress.characters == "K" {
                selectedIndex = max(selectedIndex - 1, 0)
                return .handled
            }
            return .ignored
        }
    }

    private func activate() {
        guard selectedIndex < filtered.count else { return }
        filtered[selectedIndex].activate()
        state.showQuickSelect = false
    }
}

// MARK: - QuickSelectRow

private struct QuickSelectRow: View {
    let item: QuickSelectItem
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("p.\(item.page + 1)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(4)
    }
}
