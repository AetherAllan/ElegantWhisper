import Observation

struct SettingsDraft: Equatable {
    var language: RecognitionLanguage
    var keepClipboardWithoutTarget: Bool
    var saveHistory: Bool
    var muteOutputDuringRecording: Bool
    var postEditLearningEnabled: Bool
    var llmEnabled: Bool
    var provider: LLMProvider
    var baseURL: String
    var apiKey: String
    var model: String
    var timeout: Double

    init(settings: SettingsStore) {
        language = settings.language
        keepClipboardWithoutTarget = settings.keepClipboardWithoutTarget
        saveHistory = settings.saveHistory
        muteOutputDuringRecording = settings.muteOutputDuringRecording
        postEditLearningEnabled = settings.postEditLearningEnabled
        llmEnabled = settings.llmEnabled
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

    func saveGeneral() {
        store.language = draft.language
        store.keepClipboardWithoutTarget = draft.keepClipboardWithoutTarget
        store.saveHistory = draft.saveHistory
        store.muteOutputDuringRecording = draft.muteOutputDuringRecording
        store.postEditLearningEnabled = draft.postEditLearningEnabled
        savedDraft = SettingsDraft(settings: store)
    }

    func saveAI() {
        store.llmProvider = draft.provider
        store.llmEnabled = draft.llmEnabled
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
