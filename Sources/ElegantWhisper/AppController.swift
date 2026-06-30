import AppKit
import Foundation

final class AppController {
    let state = AppState()

    private let settings = SettingsStore.shared
    private let permissions = PermissionManager()
    private let monitor = OptionKeyMonitor()
    private let recorder = AudioRecorder()
    private let transcriber = SpeechTranscriber()
    private let focusDetector = FocusDetector()
    private let inputSourceManager = InputSourceManager()
    private let panel = FloatingPanel()
    private lazy var refiner = LLMRefiner(settings: settings)
    private lazy var injector = TextInjector(focusDetector: focusDetector, inputSourceManager: inputSourceManager)

    private var initialTarget: FocusTarget?
    private var latestPartial = ""
    private var runID = 0
    private var monitorStarted = false
    private var loggedFirstAudioLevel = false

    var onChange: (() -> Void)?
    var onUserMessage: ((String) -> Void)?

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
        recorder.onLevel = { [weak self] level in
            if level > 0.02, self?.loggedFirstAudioLevel == false {
                self?.loggedFirstAudioLevel = true
                DebugLog.event("firstAudioLevel")
            }
            self?.panel.updateLevel(level)
        }
        recorder.onBuffer = { [weak self] buffer in
            self?.transcriber.append(buffer)
        }
    }

    func startHotkeyMonitorIfPermitted() {
        guard !monitorStarted else {
            return
        }
        let status = permissions.status()
        // Accessibility and Input Monitoring are separate macOS privacy gates. Accessibility
        // lets us inspect/paste into the focused UI element; Input Monitoring lets the event tap
        // keep seeing Command/Option while another app is frontmost.
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
                DispatchQueue.main.async {
                    granted ? self?.startRecording() : self?.showError("Microphone permission missing")
                }
            }
            return
        }
        if !status.speechGranted {
            permissions.requestSpeech { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.startRecording() : self?.showError("Speech permission missing")
                }
            }
            return
        }

        initialTarget = focusDetector.currentEditableTarget()
        latestPartial = ""
        // Every recording gets a fresh run id. Async Speech/LLM callbacks must present the same
        // id before they can mutate state, so old callbacks cannot revive a canceled recording.
        runID += 1
        loggedFirstAudioLevel = false

        do {
            try transcriber.start(language: settings.language)
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

        let currentRunID = runID
        transcriber.finish { [weak self] text in
            self?.handleFinalTranscript(text, runID: currentRunID)
        }
    }

    func cancelRecording() {
        guard state.mode == .recording else {
            return
        }
        recorder.stop()
        DebugLog.event("recordingStop")
        transcriber.cancel()
        runID += 1
        initialTarget = nil
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
            // Invalidate any in-flight final Speech callback. Without this, a late callback could
            // paste text after the user pressed Esc or started a new recording.
            runID += 1
            initialTarget = nil
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

    private func handleFinalTranscript(_ text: String, runID: Int) {
        guard runID == self.runID else {
            return
        }
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            showError("No speech recognized")
            return
        }

        if settings.llmEnabled {
            // Refinement is allowed to improve obvious recognition mistakes, but it is not allowed
            // to block insertion forever. LLMRefiner owns the timeout/fallback to raw text.
            _ = state.transition(to: .refining)
            panel.showStatus("Refining...")
            onChange?()
            refiner.refine(raw) { [weak self] refined in
                guard let self, runID == self.runID else {
                    return
                }
                self.inject(refined.isEmpty ? raw : refined, runID: runID)
            }
        } else {
            inject(raw, runID: runID)
        }
    }

    private func inject(_ text: String, runID: Int) {
        guard runID == self.runID else {
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
        let target = focusDetector.currentEditableTarget() ?? initialTarget.flatMap {
            focusDetector.isValid($0) ? $0 : nil
        }

        guard target != nil || settings.keepClipboardWithoutTarget else {
            saveHistory(text, result: HistoryResult.failed, app: initialTarget?.app)
            showError("No editable field")
            return
        }

        let historyApp = target?.app ?? initialTarget?.app
        injector.inject(text, target: target) { [weak self] result in
            guard let self, runID == self.runID else {
                return
            }
            switch result {
            case .pasted:
                self.panel.showSuccess("Inserted")
                self.onUserMessage?("Inserted")
                self.saveHistory(text, result: HistoryResult.pasted, app: historyApp)
            case .copied:
                self.panel.showSuccess("复制")
                self.onUserMessage?("已复制到剪贴板")
                self.saveHistory(text, result: HistoryResult.copied, app: historyApp)
            }
            self.initialTarget = nil
            self.latestPartial = ""
            _ = self.state.transition(to: .idle)
            self.onChange?()
        }
    }

    private func showError(_ message: String) {
        recorder.stop()
        transcriber.cancel()
        // Error cleanup also invalidates callbacks. Speech and network callbacks may arrive after
        // UI error handling, and they must not reopen the panel or paste stale text.
        runID += 1
        initialTarget = nil
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
}
