import Foundation

struct InferenceNetProvider: LLMProviderClient {
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
            messages: mode == .structuredOutput
                ? Self.structuredMessages(context: context)
                : context.promptContext.messages(transcript: context.transcript, speechContext: context.speechContext),
            maxTokens: context.maxOutputTokens,
            reasoning: nil,
            responseFormat: mode == .structuredOutput ? Self.responseFormat : nil
        )
        request.httpBody = try? JSONEncoder().encode(body)
        return request
    }

    private static func structuredMessages(context: LLMProviderRequestContext) -> [ChatMessage] {
        var system = """
        You are a dictation post-processor for a macOS voice input app.
        Extract the corrected dictation text from the user's raw speech transcript.
        Respond in JSON format.

        Rules:
        - Put only the final direct-insertion text in corrected_text.
        - Preserve the user's intended meaning and original language, including mixed Chinese-English input.
        - Never translate. If the transcript is Chinese, corrected_text must be Chinese. If it is mixed Chinese-English, keep the same mix.
        - Fix obvious ASR mistakes, Chinese homophones, punctuation, spacing, and spoken technical terms.
        - Clean obvious speech disfluencies when they do not change meaning: collapse repeated fillers such as 这个这个, 因为因为, 我觉得我觉得, and remove filler words such as 就是, 然后, 这个 when they only mark hesitation.
        - Do not answer questions, add facts, translate, summarize, or explain.
        - Do not include instructions, labels, markdown, schema reminders, or validation text in corrected_text.
        - Prefer canonical technical spellings for obvious ASR near-sounds: Web3, TypeScript, JavaScript, SQL, Python, JSON, API, SDK, CLI, GitHub, npm, Node.js, React, Swift, SwiftUI, AppKit, Xcode, Cursor, Codex, OpenAI, OpenRouter.

        Example:
        transcript: 一个喜欢健身的人，但是平时不太喜欢吃蔬菜，因为因为我觉得我觉得还是蛋白质更好吃
        corrected_text: 一个喜欢健身的人，但是平时不太喜欢吃蔬菜，因为我觉得蛋白质更好吃。
        """

        if let speechContext = context.speechContext?.promptSection {
            // Inference.net's Schematron models are extraction-oriented. Keep hints in the
            // instruction message and leave the user message as the transcript only, otherwise the
            // model may extract our rules instead of the dictated text.
            system += "\n\n\(speechContext)"
        }

        return [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: context.transcript)
        ]
    }

    private static let responseFormat = ResponseFormat(
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
                        description: "Corrected direct-insertion text in the same language as the user transcript. Chinese input must stay Chinese. Do not include instructions, labels, JSON reminders, or explanations."
                    )
                ]
            )
        )
    )

    func fallbackMode(
        afterHTTPStatus statusCode: Int,
        data: Data?,
        mode: LLMProviderRequestMode,
        context: LLMProviderRequestContext
    ) -> LLMProviderRequestMode? {
        guard mode == .structuredOutput,
              OpenRouterProvider.isStructuredOutputUnsupported(statusCode: statusCode, data: data)
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
            candidate = rawContent
        }

        return LLMProviderParsedResponse(
            candidateText: candidate,
            finishReason: choice.finishReason,
            model: response.model,
            provider: response.provider
        )
    }
}
