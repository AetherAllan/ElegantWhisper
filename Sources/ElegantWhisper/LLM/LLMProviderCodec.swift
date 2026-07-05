import Foundation

protocol LLMProviderCodec: Sendable {
    func makeRequest(
        request: LLMTextRequest,
        endpoint: URL,
        apiKey: String,
        timeout: TimeInterval
    ) throws -> URLRequest

    func parseResponse(
        data: Data,
        httpResponse: HTTPURLResponse,
        outputFormat: LLMOutputFormat
    ) throws -> LLMTextResponse

    func classifyError(statusCode: Int, data: Data?) -> LLMProviderError
    func supports(outputFormat: LLMOutputFormat, model: String) -> Bool
}

enum LLMProviderCodecRegistry {
    static func codec(for provider: LLMProvider) -> any LLMProviderCodec {
        switch provider {
        case .openAI:
            OpenAICompatibleCodec()
        case .custom:
            OpenAICompatibleCodec(supportsStructuredOutput: false)
        case .openRouterFree:
            OpenRouterCodec()
        case .inferenceNet:
            InferenceNetCodec()
        }
    }
}

extension LLMProviderCodec {
    func completionsURL(from base: URL) -> URL {
        if base.path.trimmingCharacters(in: .init(charactersIn: "/")).hasSuffix("chat/completions") {
            return base
        }
        return base.appendingPathComponent("chat/completions")
    }
}
