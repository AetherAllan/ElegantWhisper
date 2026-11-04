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
    private let clip = AudioClipCollector()
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
        panel.onCancel = { [weak self] in
            self?.cancelCurrentOperation()
        }
        panel.onConfirm = { [weak self] in
            guard self?.state.mode == .recording else { return }
            self?.stopAndTranscribe()
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
        let clip = clip
        recorder.onBuffer = { buffer in
            transcriber.append(buffer)
            clip.append(buffer)
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
        // Online recognition uploads the whole recording after stop, so collect it from the
        // first buffer. The key is only read at stop to keep Keychain off this path.
        if settings.transcriptionProvider.service != nil {
            clip.begin()
        } else {
            clip.cancel()
        }
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
        warmOnlineConnections()
        panel.setTheme(settings.appTheme)
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
        let dictating = settings.llmEnabled && activePack.id == StylePackStore.dictatePackID
        let category = AppCategory(bundleIdentifier: (target?.app ?? originalApplication)?.bundleIdentifier)
        let context = SpeechFocusContext(
            appName: contextAppName(target: target, application: originalApplication),
            terms: SpeechFocusContext.vocabularyHints(
                focused: focusedTerms,
                seed: StylePackStore.seedTerms(for: activePack.id)
            ),
            cursorText: cursorText,
            toneHint: dictating && settings.dictateMatchesAppTone ? category?.toneHint : nil
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
        currentSession?.focusedTerms = focusedTerms
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
        startOnlineTranscriptionIfEnabled()
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
                guard let self else { return }
                if let online = self.currentSession?.onlineTranscription {
                    Task { await self.finishWithOnlineTranscript(online, onDeviceText: text, sessionID: sessionID) }
                } else {
                    self.handleFinalTranscript(text, sessionID: sessionID)
                }
            }
        }
    }

    /// Recording lasts seconds; opening the HTTPS connections now hides the handshake.
    private func warmOnlineConnections() {
        if let service = settings.transcriptionProvider.service {
            ConnectionWarmer.shared.warm(service.endpoint)
        }
        if settings.llmEnabled, let base = URL(string: settings.apiBaseURL) {
            ConnectionWarmer.shared.warm(base)
        }
    }

    /// Starts the upload right at stop, in parallel with on-device finalization.
    private func startOnlineTranscriptionIfEnabled() {
        let samples = clip.finish()
        let provider = settings.transcriptionProvider
        guard let service = provider.service, !samples.isEmpty, let session = currentSession else {
            return
        }
        let apiKey = settings.transcriptionKey(for: provider)
        guard !apiKey.isEmpty else {
            DebugLog.event("onlineTranscriptionSkipped:missingKey")
            onUserMessage?("Add your \(provider.title) API key in Settings → Recognition to use online recognition. Used on-device text.")
            return
        }
        let model = settings.transcriptionModel(for: provider)
        let language = settings.language
        let appName = speechContext?.appName
        // Your own terms first, then what is on screen, then the Style Pack list.
        let baseTerms = session.dictionaryTerms + session.focusedTerms
        let seedTerms = StylePackStore.seedTerms(for: stylePacks.activePack().id)
        let windowTerms = session.windowTerms
        let stoppedAt = clock.now
        let clock = clock
        currentSession?.onlineTranscription = Task.detached(priority: .userInitiated) {
            let onScreen = await windowTerms?.value ?? []
            let text = try await OnlineTranscriber.transcribe(
                samples: samples,
                language: language,
                terms: baseTerms + onScreen + seedTerms,
                appName: appName,
                service: service,
                model: model,
                apiKey: apiKey
            )
            let elapsed = stoppedAt.duration(to: clock.now).components
            let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
            DebugLog.event("onlineTranscriptionDone ms=\(milliseconds) chars=\(text.count)")
            return text
        }
    }

    private func finishWithOnlineTranscript(_ online: Task<String, Error>, onDeviceText: String, sessionID: UUID) async {
        // URLRequest's timeout only covers idle gaps; this caps the total wait for the user.
        let deadline = Task {
            try await Task.sleep(for: .seconds(OnlineTranscriber.timeout))
            online.cancel()
        }
        defer { deadline.cancel() }
        do {
            let text = try await online.value
            guard isCurrentSession(sessionID) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            handleFinalTranscript(trimmed.isEmpty ? onDeviceText : trimmed, sessionID: sessionID)
        } catch {
            guard isCurrentSession(sessionID) else { return }
            // Within a live session, cancellation can only come from the deadline above.
            let failure = error as? OnlineTranscriptionError
                ?? (error is CancellationError ? .timedOut : .network(error.localizedDescription))
            DebugLog.event("onlineTranscriptionFailed:\(failure.logName)")
            if failure != .tooShort {
                onUserMessage?("Online recognition failed (\(failure.localizedDescription)). Used on-device text.")
            }
            handleFinalTranscript(onDeviceText, sessionID: sessionID)
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
        clip.cancel()
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
            clip.cancel()
            currentSession?.onlineTranscription?.cancel()
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
            let modeName = refiner.isDictateActive ? "Dictate" : "Polishing"
            if settings.effectiveLLMAPIKey.isEmpty {
                currentSession?.warning = "\(modeName) needs an API key (Settings → Dictate)"
            }
            refinementTask = refiner.refine(
                raw,
                speechContext: speechContext,
                asrFinalizedIn: asrFinalizedIn
            ) { [weak self] refined in
                guard let self, self.isCurrentSession(sessionID) else {
                    return
                }
                if let failure = self.refinementTask?.configurationFailure {
                    self.currentSession?.warning = "\(modeName) didn't run: \(failure)"
                }
                self.refinementTask = nil
                self.inject(refined.isEmpty ? raw : refined, original: raw, sessionID: sessionID)
            }
        } else {
            inject(raw, sessionID: sessionID)
        }
    }

    /// `original` is the recognized text before an LLM rewrite, kept in History for comparison.
    private func inject(_ text: String, original: String? = nil, sessionID: UUID) {
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
            saveHistory(text, result: HistoryResult.failed, app: originalTarget?.app ?? originalApplication, original: original)
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
            if let warning = self.currentSession?.warning {
                // The text went in unchanged; say why instead of failing silently.
                self.panel.showError(warning)
                self.onUserMessage?(warning)
            } else {
                self.panel.hide()
                DebugLog.event("panelHide")
            }
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
                self.saveHistory(text, result: HistoryResult.pasteAttempted, app: historyApp, duration: duration, original: original)
                self.onChange?()
            case .copied:
                guard self.isCurrentSession(sessionID) else {
                    return
                }
                self.panel.showSuccess("Copied to clipboard")
                self.onUserMessage?("Copied to clipboard")
                self.recordUsage(text, duration: duration)
                self.saveHistory(text, result: HistoryResult.copied, app: historyApp, duration: duration, original: original)
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
        clip.cancel()
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


    private func saveHistory(
        _ text: String,
        result: HistoryResult,
        app: NSRunningApplication?,
        duration: TimeInterval? = nil,
        original: String? = nil
    ) {
        guard settings.saveHistory,
              Self.shouldSaveHistory(bundleIdentifier: app?.bundleIdentifier)
        else {
            return
        }
        HistoryStore.shared.append(text: text, result: result, app: app, duration: duration, originalText: original)
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
