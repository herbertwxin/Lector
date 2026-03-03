import SwiftUI

// MARK: - CommandPanel

struct CommandPanel: View {
    @Bindable var state: AppState
    @FocusState private var focused: Bool

    private var commandText: Binding<String> {
        Binding(
            get: {
                if case .command(let t) = state.mode { return t }
                return ""
            },
            set: { state.mode = .command($0) }
        )
    }

    var body: some View {
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .onAppear { focused = true }
    }
}
