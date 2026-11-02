import Observation
import SwiftUI

struct SettingsDraft: Equatable {
    var language: RecognitionLanguage
    var speechModel: SpeechRecognitionModel
    var keepClipboardWithoutTarget: Bool
    var saveHistory: Bool
    var muteOutputDuringRecording: Bool
    var postEditLearningEnabled: Bool
    var llmEnabled: Bool
    var shareCursorTextWithLLM: Bool
    var provider: LLMProvider
    var baseURL: String
    var apiKey: String
    var model: String
    var timeout: Double

    init(settings: SettingsStore) {
        language = settings.language
        speechModel = settings.speechModel
        keepClipboardWithoutTarget = settings.keepClipboardWithoutTarget
        saveHistory = settings.saveHistory
        muteOutputDuringRecording = settings.muteOutputDuringRecording
        postEditLearningEnabled = settings.postEditLearningEnabled
        llmEnabled = settings.llmEnabled
        shareCursorTextWithLLM = settings.shareCursorTextWithLLM
        provider = settings.llmProvider
        baseURL = settings.apiBaseURL
        apiKey = settings.apiKey
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
    }

    func providerChanged(to provider: LLMProvider) {
        draft.provider = provider
        if let baseURL = provider.defaultBaseURL {
            draft.baseURL = baseURL
        }
        draft.model = provider.defaultModel ?? ""
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
        sync(\.keepClipboardWithoutTarget, store.keepClipboardWithoutTarget)
        sync(\.saveHistory, store.saveHistory)
        sync(\.muteOutputDuringRecording, store.muteOutputDuringRecording)
        sync(\.postEditLearningEnabled, store.postEditLearningEnabled)
        sync(\.llmEnabled, store.llmEnabled)
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
        savedDraft = SettingsDraft(settings: store)
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
