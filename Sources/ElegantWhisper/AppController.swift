import AppKit
import Foundation

@MainActor
final class AppController {
    let state = AppState()

    private let settings = SettingsStore.shared
    private let permissions = PermissionManager()
    private let monitor = OptionKeyMonitor()
    private let recorder = AudioRecorder()
    private let transcriber = SpeechTranscriber()
    private let dictionary = DictionaryStore.shared
    private let correctionEngine = CorrectionEngine()
    private let focusDetector = FocusDetector()
    private let inputSourceManager = InputSourceManager()
    private let panel = FloatingPanel()
    private lazy var refiner = LLMRefiner(settings: settings)
    private lazy var injector = TextInjector(focusDetector: focusDetector, inputSourceManager: inputSourceManager)

    private var currentSession: DictationSession?
    private var latestPartial = ""
    private var monitorStarted = false
    private var loggedFirstAudioLevel = false
    private var refinementTask: URLSessionDataTask?

    var onChange: (@MainActor () -> Void)?
    var onUserMessage: (@MainActor (String) -> Void)?

    func start() {
        do {
            try AppConstants.ensureApplicationDirectories()
        } catch {
            onUserMessage?("\(AppConstants.logPrefix) Cannot create Application Support directory")
        }

        monitor.onToggle = { [weak self] in
            self?.toggleRecording()
        }
        monitor.onCancel = { [weak self] in
            self?.cancelCurrentOperation()
        }

        transcriber.onPartial = { [weak self] text in
            self?.latestPartial = text
            self?.panel.updatePartial(text)
        }
        transcriber.onUnexpectedStop = { [weak self] message in
            guard self?.state.mode == .recording else {
                return
            }
            self?.showError(message)
        }
        recorder.onLevel = { [weak self] level in
            if level > 0.02, self?.loggedFirstAudioLevel == false {
                self?.loggedFirstAudioLevel = true
                DebugLog.event("firstAudioLevel")
            }
            self?.panel.updateLevel(level)
        }
        let transcriber = transcriber
        recorder.onBuffer = { buffer in
            transcriber.append(buffer)
        }
    }

    func startHotkeyMonitorIfPermitted() {
        guard !monitorStarted else {
            return
        }
        let status = permissions.status()
        // Accessibility gives us AX focus and paste safety; Input Monitoring is required for
        // background Command/Option detection. Without both, the app appears to work only while
        // its own Dock window is focused.
        guard status.accessibilityGranted, status.inputMonitoringGranted else {
            onUserMessage?("Accessibility and Input Monitoring required before hotkeys can start")
            return
        }
        if monitor.start() {
            monitorStarted = true
            DebugLog.event("hotkeyMonitorStarted")
        } else {
            onUserMessage?("Unable to start global key monitor")
        }
    }

    func stopHotkeyMonitor() {
        monitor.stop()
        monitorStarted = false
    }

    func toggleRecording() {
        // The state machine is the single entry point for hotkeys and menu actions. This prevents
        // a stale key event from starting a second recorder or submitting the same audio twice.
        switch state.mode {
        case .idle:
            startRecording()
        case .recording:
            stopAndTranscribe()
        case .transcribing, .refining:
            cancelCurrentOperation()
        case .injecting:
            onUserMessage?("Busy: \(state.mode.title)")
        }
    }

    func startRecording() {
        guard state.mode == .idle else {
            return
        }

        let status = permissions.status()
        if !status.microphoneGranted {
            permissions.requestMicrophone { [weak self] granted in
                granted ? self?.startRecording() : self?.showError("Microphone permission missing")
            }
            return
        }
        if !status.speechGranted {
            permissions.requestSpeech { [weak self] granted in
                granted ? self?.startRecording() : self?.showError("Speech permission missing")
            }
            return
        }

        currentSession = DictationSession(
            originalTarget: focusDetector.currentEditableTarget(),
            originalApplication: NSWorkspace.shared.frontmostApplication
        )
        latestPartial = ""
        refinementTask?.cancel()
        refinementTask = nil
        loggedFirstAudioLevel = false

        do {
            try transcriber.start(
                language: settings.language,
                contextualStrings: dictionary.contextualStrings(for: settings.language)
            )
            try recorder.start()
            DebugLog.event("recordingStart")
            _ = state.transition(to: .recording)
            panel.showRecording(text: "")
            DebugLog.event("panelShow")
            onChange?()
        } catch {
            showError(error.localizedDescription)
        }
    }

    func stopAndTranscribe() {
        guard state.transition(to: .transcribing) else {
            return
        }
        recorder.stop()
        DebugLog.event("recordingStop")
        panel.showStatus("Transcribing...")
        onChange?()

        guard let sessionID = currentSession?.id else {
            showError("No active session")
            return
        }
        transcriber.finish { [weak self] text in
            self?.handleFinalTranscript(text, sessionID: sessionID)
        }
    }

    func cancelRecording() {
        guard state.mode == .recording else {
            return
        }
        recorder.stop()
        DebugLog.event("recordingStop")
        transcriber.cancel()
        refinementTask?.cancel()
        refinementTask = nil
        currentSession = nil
        latestPartial = ""
        _ = state.transition(to: .idle)
        panel.hide()
        DebugLog.event("panelHide")
        onChange?()
    }

