import AVFoundation
import Foundation
import Speech

// SpeechAnalyzer is async, while AVAudioEngine still delivers microphone buffers
// synchronously on its realtime tap. This wrapper keeps the old app-facing
// lifecycle and serializes mutable analyzer state through `queue`.
//
// Analyzer setup can take hundreds of milliseconds (longer if a model must be
// installed), so callers open a session with `beginSession()` and start the
// microphone first. Audio that arrives before the analyzer is running is held
// in `pendingBuffers` and replayed in order once `start` installs the input stream.
final class SpeechEngine: @unchecked Sendable {
    private struct PreparedSetup {
        let language: RecognitionLanguage
        let requestedModel: SpeechRecognitionModel
        let model: SpeechRecognitionModel
        let locale: Locale
        let audioFormat: AVAudioFormat
    }

    private enum Module {
        case speech(Speech.SpeechTranscriber)
        case dictation(DictationTranscriber)

        init(model: SpeechRecognitionModel, locale: Locale) {
            switch model {
            case .speech:
                self = .speech(Speech.SpeechTranscriber(locale: locale, preset: .progressiveTranscription))
            case .dictation:
                self = .dictation(DictationTranscriber(locale: locale, preset: .progressiveShortDictation))
            }
        }

        var speechModule: any SpeechModule {
            switch self {
            case .speech(let module): module
            case .dictation(let module): module
            }
        }

        static func supportedLocale(model: SpeechRecognitionModel, equivalentTo locale: Locale) async -> Locale? {
            switch model {
            case .speech:
                guard Speech.SpeechTranscriber.isAvailable else { return nil }
                return await Speech.SpeechTranscriber.supportedLocale(equivalentTo: locale)
            case .dictation:
                return await DictationTranscriber.supportedLocale(equivalentTo: locale)
            }
        }
    }

    private static let maxPendingSeconds: Double = 30

    private let queue = DispatchQueue(label: "com.aetherallan.ElegantWhisper.speech-transcriber")
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var finalizeTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var finalCompletion: (@MainActor @Sendable (String) -> Void)?
    private var finalizedText = ""
    private var volatileText = ""
    private var completedEarly = false
    private var delivered = false
    private var sessionID = 0
    private var timeoutWorkItem: DispatchWorkItem?
    private var isBuffering = false
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var pendingFrameCount: AVAudioFramePosition = 0
    private var preparedSetup: PreparedSetup?

    var onPartial: (@MainActor @Sendable (String) -> Void)?
    var onUnexpectedStop: (@MainActor @Sendable (String) -> Void)?

    /// Opens a new session that holds microphone audio until `start` has the analyzer running.
    /// Call this before starting the recorder so speech during analyzer setup is not lost.
    func beginSession() {
        cancel()
        queue.sync {
            isBuffering = true
        }
    }

    /// Resolves the locale, audio format, and model install for `language` ahead of the first
    /// dictation so the hotkey path does not pay for it.
    func prewarm(language: RecognitionLanguage, model: SpeechRecognitionModel) async {
        do {
            _ = try await setup(for: language, model: model)
            DebugLog.event("speechPrewarmed")
        } catch {
            DebugLog.event("speechPrewarmFailed")
        }
    }

