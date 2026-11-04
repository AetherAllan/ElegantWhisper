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
            .frame(maxWidth: 520)

            Group {
                switch model.settingsTab {
                case .general: GeneralSettingsView()
                case .recognition: RecognitionSettingsView()
                case .ai: AISettingsView()
                case .permissions: PermissionsSettingsView()
                }
            }
            .frame(maxWidth: 680)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .navigationTitle("Settings")
        .onAppear { model.settings.beginEditing() }
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section("Appearance") {
                Picker(selection: settings.immediate(\.appTheme) { $0.appTheme = $1 }) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                } label: {
                    Text("Theme")
                    Text("Prism: black, with light split into a spectrum, for the window and the floating bar.")
                }
                .pickerStyle(.segmented)
            }

            Section("Shortcuts") {
                LabeledContent("Start or stop") { Keycap("Right ⌥") }
                LabeledContent("Cancel") { Keycap("esc") }
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

/// Provider first, then that provider's model and key. Apple runs on this Mac; OpenAI and
/// OpenRouter upload the recording when you stop, with Apple's model as the live preview and
/// fallback.
private struct RecognitionSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let provider = settings.draft.transcriptionProvider

        Form {
            Section {
                Picker("Provider", selection: settings.immediate(\.transcriptionProvider) { $0.transcriptionProvider = $1 }) {
                    ForEach(TranscriptionProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                switch provider {
                case .apple:
                    Picker(selection: settings.immediate(\.speechModel) { $0.speechModel = $1 }) {
                        ForEach(SpeechRecognitionModel.allCases, id: \.self) { model in
                            Text(model.title).tag(model)
                        }
                    } label: {
                        Text("Model")
                        Text("Runs on this Mac: free, private, and works offline.")
                    }
                case .openAI:
                    LabeledContent {
                        Text(TranscriptionModelOption.openAIModel.priceText)
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("Model: \(TranscriptionModelOption.openAIModel.id)")
                        Text(TranscriptionModelOption.openAIModel.note)
                    }
                    ProviderKeyRows(provider: .openAI)
                case .openRouter:
                    OpenRouterModelPicker()
                    ProviderKeyRows(provider: .openRouter)
                }
            } header: {
                Text("Engine")
            } footer: {
                if provider != .apple {
                    Text("When you stop, the recording is uploaded to \(provider.title) with up to 50 hints from your Dictionary and the words on screen; models that refuse hints get the audio only. Apple's model still shows live text and is used if the request fails or takes longer than 15 seconds.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Language & Context") {
                Picker("Language", selection: settings.immediate(\.language) { $0.language = $1 }) {
                    ForEach(RecognitionLanguage.allCases, id: \.self) { language in
                        Text(language.menuTitle).tag(language)
                    }
                }
                Toggle(isOn: settings.immediate(\.readWindowText) { $0.readWindowText = $1 }) {
                    Text("Use words from the front window")
                    Text(provider == .apple
                        ? "Reads technical words such as Redis or useEffect from the window you're dictating into, to fix their spelling. Password fields are skipped and nothing leaves this Mac."
                        : "Reads technical words such as Redis or useEffect from the window you're dictating into, to fix their spelling. Password fields are skipped. With online recognition, some of these words are sent as hints.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct OpenRouterModelPicker: View {
    @Environment(AppModel.self) private var model
    @State private var isCustom = false
    @State private var customID = ""

    private static let customTag = "__custom__"
    private static let browseURL = URL(string: "https://openrouter.ai/models?output_modalities=transcription")!

    var body: some View {
        let settings = model.settings
        let current = settings.draft.openRouterModel
        let preset = TranscriptionModelOption.openRouterPresets.first { $0.id == current }
        let selection = Binding<String>(
            get: { isCustom || preset == nil ? Self.customTag : current },
            set: { newValue in
                if newValue == Self.customTag {
                    isCustom = true
                    customID = preset == nil ? current : ""
                } else {
                    isCustom = false
                    apply(newValue)
                }
            }
        )

        Picker(selection: selection) {
            ForEach(TranscriptionModelOption.openRouterPresets) { option in
                Text("\(option.name)  ·  \(option.priceText)").tag(option.id)
            }
            Divider()
            Text("Other model ID…").tag(Self.customTag)
        } label: {
            Text("Model")
            if let preset, !isCustom {
                Text(preset.note)
            } else {
                Text("Any OpenRouter speech-to-text model, for example vendor/model-name.")
            }
        }

        if isCustom || preset == nil {
            HStack {
                TextField("Model ID", text: $customID, prompt: Text(preset == nil ? current : "vendor/model-name"))
                    .onSubmit { applyCustom() }
                Button("Use") { applyCustom() }
                    .disabled(customID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        LabeledContent("All models") {
            Link("Browse on OpenRouter", destination: Self.browseURL)
        }
    }

    private func applyCustom() {
        let id = customID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        apply(id)
        isCustom = TranscriptionModelOption.openRouterPresets.first { $0.id == id } == nil
    }

    private func apply(_ id: String) {
        model.settings.immediate(\.openRouterModel) { $0.openRouterTranscriptionModel = $1 }.wrappedValue = id
        // A previous "Key works" was for the old model.
        model.settings.keyStatus[.openRouter] = nil
    }
}

private struct ProviderKeyRows: View {
    @Environment(AppModel.self) private var model
    let provider: TranscriptionProvider

    var body: some View {
        let settings = model.settings
        let status = settings.keyStatus[provider] ?? ""
        let failed = status.hasPrefix("Check failed")
        let key = Binding(
            get: { settings.keyDraft(for: provider) },
            set: { settings.setKeyDraft($0, for: provider) }
        )

        SecureField("API key", text: key, prompt: Text(provider == .openRouter ? "sk-or-…" : "sk-…"))
        HStack {
            if !status.isEmpty {
                Label(status, systemImage: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(failed ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Check Key") { model.checkTranscriptionKey(for: provider) }
                .disabled(key.wrappedValue.isEmpty)
            Button("Save Key") { model.saveTranscriptionKey(for: provider) }
                .buttonStyle(.borderedProminent)
                .disabled(!settings.isKeyDirty(provider))
        }
    }
}

private struct AISettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingComparison = false

    var body: some View {
        @Bindable var settings = model.settings
        let provider = Binding(
            get: { settings.draft.provider },
            set: { settings.providerChanged(to: $0) }
        )

        let mode = Binding(
            get: { model.outputMode },
            set: { model.setOutputMode($0) }
        )

        Form {
            Section {
                Picker("After recognition", selection: mode) {
                    ForEach(OutputMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch model.outputMode {
                case .asSpoken:
                    Text("Inserts what was recognized, after the local spelling fix. Nothing is sent to a language model.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .dictate:
                    Text("Writes what you meant: removes fillers (嗯, 呃, um) and repetitions, keeps only your final wording when you correct yourself, turns spoken lists into lists, and adds punctuation. It never answers or translates what you said. The text, not the audio, is sent to the model below; very short phrases and anything slower than 5 seconds are inserted as recognized.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Toggle(isOn: settings.immediate(\.dictateMatchesAppTone) { $0.dictateMatchesAppTone = $1 }) {
                        Text("Match the tone to the app")
                        Text("Casual in chat apps, full sentences in email, minimal changes in code editors and terminals. Only the kind of app is sent.")
                    }
                case .stylePack:
                    Picker(selection: Binding(
                        get: { model.styles.activePack?.id ?? "" },
                        set: { model.selectStyle(id: $0) }
                    )) {
                        ForEach(model.styles.packs.filter { $0.id != StylePackStore.dictatePackID }) { pack in
                            Text(pack.name).tag(pack.id)
                        }
                    } label: {
                        Text("Style")
                        Text("Prompt templates you can edit on the Styles page.")
                    }
                }

                Toggle(isOn: settings.immediate(\.shareCursorTextWithLLM) { $0.shareCursorTextWithLLM = $1 }) {
                    Text("Send text around the cursor")
                    Text("Up to \(CursorTextContext.beforeLimit) characters before and \(CursorTextContext.afterLimit) after the cursor, to help with names and spelling. Password fields are skipped; links, emails, and secret-like strings are removed.")
                }
                .disabled(model.outputMode == .asSpoken)
            }

            Section("Language model") {
                Picker("Provider", selection: provider) {
                    ForEach(LLMProvider.allCases, id: \.self) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                TextField("API Base URL", text: $settings.draft.baseURL)
                SecureField(
                    "API Key",
                    text: $settings.draft.apiKey,
                    prompt: Text(settings.draft.provider.isOpenRouter ? "Empty: uses your OpenRouter key from Recognition" : "")
                )
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
                if settings.draft.provider.isOpenRouter {
                    LabeledContent {
                        Button("Compare Models…") { showingComparison = true }
                            .disabled(settings.isPolishingDirty)
                    } label: {
                        Text("Speed and accuracy")
                        Text(settings.isPolishingDirty ? "Save the provider first." : "Times each suggested model on test sentences with your key.")
                    }
                }
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
                        .disabled(!settings.isPolishingDirty)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingComparison) {
            DictateModelComparison()
        }
    }
}

/// Times every suggested Dictate model on the built-in test sentences with the saved provider and
/// key, so the choice rests on measured speed rather than the model's reputation.
private struct DictateModelComparison: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var benchmark = DictateBenchmark()

    private var sampleCount: Int { DictateBenchmarkSample.standard.count }
    private var models: [String] {
        var models = LLMProvider.openRouterDictateModels
        let current = model.settings.draft.model
        if !current.isEmpty, !models.contains(current) {
            models.insert(current, at: 0)
        }
        return models
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Compare Dictate models")
                .font(.title2.bold())
            Text("Sends \(sampleCount) built-in test sentences (fillers, a self-correction, a list, a question that must not be answered, technical terms) to each of \(models.count) models through your saved provider and key, routed to the fastest provider. Each answer is timed and checked. Costs about $0.02 in total; nothing you dictated is sent.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = benchmark.setupError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("Model")
                        Text("Typical").gridColumnAlignment(.trailing)
                        Text("Slowest").gridColumnAlignment(.trailing)
                        Text("Correct").gridColumnAlignment(.trailing)
                        Text("")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(rows) { result in
                        GridRow {
                            HStack(spacing: 6) {
                                Text(result.model)
                                    .lineLimit(1)
                                if result.model == model.settings.draft.model {
                                    Text("current")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.tint)
                                }
                            }
                            Text(result.median.map(Self.seconds) ?? (result.finished ? "—" : "…"))
                                .monospacedDigit()
                            Text(result.slowest.map(Self.seconds) ?? (result.finished ? "—" : "…"))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            correctness(result)
                            Button("Use") { model.useDictateModel(result.model) }
                                .disabled(!result.finished || result.seconds.isEmpty || result.model == model.settings.draft.model)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 260)

            HStack {
                if benchmark.isRunning {
                    ProgressView(value: Double(benchmark.completedModels), total: Double(max(rows.count, 1)))
                        .frame(width: 180)
                    Text("\(benchmark.completedModels) of \(rows.count) models")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(benchmark.isRunning ? "Stop" : "Close") {
                    if benchmark.isRunning {
                        benchmark.cancel()
                    } else {
                        dismiss()
                    }
                }
                Button(benchmark.results.isEmpty ? "Start" : "Run Again") {
                    benchmark.run(refiner: model.makeBenchmarkRefiner(), models: models)
                }
                .buttonStyle(.borderedProminent)
                .disabled(benchmark.isRunning)
            }
        }
        .padding(22)
        .frame(width: 640, height: 560)
        .onDisappear { benchmark.cancel() }
    }

    private var rows: [DictateBenchmarkResult] {
        benchmark.results.isEmpty ? models.map { DictateBenchmarkResult(model: $0) } : benchmark.ranked
    }

    @ViewBuilder
    private func correctness(_ result: DictateBenchmarkResult) -> some View {
        if !result.finished {
            Text("…").foregroundStyle(.secondary)
        } else if result.errors > 0, result.seconds.isEmpty {
            Text(result.lastError ?? "failed")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
                .help(result.lastError ?? "")
        } else {
            let total = result.passed + result.failed + result.errors
            Text("\(result.passed)/\(total)")
                .monospacedDigit()
                .foregroundStyle(result.passed == total ? Color.green : Color.orange)
                .help(result.errors > 0 ? (result.lastError ?? "") : "")
        }
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%.2f s", value)
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