    func cancelCurrentOperation() {
        switch state.mode {
        case .recording:
            cancelRecording()
        case .transcribing, .refining:
            recorder.stop()
            transcriber.cancel()
            refinementTask?.cancel()
            refinementTask = nil
            currentSession = nil
            latestPartial = ""
            _ = state.transition(to: .idle)
            panel.hide()
            DebugLog.event("panelHide")
            onUserMessage?("Cancelled")
            onChange?()
        case .idle, .injecting:
            break
        }
    }

    func setLanguage(_ language: RecognitionLanguage) {
        settings.language = language
        onChange?()
    }

    func setLLMEnabled(_ enabled: Bool) {
        settings.llmEnabled = enabled
        onChange?()
    }

    func permissionStatus() -> PermissionStatus {
        permissions.status()
    }

    func openMicrophoneSettings() {
        permissions.openMicrophoneSettings()
    }

    func openSpeechSettings() {
        permissions.openSpeechSettings()
    }

    func openAccessibilitySettings() {
        permissions.openAccessibilitySettings()
    }

    func openInputMonitoringSettings() {
        permissions.openInputMonitoringSettings()
    }

    func settingsWindowController() -> SettingsWindowController {
        SettingsWindowController(settings: settings, refiner: refiner)
    }

    private func handleFinalTranscript(_ text: String, sessionID: UUID) {
        guard isCurrentSession(sessionID) else {
            return
        }
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            showError("No speech recognized")
            return
        }

        let locallyCorrected = correctionEngine.correct(raw, entries: dictionary.entries(for: settings.language))

        if settings.llmEnabled {
            // Refinement is allowed to improve obvious recognition mistakes, but it is not allowed
            // to block insertion forever. LLMRefiner owns the timeout/fallback to raw text.
            _ = state.transition(to: .refining)
            panel.showStatus("Refining...")
            onChange?()
            refinementTask = refiner.refine(locallyCorrected) { [weak self] refined in
                guard let self, self.isCurrentSession(sessionID) else {
                    return
                }
                self.refinementTask = nil
                self.inject(refined.isEmpty ? locallyCorrected : refined, sessionID: sessionID)
            }
        } else {
            inject(locallyCorrected, sessionID: sessionID)
        }
    }

    private func inject(_ text: String, sessionID: UUID) {
        guard isCurrentSession(sessionID) else {
            return
        }
        guard state.transition(to: .injecting) else {
            return
        }
        panel.showStatus("Inserting...")
        onChange?()

        // Prefer the field focused when transcription finishes. If the user switches from one
        // editor to another while Speech is finalizing, the current field is the least surprising
        // insertion target. The start-time target is only a fallback.
        let originalTarget = currentSession?.originalTarget
        let originalApplication = currentSession?.originalApplication
        let target = focusDetector.currentEditableTarget() ?? originalTarget.flatMap {
            focusDetector.isValid($0) ? $0 : nil
        }
        let fallbackApp = fallbackPasteApplication(target: target, originalApplication: originalApplication)

        guard target != nil || fallbackApp != nil || settings.keepClipboardWithoutTarget else {
            saveHistory(text, result: HistoryResult.failed, app: originalTarget?.app ?? originalApplication)
            showError("No editable field")
            return
        }

        let historyApp = target?.app ?? fallbackApp ?? originalTarget?.app ?? originalApplication
        injector.inject(text, target: target, fallbackApp: fallbackApp) { [weak self] result in
            guard let self, self.isCurrentSession(sessionID) else {
                return
            }
            switch result {
            case .pasteAttempted:
                self.panel.hide()
                DebugLog.event("panelHide")
                self.saveHistory(text, result: HistoryResult.pasteAttempted, app: historyApp)
            case .copied:
                self.panel.showSuccess("复制")
                self.onUserMessage?("已复制到剪贴板")
                self.saveHistory(text, result: HistoryResult.copied, app: historyApp)
            }
            self.refinementTask = nil
            self.currentSession = nil
            self.latestPartial = ""
            _ = self.state.transition(to: .idle)
            self.onChange?()
        }
    }

    private func showError(_ message: String) {
        recorder.stop()
        transcriber.cancel()
        refinementTask?.cancel()
        refinementTask = nil
        currentSession = nil
        latestPartial = ""
        _ = state.transition(to: .idle)
        panel.showError(message)
        DebugLog.event("panelHide")
        onUserMessage?(message)
        onChange?()
    }


    private func saveHistory(_ text: String, result: HistoryResult, app: NSRunningApplication?) {
        guard settings.saveHistory else {
            return
        }
        HistoryStore.shared.append(text: text, result: result, app: app)
    }

    private func fallbackPasteApplication(target: FocusTarget?, originalApplication: NSRunningApplication?) -> NSRunningApplication? {
        guard target == nil else {
            return nil
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        if let frontmost, frontmost.bundleIdentifier != AppConstants.bundleIdentifier {
            return frontmost
        }

        if let originalApplication,
           !originalApplication.isTerminated,
           originalApplication.bundleIdentifier != AppConstants.bundleIdentifier
        {
            return originalApplication
        }

        return nil
    }

    private func isCurrentSession(_ id: UUID) -> Bool {
        currentSession?.id == id
    }
}