    func start(
        language: RecognitionLanguage,
        model: SpeechRecognitionModel,
        contextualStrings: [String] = []
    ) async throws {
        if !queue.sync(execute: { isBuffering }) {
            beginSession()
        }
        let currentSessionID = queue.sync { sessionID }
        try ensureCurrentSession(currentSessionID)

        let setup: PreparedSetup
        do {
            setup = try await self.setup(for: language, model: model)
        } catch {
            try ensureCurrentSession(currentSessionID)
            throw error
        }
        try ensureCurrentSession(currentSessionID)

        let audioFormat = setup.audioFormat
        let module = Module(model: setup.model, locale: setup.locale)
        let analyzer = SpeechAnalyzer(modules: [module.speechModule])

        let context = AnalysisContext()
        context.contextualStrings[.general] = contextualStrings
        try await analyzer.setContext(context)
        try ensureCurrentSession(currentSessionID)

        let input = AsyncStream<AnalyzerInput>.makeStream()
        let resultsTask = makeResultsTask(module: module, sessionID: currentSessionID)
        let shouldStart = queue.sync { () -> Bool in
            guard sessionID == currentSessionID, !delivered else {
                return false
            }
            self.analyzer = analyzer
            self.inputContinuation = input.continuation
            self.resultsTask = resultsTask
            self.analyzerFormat = audioFormat
            self.converter = nil
            self.converterInputFormat = nil
            // Replay held audio before any new tap buffer can reach append(); both run on `queue`.
            let held = pendingBuffers
            pendingBuffers = []
            pendingFrameCount = 0
            isBuffering = false
            for buffer in held {
                if let converted = convertedBuffer(buffer, to: audioFormat) {
                    input.continuation.yield(AnalyzerInput(buffer: converted))
                }
            }
            DebugLog.event("speechHeldAudioReplayed buffers=\(held.count)")
            return true
        }
        guard shouldStart else {
            resultsTask.cancel()
            input.continuation.finish()
            await analyzer.cancelAndFinishNow()
            throw CancellationError()
        }

        do {
            try await analyzer.start(inputSequence: input.stream)
            try ensureCurrentSession(currentSessionID)
        } catch {
            resultsTask.cancel()
            input.continuation.finish()
            await analyzer.cancelAndFinishNow()
            // A cached setup may be stale (for example, the model was removed). Re-resolve next time.
            queue.sync {
                preparedSetup = nil
            }
            throw error
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        queue.sync {
            guard !delivered else {
                return
            }
            if let continuation = inputContinuation, let analyzerFormat {
                if let converted = convertedBuffer(buffer, to: analyzerFormat) {
                    continuation.yield(AnalyzerInput(buffer: converted))
                }
                return
            }
            let maxFrames = AVAudioFramePosition(buffer.format.sampleRate * Self.maxPendingSeconds)
            guard isBuffering,
                  pendingFrameCount < maxFrames,
                  let copy = buffer.deepCopy()
            else {
                return
            }
            pendingBuffers.append(copy)
            pendingFrameCount += AVAudioFramePosition(copy.frameLength)
        }
    }

    func finish(_ completion: @escaping @MainActor @Sendable (String) -> Void) {
        let state = queue.sync { () -> (Int, Bool, String, SpeechAnalyzer?) in
            finalCompletion = completion
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            inputContinuation?.finish()
            let text = finalizedText + volatileText
            return (sessionID, completedEarly || analyzer == nil, text, analyzer)
        }

        if state.1 {
            completeOnce(state.2, sessionID: state.0)
            return
        }

        if let analyzer = state.3 {
            let expectedSessionID = state.0
            let task = Task { [weak self, analyzer] in
                do {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                } catch {
                    self?.handleResultsEnded(error: error, sessionID: expectedSessionID)
                }
            }
            queue.sync {
                if sessionID == expectedSessionID, !delivered {
                    finalizeTask = task
                } else {
                    task.cancel()
                }
            }
        }

        let expectedSessionID = state.0
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let timeoutState = self.queue.sync { () -> (Bool, String) in
                (self.sessionID == expectedSessionID && !self.delivered, self.finalizedText + self.volatileText)
            }
            if timeoutState.0 {
                self.completeOnce(timeoutState.1, sessionID: expectedSessionID)
            }
        }
        queue.sync {
            timeoutWorkItem = workItem
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: workItem)
    }

