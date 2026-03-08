import SwiftUI

// MARK: - PreferencesView

struct PreferencesView: View {
    @Bindable var state: AppState
    @AppStorage("scrollStep") private var scrollStep: Double = 60
    @AppStorage("largeScrollStep") private var largeScrollStep: Double = 300

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Color Scheme", selection: $state.appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Scroll") {
                LabeledContent("Scroll Step (pt)") {
                    Slider(value: $scrollStep, in: 20...200, step: 10)
                    Text("\(Int(scrollStep))")
                        .frame(width: 36, alignment: .trailing)
                }
                LabeledContent("Large Scroll Step (pt)") {
                    Slider(value: $largeScrollStep, in: 100...800, step: 50)
                    Text("\(Int(largeScrollStep))")
                        .frame(width: 36, alignment: .trailing)
                }
            }

            Section("Navigation") {
                Toggle("Remember last view position", isOn: $state.rememberLastPosition)
            }

            Section("Citations") {
                Toggle("Inline citation detection", isOn: $state.citationDetectionEnabled)
                    .help("When enabled, left-click jumps to references, right-click searches Google Scholar, hover shows full citation. Uses more CPU when loading PDFs.")
                Toggle("Citation test log", isOn: $state.citationTestLogEnabled)
                    .help("When enabled, writes the detected reference catalog to Application Support/Lector/citation-test-log.txt when a document is indexed.")
            }

            Section("Database") {
                LabeledContent("Location") {
                    let appSupport = FileManager.default.urls(
                        for: .applicationSupportDirectory, in: .userDomainMask).first!
                    let path = appSupport.appendingPathComponent("Lector/lector.db").path
                    Text(path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Section("About") {
                LabeledContent("Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 360)
        .padding()
    }
}
