import Observation
import SwiftUI

struct SettingsDraft: Equatable {
    var language: RecognitionLanguage
    var speechModel: SpeechRecognitionModel
    var transcriptionProvider: TranscriptionProvider
    var openRouterModel: String
    var readWindowText: Bool
    var appTheme: AppTheme
    var keepClipboardWithoutTarget: Bool
    var saveHistory: Bool
    var muteOutputDuringRecording: Bool
    var postEditLearningEnabled: Bool
    var llmEnabled: Bool
    var dictateMatchesAppTone: Bool
    var shareCursorTextWithLLM: Bool
    var provider: LLMProvider
    var baseURL: String
    var apiKey: String
    var openAIKey: String
    var openRouterKey: String
    var model: String
    var timeout: Double

    init(settings: SettingsStore) {
        language = settings.language
        speechModel = settings.speechModel
        transcriptionProvider = settings.transcriptionProvider
        openRouterModel = settings.openRouterTranscriptionModel
        readWindowText = settings.readWindowText
        appTheme = settings.appTheme
        keepClipboardWithoutTarget = settings.keepClipboardWithoutTarget
        saveHistory = settings.saveHistory
        muteOutputDuringRecording = settings.muteOutputDuringRecording
        postEditLearningEnabled = settings.postEditLearningEnabled
        llmEnabled = settings.llmEnabled
        dictateMatchesAppTone = settings.dictateMatchesAppTone
        shareCursorTextWithLLM = settings.shareCursorTextWithLLM
        provider = settings.llmProvider
        baseURL = settings.apiBaseURL
        apiKey = settings.apiKey
        openAIKey = settings.openAITranscriptionKey
        openRouterKey = settings.openRouterTranscriptionKey
        model = settings.model
        timeout = settings.requestTimeout
    }
}

@MainActor
@Observable
final class SettingsModel {
    private let store: SettingsStore
    private let controller: AppController
    var draft: SettingsDraft
    private(set) var savedDraft: SettingsDraft
    var connectionStatus = ""
    /// Result of the last Check Key, per online provider.
    var keyStatus: [TranscriptionProvider: String] = [:]
    /// Runs after a toggle or picker applies, so the app can react (prewarm a new language, etc.).
    var onApply: (@MainActor () -> Void)?

    init(store: SettingsStore, controller: AppController) {
        self.store = store
        self.controller = controller
        let draft = SettingsDraft(settings: store)
        self.draft = draft
        savedDraft = draft
    }

    var isDirty: Bool {
        draft != savedDraft
    }

    func beginEditing() {
        let draft = SettingsDraft(settings: store)
        self.draft = draft
        savedDraft = draft
        connectionStatus = ""
        keyStatus = [:]
    }

    func providerChanged(to provider: LLMProvider) {
        draft.provider = provider
        if let baseURL = provider.defaultBaseURL {
            draft.baseURL = baseURL
        }
        draft.model = provider.defaultModel ?? ""
    }

    /// Only the polishing fields, so editing a recognition key does not enable "Save Provider".
    var isPolishingDirty: Bool {
        draft.provider != savedDraft.provider
            || draft.baseURL != savedDraft.baseURL
            || draft.apiKey != savedDraft.apiKey
            || draft.model != savedDraft.model
            || draft.timeout != savedDraft.timeout
    }

    func keyDraft(for provider: TranscriptionProvider) -> String {
        switch provider {
        case .apple: ""
        case .openAI: draft.openAIKey
        case .openRouter: draft.openRouterKey
        }
    }

    func setKeyDraft(_ key: String, for provider: TranscriptionProvider) {
        switch provider {
        case .apple: break
        case .openAI: draft.openAIKey = key
        case .openRouter: draft.openRouterKey = key
        }
    }

    func isKeyDirty(_ provider: TranscriptionProvider) -> Bool {
        switch provider {
        case .apple: false
        case .openAI: draft.openAIKey != savedDraft.openAIKey
        case .openRouter: draft.openRouterKey != savedDraft.openRouterKey
        }
    }

    func saveKey(for provider: TranscriptionProvider) {
        store.setTranscriptionKey(keyDraft(for: provider), for: provider)
        let saved = store.transcriptionKey(for: provider)
        setKeyDraft(saved, for: provider)
        switch provider {
        case .apple: break
        case .openAI: savedDraft.openAIKey = saved
        case .openRouter: savedDraft.openRouterKey = saved
        }
    }