    func cancel() {
        let state = queue.sync { () -> (DispatchWorkItem?, Task<Void, Never>?, Task<Void, Never>?, AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?) in
            let state = (timeoutWorkItem, resultsTask, finalizeTask, inputContinuation, analyzer)
            timeoutWorkItem = nil
            resultsTask = nil
            finalizeTask = nil
            inputContinuation = nil
            analyzer = nil
            analyzerFormat = nil
            converter = nil
            converterInputFormat = nil
            finalCompletion = nil
            finalizedText = ""
            volatileText = ""
            completedEarly = false
            delivered = false
            isBuffering = false
            pendingBuffers = []
            pendingFrameCount = 0
            sessionID += 1
            return state
        }
        state.0?.cancel()
        state.1?.cancel()
        state.2?.cancel()
        state.3?.finish()
        if let analyzer = state.4 {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private func makeResultsTask(module: Module, sessionID expectedSessionID: Int) -> Task<Void, Never> {
        Task { [weak self, module] in
            do {
                switch module {
                case .speech(let transcriber):
                    for try await result in transcriber.results {
                        guard !Task.isCancelled else { return }
                        self?.handleResult(
                            String(result.text.characters),
                            isFinal: result.isFinal,
                            sessionID: expectedSessionID
                        )
                    }
                case .dictation(let transcriber):
                    for try await result in transcriber.results {
                        guard !Task.isCancelled else { return }
                        self?.handleResult(
                            String(result.text.characters),
                            isFinal: result.isFinal,
                            sessionID: expectedSessionID
                        )
                    }
                }
                self?.handleResultsEnded(error: nil, sessionID: expectedSessionID)
            } catch {
                self?.handleResultsEnded(error: error, sessionID: expectedSessionID)
            }
        }
    }

    private func handleResult(_ text: String, isFinal: Bool, sessionID expectedSessionID: Int) {
        let partial = queue.sync { () -> String? in
            guard sessionID == expectedSessionID, !delivered else {
                return nil
            }
            if isFinal {
                finalizedText += text
                volatileText = ""
            } else {
                volatileText = text
            }
            return finalizedText + volatileText
        }
        guard let partial else { return }

        let handler = onPartial
        Task { @MainActor [weak self] in
            guard self?.isCurrentSession(expectedSessionID) == true else {
                return
            }
            handler?(partial)
        }
    }

    private func handleResultsEnded(error: Error?, sessionID expectedSessionID: Int) {
        let state = queue.sync { () -> (Bool, Bool, String, String) in
            guard sessionID == expectedSessionID, !delivered else {
                return (false, false, "", "")
            }
            completedEarly = true
            let text = finalizedText + volatileText
            let message = error?.localizedDescription ?? "Speech recognition ended before recording stopped"
            return (true, finalCompletion != nil, text, message)
        }
        guard state.0 else { return }

        if state.1 {
            completeOnce(state.2, sessionID: expectedSessionID)
        } else {
            let handler = onUnexpectedStop
            Task { @MainActor [weak self] in
                guard self?.isCurrentSession(expectedSessionID) == true else {
                    return
                }
                handler?(state.3)
            }
        }
    }

    private func completeOnce(_ text: String, sessionID expectedSessionID: Int) {
        let state = queue.sync { () -> (DispatchWorkItem?, Task<Void, Never>?, Task<Void, Never>?, AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?, (@MainActor @Sendable (String) -> Void)?)? in
            guard sessionID == expectedSessionID, !delivered else {
                return nil
            }
            delivered = true
            sessionID += 1
            let state = (timeoutWorkItem, resultsTask, finalizeTask, inputContinuation, analyzer, finalCompletion)
            timeoutWorkItem = nil
            resultsTask = nil
            finalizeTask = nil
            inputContinuation = nil
            analyzer = nil
            analyzerFormat = nil
            converter = nil
            converterInputFormat = nil
            finalCompletion = nil
            isBuffering = false
            pendingBuffers = []
            pendingFrameCount = 0
            return state
        }

        guard let state else { return }
        state.0?.cancel()
        state.1?.cancel()
        state.2?.cancel()
        state.3?.finish()
        if let analyzer = state.4 {
            Task { await analyzer.cancelAndFinishNow() }
        }

        let finalText = Self.normalizedTranscript(text)
        Task { @MainActor in
            state.5?(finalText)
        }
    }

    /// The newer model joins segments with a space even before full-width punctuation
    /// ("开会 ，记得"). Drop whitespace that sits against CJK punctuation.
    static func normalizedTranscript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+(?=[，。！？；：、）」』》])", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?<=[，。！？；：、（「『《])\\s+", with: "", options: .regularExpression)
    }

