import Foundation

struct InferenceNetCodec: LLMProviderCodec {
    private let plainBase = OpenAICompatibleCodec()
    private let structuredBase = OpenAICompatibleCodec(
        correctedTextDescription: "Corrected direct-insertion text in the same language as the user transcript. Chinese input must stay Chinese. Do not include instructions, labels, JSON reminders, or explanations."
    )

    func makeRequest(
        request: LLMTextRequest,
        endpoint: URL,
        apiKey: String,
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard request.outputFormat == .correctedTextJSON else {
            return try plainBase.makeRequest(request: request, endpoint: endpoint, apiKey: apiKey, timeout: timeout)
        }

        // Schematron is tuned as an extraction model. A short instruction keeps it from copying
        // long style-pack rules into corrected_text while still letting normal providers use the
        // full style prompt through OpenAICompatibleCodec.
        let schematronRequest = LLMTextRequest(
            model: request.model,
            systemPrompt: Self.structuredSystemPrompt(from: request.systemPrompt),
            userText: request.userText,
            temperature: request.temperature,
            maxOutputTokens: request.maxOutputTokens,
            outputFormat: .correctedTextJSON
        )
        return try structuredBase.makeRequest(
            request: schematronRequest,
            endpoint: endpoint,
            apiKey: apiKey,
            timeout: timeout
        )
    }

    func parseResponse(
        data: Data,
        httpResponse: HTTPURLResponse,
        outputFormat: LLMOutputFormat
    ) throws -> LLMTextResponse {
        try (outputFormat == .correctedTextJSON ? structuredBase : plainBase)
            .parseResponse(data: data, httpResponse: httpResponse, outputFormat: outputFormat)
    }

    func classifyError(statusCode: Int, data: Data?) -> LLMProviderError {
        plainBase.classifyError(statusCode: statusCode, data: data)
    }

    func supports(outputFormat: LLMOutputFormat, model: String) -> Bool {
        switch outputFormat {
        case .plainText:
            true
        case .correctedTextJSON:
            model.lowercased().hasPrefix("inference-net/schematron-v2")
        }
    }

    private static func structuredSystemPrompt(from systemPrompt: String) -> String {
        var prompt = """
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

        if let localContext = localContextSection(from: systemPrompt) {
            prompt += "\n\n\(localContext)"
        }
        return prompt
    }

    private static func localContextSection(from systemPrompt: String) -> String? {
        // SpeechFocusContext owns the exact "Local context:" section text. Schematron gets only
        // that section plus the short extraction prompt, not the full editable style-pack prompt.
        guard let range = systemPrompt.range(of: "\n\nLocal context:\n", options: .backwards) else {
            return nil
        }
        return String(systemPrompt[range.upperBound...]).isEmpty
            ? nil
            : "Local context:\n\(systemPrompt[range.upperBound...])"
    }
}
