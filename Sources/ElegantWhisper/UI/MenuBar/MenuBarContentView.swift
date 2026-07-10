import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Text(model.mode.title)
                .disabled(true)

            Button("Open \(AppConstants.productName)") { openMainWindow() }
            Button("Settings…") { open(.settings) }
            Button("About \(AppConstants.productName)") { open(.about) }

            Divider()

            Menu("Language") {
                ForEach(RecognitionLanguage.allCases, id: \.self) { language in
                    Button {
                        model.setLanguage(language)
                    } label: {
                        if language == model.currentLanguage {
                            Label(language.menuTitle, systemImage: "checkmark")
                        } else {
                            Text(language.menuTitle)
                        }
                    }
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
                Text(model.microphoneError)
            }

            Divider()
            Button("Quit \(AppConstants.productName)") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        // A menu is rebuilt when it opens, so refreshing here keeps the device submenu current
        // without owning a second audio-device observer.
        .onAppear { model.refreshMicrophones() }
    }

    private func open(_ route: AppRoute) {
        model.route = route
        openMainWindow()
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
