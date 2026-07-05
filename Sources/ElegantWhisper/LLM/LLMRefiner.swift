import Foundation

private extension Duration {
    var milliseconds: Double {
        let components = components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

struct RefinementMetrics: Sendable {
    let asrFinalizedIn: Duration?
    let requestStartedAt: ContinuousClock.Instant
    var firstByteAt: ContinuousClock.Instant?
    var completedAt: ContinuousClock.Instant?

    func summaryLine() -> String {
        let asr = asrFinalizedIn.map(Self.formatMilliseconds) ?? "n/a"
        guard let firstByteAt, let completedAt else {
            return "polishMetrics ASR finalize: \(asr) | LLM TTFB: n/a | LLM generation: n/a | Total polish: n/a"
        }

        let ttfb = requestStartedAt.duration(to: firstByteAt)
        let generation = firstByteAt.duration(to: completedAt)
        let total = requestStartedAt.duration(to: completedAt)
        return "polishMetrics ASR finalize: \(asr) | LLM TTFB: \(Self.formatMilliseconds(ttfb)) | LLM generation: \(Self.formatMilliseconds(generation)) | Total polish: \(Self.formatSeconds(total))"
    }

    private static func formatMilliseconds(_ duration: Duration) -> String {
        "\(Int64(duration.milliseconds.rounded())) ms"
    }

    private static func formatSeconds(_ duration: Duration) -> String {
        String(format: "%.2f s", duration.milliseconds / 1_000)
    }
}

enum CorrectionRejectionReason: String {
    case empty
    case tooLong
    case languageChanged
    case editRatio
    case finishLength
}

struct LLMRefinerRequestContext: Sendable {
    let provider: LLMProvider
    let baseURL: URL
    let apiKey: String
    let model: String
    let timeout: TimeInterval
    let maxOutputTokens: Int
    let systemPrompt: String
    let transcript: String
    var outputFormat: LLMOutputFormat
}

final class LLMRefiner: Sendable {
    private let settings: SettingsStore
    private let stylePacks: StylePackStore
    private let capabilityState = LLMSessionCapabilityState()
    private let urlSession: URLSession

    init(
        settings: SettingsStore,
        stylePacks: StylePackStore = .shared,
        urlSession: URLSession = .shared
    ) {
        self.settings = settings
        self.stylePacks = stylePacks
        self.urlSession = urlSession
    }

    @discardableResult
    func refine(
        _ text: String,
        speechContext: SpeechFocusContext? = nil,
        asrFinalizedIn: Duration? = nil,
        completion: @escaping @MainActor @Sendable (String) -> Void
    ) -> LLMRefinementTask? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.llmEnabled else {
            DebugLog.event("llmRefineSkippedDisabled")
            Task { @MainActor in
                completion(text)
            }
            return nil
        }
        guard !trimmed.isEmpty else {
            DebugLog.event("llmRefineSkippedEmpty")
            Task { @MainActor in
                completion(text)
            }
            return nil
        }
        guard !settings.apiKey.isEmpty,
              let context = makeRequestContext(text: trimmed, speechContext: speechContext)
        else {
            DebugLog.event("llmRefineSkippedMissingSettings")
            Task { @MainActor in
                completion(text)
            }
            return nil
        }

        let requestStartedAt = ContinuousClock().now
        let metrics = RefinementMetrics(asrFinalizedIn: asrFinalizedIn, requestStartedAt: requestStartedAt)
        let codec = LLMProviderCodecRegistry.codec(for: context.provider)
        let task = LLMRefinementTask()

        DebugLog.event("llmRefineStarted")
        runProviderAttempt(
            codec: codec,
            context: context,
            originalText: text,
            trimmedText: trimmed,
            metrics: metrics,
            task: task,
            didFallbackStructured: false,
            completion: completion
        )
        return task
    }

    func testConnection(completion: @escaping @MainActor @Sendable (Bool, String) -> Void) {
        guard let context = makeRequestContext(text: "我想用配森解析杰森文件。") else {
            Task { @MainActor in
                completion(false, "Missing API settings")
            }
            return
        }
        let codec = LLMProviderCodecRegistry.codec(for: context.provider)

        @Sendable
        func attempt(context: LLMRefinerRequestContext, didFallbackStructured: Bool) {
            let textRequest = makeTextRequest(context: context)
            guard let request = try? codec.makeRequest(
                request: textRequest,
                endpoint: context.baseURL,
                apiKey: context.apiKey,
                timeout: context.timeout
            ) else {
                Task { @MainActor in
                    completion(false, "Missing API settings")
                }
                return
            }

            urlSession.dataTask(with: request) { data, response, error in
                if let error {
                    Task { @MainActor in
                        completion(false, error.localizedDescription)
                    }
                    return
                }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode)
                else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let providerError = codec.classifyError(statusCode: statusCode, data: data)
                    if textRequest.outputFormat == .correctedTextJSON,
                       providerError.isStructuredOutputUnsupported,
                       !didFallbackStructured {
                        self.capabilityState.markStructuredOutputUnsupported(
                            provider: context.provider,
                            model: context.model
                        )
                        var fallbackContext = context
                        fallbackContext.outputFormat = .plainText
                        attempt(
                            context: fallbackContext,
                            didFallbackStructured: true
                        )
                        return
                    }
                    Task { @MainActor in
                        completion(false, "HTTP \(statusCode): \(providerError.displayMessage)")
                    }
                    return
                }
                guard let data,
                      data.count < 512_000,
                      let parsed = try? codec.parseResponse(
                        data: data,
                        httpResponse: http,
                        outputFormat: textRequest.outputFormat
                      ),
                      !parsed.text.isEmpty
                else {
                    Task { @MainActor in
                        completion(false, "Empty or invalid response")
                    }
                    return
                }
                Task { @MainActor in
                    completion(true, "Connection OK (\(parsed.model ?? self.settings.model))")
                }
            }.resume()
        }

