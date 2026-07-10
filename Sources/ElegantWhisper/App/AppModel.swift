import Foundation
import Observation

enum AppRoute: String, CaseIterable, Hashable, Identifiable {
    case home
    case history
    case dictionary
    case styles
    case settings

    static let primary: [AppRoute] = [.home, .history, .dictionary, .styles]

    var id: Self { self }

    var title: String {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .dictionary: "Dictionary"
        case .styles: "Styles"
        case .settings: "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .home: "house"
        case .history: "clock.arrow.circlepath"
        case .dictionary: "text.book.closed"
        case .styles: "sparkles"
        case .settings: "gearshape"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private let controller: AppController
    private let settingsStore: SettingsStore
    private var started = false

    let history: HistoryModel
    let dictionary: DictionaryModel
    let styles: StylesModel
    let settings: SettingsModel

    var route: AppRoute = .home
    private(set) var mode: AppMode = .idle
    private(set) var permissionStatus: PermissionStatus
    private(set) var microphones: [AudioInputDevice] = []
    private(set) var currentMicrophoneUID: String?
    private(set) var currentLanguage: RecognitionLanguage
    private(set) var llmEnabled: Bool
    private(set) var llmProvider: LLMProvider
    var notice = ""
    var microphoneError = ""

    init(
        controller: AppController = AppController(),
        settings: SettingsStore = .shared,
        history: HistoryStore = .shared,
        dictionary: DictionaryStore = .shared,
        candidates: LearningCandidateStore = .shared,
        styles: StylePackStore = .shared
    ) {
        self.controller = controller
        settingsStore = settings
        self.history = HistoryModel(store: history)
        self.dictionary = DictionaryModel(
            dictionary: dictionary,
            candidates: candidates,
            styles: styles,
            language: settings.language
        )
        self.styles = StylesModel(store: styles)
        self.settings = SettingsModel(store: settings, controller: controller)
        permissionStatus = controller.permissionStatus()
        currentLanguage = settings.language
        llmEnabled = settings.llmEnabled
        llmProvider = settings.llmProvider
        reloadSnapshots()
    }

    func start() {
        guard !started else { return }
        started = true
        controller.onChange = { [weak self] in self?.reloadSnapshots() }
        controller.onUserMessage = { [weak self] message in self?.notice = message }
        controller.start()
        reloadSnapshots()
        if permissionStatus.missingTitles.isEmpty {
            controller.startHotkeyMonitorIfPermitted()
        }
    }

    func stop() {
        controller.stopHotkeyMonitor()
        controller.restoreOutputMuteOnTerminate()
    }

    func refreshAfterActivation() {
        reloadSnapshots()
        if started, permissionStatus.missingTitles.isEmpty {
            controller.startHotkeyMonitorIfPermitted()
        }
    }

    func completeOnboarding() {
        reloadSnapshots()
        guard started, permissionStatus.missingTitles.isEmpty else { return }
        controller.startHotkeyMonitorIfPermitted()
    }

    func openSettings() {
        route = .settings
    }

    func clearHistory() {
        history.clear()
        notice = "History cleared"
    }

    func copyHistory(_ item: HistoryItem) {
        history.copy(item)
        notice = "Copied history item"
    }

    func useHistoryAsDictionaryTerm(_ item: HistoryItem) {
        dictionary.prepareTerm(item.text)
        route = .dictionary
        notice = "Edit the term before saving"
    }

    func addDictionaryTerm() {
        if dictionary.addTerm() {
            notice = "Dictionary term saved"
        } else {
            notice = "Dictionary term is empty"
        }
    }

    func deleteDictionaryTerm(id: UUID) {
        dictionary.deleteTerm(id: id)
    }

    func acceptCandidate(_ candidate: LearningCandidate) {
        dictionary.accept(candidate)
        notice = "Added"
    }

    func dismissCandidate(_ candidate: LearningCandidate) {
        dictionary.dismiss(candidate)
        notice = "Dismissed"
    }

    func selectStyle(id: String) {
        styles.select(id: id)
        dictionary.reload()
        if let active = styles.activePack {
            notice = "Style pack active: \(active.name)"
        }
    }

    func saveStyle() {
        notice = styles.save() ? "Style pack saved" : "No style pack selected"
        dictionary.reload()
    }

    func resetStyle() {
        notice = styles.reset() ? "Built-in style pack reset" : "Only built-in style packs can be reset"
        dictionary.reload()
    }

    func saveGeneralSettings() {
        settings.saveGeneral()
        dictionary.language = settings.draft.language
        reloadRuntimeSettings()
        notice = "Settings saved"
    }

    func saveAISettings() {
        settings.saveAI()
        reloadRuntimeSettings()
        notice = "Polishing settings saved"
    }

    func testConnection() {
        settings.testConnection()
        reloadRuntimeSettings()
        notice = "Polishing settings saved"
    }

    func setLanguage(_ language: RecognitionLanguage) {
        controller.setLanguage(language)
    }

    func setLLMEnabled(_ enabled: Bool) {
        controller.setLLMEnabled(enabled)
    }

    func refreshMicrophones() {
        microphones = AudioInputDevices.list()
        currentMicrophoneUID = AudioInputDevices.currentUID()
        microphoneError = ""
    }

    func selectMicrophone(_ uid: String) async {
        guard mode == .idle else { return }
        if await AudioInputDevices.select(uid: uid) {
            refreshMicrophones()
        } else {
            microphoneError = "Could not switch microphone. Try another device in System Settings."
        }
    }

    func requestMicrophonePermission() {
        if permissionStatus.microphoneDetail == "Not requested" {
            controller.requestMicrophonePermission { [weak self] _ in self?.reloadSnapshots() }
        } else {
            controller.openMicrophoneSettings()
        }
    }

    func requestSpeechPermission() {
        if permissionStatus.speechDetail == "Not requested" {
            controller.requestSpeechPermission { [weak self] _ in self?.reloadSnapshots() }
        } else {
            controller.openSpeechSettings()
        }
    }

    func requestAccessibilityPermission() {
        controller.requestAccessibilityPermission()
        reloadSnapshots()
    }

    func requestInputMonitoringPermission() {
        controller.requestInputMonitoringPermission()
        reloadSnapshots()
    }

    func openMicrophoneSettings() { controller.openMicrophoneSettings() }
    func openSpeechSettings() { controller.openSpeechSettings() }
    func openAccessibilitySettings() { controller.openAccessibilitySettings() }
    func openInputMonitoringSettings() { controller.openInputMonitoringSettings() }

    private func reloadSnapshots() {
        mode = controller.state.mode
        permissionStatus = controller.permissionStatus()
        history.reload()
        dictionary.reload()
        styles.reloadPacks()
        reloadRuntimeSettings()
    }

    private func reloadRuntimeSettings() {
        currentLanguage = settingsStore.language
        llmEnabled = settingsStore.llmEnabled
        llmProvider = settingsStore.llmProvider
    }
}
