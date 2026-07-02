import AVFoundation
import Foundation
import Speech

struct TranscriptAccumulator {
    private(set) var finalizedTranscript = ""
    private(set) var volatileTranscript = ""

    var currentText: String {
        finalizedTranscript + volatileTranscript
    }

    mutating func update(text: String, isFinal: Bool) -> String {
        if isFinal {
            finalizedTranscript += text
            volatileTranscript = ""
        } else {
            // SpeechAnalyzer reports volatile text as the current unstable segment. Do not append
            // it, or long dictations duplicate the same tail every time the model revises it.
            volatileTranscript = text
        }
        return currentText
    }
}

final class LiveTranscriptionEngine: @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "com.aetherallan.ElegantWhisper.transcription")
    private var analyzer: SpeechAnalyzer?
    private var transcriber: Speech.SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var runTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var accumulator = TranscriptAccumulator()
    private var sessionID = 0
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var reservedLocale: Locale?

    var onPartial: ((String) -> Void)?
    var onStatus: ((String) -> Void)?

    func prepare(language: RecognitionLanguage) async throws {
        cancel()

        let expectedSessionID = beginSession()
        guard Speech.SpeechTranscriber.isAvailable else {
            throw AppError.message("Local SpeechAnalyzer transcription is not available")
        }
        guard let locale = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language.rawValue)) else {
            throw AppError.message("SpeechAnalyzer does not support \(language.rawValue)")
        }

        try await reserve(locale: locale, sessionID: expectedSessionID)

        let transcriber = Speech.SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        let modules: [any SpeechModule] = [transcriber]

        do {
            try await installAssetsIfNeeded(for: modules, sessionID: expectedSessionID)

            let bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
            let analyzer = SpeechAnalyzer(
                modules: modules,
                options: .init(priority: .userInitiated, modelRetention: .lingering)
            )
            try await analyzer.prepareToAnalyze(in: bestFormat)

            let stillCurrent = stateQueue.sync { sessionID == expectedSessionID }
            guard stillCurrent else {
                throw CancellationError()
            }
            stateQueue.sync {
                self.analyzer = analyzer
                self.transcriber = transcriber
                self.targetFormat = bestFormat
            }
        } catch {
            releaseReservation(sessionID: expectedSessionID)
            throw error
        }
    }

    func start() async throws {
        let stream = AsyncStream<AnalyzerInput>(bufferingPolicy: .bufferingNewest(2_048)) { [weak self] continuation in
            self?.stateQueue.sync {
                self?.continuation = continuation
            }
        }

        let prepared = stateQueue.sync { () -> (SpeechAnalyzer?, Speech.SpeechTranscriber?, Int) in
            (analyzer, transcriber, sessionID)
        }
        guard let analyzer = prepared.0, let transcriber = prepared.1 else {
            throw AppError.message("SpeechAnalyzer is not prepared")
        }
        let expectedSessionID = prepared.2

        let resultsTask = Task { [weak self, transcriber] in
            guard let self else { return }
            await self.consumeResults(from: transcriber, sessionID: expectedSessionID)
        }
        let runTask = Task { [weak self, analyzer, stream] in
            guard let self else { return }
            await self.runAnalyzer(analyzer, stream: stream, sessionID: expectedSessionID)
        }
        stateQueue.sync {
            self.resultsTask = resultsTask
            self.runTask = runTask
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let prepared = stateQueue.sync { () -> (AsyncStream<AnalyzerInput>.Continuation?, AVAudioPCMBuffer?) in
            (continuation, analyzerInputBuffer(from: buffer))
        }

        guard let converted = prepared.1 else {
            DebugLog.event("audioBufferDropped")
            return
        }
        prepared.0?.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async -> String {
        let snapshot = stateQueue.sync { () -> (Int, AsyncStream<AnalyzerInput>.Continuation?, Task<Void, Never>?, Task<Void, Never>?) in
            (sessionID, continuation, runTask, resultsTask)
        }

        snapshot.1?.finish()

        // The normal path waits for SpeechAnalyzer to finalize and for the results sequence to
        // exit. The timeout is a state-machine safety valve: if Apple's async sequence stalls,
        // ElegantWhisper still returns the latest recognized text instead of staying stuck.
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            snapshot.2?.cancel()
            snapshot.3?.cancel()
        }
        await snapshot.2?.value
        await snapshot.3?.value
        timeout.cancel()

        return finishSession(sessionID: snapshot.0)
    }

    func cancel() {
        let locale = stateQueue.sync { () -> Locale? in
            continuation?.finish()
            continuation = nil
            runTask?.cancel()
            runTask = nil
            resultsTask?.cancel()
            resultsTask = nil
            analyzer = nil
            transcriber = nil
            accumulator = TranscriptAccumulator()
            targetFormat = nil
            converter = nil
            let locale = reservedLocale
            reservedLocale = nil
            sessionID += 1
            return locale
        }

        release(locale)
    }

    private func beginSession() -> Int {
        stateQueue.sync {
            accumulator = TranscriptAccumulator()
            analyzer = nil
            transcriber = nil
            continuation = nil
            runTask = nil
            resultsTask = nil
            targetFormat = nil
            converter = nil
            sessionID += 1
            return sessionID
        }
    }

    private func reserve(locale: Locale, sessionID expectedSessionID: Int) async throws {
        guard try await AssetInventory.reserve(locale: locale) else {
            throw AppError.message("Cannot reserve local speech model for \(locale.identifier)")
        }

        let stillCurrent = stateQueue.sync { sessionID == expectedSessionID }
        guard stillCurrent else {
            release(locale)
            throw CancellationError()
        }
        stateQueue.sync {
            reservedLocale = locale
        }
    }

    private func installAssetsIfNeeded(for modules: [any SpeechModule], sessionID expectedSessionID: Int) async throws {
        switch await AssetInventory.status(forModules: modules) {
        case .installed:
            return
        case .unsupported:
            throw AppError.message("Local speech model is unsupported for this language")
        case .supported, .downloading:
            DispatchQueue.main.async { [weak self] in
                guard self?.isCurrentSession(expectedSessionID) == true else { return }
                self?.onStatus?("Preparing local speech model...")
            }
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
                return
            }
            try await request.downloadAndInstall()
        @unknown default:
            throw AppError.message("Unknown local speech model status")
        }
    }

    private func runAnalyzer(_ analyzer: SpeechAnalyzer, stream: AsyncStream<AnalyzerInput>, sessionID expectedSessionID: Int) async {
        do {
            _ = try await analyzer.analyzeSequence(stream)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch is CancellationError {
            return
        } catch {
            DebugLog.event("speechAnalyzerFailed")
        }

        let continuation = stateQueue.sync { () -> AsyncStream<AnalyzerInput>.Continuation? in
            sessionID == expectedSessionID ? self.continuation : nil
        }
        continuation?.finish()
    }

    private func consumeResults(from transcriber: Speech.SpeechTranscriber, sessionID expectedSessionID: Int) async {
        do {
            for try await result in transcriber.results {
                let currentText = stateQueue.sync { () -> String? in
                    guard sessionID == expectedSessionID else {
                        return nil
                    }
                    return accumulator.update(text: String(result.text.characters), isFinal: result.isFinal)
                }
                guard let currentText else {
                    return
                }

                DispatchQueue.main.async { [weak self] in
                    guard self?.isCurrentSession(expectedSessionID) == true else { return }
                    self?.onPartial?(currentText)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            DebugLog.event("speechResultsFailed")
        }
    }

    private func finishSession(sessionID expectedSessionID: Int) -> String {
        let result = stateQueue.sync { () -> (String, Locale?) in
            guard sessionID == expectedSessionID else {
                return (accumulator.currentText, nil)
            }
            let text = accumulator.currentText
            analyzer = nil
            transcriber = nil
            continuation = nil
            runTask = nil
            resultsTask = nil
            targetFormat = nil
            converter = nil
            let locale = reservedLocale
            reservedLocale = nil
            sessionID += 1
            return (text, locale)
        }

        release(result.1)
        return result.0
    }

    private func releaseReservation(sessionID expectedSessionID: Int) {
        let locale = stateQueue.sync { () -> Locale? in
            guard sessionID == expectedSessionID else {
                return nil
            }
            let locale = reservedLocale
            reservedLocale = nil
            return locale
        }

        release(locale)
    }

    private func release(_ locale: Locale?) {
        guard let locale else {
            return
        }
        Task {
            _ = await AssetInventory.release(reservedLocale: locale)
        }
    }

    private func isCurrentSession(_ expectedSessionID: Int) -> Bool {
        stateQueue.sync {
            sessionID == expectedSessionID
        }
    }

    private func analyzerInputBuffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let targetFormat else {
            return copyBuffer(buffer)
        }
        guard !formatsMatch(buffer.format, targetFormat) else {
            return copyBuffer(buffer)
        }

        if converter == nil ||
            !formatsMatch(converter!.inputFormat, buffer.format) ||
            !formatsMatch(converter!.outputFormat, targetFormat)
        {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter,
              let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: convertedCapacity(from: buffer, to: targetFormat)
              )
        else {
            return nil
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil else {
            return nil
        }
        return output
    }

    private func convertedCapacity(from buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioFrameCount {
        let ratio = format.sampleRate / buffer.format.sampleRate
        return max(1, AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32)
    }

    private func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate &&
            lhs.channelCount == rhs.channelCount &&
            lhs.commonFormat == rhs.commonFormat &&
            lhs.isInterleaved == rhs.isInterleaved
    }

    private func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength

        // AnalyzerInput retains the buffer object and consumes it asynchronously. Copying here
        // keeps the audio tap free to return immediately without depending on AVAudioEngine's
        // internal buffer lifetime.
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
            guard let source = sourceBuffers[index].mData,
                  let destination = destinationBuffers[index].mData
            else {
                continue
            }
            memcpy(destination, source, Int(sourceBuffers[index].mDataByteSize))
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }
        return copy
    }
}
