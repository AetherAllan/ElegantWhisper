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
    private let stylePacks = StylePackStore.shared
    private let focusDetector = FocusDetector()
    private let inputSourceManager = InputSourceManager()
    private let postEditLearner = PostEditLearner()
    private let panel = FloatingPanel()
    private let clock = ContinuousClock()
    private lazy var refiner = LLMRefiner(settings: settings)
    private lazy var injector = TextInjector(focusDetector: focusDetector, inputSourceManager: inputSourceManager)

    private var currentSession: DictationSession?
    private var latestPartial = ""
    private var monitorStarted = false
    private var loggedFirstAudioLevel = false
    private var refinementTask: LLMRefinementTask?
    private var recordingStoppedAt: ContinuousClock.Instant?
    private var ignoreToggleCancellationUntil: ContinuousClock.Instant?
    private var speechContext: SpeechFocusContext?

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
        // background Right Option detection. Without both, the app appears to work only while
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
        case .preparing, .transcribing, .refining:
            if let until = ignoreToggleCancellationUntil, clock.now < until {
                // The same physical Right Option release can occasionally surface as a second
                // toggle just after we leave recording. Do not let that stale hotkey cancel ASR/LLM
                // before insertion. Esc still goes through cancelCurrentOperation immediately.
                DebugLog.event("shortcutIgnoredDuringFinalize")
                return
            }
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

        let target = focusDetector.currentEditableTarget()
        let originalApplication = NSWorkspace.shared.frontmostApplication
        currentSession = DictationSession(
            originalTarget: target,
            originalApplication: originalApplication
        )
        postEditLearner.stop()
        latestPartial = ""
        refinementTask?.cancel()
        refinementTask = nil
        loggedFirstAudioLevel = false
        recordingStoppedAt = nil
        ignoreToggleCancellationUntil = nil

        guard state.transition(to: .preparing), let sessionID = currentSession?.id else {
            return
        }
        let language = settings.language
        let snippets = AXFocusedTextContextReader.snippets(from: target)
        let focusedTerms = SpeechContextTermExtractor.terms(from: snippets)
        let context = SpeechFocusContext(
            appName: contextAppName(target: target, application: originalApplication),
            terms: focusedTerms
        )
        speechContext = context
        let vocabulary = SpeechVocabulary.terms(
            stylePack: stylePacks.activePack(),
            userDictionary: dictionary,
            language: language,
            focusedTerms: focusedTerms
        )
        DebugLog.event("asrContextBuilt total=\(vocabulary.count) focused=\(focusedTerms.count) llmTerms=\(context.terms.count) usedAX=\(!snippets.isEmpty)")
        panel.showStatus("Preparing...")
        panel.retryShowIfNeeded()
        DebugLog.event("panelShow")
        onChange?()

        Task { [weak self] in
            await self?.prepareRecording(language: language, contextualStrings: vocabulary, sessionID: sessionID)
        }
    }

    private func prepareRecording(
        language: RecognitionLanguage,
        contextualStrings: [String],
        sessionID: UUID
    ) async {
        do {
            try await transcriber.start(language: language, contextualStrings: contextualStrings)
            guard isCurrentSession(sessionID), state.mode == .preparing else {
                transcriber.cancel()
                return
            }
            try recorder.start()
            DebugLog.event("recordingStart")
            guard state.transition(to: .recording) else {
                recorder.stop()
                transcriber.cancel()
                return
            }
            panel.showRecording(text: "")
            onChange?()
        } catch {
            guard isCurrentSession(sessionID) else {
                return
            }
            showError(error.localizedDescription)
        }
    }

    func stopAndTranscribe() {
        guard state.transition(to: .transcribing) else {
            return
        }
        recordingStoppedAt = clock.now
        ignoreToggleCancellationUntil = clock.now.advanced(by: .milliseconds(800))
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
        recordingStoppedAt = nil
        ignoreToggleCancellationUntil = nil
        currentSession = nil
        postEditLearner.stop()
        latestPartial = ""
        speechContext = nil
        _ = state.transition(to: .idle)
        panel.hide()
        DebugLog.event("panelHide")
        onChange?()
    }

    func cancelCurrentOperation() {
        switch state.mode {
        case .recording:
            cancelRecording()
        case .preparing, .transcribing, .refining:
            recorder.stop()
            transcriber.cancel()
            refinementTask?.cancel()
            refinementTask = nil
            recordingStoppedAt = nil
            ignoreToggleCancellationUntil = nil
            currentSession = nil
            postEditLearner.stop()
            latestPartial = ""
            speechContext = nil
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

    func mainWindowController() -> MainWindowController {
        MainWindowController(settings: settings, refiner: refiner, controller: self)
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

        let asrFinalizedIn = recordingStoppedAt.map { $0.duration(to: clock.now) }

        if settings.llmEnabled {
            // Refinement is allowed to improve obvious recognition mistakes, but it is not allowed
            // to block insertion forever. LLMRefiner owns the timeout/fallback to raw text.
            _ = state.transition(to: .refining)
            panel.showStatus("Refining...")
            onChange?()
            refinementTask = refiner.refine(
                raw,
                speechContext: speechContext,
                asrFinalizedIn: asrFinalizedIn
            ) { [weak self] refined in
                guard let self, self.isCurrentSession(sessionID) else {
                    return
                }
                self.refinementTask = nil
                self.inject(refined.isEmpty ? raw : refined, sessionID: sessionID)
            }
        } else {
            inject(raw, sessionID: sessionID)
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
        let learningContext = postEditLearner.prepare(
            target: target,
            insertedText: text,
            language: settings.language,
            enabled: settings.postEditLearningEnabled
        ).1
        injector.inject(text, target: target, fallbackApp: fallbackApp) { [weak self] result in
            guard let self, self.isCurrentSession(sessionID) else {
                return
            }
            switch result {
            case .pasteAttempted:
                self.postEditLearner.start(learningContext)
                self.panel.hide()
                DebugLog.event("panelHide")
                self.saveHistory(text, result: HistoryResult.pasteAttempted, app: historyApp)
            case .copied:
                self.panel.showSuccess("复制")
                self.onUserMessage?("已复制到剪贴板")
                self.saveHistory(text, result: HistoryResult.copied, app: historyApp)
            }
            self.refinementTask = nil
            self.recordingStoppedAt = nil
            self.ignoreToggleCancellationUntil = nil
            self.currentSession = nil
            self.latestPartial = ""
            self.speechContext = nil
            _ = self.state.transition(to: .idle)
            self.onChange?()
        }
    }

    private func showError(_ message: String) {
        recorder.stop()
        transcriber.cancel()
        refinementTask?.cancel()
        refinementTask = nil
        recordingStoppedAt = nil
        ignoreToggleCancellationUntil = nil
        currentSession = nil
        postEditLearner.stop()
        latestPartial = ""
        speechContext = nil
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

    private func contextAppName(target: FocusTarget?, application: NSRunningApplication?) -> String? {
        let app = target?.app ?? application
        guard app?.bundleIdentifier != AppConstants.bundleIdentifier else {
            return nil
        }
        return app?.localizedName ?? app?.bundleIdentifier
    }

    private func isCurrentSession(_ id: UUID) -> Bool {
        currentSession?.id == id
    }
}
