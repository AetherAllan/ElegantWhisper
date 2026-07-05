import Foundation

struct OpenRouterProvider: LLMProviderClient {
    private let capabilityCache: ProviderCapabilityCache

    init(capabilityCache: ProviderCapabilityCache = .shared) {
        self.capabilityCache = capabilityCache
    }

    func firstMode(for context: LLMProviderRequestContext) -> LLMProviderRequestMode {
        capabilityCache.supportsStructuredOutput(for: context.provider, model: context.model)
            ? .structuredOutput
            : .plainText
    }

    func makeRequest(context: LLMProviderRequestContext, mode: LLMProviderRequestMode) -> URLRequest? {
        var request = baseRequest(context: context)
        let body = ChatRequest(
            model: context.model,
            messages: context.promptContext.messages(transcript: context.transcript, speechContext: context.speechContext),
            maxTokens: context.maxOutputTokens,
            reasoning: ChatReasoning(effort: "none", exclude: true),
            responseFormat: mode == .structuredOutput ? .dictationPolishResult : nil
        )
        request.httpBody = try? JSONEncoder().encode(body)
        return request
    }

    func fallbackMode(
        afterHTTPStatus statusCode: Int,
        data: Data?,
        mode: LLMProviderRequestMode,
        context: LLMProviderRequestContext
    ) -> LLMProviderRequestMode? {
        guard mode == .structuredOutput,
              Self.isStructuredOutputUnsupported(statusCode: statusCode, data: data)
        else {
            return nil
        }
        capabilityCache.markStructuredOutputUnsupported(provider: context.provider, model: context.model)
        return .plainText
    }

    func parseResponse(data: Data, mode: LLMProviderRequestMode) -> LLMProviderParsedResponse? {
        guard let response = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let choice = response.choices.first
        else {
            return nil
        }

        let rawContent = choice.message.content ?? ""
        let candidate: String
        if mode == .structuredOutput,
           let decoded = try? JSONDecoder().decode(DictationPolishResult.self, from: Data(rawContent.utf8))
        {
            candidate = decoded.correctedText
        } else {
            // Structured decode failure is a provider/model problem, not a paste-safety bypass.
            // Return the raw content and let LLMRefiner's existing validator reject unsafe output.
            candidate = rawContent
        }

        return LLMProviderParsedResponse(
            candidateText: candidate,
            finishReason: choice.finishReason,
            model: response.model,
            provider: response.provider
        )
    }

    static func isStructuredOutputUnsupported(statusCode: Int, data: Data?) -> Bool {
        guard statusCode == 400 else {
            return false
        }
        let message = LLMProviderErrorReason.message(data)
        return (message.contains("response_format") || message.contains("json_schema") || message.contains("structured"))
            && (message.contains("unsupported") || message.contains("invalid"))
    }
}
