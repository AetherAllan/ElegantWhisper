import AppKit
import SwiftUI

struct AboutView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 6) {
                Text(AppConstants.productName).font(.largeTitle.bold())
                Text(version).foregroundStyle(.secondary)
                Text("Native voice input for macOS.")
                    .font(.title3)
            }

            // A themed card rather than GroupBox, which paints its own gray box.
            VStack(alignment: .leading, spacing: 12) {
                Label("Tap Right Option to start and stop dictation.", systemImage: "option")
                Label("Transcription history and dictionary data stay on this Mac.", systemImage: "lock.shield")
                Label("Online recognition and Dictate are optional and off by default.", systemImage: "sparkles")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .cardBackground()
            .frame(maxWidth: 520)

            HStack {
                Link("GitHub", destination: URL(string: "https://github.com/AetherAllan/ElegantWhisper")!)
                Spacer()
                Button("Replay Tutorial") {
                    model.prepareTutorialReplay()
                    openWindow(id: "onboarding")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .navigationTitle("About")
    }
}
