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
        permissions.requestMissingPermissions()
        if !monitor.start() {
            permissions.requestAccessibilityPrompt()
            let status = permissions.status()
            if !status.accessibilityGranted {
                onUserMessage?("Accessibility required. Enable in System Settings, then quit and reopen.")
            }
        }

        transcriber.onPartial = { [weak self] text in
            self?.latestPartial = text
            self?.panel.updatePartial(text)
        }
        recorder.onLevel = { [weak self] level in
            self?.panel.updateLevel(level)
        }
        recorder.onBuffer = { [weak self] buffer in
            self?.transcriber.append(buffer)
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

        do {
            try transcriber.start(language: settings.language)
            try recorder.start()
            _ = state.transition(to: .recording)
            panel.showRecording(text: "")
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
        transcriber.cancel()
        runID += 1
        initialTarget = nil
        latestPartial = ""
        _ = state.transition(to: .idle)
        panel.hide()
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
            showError("No editable field")
            return
        }

        injector.inject(text, target: target) { [weak self] result in
            guard let self, runID == self.runID else {
                return
            }
            switch result {
            case .pasted:
                self.panel.showSuccess("Inserted")
                self.onUserMessage?("Inserted")
            case .copied:
                self.panel.showSuccess("Copied")
                self.onUserMessage?("Text copied to clipboard")
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
        onUserMessage?(message)
        onChange?()
    }
}
