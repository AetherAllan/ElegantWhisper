import Foundation

struct PlainTextProviderFallback: LLMProviderClient {
    func firstMode(for context: LLMProviderRequestContext) -> LLMProviderRequestMode {
        .plainText
    }

    func makeRequest(context: LLMProviderRequestContext, mode: LLMProviderRequestMode) -> URLRequest? {
        guard mode == .plainText else {
            return nil
        }
        var request = baseRequest(context: context)
        let body = ChatRequest(
            model: context.model,
            messages: context.promptContext.messages(transcript: context.transcript),
            temperature: 0,
            maxTokens: context.maxOutputTokens,
            reasoning: nil,
            responseFormat: nil
        )
        request.httpBody = try? JSONEncoder().encode(body)
        return request
    }

    func parseResponse(data: Data, mode: LLMProviderRequestMode) -> LLMProviderParsedResponse? {
        guard let response = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let choice = response.choices.first
        else {
            return nil
        }
        return LLMProviderParsedResponse(
            candidateText: choice.message.content ?? "",
            finishReason: choice.finishReason,
            model: response.model,
            provider: response.provider
        )
    }
}
