import AppKit
import Foundation
import Observation

enum AppRoute: String, CaseIterable, Hashable, Identifiable {
    case home
    case history
    case dictionary
    case styles
    case settings
    case about

    static let primary: [AppRoute] = [.home, .history, .dictionary, .styles]
    static let application: [AppRoute] = [.settings, .about]

    var id: Self { self }

    var title: String {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .dictionary: "Dictionary"
        case .styles: "Styles"
        case .settings: "Settings"
        case .about: "About"
        }
    }

    var symbolName: String {
        switch self {
        case .home: "house"
        case .history: "clock.arrow.circlepath"
        case .dictionary: "text.book.closed"
        case .styles: "sparkles"
        case .settings: "gearshape"
        case .about: "info.circle"
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case recognition
    case ai
    case permissions

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .recognition: "Recognition"
        case .ai: "Dictate"
        case .permissions: "Permissions"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .recognition: "waveform"
        case .ai: "sparkles"
        case .permissions: "hand.raised"
        }
    }
}

/// What happens to the recognized text before it is inserted.
enum OutputMode: String, CaseIterable, Identifiable {
    /// Inserted as recognized, after the local spelling fix. No language model.
    case asSpoken
    /// The built-in Dictate rewrite.
    case dictate
    /// Another Style Pack prompt (conservative correction, programmer, …).
    case stylePack

    var id: Self { self }

    var title: String {
        switch self {
        case .asSpoken: "As spoken"
        case .dictate: "Dictate"
        case .stylePack: "Style pack"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private let controller: AppController
    @ObservationIgnored private let appIcon = AppIconSwitcher()
    private let settingsStore: SettingsStore
    private let stylePackStore: StylePackStore
    private var started = false
    private var accessibilityRequestPending = false

    let history: HistoryModel
    let dictionary: DictionaryModel
    let styles: StylesModel
    let settings: SettingsModel

    var route: AppRoute = .home
    var settingsTab: SettingsTab = .general
    private(set) var mode: AppMode = .idle
    private(set) var permissionStatus: PermissionStatus
    private(set) var microphones: [AudioInputDevice] = []
    private(set) var currentMicrophoneUID: String?
    private(set) var currentLanguage: RecognitionLanguage
    private(set) var currentSpeechModel: SpeechRecognitionModel
    private(set) var currentProvider: TranscriptionProvider
    private(set) var currentTheme: AppTheme
    private(set) var usage: UsageStats
    private(set) var llmEnabled: Bool
    private(set) var llmProvider: LLMProvider
    private(set) var onboardingCompleted: Bool
    private(set) var tutorialReplayID = UUID()
    private(set) var accessibilityRestartSuggested = false
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
        stylePackStore = styles
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
        settings.migrateTranscriptionSettings()
        currentSpeechModel = settings.speechModel
        currentProvider = settings.transcriptionProvider
        currentTheme = settings.appTheme
        usage = settings.usageStats
        llmEnabled = settings.llmEnabled
        llmProvider = settings.llmProvider
        onboardingCompleted = settings.onboardingCompleted
        seedUsageFromHistoryIfNeeded()
        reloadSnapshots()
        self.settings.onApply = { [weak self] in self?.settingsApplied() }
    }

    /// Lifetime stats started after history did. Seed them once from saved history so existing
    /// users do not see an empty dashboard. Durations were not recorded then, so pace starts later.
    private func seedUsageFromHistoryIfNeeded() {
        guard usage.dictations == 0, !history.items.isEmpty else { return }
        var seeded = UsageStats()
        for item in history.items where item.result != .failed {
            seeded.record(text: item.text, duration: item.duration)
        }
        settingsStore.usageStats = seeded
        usage = seeded
    }

    func start() {
        guard !started else { return }
        started = true
        controller.onChange = { [weak self] in self?.reloadDictationState() }
        controller.onUserMessage = { [weak self] message in self?.notice = message }
        controller.start()
        reloadSnapshots()
        appIcon.start(theme: currentTheme)
        if permissionStatus.missingTitles.isEmpty {
            controller.startHotkeyMonitorIfPermitted()
        }
    }

    func stop() {
        controller.stopHotkeyMonitor()
        controller.restoreOutputMuteOnTerminate()
    }

    func refreshAfterActivation() {
        refreshPermissions()
        if accessibilityRequestPending {
            accessibilityRestartSuggested = !permissionStatus.accessibilityGranted
            accessibilityRequestPending = false
        }
    }

    func refreshPermissions() {
        reloadSnapshots()
        if started, permissionStatus.missingTitles.isEmpty {
            controller.startHotkeyMonitorIfPermitted()
        }
    }

    func completeOnboarding() {
        settingsStore.onboardingCompleted = true
        onboardingCompleted = true
        reloadSnapshots()
        guard started, permissionStatus.missingTitles.isEmpty else { return }
        controller.startHotkeyMonitorIfPermitted()
    }

    func prepareTutorialReplay() {
        tutorialReplayID = UUID()
    }

    func openSettings() {
        route = .settings
    }

    func openPermissionSettings() {
        settingsTab = .permissions
        route = .settings
    }

    func openAbout() {
        route = .about
    }

    func clearHistory() {
        history.clear()
        notice = "History cleared"
    }

    func copyHistory(_ item: HistoryItem) {
        history.copy(item)
        notice = "Copied history item"
    }

    func copyHistoryOriginal(_ item: HistoryItem) {
        guard let original = item.originalText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(original, forType: .string)
        notice = "Copied the text as recognized"
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
        if id != StylePackStore.dictatePackID {
            settingsStore.lastStylePackID = id
        }
        dictionary.reload()
        if let active = styles.activePack {
            notice = "Style pack active: \(active.name)"
        }
    }

    /// Output mode is not stored on its own: it is "polishing on or off" plus which Style Pack is
    /// active, so the Styles page and the menu bar toggle stay consistent with it.
    var outputMode: OutputMode {
        guard settings.draft.llmEnabled else { return .asSpoken }
        return styles.activePack?.id == StylePackStore.dictatePackID ? .dictate : .stylePack
    }

    func setOutputMode(_ mode: OutputMode) {
        let enable = settings.immediate(\.llmEnabled) { $0.llmEnabled = $1 }
        switch mode {
        case .asSpoken:
            enable.wrappedValue = false
        case .dictate:
            if let active = styles.activePack?.id, active != StylePackStore.dictatePackID {
                settingsStore.lastStylePackID = active
            }
            styles.select(id: StylePackStore.dictatePackID)
            enable.wrappedValue = true
        case .stylePack:
            if styles.activePack?.id == StylePackStore.dictatePackID {
                let last = settingsStore.lastStylePackID
                let fallback = styles.packs.contains { $0.id == last } ? last : StylePackStore.programmerPackID
                styles.select(id: fallback)
            }
            enable.wrappedValue = true
        }
        dictionary.reload()
    }

    func saveStyle() {
        notice = styles.save() ? "Style pack saved" : "No style pack selected"
        dictionary.reload()
    }

    func resetStyle() {
        notice = styles.reset() ? "Built-in style pack reset" : "Only built-in style packs can be reset"
        dictionary.reload()
    }

    private func settingsApplied() {
        dictionary.language = settingsStore.language
        reloadRuntimeSettings()
        controller.prewarmSpeech()
    }

    func saveAISettings() {
        settings.saveAI()
        reloadRuntimeSettings()
        notice = "Language model settings saved"
    }

    /// A refiner on the saved settings, for Compare Models.
    func makeBenchmarkRefiner() -> LLMRefiner {
        LLMRefiner(settings: settingsStore, stylePacks: stylePackStore)
    }

    func useDictateModel(_ id: String) {
        settings.draft.model = id
        settings.saveAI()
        reloadRuntimeSettings()
        notice = "Dictate now uses \(id)"
    }

    func saveTranscriptionKey(for provider: TranscriptionProvider) {
        settings.saveKey(for: provider)
        notice = settings.keyDraft(for: provider).isEmpty ? "\(provider.title) key removed" : "\(provider.title) key saved"
    }

    func checkTranscriptionKey(for provider: TranscriptionProvider) {
        settings.checkKey(for: provider)
    }

    func testConnection() {
        settings.testConnection()
        reloadRuntimeSettings()
        notice = "Language model settings saved"
    }

    func setLanguage(_ language: RecognitionLanguage) {
        controller.setLanguage(language)
        dictionary.language = language
        reloadRuntimeSettings()
    }

    func setLLMEnabled(_ enabled: Bool) {
        controller.setLLMEnabled(enabled)
        reloadRuntimeSettings()
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
            controller.requestSpeechPermission { [weak self] _ in
                self?.reloadSnapshots()
                self?.controller.prewarmSpeech()
            }
        } else {
            controller.openSpeechSettings()
        }
    }