    private func ensureCurrentSession(_ expectedSessionID: Int) throws {
        let current = queue.sync {
            sessionID == expectedSessionID && !delivered
        }
        if !current {
            throw CancellationError()
        }
    }

    private func isCurrentSession(_ expectedSessionID: Int) -> Bool {
        queue.sync {
            sessionID == expectedSessionID && !delivered
        }
    }

    private func setup(for language: RecognitionLanguage, model requestedModel: SpeechRecognitionModel) async throws -> PreparedSetup {
        if let cached = queue.sync(execute: { preparedSetup }),
           cached.language == language,
           cached.requestedModel == requestedModel
        {
            return cached
        }

        let requestedLocale = Locale(identifier: language.rawValue)
        var model = requestedModel
        var resolvedLocale = await Module.supportedLocale(model: model, equivalentTo: requestedLocale)
        if resolvedLocale == nil, model == .speech {
            // The newer model is unavailable on some hardware and covers fewer locales.
            DebugLog.event("speechModelFallback:\(language.rawValue)")
            model = .dictation
            resolvedLocale = await Module.supportedLocale(model: model, equivalentTo: requestedLocale)
        }
        guard let locale = resolvedLocale else {
            throw AppError.message("Dictation is unavailable for \(language.rawValue)")
        }
        let module = Module(model: model, locale: locale).speechModule
        guard let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw AppError.message("No compatible SpeechAnalyzer audio format")
        }
        try await ensureModelInstalled(for: module, locale: locale)

        let setup = PreparedSetup(
            language: language,
            requestedModel: requestedModel,
            model: model,
            locale: locale,
            audioFormat: audioFormat
        )
        queue.sync {
            preparedSetup = setup
        }
        return setup
    }

    private func ensureModelInstalled(for module: any SpeechModule, locale: Locale) async throws {
        let modules: [any SpeechModule] = [module]
        let status = await AssetInventory.status(forModules: modules)
        guard status != .unsupported else {
            throw AppError.message("Dictation is unsupported for \(locale.identifier)")
        }
        guard status != .installed else {
            return
        }

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw AppError.message("Cannot install speech model for \(locale.identifier): \(error.localizedDescription)")
        }

        let finalStatus = await AssetInventory.status(forModules: modules)
        if finalStatus == .unsupported {
            throw AppError.message("Dictation is unsupported for \(locale.identifier)")
        }
    }

    private func convertedBuffer(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        if audioFormatsMatch(buffer.format, targetFormat) {
            return buffer
        }

        if converter == nil || converterInputFormat.map({ !audioFormatsMatch($0, buffer.format) }) == true {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterInputFormat = buffer.format
        }
        guard let converter else {
            return nil
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(max(1, ceil(Double(buffer.frameLength) * ratio))) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        let inputState = ConverterInputState(buffer: buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if inputState.didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputState.didProvideInput = true
            outStatus.pointee = .haveData
            return inputState.buffer
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return output.frameLength > 0 ? output : nil
        case .error:
            DebugLog.event("speechAudioConvertFailed")
            return nil
        @unknown default:
            return nil
        }
    }

    private func audioFormatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate &&
            lhs.channelCount == rhs.channelCount &&
            lhs.commonFormat == rhs.commonFormat &&
            lhs.isInterleaved == rhs.isInterleaved
    }
}

private final class ConverterInputState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private extension AVAudioPCMBuffer {
    /// The tap may reuse its buffer after the callback returns, so held audio gets its own storage.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else {
                continue
            }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}
