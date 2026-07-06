import Foundation

struct OpenRouterCodec: LLMProviderCodec {
    private let base = OpenAICompatibleCodec()

    func makeRequest(
        request: LLMTextRequest,
        endpoint: URL,
        apiKey: String,
        timeout: TimeInterval
    ) throws -> URLRequest {
        var urlRequest = try base.makeRequest(
            request: request,
            endpoint: endpoint,
            apiKey: apiKey,
            timeout: timeout
        )
        // ponytail: OpenRouter-only field; patch after encode instead of threading through LLMTextRequest.
        var body = try JSONSerialization.jsonObject(with: urlRequest.httpBody!) as! [String: Any]
        body["reasoning"] = ["effort": Self.reasoningEffort(for: request.model)]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.setValue("https://github.com/AetherAllan/ElegantWhisper", forHTTPHeaderField: "HTTP-Referer")
        urlRequest.setValue(AppConstants.productName, forHTTPHeaderField: "X-Title")
        return urlRequest
    }

    func parseResponse(
        data: Data,
        httpResponse: HTTPURLResponse,
        outputFormat: LLMOutputFormat
    ) throws -> LLMTextResponse {
        try base.parseResponse(data: data, httpResponse: httpResponse, outputFormat: outputFormat)
    }

    func classifyError(statusCode: Int, data: Data?) -> LLMProviderError {
        base.classifyError(statusCode: statusCode, data: data)
    }

    func supports(outputFormat: LLMOutputFormat, model: String) -> Bool {
        switch outputFormat {
        case .plainText:
            true
        case .correctedTextJSON:
            Self.structuredOutputAllowlist.contains(model)
        }
    }

    private static let structuredOutputAllowlist: Set<String> = [
        "nvidia/nemotron-3-nano-30b-a3b:free"
    ]

    private static func reasoningEffort(for model: String) -> String {
        // GPT-OSS free endpoints reject effort "none"; low keeps reasoning short enough to polish.
        model.lowercased().hasPrefix("openai/gpt-oss") ? "low" : "none"
    }
}