    func requestAccessibilityPermission() {
        accessibilityRequestPending = true
        accessibilityRestartSuggested = false
        controller.requestAccessibilityPermission()
        reloadSnapshots()
    }

    func requestInputMonitoringPermission() {
        controller.requestInputMonitoringPermission()
        reloadSnapshots()
    }

    func openMicrophoneSettings() { controller.openMicrophoneSettings() }
    func openSpeechSettings() { controller.openSpeechSettings() }
    func openAccessibilitySettings() {
        accessibilityRequestPending = true
        controller.openAccessibilitySettings()
    }
    func openInputMonitoringSettings() { controller.openInputMonitoringSettings() }

    func restartApplication() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.addsToRecentItems = false

        // Privacy grants can remain stale in the current process after System Settings changes.
        // Stop global input and restore audio before overlapping briefly with the replacement app.
        stop()
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    self?.notice = "Could not restart: \(error.localizedDescription)"
                    self?.refreshPermissions()
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    private func reloadSnapshots() {
        mode = controller.state.mode
        permissionStatus = controller.permissionStatus()
        history.reload()
        dictionary.reload()
        styles.reloadPacks()
        usage = settingsStore.usageStats
        reloadRuntimeSettings()
    }

    /// Runs on every dictation state change, so it skips the permission probe and Style Pack
    /// reload in reloadSnapshots(). Lists only change once a dictation ends.
    private func reloadDictationState() {
        mode = controller.state.mode
        reloadRuntimeSettings()
        if mode == .idle {
            history.reload()
            dictionary.reload()
            usage = settingsStore.usageStats
        }
    }

    private func reloadRuntimeSettings() {
        currentLanguage = settingsStore.language
        currentSpeechModel = settingsStore.speechModel
        currentProvider = settingsStore.transcriptionProvider
        currentTheme = settingsStore.appTheme
        appIcon.setTheme(currentTheme)
        settings.syncImmediateFields()
        llmEnabled = settingsStore.llmEnabled
        llmProvider = settingsStore.llmProvider
    }
}
