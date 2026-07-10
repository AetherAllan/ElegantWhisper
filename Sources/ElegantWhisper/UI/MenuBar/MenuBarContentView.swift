import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: model.mode == .recording ? "waveform.circle.fill" : "waveform.circle")
                    .font(.title2)
                VStack(alignment: .leading) {
                    Text(AppConstants.productName).fontWeight(.semibold)
                    Text(model.mode.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()
            Button("Open \(AppConstants.productName)") { openMainWindow() }
            Button("Settings…") {
                model.openSettings()
                openMainWindow()
            }

            Picker("Language", selection: Binding(
                get: { model.currentLanguage },
                set: { model.setLanguage($0) }
            )) {
                ForEach(RecognitionLanguage.allCases, id: \.self) { language in
                    Text(language.menuTitle).tag(language)
                }
            }

            Menu("Microphone") {
                if model.microphones.isEmpty {
                    Text("No input devices")
                } else {
                    ForEach(model.microphones, id: \.uid) { device in
                        Button {
                            Task { await model.selectMicrophone(device.uid) }
                        } label: {
                            if device.uid == model.currentMicrophoneUID {
                                Label(device.name, systemImage: "checkmark")
                            } else {
                                Text(device.name)
                            }
                        }
                        .disabled(model.mode != .idle)
                    }
                }
            }

            Toggle("LLM Polishing", isOn: Binding(
                get: { model.llmEnabled },
                set: { model.setLLMEnabled($0) }
            ))

            if !model.microphoneError.isEmpty {
                Text(model.microphoneError).font(.caption).foregroundStyle(.red)
            }

            Divider()
            Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 290)
        .onAppear { model.refreshMicrophones() }
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}

struct StatusBarLabel: View {
    private let icon: NSImage

    init() {
        if let url = Bundle.main.url(forResource: "StatusBarIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            icon = image
        } else {
            icon = NSImage(systemSymbolName: "waveform", accessibilityDescription: AppConstants.productName) ?? NSImage()
        }
    }

    var body: some View {
        Image(nsImage: icon)
            .renderingMode(.template)
            .accessibilityLabel(AppConstants.productName)
    }
}
