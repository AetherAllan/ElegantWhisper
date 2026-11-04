import SwiftUI

struct StylesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var styles = model.styles
        let activeStyle = Binding(
            get: { styles.activePack?.id ?? "" },
            set: { model.selectStyle(id: $0) }
        )

        Form {
            Section("Style Pack") {
                Picker("Active Style", selection: activeStyle) {
                    ForEach(styles.packs) { pack in
                        Text(pack.name).tag(pack.id)
                    }
                }
                Text(styles.activePack?.description ?? "")
                    .foregroundStyle(.secondary)
            }

            Section("System Prompt") {
                TextEditor(text: $styles.draft.prompt)
                    .font(.system(.body, design: .monospaced))
                    // The editor paints its own text-view background (white, or gray in dark),
                    // which the shell-wide setting does not reach; let the row color show.
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 180)
            }

            Section("Effective Prompt") {
                ScrollView {
                    Text(styles.effectivePrompt)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 130)
            }

            HStack {
                Button("Reset Built-in") { model.resetStyle() }
                Spacer()
                Button("Save Style") { model.saveStyle() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!styles.isDirty)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Styles")
    }
}
