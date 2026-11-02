import AppKit
import Foundation

@MainActor
final class AppController {
    let state = AppState()

    private let settings: SettingsStore
    private let permissions = PermissionManager()
    private let monitor = OptionKeyMonitor()
    private let recorder = AudioRecorder()
    private let outputMute = SystemOutputMute.shared
    private let transcriber = SpeechEngine()
    private let dictionary = DictionaryStore.shared
    private let stylePacks: StylePackStore
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
    private var recordingStartedAt: ContinuousClock.Instant?
    private var recordingStoppedAt: ContinuousClock.Instant?
    private var ignoreToggleCancellationUntil: ContinuousClock.Instant?
    private var speechContext: SpeechFocusContext?
    private var transcriberStart: Task<Void, Error>?

    var onChange: (@MainActor () -> Void)?
    var onUserMessage: (@MainActor (String) -> Void)?

    init(
        settings: SettingsStore = .shared,
        stylePacks: StylePackStore = .shared
    ) {
        self.settings = settings
        self.stylePacks = stylePacks
    }

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
        recorder.onLevels = { [weak self] levels in
            if levels.contains(where: { $0 > 0.02 }), self?.loggedFirstAudioLevel == false {
                self?.loggedFirstAudioLevel = true
                DebugLog.event("firstAudioLevel")
            }
            self?.panel.enqueueLevels(levels)
        }
        let transcriber = transcriber
        recorder.onBuffer = { buffer in
            transcriber.append(buffer)
        }
        prewarmSpeech()
    }

    /// Resolve the speech model before the first hotkey press so starting dictation stays fast.
    func prewarmSpeech() {
        guard permissions.speechGranted else {
            return
        }
        let language = settings.language
        let model = settings.speechModel
        Task { [transcriber] in
            await transcriber.prewarm(language: language, model: model)
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

        // Only the two cheap TCC reads here: the full status() probes an event tap, which does not
        // belong on the path between the hotkey and the microphone opening.
        if !permissions.microphoneGranted {
            permissions.requestMicrophone { [weak self] granted in
                granted ? self?.startRecording() : self?.showError("Microphone permission missing")
            }
            return
        }
        if !permissions.speechGranted {
            permissions.requestSpeech { [weak self] granted in
                granted ? self?.startRecording() : self?.showError("Speech permission missing")
            }
            return
        }

        let target = focusDetector.currentEditableTarget()
        panel.setPreferredAnchor(focusDetector.screenAnchor(for: target))
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

        // Open the microphone before analyzer setup and AX context reads. SpeechEngine holds audio
        // that arrives before the analyzer runs, so the first words are not clipped.
        transcriber.beginSession()
        do {
            try recorder.start()
        } catch {
            showError(error.localizedDescription)
            return
        }
        DebugLog.event("recordingStart")
        recordingStartedAt = clock.now
        guard state.transition(to: .recording) else {
            recorder.stop()
            transcriber.cancel()
            return
        }
        scheduleOutputMuteIfEnabled()
        panel.showRecording(text: "")
        panel.retryShowIfNeeded()
        DebugLog.event("panelShow")
        onChange?()

        let language = settings.language
        let model = settings.speechModel
        // AX → token extract: snippets stay on-device; terms → Apple Speech + optional LLM local context.
        let snippets = AXFocusedTextContextReader.snippets(from: target)
        let focusedTerms = SpeechContextTermExtractor.terms(from: snippets)
        let activePack = stylePacks.activePack()
        // Raw editor text leaves the Mac only with polishing on and the explicit opt-in.
        let cursorText = settings.llmEnabled && settings.shareCursorTextWithLLM
            ? AXFocusedTextContextReader.cursorText(from: target)
            : nil
        let context = SpeechFocusContext(
            appName: contextAppName(target: target, application: originalApplication),
            terms: SpeechFocusContext.vocabularyHints(
                focused: focusedTerms,
                seed: StylePackStore.seedTerms(for: activePack.id)
            ),
            cursorText: cursorText
        )
        speechContext = context
        let vocabulary = SpeechVocabulary.terms(
            stylePack: stylePacks.activePack(),
            userDictionary: dictionary,
            language: language,
            focusedTerms: focusedTerms
        )
        currentSession?.dictionaryTerms = dictionary.terms(for: language, limit: 500)
        currentSession?.correctionTerms = focusedTerms + StylePackStore.seedTerms(for: activePack.id)
        // Walking the whole window takes up to a few hundred milliseconds of AX IPC, so it runs in
        // the background while the user speaks; the result is only needed at finalize.
        if settings.readWindowText,
           let app = target?.app ?? originalApplication,
           app.bundleIdentifier != AppConstants.bundleIdentifier
        {
            let processIdentifier = app.processIdentifier
            currentSession?.windowTerms = Task.detached(priority: .userInitiated) { [target] in
                AXWindowTextReader.terms(processIdentifier: processIdentifier, focused: target)
            }
        }
        DebugLog.event("asrContextBuilt total=\(vocabulary.count) focused=\(focusedTerms.count) llmTerms=\(context.terms.count) usedAX=\(!snippets.isEmpty) target=\(target != nil) appContext=\(context.appName != nil) cursorChars=\((cursorText?.before.count ?? 0) + (cursorText?.after.count ?? 0))")

        let start = Task { [transcriber] in
            try await transcriber.start(language: language, model: model, contextualStrings: vocabulary)
        }
        transcriberStart = start
        Task { [weak self] in
            do {
                try await start.value
                DebugLog.event("speechAnalyzerReady")
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.isCurrentSession(sessionID) else {
                    return
                }
                self.showError(error.localizedDescription)
            }
        }
    }

    func stopAndTranscribe() {
        guard state.transition(to: .transcribing) else {
            return
        }
        recordingStoppedAt = clock.now
        ignoreToggleCancellationUntil = clock.now.advanced(by: .milliseconds(800))
        recorder.stop()
        scheduleOutputUnmute()
        DebugLog.event("recordingStop")
        // Partials already streamed during recording; finalize is usually sub-frame.
        // Skip "Transcribing..." — it only flashes before Polishing/Insert/hide.
        panel.stopWaveform()
        onChange?()

        guard let sessionID = currentSession?.id else {
            showError("No active session")
            return
        }
        // The analyzer may still be starting (held audio is replayed once it runs). Finalize only
        // after it is up; a failed start already reported its error and ended the session.
        let start = transcriberStart
        Task { [weak self] in
            do {
                try await start?.value
            } catch {
                return
            }
            guard let self, self.isCurrentSession(sessionID) else {
                return
            }
            // Started with the recording and time-bounded, so normally already finished.
            if let windowTerms = self.currentSession?.windowTerms {
                let terms = await windowTerms.value
                guard self.isCurrentSession(sessionID) else {
                    return
                }
                self.currentSession?.correctionTerms.append(contentsOf: terms)
            }
            self.transcriber.finish { [weak self] text in
                self?.handleFinalTranscript(text, sessionID: sessionID)
            }
        }
    }

    func cancelRecording() {
        guard state.mode == .recording else {
            return
        }
        recorder.stop()
        scheduleOutputUnmute()
        DebugLog.event("recordingStop")
        transcriber.cancel()
        refinementTask?.cancel()
        refinementTask = nil
        recordingStoppedAt = nil
        ignoreToggleCancellationUntil = nil
        transcriberStart = nil
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
            scheduleOutputUnmute()
            transcriber.cancel()
            refinementTask?.cancel()
            refinementTask = nil
            recordingStoppedAt = nil
            ignoreToggleCancellationUntil = nil
            transcriberStart = nil
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
        prewarmSpeech()
        onChange?()
    }

    func setLLMEnabled(_ enabled: Bool) {
        settings.llmEnabled = enabled
        onChange?()
    }

    func permissionStatus() -> PermissionStatus {
        permissions.status()
    }

    func requestMicrophonePermission(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        permissions.requestMicrophone(completion)
    }

    func requestSpeechPermission(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        permissions.requestSpeech(completion)
    }

    func requestAccessibilityPermission() {
        permissions.requestAccessibilityPrompt()
    }

    func requestInputMonitoringPermission() {
        permissions.requestInputMonitoring()
        permissions.openInputMonitoringSettings()
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

    func testConnection(completion: @escaping @MainActor @Sendable (Bool, String) -> Void) {
        refiner.testConnection(completion: completion)
    }

    private func handleFinalTranscript(_ text: String, sessionID: UUID) {
        guard isCurrentSession(sessionID) else {
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showError("No speech recognized")
            return
        }
        // The newer speech model ignores contextual strings, so known terms are applied here.
        let corrected = VocabularyCorrector.correct(
            trimmed,
            userTerms: currentSession?.dictionaryTerms ?? [],
            terms: currentSession?.correctionTerms ?? [],
            isKnownWord: SystemSpelling.isKnownWord
        )
        if corrected.corrections > 0 {
            DebugLog.event("vocabularyCorrections count=\(corrected.corrections)")
        }
        let raw = corrected.text

        let asrFinalizedIn = recordingStoppedAt.map { $0.duration(to: clock.now) }

        if settings.llmEnabled {
            // Refinement is allowed to improve obvious recognition mistakes, but it is not allowed
            // to block insertion forever. LLMRefiner owns the timeout/fallback to raw text.
            _ = state.transition(to: .refining)
            panel.showStatus("Polishing...")
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
        let duration = recordingStartedAt.flatMap { start in
            recordingStoppedAt.map { Self.seconds(start.duration(to: $0)) }
        }
        let learningContext = postEditLearner.prepare(
            target: target,
            insertedText: text,
            language: settings.language,
            enabled: settings.postEditLearningEnabled
        ).1
        injector.inject(text, target: target, fallbackApp: fallbackApp, pasteSent: { [weak self] in
            // Cmd+V is posted. The injector still waits before restoring the clipboard, but the
            // text is already appearing, so free the HUD and the hotkey now.
            guard let self, self.isCurrentSession(sessionID) else {
                return
            }
            self.panel.hide()
            DebugLog.event("panelHide")
            self.endInjectedSession()
        }) { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case .pasteAttempted:
                // The session already ended in pasteSent. Learning reads the pasted value, so it
                // starts here, unless a new dictation began in the meantime.
                if self.currentSession == nil, self.state.mode == .idle {
                    self.postEditLearner.start(learningContext)
                }
                self.recordUsage(text, duration: duration)
                self.saveHistory(text, result: HistoryResult.pasteAttempted, app: historyApp, duration: duration)
                self.onChange?()
            case .copied:
                guard self.isCurrentSession(sessionID) else {
                    return
                }
                self.panel.showSuccess("Copied to clipboard")
                self.onUserMessage?("Copied to clipboard")
                self.recordUsage(text, duration: duration)
                self.saveHistory(text, result: HistoryResult.copied, app: historyApp, duration: duration)
                self.endInjectedSession()
            }
        }
    }

    private func endInjectedSession() {
        refinementTask = nil
        recordingStoppedAt = nil
        ignoreToggleCancellationUntil = nil
        transcriberStart = nil
        currentSession = nil
        latestPartial = ""
        speechContext = nil
        _ = state.transition(to: .idle)
        onChange?()
    }

    private func showError(_ message: String) {
        recorder.stop()
        scheduleOutputUnmute()
        transcriber.cancel()
        refinementTask?.cancel()
        refinementTask = nil
        recordingStoppedAt = nil
        ignoreToggleCancellationUntil = nil
        transcriberStart = nil
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

    func restoreOutputMuteOnTerminate() {
        outputMute.unmuteIfNeededSync()
    }

    private func scheduleOutputMuteIfEnabled() {
        guard settings.muteOutputDuringRecording else {
            return
        }
        outputMute.muteIfNeededAsync()
    }

    private func scheduleOutputUnmute() {
        outputMute.unmuteIfNeededAsync()
    }


    private func saveHistory(_ text: String, result: HistoryResult, app: NSRunningApplication?, duration: TimeInterval? = nil) {
        guard settings.saveHistory,
              Self.shouldSaveHistory(bundleIdentifier: app?.bundleIdentifier)
        else {
            return
        }
        HistoryStore.shared.append(text: text, result: result, app: app, duration: duration)
    }

    private func recordUsage(_ text: String, duration: TimeInterval?) {
        var stats = settings.usageStats
        stats.record(text: text, duration: duration)
        settings.usageStats = stats
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }

    static func shouldSaveHistory(bundleIdentifier: String?) -> Bool {
        bundleIdentifier != AppConstants.bundleIdentifier
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
