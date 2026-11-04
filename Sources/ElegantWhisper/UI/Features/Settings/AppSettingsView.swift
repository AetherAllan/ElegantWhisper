import SwiftUI

struct AppSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 16) {
            Picker("Settings", selection: $model.settingsTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbolName).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)

            Group {
                switch model.settingsTab {
                case .general: GeneralSettingsView()
                case .ai: AISettingsView()
                case .permissions: PermissionsSettingsView()
                }
            }
            .frame(maxWidth: 680)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Settings")
        .onAppear { model.settings.beginEditing() }
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section("Dictation") {
                LabeledContent("Start or stop") { Keycap("Right ⌥") }
                LabeledContent("Cancel") { Keycap("esc") }
                Picker("Language", selection: settings.immediate(\.language) { $0.language = $1 }) {
                    ForEach(RecognitionLanguage.allCases, id: \.self) { language in
                        Text(language.menuTitle).tag(language)
                    }
                }
                Picker(selection: settings.immediate(\.speechModel) { $0.speechModel = $1 }) {
                    ForEach(SpeechRecognitionModel.allCases, id: \.self) { model in
                        Text(model.title).tag(model)
                    }
                } label: {
                    Text("Recognition model")
                    Text("Apple models run on this Mac; OpenAI runs online. Try each with your own voice.")
                }
                if settings.draft.speechModel.isOnline {
                    OpenAIKeyRows()
                }
                Toggle(isOn: settings.immediate(\.readWindowText) { $0.readWindowText = $1 }) {
                    Text("Use words from the front window")
                    Text(settings.draft.speechModel.isOnline
                        ? "Reads technical words such as Redis or useEffect from the window you're dictating into, to fix their spelling. Password fields are skipped. With OpenAI recognition, some of these words are sent as hints."
                        : "Reads technical words such as Redis or useEffect from the window you're dictating into, to fix their spelling. Password fields are skipped and nothing leaves this Mac.")
                }
            }

            Section("While Recording") {
                Toggle("Mute system audio", isOn: settings.immediate(\.muteOutputDuringRecording) { $0.muteOutputDuringRecording = $1 })
            }

            Section("Output") {
                Toggle(isOn: settings.immediate(\.keepClipboardWithoutTarget) { $0.keepClipboardWithoutTarget = $1 }) {
                    Text("Copy to clipboard when there is no text field")
                    Text("Otherwise the dictation is discarded and only kept in History.")
                }
            }

            Section("History & Learning") {
                Toggle("Save dictation history on this Mac", isOn: settings.immediate(\.saveHistory) { $0.saveHistory = $1 })
                Toggle(isOn: settings.immediate(\.postEditLearningEnabled) { $0.postEditLearningEnabled = $1 }) {
                    Text("Suggest dictionary terms from your corrections")
                    Text("Watches the field briefly after inserting and suggests a term when the same fix repeats.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct OpenAIKeyRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let failed = settings.openAIKeyStatus.hasPrefix("Check failed")

        SecureField("API key", text: $settings.draft.openAIKey, prompt: Text("OpenAI or OpenRouter key"))
        HStack {
            if !settings.openAIKeyStatus.isEmpty {
                Label(settings.openAIKeyStatus, systemImage: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(failed ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Check Key") { model.checkOpenAIKey() }
                .disabled(settings.draft.openAIKey.isEmpty)
            Button("Save Key") { model.saveOpenAIKey() }
                .buttonStyle(.borderedProminent)
                .disabled(!settings.isOpenAIKeyDirty)
        }
        Text(Self.caption(for: settings.draft.openAIKey))
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private static func caption(for key: String) -> String {
        let service = TranscriptionService(apiKey: key)
        let route = key.isEmpty
            ? "OpenAI keys call OpenAI directly; OpenRouter keys (sk-or-…) go through OpenRouter."
            : "This key uses \(service.displayName)."
        return "\(route) When you stop, the recording is uploaded (about $0.0045 per minute) with up to 50 hints from your Dictionary and the words on screen. Apple's on-device model still shows live text and is used if the request fails."
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
            Section {
                Toggle(isOn: settings.immediate(\.llmEnabled) { $0.llmEnabled = $1 }) {
                    Text("Polish dictation with an LLM")
                    Text("Optional. Fixes punctuation and obvious recognition mistakes. The transcript is sent to your provider.")
                }
                Toggle(isOn: settings.immediate(\.shareCursorTextWithLLM) { $0.shareCursorTextWithLLM = $1 }) {
                    Text("Send text around the cursor")
                    Text("Up to \(CursorTextContext.beforeLimit) characters before and \(CursorTextContext.afterLimit) after the cursor, to help with names and spelling. Password fields are skipped; links, emails, and secret-like strings are removed.")
                }
                .disabled(!settings.draft.llmEnabled)
            }

            Section("Provider") {
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
                        .fixedSize()
                    }
                }
                TextField("Timeout (seconds)", value: $settings.draft.timeout, format: .number)
                if let note = settings.draft.provider.note {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    if !settings.connectionStatus.isEmpty {
                        Label(
                            settings.connectionStatus,
                            systemImage: settings.connectionStatus.hasPrefix("Connection failed") ? "xmark.circle.fill" : "checkmark.circle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(settings.connectionStatus.hasPrefix("Connection failed") ? Color.red : Color.secondary)
                        .lineLimit(2)
                    }
                    Spacer()
                    Button("Test Connection") { model.testConnection() }
                    Button("Save Provider") { model.saveAISettings() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!settings.isDirty)
                }
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
