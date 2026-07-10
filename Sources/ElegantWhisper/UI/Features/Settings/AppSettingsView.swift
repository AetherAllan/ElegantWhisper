import SwiftUI

struct AppSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AISettingsView()
                .tabItem { Label("AI Provider", systemImage: "sparkles") }
            PermissionsSettingsView()
                .tabItem { Label("Permissions", systemImage: "hand.raised") }
        }
        .frame(maxWidth: 700, maxHeight: 560)
        .padding()
        .navigationTitle("Settings")
        .onAppear { model.settings.beginEditing() }
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Picker("Recognition Language", selection: $settings.draft.language) {
                ForEach(RecognitionLanguage.allCases, id: \.self) { language in
                    Text(language.menuTitle).tag(language)
                }
            }
            Toggle("Keep text on clipboard when no editable field is available", isOn: $settings.draft.keepClipboardWithoutTarget)
            Toggle("Save transcription history", isOn: $settings.draft.saveHistory)
            Toggle("Mute system audio while recording", isOn: $settings.draft.muteOutputDuringRecording)
            Toggle("Suggest dictionary terms from supported edits", isOn: $settings.draft.postEditLearningEnabled)

            HStack {
                Spacer()
                Button("Save Settings") { model.saveGeneralSettings() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AISettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let provider = Binding(
            get: { settings.draft.provider },
            set: { settings.providerChanged(to: $0) }
        )

        Form {
            Toggle("Enable LLM Polishing", isOn: $settings.draft.llmEnabled)
            Picker("Provider", selection: provider) {
                ForEach(LLMProvider.allCases, id: \.self) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            TextField("API Base URL", text: $settings.draft.baseURL)
            SecureField("API Key", text: $settings.draft.apiKey)
            HStack {
                TextField("Model", text: $settings.draft.model)
                if !settings.draft.provider.modelPresets.isEmpty {
                    Menu("Presets") {
                        ForEach(settings.draft.provider.modelPresets, id: \.self) { preset in
                            Button(preset) { settings.draft.model = preset }
                        }
                    }
                }
            }
            TextField("Timeout Seconds", value: $settings.draft.timeout, format: .number)
            Text(settings.draft.provider.note).font(.callout).foregroundStyle(.secondary)

            if !settings.connectionStatus.isEmpty {
                Text(settings.connectionStatus)
                    .font(.callout)
                    .foregroundStyle(settings.connectionStatus.hasPrefix("Connection failed") ? Color.red : Color.secondary)
            }

            HStack {
                Button("Test Connection") { model.testConnection() }
                Spacer()
                Button("Save Polishing") { model.saveAISettings() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            PermissionActionRow(title: "Microphone", detail: model.permissionStatus.microphoneDetail, granted: model.permissionStatus.microphoneGranted, actionTitle: "Open", action: model.openMicrophoneSettings)
            PermissionActionRow(title: "Speech Recognition", detail: model.permissionStatus.speechDetail, granted: model.permissionStatus.speechGranted, actionTitle: "Open", action: model.openSpeechSettings)
            PermissionActionRow(title: "Accessibility", detail: model.permissionStatus.accessibilityDetail, granted: model.permissionStatus.accessibilityGranted, actionTitle: "Open", action: model.openAccessibilitySettings)
            PermissionActionRow(title: "Input Monitoring", detail: model.permissionStatus.inputMonitoringDiagnostics, granted: model.permissionStatus.inputMonitoringGranted, actionTitle: "Open", action: model.openInputMonitoringSettings)
        }
        .formStyle(.grouped)
        .onAppear { model.refreshAfterActivation() }
    }
}
