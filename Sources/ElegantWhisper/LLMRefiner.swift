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
    case editRatio
    case finishLength
}

final class LLMRefiner: Sendable {
    private let settings: SettingsStore
    private let stylePacks: StylePackStore

    init(settings: SettingsStore, stylePacks: StylePackStore = .shared) {
        self.settings = settings
        self.stylePacks = stylePacks
    }

    @discardableResult
    func refine(
        _ text: String,
        hotwords: [String] = [],
        asrFinalizedIn: Duration? = nil,
        completion: @escaping @MainActor @Sendable (String) -> Void
    ) -> URLSessionDataTask? {
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
              let request = makeRequest(text: trimmed, hotwords: hotwords)
        else {
            DebugLog.event("llmRefineSkippedMissingSettings")
            Task { @MainActor in
                completion(text)
            }
            return nil
        }

        let requestStartedAt = ContinuousClock().now
        let metrics = RefinementMetrics(asrFinalizedIn: asrFinalizedIn, requestStartedAt: requestStartedAt)
        let delegate = TimedLLMRequestDelegate(metrics: metrics) { data, response, error, metrics in
            DebugLog.event(metrics.summaryLine())
            if let error {
                DebugLog.event("llmRefineFallback:error:\(error._code)")
                Task { @MainActor in
                    completion(text)
                }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                DebugLog.event("llmRefineFallback:noHTTPResponse")
                Task { @MainActor in
                    completion(text)
                }
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                DebugLog.event("llmRefineFallback:http\(http.statusCode):\(self.providerErrorReason(from: data) ?? "unknown")")
                Task { @MainActor in
                    completion(text)
                }
                return
            }
            guard let data, data.count < 512_000 else {
                DebugLog.event("llmRefineFallback:badBody")
                Task { @MainActor in
                    completion(text)
                }
                return
            }
            guard let response = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
                DebugLog.event("llmRefineFallback:decode")
                Task { @MainActor in
                    completion(text)
                }
                return
            }
            guard let choice = response.choices.first else {
                DebugLog.event("llmRefineFallback:noChoice")
                Task { @MainActor in
                    completion(text)
                }
                return
            }
            DebugLog.event("llmRefineResponse:\(response.provider ?? "unknown"):\(response.model ?? "unknown"):\(choice.finishReason ?? "unknown")")
            guard let correction = self.acceptedCorrection(original: trimmed, choice: choice) else {
                DebugLog.event("llmRefineFallback:rejected:\(self.rejectionReason(original: trimmed, choice: choice)?.rawValue ?? "unknown")")
                Task { @MainActor in
                    completion(text)
                }
                return
            }
            DebugLog.event("llmRefineCompleted")
            Task { @MainActor in
                completion(correction)
            }
        }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: queue)

        DebugLog.event("llmRefineStarted")
        DebugLog.event("llmHTTPStart")
        let task = session.dataTask(with: request)
        task.resume()
        return task
    }

    func testConnection(completion: @escaping @MainActor @Sendable (Bool, String) -> Void) {
        guard let request = makeRequest(text: "我想用配森解析杰森文件。", hotwords: ["Python", "JSON"]) else {
            Task { @MainActor in
                completion(false, "Missing API settings")
            }
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
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
                let reason = self.providerErrorReason(from: data) ?? "request failed"
                Task { @MainActor in
                    completion(false, "HTTP \(statusCode): \(reason)")
                }
                return
            }
            guard let data,
                  data.count < 512_000,
                  let response = try? JSONDecoder().decode(ChatResponse.self, from: data),
                  response.choices.first?.message.content?.isEmpty == false
            else {
                Task { @MainActor in
                    completion(false, "Empty or invalid response")
                }
                return
            }
            Task { @MainActor in
                completion(true, "Connection OK (\(response.model ?? self.settings.model))")
            }
        }.resume()
    }

    func makeRequest(text: String, hotwords: [String] = []) -> URLRequest? {
        guard let base = URL(string: settings.apiBaseURL),
              isAllowedBaseURL(base),
              !settings.apiKey.isEmpty
        else {
            return nil
        }

        let url = completionsURL(from: base)
        let provider = settings.llmProvider
        let stylePack = stylePacks.activePack()
        let systemPrompt = LLMPromptBuilder.systemPrompt(stylePack: stylePack, hotwords: hotwords)
        let maxOutputTokens = maxTokens(for: text)
        var request = URLRequest(url: url, timeoutInterval: effectiveTimeout())
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        provider.applyHeaders(to: &request)

        let body = ChatRequest(
            model: settings.model,
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: text)
            ],
            temperature: 0,
            maxTokens: maxOutputTokens,
            reasoning: provider.reasoningPolicy
        )

        // Log counts only. System prompts, transcripts, model output, and API keys can all contain
        // private text, but these numbers are enough to confirm output budgeting uses user text
        // separately from the prompt.
        DebugLog.event("llmRequestShape:provider=\(provider.rawValue):model=\(settings.model):systemChars=\(systemPrompt.count):userChars=\(text.count):hotwordCount=\(hotwords.count):maxOutputTokens=\(maxOutputTokens)")
        request.httpBody = try? JSONEncoder().encode(body)
        return request
    }

    func acceptsChoice(original: String, choice: ChatResponse.Choice) -> Bool {
        acceptedCorrection(original: original, choice: choice) != nil
    }

    func acceptedCorrection(original: String, choice: ChatResponse.Choice) -> String? {
        // OpenAI-compatible APIs report `finish_reason=length` when max_tokens cuts the response.
        // A truncated correction is worse than no correction because it can silently drop the end
        // of a dictation before paste. Fall back to the original transcript instead.
        let corrected = normalizeModelOutput(choice.message.content ?? "")
        guard rejectionReason(original: original, corrected: corrected, finishReason: choice.finishReason) == nil else {
            return nil
        }
        return corrected
    }

    func acceptsCorrection(original: String, corrected: String) -> Bool {
        rejectionReason(original: original, corrected: corrected, finishReason: nil) == nil
    }

    func rejectionReason(original: String, choice: ChatResponse.Choice) -> CorrectionRejectionReason? {
        rejectionReason(
            original: original,
            corrected: normalizeModelOutput(choice.message.content ?? ""),
            finishReason: choice.finishReason
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

    func providerErrorReason(from data: Data?) -> String? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String
        else {
            return nil
        }
        let lower = message.lowercased()
        if lower.contains("free-models-per-day") {
            return "free-models-per-day"
        }
        if lower.contains("rate limit") {
            return "rate-limit"
        }
        if lower.contains("invalid") {
            return "invalid-request"
        }
        return "provider-error"
    }

    private func completionsURL(from base: URL) -> URL {
        if base.path.trimmingCharacters(in: .init(charactersIn: "/")).hasSuffix("chat/completions") {
            return base
        }
        return base.appendingPathComponent("chat/completions")
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

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let maxTokens: Int
    let reasoning: ChatReasoning?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case reasoning
    }
}

private struct ChatReasoning: Encodable {
    let effort: String
    let exclude: Bool
}

private extension LLMProvider {
    var reasoningPolicy: ChatReasoning? {
        switch self {
        case .openRouterFree:
            // OpenRouter Free is a random router, so this is only a best-effort hint. Some routed
            // models ignore or reject non-thinking mode; fallback validation still protects paste.
            ChatReasoning(effort: "none", exclude: true)
        case .openAI, .custom:
            nil
        }
    }
}

struct ChatMessage: Codable {
    let role: String
    let content: String?
}

struct ChatResponse: Decodable {
    let model: String?
    let provider: String?
    let choices: [Choice]

    struct Choice: Decodable {
        let message: ChatMessage
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }
}
