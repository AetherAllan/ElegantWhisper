import Foundation

struct OpenAICompatibleCodec: LLMProviderCodec {
    private let supportsStructuredOutput: Bool
    private let correctedTextDescription: String

    init(
        supportsStructuredOutput: Bool = true,
        correctedTextDescription: String = "The corrected dictation text only. No explanation."
    ) {
        self.supportsStructuredOutput = supportsStructuredOutput
        self.correctedTextDescription = correctedTextDescription
    }

    func makeRequest(
        request: LLMTextRequest,
        endpoint: URL,
        apiKey: String,
        timeout: TimeInterval
    ) throws -> URLRequest {
        var urlRequest = URLRequest(url: completionsURL(from: endpoint), timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = OpenAIChatRequest(
            model: request.model,
            messages: [
                ChatMessage(role: "system", content: request.systemPrompt),
                ChatMessage(role: "user", content: request.userText)
            ],
            temperature: request.temperature,
            maxTokens: request.maxOutputTokens,
            responseFormat: request.outputFormat == .correctedTextJSON ? responseFormat : nil
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }

    func parseResponse(
        data: Data,
        httpResponse: HTTPURLResponse,
        outputFormat: LLMOutputFormat
    ) throws -> LLMTextResponse {
        let response = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        guard let choice = response.choices.first else {
            throw LLMCodecError.emptyResponse
        }

        let rawContent = choice.message.content ?? ""
        let text: String
        switch outputFormat {
        case .plainText:
            text = rawContent
        case .correctedTextJSON:
            let payload = try JSONDecoder().decode(CorrectedTextPayload.self, from: Data(rawContent.utf8))
            text = payload.correctedText
        }

        return LLMTextResponse(
            text: text,
            finishReason: choice.finishReason,
            model: response.model,
            usage: response.usage.map {
                LLMUsage(
                    promptTokens: $0.promptTokens,
                    completionTokens: $0.completionTokens,
                    totalTokens: $0.totalTokens
                )
            }
        )
    }

    func classifyError(statusCode: Int, data: Data?) -> LLMProviderError {
        let parsed = Self.providerErrorMessage(data)
        let lower = Self.providerErrorSearchText(data).lowercased()
        if lower.contains("free-models-per-day") {
            return .freeDailyLimit
        }
        if lower.contains("rate limit") {
            return .rateLimit
        }
        if statusCode == 400,
           (lower.contains("response_format") || lower.contains("json_schema") || lower.contains("structured")),
           (lower.contains("unsupported") || lower.contains("invalid"))
        {
            return .structuredOutputUnsupported(parsed.isEmpty ? "structured output unsupported" : parsed)
        }
        return parsed.isEmpty ? .requestFailed : .providerMessage(String(parsed.prefix(180)))
    }

    func supports(outputFormat: LLMOutputFormat, model: String) -> Bool {
        switch outputFormat {
        case .plainText:
            true
        case .correctedTextJSON:
            supportsStructuredOutput
        }
    }

    private var responseFormat: ResponseFormat {
        ResponseFormat(
            type: "json_schema",
            jsonSchema: JSONSchemaResponseFormat(
                name: "dictation_polish_result",
                strict: true,
                schema: JSONSchemaObject(
                    type: "object",
                    additionalProperties: false,
                    required: ["corrected_text"],
                    properties: [
                        "corrected_text": JSONSchemaProperty(
                            type: "string",
                            description: correctedTextDescription
                        )
                    ]
                )
            )
        )
    }

    private static func providerErrorMessage(_ data: Data?) -> String {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String
        else {
            return ""
        }
        return message
    }

    private static func providerErrorSearchText(_ data: Data?) -> String {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any]
        else {
            return ""
        }
        return [error["message"], error["code"]]
            .compactMap { $0.map(String.init(describing:)) }
            .joined(separator: " ")
    }
}

enum LLMCodecError: Error {
    case emptyResponse
}

private struct OpenAIChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double?
    let maxTokens: Int
    let responseFormat: ResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
    }
}

private struct ResponseFormat: Encodable {
    let type: String
    let jsonSchema: JSONSchemaResponseFormat

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }
}

private struct JSONSchemaResponseFormat: Encodable {
    let name: String
    let strict: Bool
    let schema: JSONSchemaObject
}

private struct JSONSchemaObject: Encodable {
    let type: String
    let additionalProperties: Bool
    let required: [String]
    let properties: [String: JSONSchemaProperty]
}

private struct JSONSchemaProperty: Encodable {
    let type: String
    let description: String?
}

private struct CorrectedTextPayload: Decodable {
    let correctedText: String

    enum CodingKeys: String, CodingKey {
        case correctedText = "corrected_text"
    }
}

private struct OpenAIChatResponse: Decodable {
    let model: String?
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Decodable {
        let message: ChatMessage
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}