    /// Checks the typed key (saved or not), and for OpenRouter the chosen model; no audio is sent.
    func checkKey(for provider: TranscriptionProvider) {
        guard let service = provider.service else { return }
        let key = keyDraft(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        let model = provider == .openRouter ? draft.openRouterModel : TranscriptionModelOption.openAIModel.id
        // A key pasted under the other provider is the most likely mistake; say so directly.
        if provider == .openAI, TranscriptionService.looksLikeOpenRouterKey(key) {
            keyStatus[provider] = "Check failed: this is an OpenRouter key. Choose OpenRouter above."
            return
        }
        keyStatus[provider] = "Checking…"
        Task { [weak self] in
            let result = await OnlineTranscriber.checkKey(key, service: service, model: model)
            switch result {
            case .success:
                self?.keyStatus[provider] = "Key works. \(model) is available."
            case .failure(let error):
                self?.keyStatus[provider] = "Check failed: \(error.localizedDescription)"
            }
        }
    }

    /// Toggles and pickers apply as soon as they change, like macOS System Settings. Provider
    /// credentials keep the draft and Save flow so a half-typed URL or key is never used.
    func immediate<Value>(
        _ keyPath: WritableKeyPath<SettingsDraft, Value>,
        write: @escaping (SettingsStore, Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { self.draft[keyPath: keyPath] },
            set: { value in
                self.draft[keyPath: keyPath] = value
                self.savedDraft[keyPath: keyPath] = value
                write(self.store, value)
                self.onApply?()
            }
        )
    }

    /// Pulls immediate settings changed elsewhere (the menu bar) into the form, leaving unsaved
    /// provider fields alone. Reads UserDefaults only; the API key is never re-read here.
    func syncImmediateFields() {
        sync(\.language, store.language)
        sync(\.speechModel, store.speechModel)
        sync(\.transcriptionProvider, store.transcriptionProvider)
        sync(\.openRouterModel, store.openRouterTranscriptionModel)
        sync(\.readWindowText, store.readWindowText)
        sync(\.appTheme, store.appTheme)
        sync(\.keepClipboardWithoutTarget, store.keepClipboardWithoutTarget)
        sync(\.saveHistory, store.saveHistory)
        sync(\.muteOutputDuringRecording, store.muteOutputDuringRecording)
        sync(\.postEditLearningEnabled, store.postEditLearningEnabled)
        sync(\.llmEnabled, store.llmEnabled)
        sync(\.dictateMatchesAppTone, store.dictateMatchesAppTone)
        sync(\.shareCursorTextWithLLM, store.shareCursorTextWithLLM)
    }

    private func sync<Value: Equatable>(_ keyPath: WritableKeyPath<SettingsDraft, Value>, _ value: Value) {
        if draft[keyPath: keyPath] != value {
            draft[keyPath: keyPath] = value
        }
        if savedDraft[keyPath: keyPath] != value {
            savedDraft[keyPath: keyPath] = value
        }
    }

    func saveAI() {
        store.llmProvider = draft.provider
        store.llmEnabled = draft.llmEnabled
        store.shareCursorTextWithLLM = draft.shareCursorTextWithLLM
        store.apiBaseURL = draft.baseURL
        store.apiKey = draft.apiKey
        store.model = draft.model
        store.requestTimeout = draft.timeout
        // Refresh only the polishing fields: an unsaved recognition key stays unsaved.
        let saved = SettingsDraft(settings: store)
        savedDraft.provider = saved.provider
        savedDraft.llmEnabled = saved.llmEnabled
        savedDraft.shareCursorTextWithLLM = saved.shareCursorTextWithLLM
        savedDraft.baseURL = saved.baseURL
        savedDraft.apiKey = saved.apiKey
        savedDraft.model = saved.model
        savedDraft.timeout = saved.timeout
    }

    func testConnection() {
        // Preserve the existing UI contract: testing commits the form before the request.
        saveAI()
        connectionStatus = "Testing…"
        controller.testConnection { [weak self] ok, message in
            self?.connectionStatus = ok ? message : "Connection failed: \(message)"
        }
    }
}
