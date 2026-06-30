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
        guard permissions.status().accessibilityGranted else {
            onUserMessage?("Accessibility required before hotkeys can start")
            return
        }
        if monitor.start() {
            monitorStarted = true
        } else {
            onUserMessage?("Unable to start global key monitor")
        }
    }

    func toggleRecording() {
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
