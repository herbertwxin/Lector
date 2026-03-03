import SwiftUI
import PDFKit

// MARK: - ContentView

struct ContentView: View {
    @Bindable var state: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            TOCView(state: state)
        } detail: {
            ZStack(alignment: .bottom) {
                if state.document != nil {
                    PDFHostView(state: state)
                        .ignoresSafeArea()
                } else {
                    WelcomeView(state: state)
                }

                // Overlay panels
                VStack(spacing: 0) {
                    Spacer()

                    if state.isSearching {
                        SearchPanel(state: state)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if case .command = state.mode {
                        CommandPanel(state: state)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    StatusBar(state: state)
                }
                .animation(.easeInOut(duration: 0.15), value: state.isSearching)
            }
        }
        .onChange(of: state.showTOC) { _, newValue in
            withAnimation { columnVisibility = newValue ? .all : .detailOnly }
        }
        .sheet(isPresented: $state.showQuickSelect) {
            QuickSelectPanel(state: state)
                .frame(minWidth: 500, minHeight: 400)
        }
        .preferredColorScheme(state.appearanceMode.preferredColorScheme)
        .focusedValue(\.appState, state)
    }
}

// MARK: - WelcomeView

struct WelcomeView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 72))
                .foregroundColor(.secondary)

            Text("Lector")
                .font(.largeTitle.bold())

            Text("A keyboard-driven PDF viewer for academics")
                .font(.body)
                .foregroundColor(.secondary)

            Divider().frame(width: 240)

            VStack(alignment: .leading, spacing: 6) {
                KeyHintRow(key: "o",        desc: "Open document")
                KeyHintRow(key: "j / k",    desc: "Scroll down / up")
                KeyHintRow(key: "gg / G",   desc: "Go to beginning / end")
                KeyHintRow(key: "/ ",       desc: "Search")
                KeyHintRow(key: "t",        desc: "Table of contents")
                KeyHintRow(key: "b",        desc: "Add bookmark")
                KeyHintRow(key: "h + char", desc: "Highlight selection")
                KeyHintRow(key: "m + char", desc: "Set mark")
                KeyHintRow(key: "` + char", desc: "Jump to mark")
                KeyHintRow(key: ":",        desc: "Command mode")
            }

            Button("Open Document") { state.openDocumentDialog() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            if !state.recentDocuments.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent").font(.headline)
                    ForEach(state.recentDocuments.prefix(5)) { doc in
                        Button(action: { state.openDocument(at: doc.url) }) {
                            Label(doc.url.lastPathComponent, systemImage: "doc.fill")
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.primary)
                    }
                }
                .frame(maxWidth: 340, alignment: .leading)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - KeyHintRow

struct KeyHintRow: View {
    let key: String
    let desc: String

    var body: some View {
        HStack(spacing: 12) {
            Text(key)
                .font(.system(.body, design: .monospaced))
                .frame(width: 90, alignment: .trailing)
                .foregroundColor(.accentColor)
            Text(desc)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - AppState FocusedValue

struct AppStateFocusedValueKey: FocusedValueKey {
    typealias Value = AppState
}

extension FocusedValues {
    var appState: AppState? {
        get { self[AppStateFocusedValueKey.self] }
        set { self[AppStateFocusedValueKey.self] = newValue }
    }
}
