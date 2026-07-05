import Foundation

enum LLMProviderRequestMode: Equatable, Sendable {
    case plainText
    case structuredOutput
}

struct LLMProviderRequestContext: Sendable {
    let provider: LLMProvider
    let baseURL: URL
    let apiKey: String
    let model: String
    let timeout: TimeInterval
    let maxOutputTokens: Int
    let promptContext: PromptStaticContext
    let speechContext: SpeechFocusContext?
    let transcript: String
}

struct LLMProviderParsedResponse: Sendable {
    let candidateText: String
    let finishReason: String?
    let model: String?
    let provider: String?
}

protocol LLMProviderClient: Sendable {
    func firstMode(for context: LLMProviderRequestContext) -> LLMProviderRequestMode
    func makeRequest(context: LLMProviderRequestContext, mode: LLMProviderRequestMode) -> URLRequest?
    func fallbackMode(
        afterHTTPStatus statusCode: Int,
        data: Data?,
        mode: LLMProviderRequestMode,
        context: LLMProviderRequestContext
    ) -> LLMProviderRequestMode?
    func parseResponse(data: Data, mode: LLMProviderRequestMode) -> LLMProviderParsedResponse?
}

extension LLMProviderClient {
    func fallbackMode(
        afterHTTPStatus statusCode: Int,
        data: Data?,
        mode: LLMProviderRequestMode,
        context: LLMProviderRequestContext
    ) -> LLMProviderRequestMode? {
        nil
    }

    func completionsURL(from base: URL) -> URL {
        if base.path.trimmingCharacters(in: .init(charactersIn: "/")).hasSuffix("chat/completions") {
            return base
        }
        return base.appendingPathComponent("chat/completions")
    }

    func baseRequest(context: LLMProviderRequestContext) -> URLRequest {
        var request = URLRequest(url: completionsURL(from: context.baseURL), timeoutInterval: context.timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(context.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        context.provider.applyHeaders(to: &request)
        return request
    }
}

enum LLMProviderErrorReason {
    static func classify(_ data: Data?) -> String? {
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

    static func message(_ data: Data?) -> String {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any]
        else {
            return ""
        }
        return [error["message"], error["code"]]
            .compactMap { $0.map(String.init(describing:)) }
            .joined(separator: " ")
            .lowercased()
    }
}

final class LLMRefinementTask: @unchecked Sendable {
    private let lock = NSLock()
    private var currentTask: URLSessionDataTask?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func setCurrentTask(_ task: URLSessionDataTask) {
        lock.lock()
        if cancelled {
            lock.unlock()
            task.cancel()
            return
        }
        currentTask = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = currentTask
        currentTask = nil
        lock.unlock()
        task?.cancel()
    }
}

struct ChatMessage: Codable {
    let role: String
    let content: String?
}

struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let maxTokens: Int
    let reasoning: ChatReasoning?
    let responseFormat: ResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case reasoning
        case responseFormat = "response_format"
    }
}

struct ChatReasoning: Encodable {
    let effort: String
    let exclude: Bool
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
