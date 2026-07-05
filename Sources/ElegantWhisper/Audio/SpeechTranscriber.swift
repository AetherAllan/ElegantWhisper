import AVFoundation
import Foundation
import Speech

// SpeechAnalyzer is async, while AVAudioEngine still delivers microphone buffers
// synchronously on its realtime tap. This wrapper keeps the old app-facing
// lifecycle and serializes mutable analyzer state through `queue`.
final class SpeechTranscriber: @unchecked Sendable {
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

    var onPartial: (@MainActor @Sendable (String) -> Void)?
    var onUnexpectedStop: (@MainActor @Sendable (String) -> Void)?

    func start(language: RecognitionLanguage, contextualStrings: [String] = []) async throws {
        cancel()
        let currentSessionID = queue.sync { () -> Int in
            sessionID += 1
            finalizedText = ""
            volatileText = ""
            completedEarly = false
            delivered = false
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            return sessionID
        }

        let requestedLocale = Locale(identifier: language.rawValue)
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw AppError.message("Dictation is unavailable for \(language.rawValue)")
        }
        try ensureCurrentSession(currentSessionID)

        let module = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        let analyzer = SpeechAnalyzer(modules: [module])
        guard let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw AppError.message("No compatible SpeechAnalyzer audio format")
        }
        try ensureCurrentSession(currentSessionID)
        try await ensureModelInstalled(for: module, locale: locale)
        try ensureCurrentSession(currentSessionID)

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
            throw error
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        queue.sync {
            guard !delivered,
                  let continuation = inputContinuation,
                  let analyzerFormat,
                  let converted = convertedBuffer(buffer, to: analyzerFormat)
            else {
                return
            }
            continuation.yield(AnalyzerInput(buffer: converted))
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

    private func makeResultsTask(module: DictationTranscriber, sessionID expectedSessionID: Int) -> Task<Void, Never> {
        Task { [weak self, module] in
            do {
                for try await result in module.results {
                    guard !Task.isCancelled else { return }
                    self?.handleResult(
                        String(result.text.characters),
                        isFinal: result.isFinal,
                        sessionID: expectedSessionID
                    )
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

        Task { @MainActor in
            state.5?(text)
        }
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

    private func ensureModelInstalled(for module: DictationTranscriber, locale: Locale) async throws {
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