        attempt(context: context, didFallbackStructured: false)
    }

    func makeRequest(text: String, speechContext: SpeechFocusContext? = nil) -> URLRequest? {
        guard let context = makeRequestContext(text: text, speechContext: speechContext) else {
            return nil
        }
        let codec = LLMProviderCodecRegistry.codec(for: context.provider)
        return try? codec.makeRequest(
            request: makeTextRequest(context: context),
            endpoint: context.baseURL,
            apiKey: context.apiKey,
            timeout: context.timeout
        )
    }

    func makeRequestContext(text: String, speechContext: SpeechFocusContext? = nil) -> LLMRefinerRequestContext? {
        guard let base = URL(string: settings.apiBaseURL),
              isAllowedBaseURL(base),
              !settings.apiKey.isEmpty
        else {
            return nil
        }

        let provider = settings.llmProvider
        let codec = LLMProviderCodecRegistry.codec(for: provider)
        let stylePack = stylePacks.activePack()
        let promptContext = PromptStaticContextCache.context(stylePack: stylePack)
        let maxOutputTokens = maxTokens(for: text)
        let format = outputFormat(provider: provider, codec: codec, model: settings.model)

        // Log counts only. System prompts, transcripts, model output, and API keys can all contain
        // private text, but these numbers are enough to confirm output budgeting uses user text
        // separately from the prompt.
        DebugLog.event("llmRequestShape:provider=\(provider.rawValue):model=\(settings.model):systemChars=\(promptContext.systemPrompt.count):userChars=\(text.count):maxOutputTokens=\(maxOutputTokens)")
        return LLMRefinerRequestContext(
            provider: provider,
            baseURL: base,
            apiKey: settings.apiKey,
            model: settings.model,
            timeout: effectiveTimeout(),
            maxOutputTokens: maxOutputTokens,
            systemPrompt: makeSystemPrompt(promptContext: promptContext, speechContext: speechContext),
            transcript: text,
            outputFormat: format
        )
    }

    func rejectionReason(
        original: String,
        corrected rawCorrected: String,
        finishReason: String?
    ) -> CorrectionRejectionReason? {
        guard finishReason != "length" else {
            return .finishLength
        }
        let corrected = rawCorrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty else {
            return .empty
        }

        let originalCount = original.count
        let correctedCount = corrected.count
        guard !Self.lostChineseLanguage(original: original, corrected: corrected) else {
            return .languageChanged
        }
        guard correctedCount <= max(32, Int(Double(originalCount) * 1.8)) else {
            return .tooLong
        }

        // ponytail: exact edit-ratio check only for normal dictation snippets; very long text
        // falls back to length bounds so correction never becomes an O(n^2) surprise.
        guard max(originalCount, correctedCount) <= 300 else {
            return nil
        }
        return editDistanceRatio(original, corrected) <= 0.8 ? nil : .editRatio
    }

    private static func lostChineseLanguage(original: String, corrected: String) -> Bool {
        containsCJK(original)
            && !containsCJK(corrected)
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
    }

    func maxTokens(for text: String) -> Int {
        // This is an output budget, so it intentionally depends only on the user transcript.
        // The system prompt has its own context cost and must not inflate completion tokens.
        // OpenRouter Free can still route to models that spend output tokens on preamble; the
        // acceptance checks below reject rambling or meaning-changing output.
        min(4096, max(192, text.count * 4))
    }

    func effectiveTimeout() -> TimeInterval {
        // OpenRouter Free randomly routes to free models, and some are slow enough that a 12 second
        // timeout causes frequent silent fallbacks. Keep the UI value for paid/stable providers,
        // but give the free router enough room to prove whether polishing actually works.
        settings.llmProvider == .openRouterFree ? max(settings.requestTimeout, 25) : settings.requestTimeout
    }

    private func outputFormat(
        provider: LLMProvider,
        codec: any LLMProviderCodec,
        model: String
    ) -> LLMOutputFormat {
        guard capabilityState.supportsStructuredOutput(provider: provider, model: model),
              codec.supports(outputFormat: .correctedTextJSON, model: model)
        else {
            return .plainText
        }
        return .correctedTextJSON
    }

    private func makeSystemPrompt(
        promptContext: PromptStaticContext,
        speechContext: SpeechFocusContext?
    ) -> String {
        speechContext?.promptSection.map { "\(promptContext.systemPrompt)\n\n\($0)" }
            ?? promptContext.systemPrompt
    }

    private func makeTextRequest(context: LLMRefinerRequestContext) -> LLMTextRequest {
        LLMTextRequest(
            model: context.model,
            systemPrompt: context.systemPrompt,
            userText: context.transcript,
            temperature: nil,
            maxOutputTokens: context.maxOutputTokens,
            outputFormat: context.outputFormat
        )
    }

    func normalizeModelOutput(_ output: String) -> String {
        var value = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Free OpenAI-compatible routers often return a helpful label even when the prompt asks
        // for text only. Strip only boring wrappers; the stricter length/edit checks still decide
        // whether the correction is safe enough to paste.
        let prefixes = [
            "Corrected text:",
            "Corrected:",
            "Output:",
            "Result:",
            "修正后：",
            "修正结果：",
            "结果："
        ]
        if let prefix = prefixes.first(where: {
            value.range(of: $0, options: [.caseInsensitive, .anchored]) != nil
        }) {
            value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if value.hasPrefix("```"), value.hasSuffix("```") {
            value = value
                .replacingOccurrences(of: "```text", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let matchingQuotes: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’")]
        if let first = value.first,
           let last = value.last,
           matchingQuotes.contains(where: { $0.0 == first && $0.1 == last })
        {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private func runProviderAttempt(
        codec: any LLMProviderCodec,
        context: LLMRefinerRequestContext,
        originalText: String,
        trimmedText: String,
        metrics: RefinementMetrics,
        task: LLMRefinementTask,
        didFallbackStructured: Bool,
        completion: @escaping @MainActor @Sendable (String) -> Void
    ) {
        let textRequest = makeTextRequest(context: context)
        guard !task.isCancelled,
              let request = try? codec.makeRequest(
                request: textRequest,
                endpoint: context.baseURL,
                apiKey: context.apiKey,
                timeout: context.timeout
              )
        else {
            complete(originalText, task: task, completion: completion)
            return
        }

        let delegate = TimedLLMRequestDelegate(metrics: metrics) { [weak self] data, response, error, metrics in
            guard let self, !task.isCancelled else {
                return
            }

            DebugLog.event(metrics.summaryLine())
            if let error {
                DebugLog.event("llmRefineFallback:error:\(error._code)")
                self.complete(originalText, task: task, completion: completion)
                return
            }

            guard let http = response as? HTTPURLResponse else {
                DebugLog.event("llmRefineFallback:noHTTPResponse")
                self.complete(originalText, task: task, completion: completion)
                return
            }

            guard (200..<300).contains(http.statusCode) else {
                let providerError = codec.classifyError(statusCode: http.statusCode, data: data)
                if textRequest.outputFormat == .correctedTextJSON,
                   providerError.isStructuredOutputUnsupported,
                   !didFallbackStructured {
                    self.capabilityState.markStructuredOutputUnsupported(
                        provider: context.provider,
                        model: context.model
                    )
                    var fallbackContext = context
                    fallbackContext.outputFormat = .plainText
                    DebugLog.event("llmRefineFallback:structuredUnsupported")
                    self.runProviderAttempt(
                        codec: codec,
                        context: fallbackContext,
                        originalText: originalText,
                        trimmedText: trimmedText,
                        metrics: metrics,
                        task: task,
                        didFallbackStructured: true,
                        completion: completion
                    )
                    return
                }
                DebugLog.event("llmRefineFallback:http\(http.statusCode):\(providerError.displayMessage)")
                self.complete(originalText, task: task, completion: completion)
                return
            }

            guard let data, data.count < 512_000 else {
                DebugLog.event("llmRefineFallback:badBody")
                self.complete(originalText, task: task, completion: completion)
                return
            }
            guard let parsed = try? codec.parseResponse(
                data: data,
                httpResponse: http,
                outputFormat: textRequest.outputFormat
            ) else {
                DebugLog.event("llmRefineFallback:decode")
                self.complete(originalText, task: task, completion: completion)
                return
            }
            DebugLog.event("llmRefineResponse:\(context.provider.rawValue):\(parsed.model ?? "unknown"):\(parsed.finishReason ?? "unknown")")

            let normalized = self.normalizeModelOutput(parsed.text)
            let rejectionReason = self.rejectionReason(
                original: trimmedText,
                corrected: normalized,
                finishReason: parsed.finishReason
            )
            guard rejectionReason == nil else {
                DebugLog.event("llmRefineFallback:rejected:\(rejectionReason?.rawValue ?? "unknown"):originalChars=\(trimmedText.count):correctedChars=\(normalized.count):finishReason=\(parsed.finishReason ?? "nil")")
                self.complete(originalText, task: task, completion: completion)
                return
            }
            DebugLog.event("llmRefineCompleted")
            self.complete(normalized, task: task, completion: completion)
        }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: queue)

        DebugLog.event("llmHTTPStart")
        let dataTask = session.dataTask(with: request)
        task.setCurrentTask(dataTask)
        dataTask.resume()
    }

    private func complete(
        _ text: String,
        task: LLMRefinementTask,
        completion: @escaping @MainActor @Sendable (String) -> Void
    ) {
        guard !task.isCancelled else {
            return
        }
        Task { @MainActor in
            guard !task.isCancelled else {
                return
            }
            completion(text)
        }
    }

    private func isAllowedBaseURL(_ url: URL) -> Bool {
        if url.scheme == "https" {
            return true
        }
        let host = url.host?.lowercased()
        return url.scheme == "http" && (host == "localhost" || host == "127.0.0.1" || host == "::1")
    }

    private func editDistanceRatio(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(lhs)
        let b = Array(rhs)
        guard !a.isEmpty || !b.isEmpty else {
            return 0
        }
        var previous = Array(0...b.count)
        var current = previous
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return Double(previous[b.count]) / Double(max(a.count, b.count))
    }
}

private final class TimedLLMRequestDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let completion: @Sendable (Data?, URLResponse?, Error?, RefinementMetrics) -> Void
    private let clock = ContinuousClock()
    private var metrics: RefinementMetrics
    private var body = Data()

    init(
        metrics: RefinementMetrics,
        completion: @escaping @Sendable (Data?, URLResponse?, Error?, RefinementMetrics) -> Void
    ) {
        self.metrics = metrics
        self.completion = completion
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // TTFB is measured at the first response body byte. That is close enough for the product
        // question here: high TTFB means network/provider/model queue, while low TTFB with a long
        // completion tail means generation speed or output length.
        if metrics.firstByteAt == nil {
            metrics.firstByteAt = clock.now
            DebugLog.event("llmHTTPFirstByte")
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        metrics.completedAt = clock.now
        DebugLog.event("llmHTTPComplete")
        completion(body, task.response, error, metrics)
        session.finishTasksAndInvalidate()
    }
}
