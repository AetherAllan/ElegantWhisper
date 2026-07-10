import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var completed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Set up \(AppConstants.productName)").font(.largeTitle.bold())
            Text("Grant these permissions one by one. Background Right Option hotkeys require Input Monitoring.")
                .foregroundStyle(.secondary)

            PermissionActionRow(title: "Microphone", detail: "Record your voice for dictation.", granted: model.permissionStatus.microphoneGranted, actionTitle: "Allow", action: model.requestMicrophonePermission)
            PermissionActionRow(title: "Speech Recognition", detail: "Transcribe with Apple Speech.", granted: model.permissionStatus.speechGranted, actionTitle: "Allow", action: model.requestSpeechPermission)
            PermissionActionRow(title: "Accessibility", detail: "Find the focused field and paste safely.", granted: model.permissionStatus.accessibilityGranted, actionTitle: "Open Settings", action: model.requestAccessibilityPermission)
            PermissionActionRow(title: "Input Monitoring", detail: "Listen for Right Option in the background.", granted: model.permissionStatus.inputMonitoringGranted, actionTitle: "Allow", action: model.requestInputMonitoringPermission)

            HStack {
                if let hint = model.permissionStatus.rebuildHint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Continue") { finishIfReady() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.permissionStatus.missingTitles.isEmpty)
            }
        }
        .padding(34)
        .task {
            while !Task.isCancelled, !completed {
                model.refreshAfterActivation()
                finishIfReady()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func finishIfReady() {
        guard !completed, model.permissionStatus.missingTitles.isEmpty else { return }
        completed = true
        model.completeOnboarding()
        openWindow(id: "main")
        dismissWindow(id: "onboarding")
    }
}
